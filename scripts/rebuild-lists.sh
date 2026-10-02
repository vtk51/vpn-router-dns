#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE/config/router.conf"
: "${LAN_IF:?set LAN_IF in config/router.conf}"
: "${LAN_NET:?set LAN_NET in config/router.conf}"
(( ${#DNS_UPSTREAMS[@]} > 0 )) || { printf 'error: DNS_UPSTREAMS is empty\n' >&2; exit 1; }
# Keep this preflight identical to apply-rules.sh; no commit before validation.
python3 - "$LAN_IF" "$LAN_NET" "${#DNS_UPSTREAMS[@]}" "${DNS_UPSTREAMS[@]}" "${DNS_DIRECT[@]}" <<'PY'
import ipaddress
import re
import sys

interface, cidr, upstream_count, *resolvers = sys.argv[1:]
if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
    raise ValueError('invalid LAN_IF')
network = ipaddress.ip_network(cidr, strict=True)
if network.version != 4 or network.with_prefixlen != cidr:
    raise ValueError('LAN_NET must be a canonical IPv4 CIDR')
for resolver in resolvers:
    if str(ipaddress.IPv4Address(resolver)) != resolver:
        raise ValueError('DNS resolvers must be IPv4 literals')
upstreams = set(resolvers[:int(upstream_count)])
direct = set(resolvers[int(upstream_count):])
if upstreams & direct:
    raise ValueError('DNS_UPSTREAMS and DNS_DIRECT must not overlap')
PY
DOMAINS_FILE="$BASE/lists/vpn-domains.txt"
NETS_FILE="$BASE/lists/vpn-nets.txt"
DNSMASQ_CONF="$BASE/dnsmasq/dnsmasq.conf"
LOCK_FILE="/run/lock/vpn-router-rebuild.lock"
RUNTIME_DIR="/run/vpn-router"
TXN_RECORD="$RUNTIME_DIR/rebuild.transaction"
VPN_DOMAINS="vpn_domains"
VPN_NETS="vpn_nets"

WORK_DIR=""
TEMP_SET=""
TEMP_CREATED=0
PHASE="INIT"
TXID=""
OLD_NETS_FP=""
CANDIDATE_NETS_FP=""
OLD_DNSMASQ_HASH=""
CANDIDATE_DNSMASQ_HASH=""
EXPECTED_NETS=0
EXPECTED_DOMAINS=0
ABORT_PENDING=0
CONFIG_INSTALLED=0
DNSMASQ_RESTARTED=0
KEEP_ARTIFACTS=0
FINALIZED=0
EXIT_HANDLER_RUNNING=0
DNSMASQ_CANDIDATE=""
CANDIDATE_INSTALLED=0
CANDIDATE_CREATED=0
DNSMASQ_ID_BEFORE=""
DNSMASQ_ID_AFTER=""

content_hash() {
  sha256sum "$1" | awk '{print $1}'
}

ipset_membership_hash() {
  local set_name="$1"
  ipset save "$set_name" | python3 -c '
import hashlib
import ipaddress
import sys

values = set()
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 3 and parts[0] == "add":
        values.add(ipaddress.ip_network(parts[2], strict=False).with_prefixlen)

payload = "\n".join(sorted(values))
if payload:
    payload += "\n"
print(hashlib.sha256(payload.encode()).hexdigest())
'
}

ipset_address_membership_hash() {
  local set_name="$1"
  ipset save "$set_name" | awk '$1 == "add" {print $3}' | sort -u | sha256sum | awk '{print $1}'
}

ipset_entry_count() {
  ipset list "$1" | awk '$1 == "Number" && $2 == "of" && $3 == "entries:" {value=$4} END {print value}'
}

ipset_references() {
  ipset list "$1" | awk '$1 == "References:" {value=$2} END {print value}'
}

write_record() {
  local next_phase="$1"
  local record_tmp="$TXN_RECORD.tmp.$TXID"

  PHASE="$next_phase"
  {
    printf 'transaction_id=%s\n' "$TXID"
    printf 'phase=%s\n' "$PHASE"
    printf 'temporary_set=%s\n' "$TEMP_SET"
    printf 'work_dir=%s\n' "$WORK_DIR"
    printf 'dnsmasq_candidate=%s\n' "$DNSMASQ_CANDIDATE"
    printf 'old_vpn_nets_fingerprint=%s\n' "$OLD_NETS_FP"
    printf 'candidate_vpn_nets_fingerprint=%s\n' "$CANDIDATE_NETS_FP"
    printf 'old_dnsmasq_config_hash=%s\n' "$OLD_DNSMASQ_HASH"
    printf 'candidate_dnsmasq_config_hash=%s\n' "$CANDIDATE_DNSMASQ_HASH"
    printf 'expected_network_count=%s\n' "$EXPECTED_NETS"
    printf 'expected_domain_count=%s\n' "$EXPECTED_DOMAINS"
    printf 'dnsmasq_container_id_before=%s\n' "$DNSMASQ_ID_BEFORE"
    printf 'dnsmasq_container_id_after=%s\n' "$DNSMASQ_ID_AFTER"
  } > "$record_tmp"
  chmod 600 "$record_tmp"
  python3 - "$record_tmp" <<'PY'
import os
import sys

with open(sys.argv[1], 'rb', buffering=0) as record:
    os.fsync(record.fileno())
PY
  mv -f "$record_tmp" "$TXN_RECORD"
  python3 - "$RUNTIME_DIR" <<'PY'
import os
import sys

directory = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

signal_handler() {
  ABORT_PENDING=1
  printf 'signal received; deferred until safe transaction checkpoint (phase=%s)\n' "$PHASE" >&2
}

set_has_expected_membership() {
  local set_name="$1"
  [[ "$(ipset_membership_hash "$set_name")" == "$CANDIDATE_NETS_FP" ]] || return 1
  [[ "$(ipset_entry_count "$set_name")" == "$EXPECTED_NETS" ]] || return 1
}

destroy_owned_candidate() {
  local current_fp recorded_temp_set recorded_candidate_fp
  [[ "$TEMP_CREATED" -eq 1 ]] || return 0
  recorded_temp_set="$(awk -F= '$1 == "temporary_set" {print $2}' "$TXN_RECORD" 2>/dev/null || true)"
  recorded_candidate_fp="$(awk -F= '$1 == "candidate_vpn_nets_fingerprint" {print $2}' "$TXN_RECORD" 2>/dev/null || true)"
  [[ "$recorded_temp_set" == "$TEMP_SET" && "$recorded_candidate_fp" == "$CANDIDATE_NETS_FP" ]] || {
    printf 'preserving temporary set %s: transaction ownership could not be verified\n' "$TEMP_SET" >&2
    KEEP_ARTIFACTS=1
    return 1
  }
  if ! ipset list "$TEMP_SET" >/dev/null 2>&1; then
    printf 'preserving temporary set %s: temporary-set inspection failed\n' "$TEMP_SET" >&2
    KEEP_ARTIFACTS=1
    return 1
  fi
  current_fp="$(ipset_membership_hash "$TEMP_SET" 2>/dev/null || true)"
  if [[ "$PHASE" != "SWAPPED" && "$PHASE" != "DNSMASQ_CONFIG_INSTALLED" &&
        "$PHASE" != "DNSMASQ_COMMITTED" && "$PHASE" != "RECONCILED" &&
        "$PHASE" != "FINALIZING" && "$(ipset_references "$TEMP_SET")" == "0" &&
        "$current_fp" == "$recorded_candidate_fp" &&
        "$(ipset_entry_count "$TEMP_SET")" == "$EXPECTED_NETS" &&
        "$(ipset list "$TEMP_SET" | awk '$1 == "Type:" {value=$2} END {print value}')" == "hash:net" &&
        "$(ipset list "$TEMP_SET" | awk '$1 == "Header:" && /family inet/ {value="inet"} END {print value}')" == "inet" ]]; then
    ipset destroy "$TEMP_SET"
    TEMP_CREATED=0
  elif [[ "$PHASE" == "SWAPPED" || "$PHASE" == "DNSMASQ_CONFIG_INSTALLED" ||
          "$PHASE" == "DNSMASQ_COMMITTED" || "$PHASE" == "RECONCILED" ||
          "$PHASE" == "FINALIZING" ]]; then
    if [[ "$current_fp" == "$OLD_NETS_FP" && "$(ipset_references "$TEMP_SET")" == "0" ]]; then
      return 0
    fi
    printf 'preserving temporary set %s: ownership/content could not be verified\n' "$TEMP_SET" >&2
    KEEP_ARTIFACTS=1
  else
    printf 'preserving temporary set %s: ownership/content could not be verified\n' "$TEMP_SET" >&2
    KEEP_ARTIFACTS=1
  fi
}

rollback_ipset_if_safe() {
  local production_fp temporary_fp

  production_fp="$(ipset_membership_hash "$VPN_NETS" 2>/dev/null || true)"
  temporary_fp="$(ipset_membership_hash "$TEMP_SET" 2>/dev/null || true)"

  if [[ "$production_fp" == "$CANDIDATE_NETS_FP" && "$temporary_fp" == "$OLD_NETS_FP" ]]; then
    ipset swap "$TEMP_SET" "$VPN_NETS"
    [[ "$(ipset_membership_hash "$VPN_NETS")" == "$OLD_NETS_FP" ]] || return 1
    [[ "$(ipset_membership_hash "$TEMP_SET")" == "$CANDIDATE_NETS_FP" ]] || return 1
    write_record ROLLED_BACK
    return 0
  fi

  [[ "$production_fp" == "$OLD_NETS_FP" && "$temporary_fp" == "$CANDIDATE_NETS_FP" ]]
}

restore_dnsmasq_if_safe() {
  local restore_candidate="$WORK_DIR/dnsmasq.conf.restore"

  [[ "$CONFIG_INSTALLED" -eq 1 ]] || return 0
  cp -- "$WORK_DIR/dnsmasq.conf.old" "$restore_candidate"
  chmod --reference="$DNSMASQ_CONF" "$restore_candidate"
  chown --reference="$DNSMASQ_CONF" "$restore_candidate"
  mv -f "$restore_candidate" "$DNSMASQ_CONF"
  if ! recreate_dnsmasq "$OLD_DNSMASQ_HASH" "$EXPECTED_DOMAINS"; then
    write_record DNSMASQ_RECOVERY_FAILED || true
    return 1
  fi
}

verify_dnsmasq() {
  local expected_hash="$1" expected_domains="$2"
  local host_hash container_hash container_domain_rules udp_listeners tcp_listeners

  [[ "$(docker inspect -f '{{.State.Running}}' vpn-router-dns 2>/dev/null || true)" == "true" ]] || return 1
  host_hash="$(content_hash "$DNSMASQ_CONF")"
  container_hash="$(docker exec vpn-router-dns cat /etc/dnsmasq.conf | sha256sum | awk '{print $1}')"
  [[ "$host_hash" == "$expected_hash" && "$container_hash" == "$expected_hash" ]] || return 1
  if ! docker exec vpn-router-dns dnsmasq --test --conf-file=/etc/dnsmasq.conf >/dev/null; then
    return 1
  fi
  container_domain_rules="$(docker exec vpn-router-dns awk 'index($0, "vpn_domains") > 0 {count++} END{print count+0}' /etc/dnsmasq.conf)"
  [[ "$container_domain_rules" == "$expected_domains" ]] || return 1
  udp_listeners="$(ss -H -lun 'sport = :53' 2>/dev/null || true)"
  tcp_listeners="$(ss -H -ltn 'sport = :53' 2>/dev/null || true)"
  [[ "$udp_listeners" == *":53 "* && "$tcp_listeners" == *":53 "* ]]
}

recreate_dnsmasq() {
  local expected_hash="$1" expected_domains="$2"

  DNSMASQ_ID_BEFORE="$(docker inspect -f '{{.Id}}' vpn-router-dns)"
  if ! (cd "$BASE" && docker compose up -d --no-deps --force-recreate dnsmasq); then
    return 1
  fi
  DNSMASQ_ID_AFTER="$(docker inspect -f '{{.Id}}' vpn-router-dns)"
  [[ -n "$DNSMASQ_ID_BEFORE" && -n "$DNSMASQ_ID_AFTER" &&
     "$DNSMASQ_ID_BEFORE" != "$DNSMASQ_ID_AFTER" ]] || return 1
  printf 'dnsmasq container recreated: %s -> %s\n' "$DNSMASQ_ID_BEFORE" "$DNSMASQ_ID_AFTER"
  verify_dnsmasq "$expected_hash" "$expected_domains"
}

recover_before_reconcile() {
  local recovered=1

  set +e
  if [[ "$CONFIG_INSTALLED" -eq 1 ]]; then
    restore_dnsmasq_if_safe || recovered=0
  fi
  rollback_ipset_if_safe || recovered=0
  if [[ "$recovered" -eq 1 ]]; then
    destroy_owned_candidate || recovered=0
  fi
  set -e

  if [[ "$recovered" -eq 1 ]]; then
    rm -f "$TXN_RECORD"
    rm -rf "$WORK_DIR"
    return 0
  fi

  KEEP_ARTIFACTS=1
  return 1
}

exit_handler() {
  local rc="$1"
  ((EXIT_HANDLER_RUNNING)) && return
  EXIT_HANDLER_RUNNING=1
  set +e

  if [[ "$CANDIDATE_CREATED" -eq 1 && "$CANDIDATE_INSTALLED" -eq 0 ]]; then
    rm -f "$DNSMASQ_CANDIDATE"
  fi

  if [[ "$FINALIZED" -eq 1 ]]; then
    [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  elif [[ "$KEEP_ARTIFACTS" -eq 0 && "$PHASE" != "RECONCILE_FAILED" &&
          "$PHASE" != "RECONCILED" && "$PHASE" != "FINALIZING" &&
          "$PHASE" != "DNSMASQ_ABORT_PENDING" &&
          "$PHASE" != "RECONCILE_ABORT_PENDING" &&
          "$PHASE" != "VERIFY_ABORT_PENDING" &&
          "$PHASE" != "FINALIZE_ABORT_PENDING" &&
          "$PHASE" != "FINALIZE_SIGNAL_PENDING" ]]; then
    if [[ "$PHASE" == "COMMITTING" || "$PHASE" == "SWAPPED" ||
          "$PHASE" == "DNSMASQ_CONFIG_INSTALLED" || "$PHASE" == "DNSMASQ_COMMITTED" ]]; then
      recover_before_reconcile >/dev/null 2>&1 || true
    else
      destroy_owned_candidate >/dev/null 2>&1 || true
      rm -f "$TXN_RECORD"
      [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
    fi
  fi

  if [[ "$rc" -ne 0 && "$KEEP_ARTIFACTS" -eq 1 ]]; then
    printf 'transaction artifacts retained: record=%s work_dir=%s temp_set=%s\n' "$TXN_RECORD" "$WORK_DIR" "$TEMP_SET" >&2
  fi
  set +e
  return "$rc"
}

mkdir -p "$RUNTIME_DIR"
exec 9>"$LOCK_FILE"
flock -x 9
trap 'exit_handler $?' EXIT
trap signal_handler INT TERM HUP

if [[ -e "$TXN_RECORD" ]]; then
  if grep -qx 'phase=COMPLETE' "$TXN_RECORD"; then
    completed_temp_set="$(awk -F= '$1 == "temporary_set" {print $2}' "$TXN_RECORD")"
    completed_work_dir="$(awk -F= '$1 == "work_dir" {print $2}' "$TXN_RECORD")"
    if ipset list "$completed_temp_set" >/dev/null 2>&1; then
      printf 'error: completed transaction record still names an existing temporary set: %s\n' "$TXN_RECORD" >&2
      cat "$TXN_RECORD" >&2
      KEEP_ARTIFACTS=1
      exit 1
    fi
    rm -f "$TXN_RECORD"
    [[ -z "$completed_work_dir" ]] || rm -rf "$completed_work_dir"
  else
    printf 'error: unfinished transaction record exists: %s\n' "$TXN_RECORD" >&2
    cat "$TXN_RECORD" >&2
    KEEP_ARTIFACTS=1
    exit 1
  fi
fi

[[ -f "$NETS_FILE" && -f "$DOMAINS_FILE" && -f "$DNSMASQ_CONF" ]] || {
  printf 'error: required source/config file is missing\n' >&2
  exit 1
}

RANDOM_HEX="$(od -An -N4 -tx4 /dev/urandom | tr -d '[:space:]')"
TEMP_SET="vrn_${BASHPID}_${RANDOM_HEX}"
TXID="$(date +%Y%m%d-%H%M%S)-${BASHPID}-${RANDOM_HEX}"
WORK_DIR="$RUNTIME_DIR/rebuild.$TXID"
DNSMASQ_CANDIDATE="$BASE/dnsmasq/dnsmasq.conf.candidate.$TXID"
if [[ -e "$WORK_DIR" || -e "$DNSMASQ_CANDIDATE" ]]; then
  printf 'error: transaction artifact collision for %s\n' "$TXID" >&2
  exit 1
fi
write_record PREPARE

mkdir "$WORK_DIR"
chmod 700 "$WORK_DIR"
cp -- "$NETS_FILE" "$WORK_DIR/vpn-nets.snapshot"
cp -- "$DOMAINS_FILE" "$WORK_DIR/vpn-domains.snapshot"
cp -p -- "$DNSMASQ_CONF" "$WORK_DIR/dnsmasq.conf.old"

NETS_SNAPSHOT="$WORK_DIR/vpn-nets.snapshot"
DOMAINS_SNAPSHOT="$WORK_DIR/vpn-domains.snapshot"
NETS_CANONICAL="$WORK_DIR/vpn-nets.canonical"
DOMAINS_NORMALIZED="$WORK_DIR/vpn-domains.normalized"
if ! (set -o noclobber; : > "$DNSMASQ_CANDIDATE"); then
  printf 'error: unable to create transaction dnsmasq candidate: %s\n' "$DNSMASQ_CANDIDATE" >&2
  KEEP_ARTIFACTS=1
  exit 1
fi
CANDIDATE_CREATED=1

python3 - "$NETS_SNAPSHOT" "$NETS_CANONICAL" "$DOMAINS_SNAPSHOT" "$DOMAINS_NORMALIZED" <<'PY'
import ipaddress
import re
import sys
from pathlib import Path

nets_source, nets_output, domains_source, domains_output = sys.argv[1:]

def source_values(path):
    values = []
    for raw in Path(path).read_text().splitlines():
        value = raw.strip()
        if not value or value.startswith('#'):
            continue
        values.append(value)
    return values

nets = set()
for value in source_values(nets_source):
    network = ipaddress.ip_network(value, strict=False)
    if network.version != 4:
        raise ValueError(f'IPv6 network is not supported: {value}')
    nets.add(network.with_prefixlen)

domains = set()
label = re.compile(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?')
for value in source_values(domains_source):
    domain = value.rstrip('.').lower()
    labels = domain.split('.')
    if len(domain) > 253 or len(labels) < 2 or any(not label.fullmatch(item) for item in labels):
        raise ValueError(f'invalid domain: {value}')
    domains.add(domain)

Path(nets_output).write_text(''.join(f'{item}\n' for item in sorted(nets)))
Path(domains_output).write_text(''.join(f'{item}\n' for item in sorted(domains)))
PY

EXPECTED_NETS="$(wc -l < "$NETS_CANONICAL")"
EXPECTED_DOMAINS="$(wc -l < "$DOMAINS_NORMALIZED")"
[[ "$EXPECTED_NETS" -gt 0 ]] || { printf 'error: vpn-nets source is empty\n' >&2; exit 1; }

{
  cat <<EOF
port=53
bind-interfaces
interface=$LAN_IF

no-resolv
EOF
  for resolver in "${DNS_UPSTREAMS[@]}"; do
    printf 'server=%s\n' "$resolver"
  done
  cat <<'EOF'

cache-size=10000
min-cache-ttl=300

addn-hosts=/etc/custom-hosts.hosts

EOF
  while IFS= read -r domain; do
    printf 'ipset=/%s/vpn_domains\n' "$domain"
  done < "$DOMAINS_NORMALIZED"
} > "$DNSMASQ_CANDIDATE"

chmod --reference="$DNSMASQ_CONF" "$DNSMASQ_CANDIDATE"
chown --reference="$DNSMASQ_CONF" "$DNSMASQ_CANDIDATE"
touch --reference="$DNSMASQ_CONF" "$DNSMASQ_CANDIDATE"

GENERATED_DOMAIN_RULES="$(awk '/^ipset=\/[^/]+\/vpn_domains$/{count++} END{print count+0}' "$DNSMASQ_CANDIDATE")"
[[ "$GENERATED_DOMAIN_RULES" == "$EXPECTED_DOMAINS" ]] || {
  printf 'error: generated domain rule count %s != expected %s\n' "$GENERATED_DOMAIN_RULES" "$EXPECTED_DOMAINS" >&2
  exit 1
}

if ! ipset list -n | grep -Fx "$VPN_NETS" >/dev/null; then
  printf 'error: production ipset %s is missing\n' "$VPN_NETS" >&2
  exit 1
fi
if ! ipset list -n | grep -Fx "$VPN_DOMAINS" >/dev/null; then
  printf 'error: required ipset %s is missing\n' "$VPN_DOMAINS" >&2
  exit 1
fi
grep -qx 'Type: hash:ip' < <(ipset list "$VPN_DOMAINS") || {
  printf 'error: %s has unexpected type\n' "$VPN_DOMAINS" >&2
  exit 1
}
grep -q 'timeout 86400' < <(ipset list "$VPN_DOMAINS") || {
  printf 'error: %s does not have timeout 86400\n' "$VPN_DOMAINS" >&2
  exit 1
}

OLD_NETS_FP="$(ipset_membership_hash "$VPN_NETS")"
OLD_DNSMASQ_HASH="$(content_hash "$DNSMASQ_CONF")"
CANDIDATE_DNSMASQ_HASH="$(content_hash "$DNSMASQ_CANDIDATE")"

CREATE_LINE="$(ipset save "$VPN_NETS" | awk '$1 == "create" && !found {line=$0; found=1} END {print line}')"
read -r -a CREATE_WORDS <<< "$CREATE_LINE"
[[ "${CREATE_WORDS[2]:-}" == "hash:net" && "$CREATE_LINE" == *'family inet'* ]] || {
  printf 'error: production ipset is not compatible hash:net family inet\n' >&2
  exit 1
}
CANDIDATE_NETS_FP="$(sha256sum "$NETS_CANONICAL" | awk '{print $1}')"
write_record PREPARE

if ipset list "$TEMP_SET" >/dev/null 2>&1; then
  printf 'error: temporary ipset collision: %s\n' "$TEMP_SET" >&2
  exit 1
fi
ipset create "$TEMP_SET" "${CREATE_WORDS[@]:2}"
TEMP_CREATED=1
write_record TEMPORARY_SET_CREATED

while IFS= read -r network; do
  ipset add "$TEMP_SET" "$network"
done < "$NETS_CANONICAL"

set_has_expected_membership "$TEMP_SET" || {
  printf 'error: temporary vpn_nets membership validation failed\n' >&2
  exit 1
}

if ! docker exec -i vpn-router-dns dnsmasq --test --conf-file=/dev/stdin < "$DNSMASQ_CANDIDATE"; then
  printf 'error: dnsmasq candidate validation failed\n' >&2
  exit 1
fi
write_record CANDIDATES_VALIDATED

check_abort() {
  if [[ "$ABORT_PENDING" -eq 1 ]]; then
    printf 'abort requested at safe checkpoint (phase=%s)\n' "$PHASE" >&2
    if ! recover_before_reconcile; then
      exit 1
    fi
    exit 130
  fi
}

stop_on_pending_signal() {
  local next_phase="$1"
  if [[ "$ABORT_PENDING" -eq 1 ]]; then
    write_record "$next_phase"
    KEEP_ARTIFACTS=1
    printf 'abort requested after irreversible commit checkpoint (phase=%s)\n' "$PHASE" >&2
    exit 130
  fi
}

check_abort
write_record COMMITTING
check_abort

if ipset swap "$TEMP_SET" "$VPN_NETS"; then
  :
else
  printf 'error: ipset swap command failed; inspecting actual state\n' >&2
fi

PRODUCTION_AFTER_SWAP_FP="$(ipset_membership_hash "$VPN_NETS" 2>/dev/null || true)"
TEMP_AFTER_SWAP_FP="$(ipset_membership_hash "$TEMP_SET" 2>/dev/null || true)"

if [[ "$PRODUCTION_AFTER_SWAP_FP" == "$CANDIDATE_NETS_FP" && "$TEMP_AFTER_SWAP_FP" == "$OLD_NETS_FP" ]]; then
  write_record SWAPPED
elif [[ "$PRODUCTION_AFTER_SWAP_FP" == "$OLD_NETS_FP" && "$TEMP_AFTER_SWAP_FP" == "$CANDIDATE_NETS_FP" ]]; then
  printf 'error: ipset swap did not commit; production set is unchanged\n' >&2
  exit 1
else
  write_record COMMIT_STATE_AMBIGUOUS
  KEEP_ARTIFACTS=1
  printf 'error: ipset commit state is ambiguous; recovery artifacts retained\n' >&2
  exit 1
fi

check_abort

mv -f "$DNSMASQ_CANDIDATE" "$DNSMASQ_CONF"
CONFIG_INSTALLED=1
CANDIDATE_INSTALLED=1
DNSMASQ_ID_BEFORE="$(docker inspect -f '{{.Id}}' vpn-router-dns)"
write_record DNSMASQ_CONFIG_INSTALLED

if ! recreate_dnsmasq "$CANDIDATE_DNSMASQ_HASH" "$EXPECTED_DOMAINS"; then
  printf 'error: dnsmasq recreation or validation failed; attempting pre-reconcile recovery\n' >&2
  recover_before_reconcile || exit 1
  exit 1
fi
write_record DNSMASQ_COMMITTED
stop_on_pending_signal DNSMASQ_ABORT_PENDING

if ! VPN_ROUTER_INHERITED_LOCK=1 "$BASE/scripts/apply-rules.sh"; then
  write_record RECONCILE_FAILED
  KEEP_ARTIFACTS=1
  printf 'error: apply-rules.sh failed after commits; routing rollback was not attempted\n' >&2
  exit 1
fi
write_record RECONCILED
stop_on_pending_signal RECONCILE_ABORT_PENDING

[[ "$(ipset_membership_hash "$VPN_NETS")" == "$CANDIDATE_NETS_FP" ]] || { printf 'error: final vpn_nets fingerprint mismatch\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
[[ "$(ipset_entry_count "$VPN_NETS")" == "$EXPECTED_NETS" ]] || { printf 'error: final vpn_nets count mismatch\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
grep -qx 'Type: hash:ip' < <(ipset list "$VPN_DOMAINS") || { printf 'error: vpn_domains type changed\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
grep -q '^Header:.*timeout 86400' < <(ipset list "$VPN_DOMAINS") || { printf 'error: vpn_domains timeout changed\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
WG_NETWORK_ID="$(docker network inspect -f '{{.Id}}' vpn-router_default)"
WG_BRIDGE="br-${WG_NETWORK_ID:0:12}"
WG_IP="$(docker inspect -f '{{with index .NetworkSettings.Networks "vpn-router_default"}}{{.IPAddress}}{{end}}' vpn-router-wg)"
WG_ENDPOINT="$(docker exec vpn-router-wg wg show wg0 endpoints | awk 'NF >= 2 && !found {value=$2; found=1} END {print value}')"
WG_ENDPOINT_IP="${WG_ENDPOINT%:*}"
ENDPOINT_ROUTE="$(ip -4 route get "$WG_ENDPOINT_IP")"
[[ "$ENDPOINT_ROUTE" == *" dev $LAN_IF "* ]] || { printf 'error: endpoint route is not ISP route: %s\n' "$ENDPOINT_ROUTE" >&2; KEEP_ARTIFACTS=1; exit 1; }
grep -q 'from all fwmark 0xc8 lookup 200' < <(ip -4 rule show) || { printf 'error: policy rule 0xc8/200 missing\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
ip -4 route show table 200 | awk -v expected_ip="$WG_IP" -v expected_bridge="$WG_BRIDGE" '
  $1 == "default" && $2 == "via" && $3 == expected_ip && $4 == "dev" && $5 == expected_bridge {found=1}
  END {exit !found}
' || { printf 'error: table 200 mismatch\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
iptables -t mangle -C PREROUTING -s "$LAN_NET" -j VPN_ROUTER_LAN
iptables -t mangle -C OUTPUT -j VPN_ROUTER_HOST
iptables -t filter -C FORWARD -j VPN_ROUTER_FWD
iptables -t nat -C POSTROUTING -j VPN_ROUTER_NAT

SELECTED_IP="$(head -n 1 "$NETS_CANONICAL" | cut -d/ -f1)"
SELECTED_ROUTE="$(ip -4 route get "$SELECTED_IP" mark 0xc8)"
NON_SELECTED_ROUTE="$(ip -4 route get 203.0.113.1)"
[[ "$SELECTED_ROUTE" == *" dev $WG_BRIDGE "* ]] || { printf 'error: selected route is not VPN path: %s\n' "$SELECTED_ROUTE" >&2; KEEP_ARTIFACTS=1; exit 1; }
[[ "$NON_SELECTED_ROUTE" == *" dev $LAN_IF "* ]] || { printf 'error: non-selected route is not ISP path: %s\n' "$NON_SELECTED_ROUTE" >&2; KEEP_ARTIFACTS=1; exit 1; }

[[ "$(docker inspect -f '{{.State.Running}}' vpn-router-wg)" == "true" ]] || { printf 'error: WireGuard container is not running\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
[[ "$(docker inspect -f '{{.State.Running}}' vpn-router-dns)" == "true" ]] || { printf 'error: DNS container is not running\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
[[ "$(systemctl is-active vpn-router-rules.timer)" == "active" ]] || { printf 'error: routing timer is not active\n' >&2; KEEP_ARTIFACTS=1; exit 1; }
[[ "$(systemctl is-enabled vpn-router-rules.timer)" == "enabled" ]] || { printf 'error: routing timer is not enabled\n' >&2; KEEP_ARTIFACTS=1; exit 1; }

[[ "$(ipset_references "$TEMP_SET")" == "0" ]] || {
  printf 'error: old rollback set still has references; preserving it\n' >&2
  KEEP_ARTIFACTS=1
  exit 1
}
[[ "$(ipset_membership_hash "$TEMP_SET")" == "$OLD_NETS_FP" ]] || {
  printf 'error: old rollback set fingerprint changed; preserving it\n' >&2
  KEEP_ARTIFACTS=1
  exit 1
}

stop_on_pending_signal VERIFY_ABORT_PENDING
write_record FINALIZING
stop_on_pending_signal FINALIZE_ABORT_PENDING
if ! ipset destroy "$TEMP_SET"; then
  printf 'error: failed to destroy old rollback set; recovery information retained\n' >&2
  KEEP_ARTIFACTS=1
  exit 1
fi
TEMP_CREATED=0
if [[ "$ABORT_PENDING" -eq 1 ]]; then
  write_record FINALIZE_SIGNAL_PENDING
  KEEP_ARTIFACTS=1
  printf 'abort requested after temporary set destruction; transaction metadata retained\n' >&2
  exit 130
fi
if ! write_record COMPLETE; then
  KEEP_ARTIFACTS=1
  printf 'error: failed to record transaction completion; recovery information retained\n' >&2
  exit 1
fi
if [[ "$ABORT_PENDING" -eq 1 ]]; then
  KEEP_ARTIFACTS=1
  printf 'abort requested before transaction cleanup; transaction metadata retained\n' >&2
  exit 130
fi
rm -f "$TXN_RECORD"
rm -rf "$WORK_DIR"
WORK_DIR=""
FINALIZED=1
if [[ "$ABORT_PENDING" -eq 1 ]]; then
  printf 'abort requested during final cleanup; transaction completed without success report\n' >&2
  exit 130
fi

printf 'OK: transaction %s committed and verified (networks=%s domains=%s)\n' "$TXID" "$EXPECTED_NETS" "$EXPECTED_DOMAINS"
