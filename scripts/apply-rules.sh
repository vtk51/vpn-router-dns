#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Trusted, root-owned Bash configuration, not an environment file.
source "$BASE_DIR/config/router.conf"
: "${LAN_IF:?set LAN_IF in config/router.conf}"
: "${LAN_NET:?set LAN_NET in config/router.conf}"
(( ${#DNS_UPSTREAMS[@]} > 0 )) || { printf 'error: DNS_UPSTREAMS is empty\n' >&2; exit 1; }
# Reject malformed configurable rule arguments before any network mutation.
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
WG_CONTAINER="vpn-router-wg"
DNS_CONTAINER="vpn-router-dns"
DOCKER_NETWORK="vpn-router_default"
MARK="0xc8"
ROUTE_TABLE="200"
LOCK_FILE="/run/lock/vpn-router-rebuild.lock"
CHANGED=0

if [[ "${VPN_ROUTER_INHERITED_LOCK:-0}" == "1" ]]; then
  inherited_lock_path="$(readlink "/proc/$$/fd/9" 2>/dev/null || true)"
  if [[ "$inherited_lock_path" != "$LOCK_FILE" ]]; then
    printf 'error: inherited rebuild lock fd 9 is not %s\n' "$LOCK_FILE" >&2
    exit 1
  fi
  if ! flock -n 9; then
    printf 'error: inherited rebuild lock fd 9 is busy or invalid\n' >&2
    exit 1
  fi
else
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    printf 'deferred: rebuild in progress; routing reconciliation will retry\n'
    exit 0
  fi
fi

changed() {
  CHANGED=1
  printf 'change: %s\n' "$*"
}

require_containers_ready() {
  local deadline=$((SECONDS + 120))
  local container names state

  if ! systemctl is-active --quiet docker.service; then
    printf 'error: Docker daemon is not active; refusing lifecycle or network reconciliation\n' >&2
    return 1
  fi

  while ((SECONDS < deadline)); do
    for container in "$WG_CONTAINER" "$DNS_CONTAINER"; do
      if ! names="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>/dev/null)"; then
        printf 'error: Docker inspection failed while locating container %s\n' "$container" >&2
        return 1
      fi
      if [[ -z "$names" ]]; then
        printf 'error: required container is missing: %s\n' "$container" >&2
        return 1
      fi
      if [[ "$names" != "$container" ]]; then
        printf 'error: unexpected exact-name inspection result for %s\n' "$container" >&2
        return 1
      fi
      if ! state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)"; then
        printf 'error: Docker inspection failed while reading container %s\n' "$container" >&2
        return 1
      fi
      if [[ "$state" != "running" ]]; then
        printf 'error: required container %s is %s; lifecycle is owned by Docker/Compose\n' "$container" "$state" >&2
        return 1
      fi
    done

    if docker exec "$WG_CONTAINER" ip link show wg0 >/dev/null 2>&1 &&
       [[ -n "$(docker exec "$WG_CONTAINER" wg show wg0 peers 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 2
  done

  printf 'error: required containers or WireGuard readiness did not become available within 120 seconds\n' >&2
  return 1
}

has_line() {
  local text="$1" expected="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$expected" ]] && return 0
  done <<< "$text"
  return 1
}

chain_missing() {
  [[ "$1" == *"No chain/target/match by that name"* ||
     "$1" == *"Chain '"*"' does not exist"* ]]
}

rule_absent() {
  [[ "$1" == *"Bad rule"* || "$1" == *"No chain/target/match by that name"* ]]
}

ip_rule_absent() {
  [[ "$1" == *"No such file or directory"* || "$1" == *"Cannot find device"* ]]
}

header_has_pair() {
  local text="$1" first="$2" second="$3" line i
  local -a fields
  while IFS= read -r line; do
    [[ "$line" == Header:* ]] || continue
    read -r -a fields <<< "$line"
    for ((i = 0; i + 1 < ${#fields[@]}; i++)); do
      [[ "${fields[i]}" == "$first" && "${fields[i + 1]}" == "$second" ]] && return 0
    done
  done <<< "$text"
  return 1
}

policy_rule_matches() {
  local line="$1" i
  local -a fields
  read -r -a fields <<< "$line"
  for ((i = 0; i + 5 < ${#fields[@]}; i++)); do
    [[ "${fields[i]}" == from && "${fields[i + 1]}" == all &&
       "${fields[i + 2]}" == fwmark && "${fields[i + 3]}" == "$MARK" &&
       "${fields[i + 4]}" == lookup && "${fields[i + 5]}" == "$ROUTE_TABLE" ]] && return 0
  done
  return 1
}

route_uses_dev() {
  local route="$1" expected="$2" i
  local -a fields
  read -r -a fields <<< "$route"
  for ((i = 0; i + 1 < ${#fields[@]}; i++)); do
    [[ "${fields[i]}" == "dev" && "${fields[i + 1]}" == "$expected" ]] && return 0
  done
  return 1
}

sync_chain() {
  local table="$1" chain="$2" desired="$3" actual rule
  local -a args

  local inspection
  # nft -nL can report an absent chain as "incompatible". A successful table
  # inventory establishes absence without treating operational errors as absence.
  if ! inspection="$(iptables -t "$table" -S)"; then
    printf 'error: unable to inspect %s chain inventory\n' "$table" >&2
    return 1
  fi
  if ! has_line "$inspection" "-N $chain"; then
    iptables -t "$table" -N "$chain"
    changed "create $table/$chain"
  fi

  actual="$(iptables -t "$table" -S "$chain" | while read -r op name rest; do
    if [[ "$op" == "-A" ]]; then
      printf '%s\n' "$rest"
    fi
  done)"
  if [[ "$actual" == "$desired" ]]; then
    return
  fi

  iptables -t "$table" -F "$chain"
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    read -r -a args <<< "$rule"
    iptables -t "$table" -A "$chain" "${args[@]}"
  done <<< "$desired"
  changed "sync $table/$chain"
}

ensure_jump_first() {
  local table="$1" parent="$2" child="$3" line first="" count=0 listing
  local -a match_args
  shift 3
  match_args=("$@")
  local expected="-A $parent"
  if ((${#match_args[@]})); then
    expected+=" ${match_args[*]}"
  fi
  expected+=" -j $child"

  if ! listing="$(iptables -t "$table" -S "$parent")"; then
    printf 'error: unable to inspect %s/%s\n' "$table" "$parent" >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" != "-A $parent "* ]] && continue
    [[ -z "$first" ]] && first="$line"
    [[ "$line" == "$expected" ]] && count=$((count + 1))
  done <<< "$listing"

  if [[ "$count" -eq 1 && "$first" == "$expected" ]]; then
    return
  fi
  local probe status
  while :; do
    if probe="$(iptables -t "$table" -D "$parent" "${match_args[@]}" -j "$child" 2>&1)"; then
      continue
    else
      status=$?
      break
    fi
  done
  if [[ "$status" -ne 0 ]] && ! rule_absent "$probe"; then
    printf '%s\n' "$probe" >&2
    return 1
  fi
  iptables -t "$table" -I "$parent" 1 "${match_args[@]}" -j "$child"
  changed "hook $table/$parent to $child"
}

remove_exact_rule() {
  local table="$1" chain="$2" probe status
  shift 2
  while :; do
    if probe="$(iptables -t "$table" -C "$chain" "$@" 2>&1)"; then
      iptables -t "$table" -D "$chain" "$@"
      changed "remove obsolete $table/$chain rule"
      continue
    else
      status=$?
      break
    fi
  done
  if [[ "$status" -ne 0 ]] && ! rule_absent "$probe"; then
    printf '%s\n' "$probe" >&2
    return 1
  fi
}

require_containers_ready

NETWORK_ID="$(docker network inspect -f '{{.Id}}' "$DOCKER_NETWORK")"
WG_BRIDGE="br-${NETWORK_ID:0:12}"
WG_GATEWAY="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$DOCKER_NETWORK")"
WG_IP="$(docker inspect -f '{{with index .NetworkSettings.Networks "vpn-router_default"}}{{.IPAddress}}{{end}}' "$WG_CONTAINER")"

[[ -n "$NETWORK_ID" && -n "$WG_GATEWAY" && -n "$WG_IP" ]] || {
  printf 'error: incomplete Docker topology discovery\n' >&2
  exit 1
}
ip link show "$WG_BRIDGE" >/dev/null

if ! endpoint_output="$(docker exec "$WG_CONTAINER" wg show wg0 endpoints)"; then
  printf 'error: unable to inspect WireGuard endpoint\n' >&2
  exit 1
fi
ENDPOINT=""
while read -r _ candidate; do
  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    ENDPOINT="$candidate"
    break
  fi
done <<< "$endpoint_output"

if [[ "$ENDPOINT" == \[*\]:* ]]; then
  printf 'error: IPv6 WireGuard endpoints are not supported by this IPv4 policy\n' >&2
  exit 1
fi
WG_ENDPOINT_IP="${ENDPOINT%:*}"
[[ "$WG_ENDPOINT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  printf 'error: invalid WireGuard endpoint: %s\n' "$ENDPOINT" >&2
  exit 1
}

if ! endpoint_route="$(ip -4 route get "$WG_ENDPOINT_IP")"; then
  printf 'error: unable to inspect route to WireGuard endpoint %s\n' "$WG_ENDPOINT_IP" >&2
  exit 1
fi
route_uses_dev "$endpoint_route" "$LAN_IF" || {
  printf 'error: WireGuard endpoint is not routed through %s: %s\n' "$LAN_IF" "$endpoint_route" >&2
  exit 1
}

if ! FORWARDING="$(sysctl -n net.ipv4.ip_forward)"; then
  printf 'error: unable to inspect IPv4 forwarding state\n' >&2
  exit 1
fi

# Bootstrap is owned by this reconciler; established list updates remain owned
# by rebuild-lists.sh. This runs under the same lock, before firewall consumers.
bootstrap_missing_ipsets() (
  set -euo pipefail
  missing_domains="$1" missing_nets="$2"
  temporary_set="" temporary_created=0

  cleanup_bootstrap() {
    local rc=$? names info
    trap - EXIT
    if [[ "$temporary_created" -eq 1 ]]; then
      if names="$(ipset list -n)"; then
        if has_line "$names" "$temporary_set"; then
          if info="$(ipset list "$temporary_set")" &&
             has_line "$info" 'Type: hash:net' &&
             header_has_pair "$info" family inet &&
             has_line "$info" 'References: 0' &&
             ipset destroy "$temporary_set"; then
            :
          else
            printf 'error: bootstrap candidate retained: %s\n' "$temporary_set" >&2
            rc=1
          fi
        fi
      else
        printf 'error: cannot inspect bootstrap candidate: %s\n' "$temporary_set" >&2
        rc=1
      fi
    fi
    exit "$rc"
  }
  trap cleanup_bootstrap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if [[ "$missing_nets" -eq 1 ]]; then
    # Match rebuild-lists.sh normalization; read once and validate ALL input
    # before publishing either missing production set. Never load a backup.
    canonical_nets="$(python3 - "$BASE_DIR/lists/vpn-nets.txt" <<'PY'
import ipaddress
import sys
from pathlib import Path

nets = set()
for raw in Path(sys.argv[1]).read_text().splitlines():
    value = raw.strip()
    if not value or value.startswith('#'):
        continue
    network = ipaddress.ip_network(value, strict=False)
    if network.version != 4:
        raise ValueError(f'IPv6 network is not supported: {value}')
    nets.add(network.with_prefixlen)
if not nets:
    raise ValueError('vpn-nets source is empty')
print('\n'.join(sorted(nets)))
PY
)"
    temporary_set="vrb_${BASHPID}_${RANDOM}_${RANDOM}"
    # No -exist: a collision or create failure must abort, never take ownership.
    ipset create "$temporary_set" hash:net family inet hashsize 1024 maxelem 65536
    temporary_created=1
    while IFS= read -r network; do
      ipset add "$temporary_set" "$network"
    done <<< "$canonical_nets"
    ipset save "$temporary_set" | python3 -c '
import ipaddress
import sys

expected = sys.argv[1].splitlines()
actual = []
for line in sys.stdin:
    parts = line.split()
    if parts and parts[0] == "add":
        actual.append(ipaddress.ip_network(parts[2], strict=False).with_prefixlen)
if sorted(actual) != expected:
    raise ValueError("bootstrap vpn_nets membership/count mismatch")
' "$canonical_nets"
    # Atomic publication; rename refuses an existing destination. On failure,
    # cleanup owns only the candidate name, never vpn_nets or vpn_domains.
    ipset rename "$temporary_set" vpn_nets
    temporary_created=0
  fi
  if [[ "$missing_domains" -eq 1 ]]; then
    ipset create vpn_domains hash:ip family inet hashsize 1024 maxelem 65536 timeout 86400
  fi
)

if ! IPSET_NAMES="$(ipset list -n)"; then
  printf 'error: unable to inspect ipsets\n' >&2
  exit 1
fi
MISSING_DOMAINS=0
MISSING_NETS=0
has_line "$IPSET_NAMES" vpn_domains || MISSING_DOMAINS=1
has_line "$IPSET_NAMES" vpn_nets || MISSING_NETS=1
# Validate every existing set before making bootstrap mutations.
if [[ "$MISSING_DOMAINS" -eq 0 ]]; then
  if ! VPN_DOMAINS_INFO="$(ipset list vpn_domains)"; then
    printf 'error: unable to inspect vpn_domains\n' >&2
    exit 1
  fi
  has_line "$VPN_DOMAINS_INFO" "Type: hash:ip" &&
  header_has_pair "$VPN_DOMAINS_INFO" family inet || {
    printf 'error: vpn_domains has unexpected type\n' >&2
    exit 1
  }
  header_has_pair "$VPN_DOMAINS_INFO" timeout 86400 || {
    printf 'error: vpn_domains does not have timeout 86400\n' >&2
    exit 1
  }
fi
if [[ "$MISSING_NETS" -eq 0 ]]; then
  if ! VPN_NETS_INFO="$(ipset list vpn_nets)"; then
    printf 'error: unable to inspect vpn_nets\n' >&2
    exit 1
  fi
  has_line "$VPN_NETS_INFO" "Type: hash:net" &&
  header_has_pair "$VPN_NETS_INFO" family inet || {
    printf 'error: vpn_nets has unexpected type\n' >&2
    exit 1
  }
  VPN_NETS_ENTRIES=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^Number[[:space:]]+of[[:space:]]+entries:[[:space:]]+([0-9]+)$ ]]; then
      VPN_NETS_ENTRIES="${BASH_REMATCH[1]}"
      break
    fi
  done <<< "$VPN_NETS_INFO"
  [[ -n "$VPN_NETS_ENTRIES" && "$VPN_NETS_ENTRIES" -gt 0 ]] || {
    printf 'error: vpn_nets is empty or entry count is unavailable\n' >&2
    exit 1
  }
fi
if [[ "$MISSING_DOMAINS" -eq 1 || "$MISSING_NETS" -eq 1 ]]; then
  # A normal rebuild calls us with valid sets and a live transaction record.
  # Only missing-set recovery must refuse that potentially ambiguous state.
  if [[ -e /run/vpn-router/rebuild.transaction ]]; then
    printf 'error: cannot bootstrap missing ipsets with a rebuild transaction record present\n' >&2
    exit 1
  fi
  bootstrap_missing_ipsets "$MISSING_DOMAINS" "$MISSING_NETS"
  changed "bootstrap missing ipsets (vpn_domains=$MISSING_DOMAINS vpn_nets=$MISSING_NETS)"
fi

if ! mangle_output_rules="$(iptables -t mangle -S OUTPUT)"; then
  printf 'error: unable to inspect mangle/OUTPUT\n' >&2
  exit 1
fi
vpn_host_references=0
while IFS= read -r line; do
  [[ "$line" == "-A OUTPUT -j VPN_HOST_OUT" ]] && vpn_host_references=$((vpn_host_references + 1))
done <<< "$mangle_output_rules"
vpn_host_chain_present=0
if [[ "$vpn_host_references" -gt 0 ]]; then
  if ! vpn_host_probe="$(iptables -t mangle -nL VPN_HOST_OUT 2>&1)"; then
    printf '%s\n' "$vpn_host_probe" >&2
    exit 1
  fi
  vpn_host_chain_present=1
fi

if [[ "$FORWARDING" != "1" ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  changed "enable IPv4 forwarding"
fi

remove_exact_rule mangle PREROUTING -s "$LAN_NET" -m set --match-set vpn_domains dst -j MARK --set-mark 200
remove_exact_rule mangle PREROUTING -s "$LAN_NET" -m set --match-set vpn_nets dst -j MARK --set-mark 200
if [[ "$vpn_host_chain_present" -eq 1 ]]; then
  remove_exact_rule mangle OUTPUT -j VPN_HOST_OUT
  iptables -t mangle -F VPN_HOST_OUT
  iptables -t mangle -X VPN_HOST_OUT
  changed "remove obsolete VPN_HOST_OUT"
fi

remove_exact_rule filter FORWARD -i "$LAN_IF" -o "$LAN_IF" -s "$LAN_NET" -j ACCEPT
remove_exact_rule filter FORWARD -i "$LAN_IF" -o "$LAN_IF" -d "$LAN_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
remove_exact_rule nat POSTROUTING -s "$LAN_NET" -o "$LAN_IF" ! -d "$LAN_NET" -j MASQUERADE

sync_chain mangle VPN_ROUTER_LAN "-d $WG_ENDPOINT_IP/32 -j RETURN
-m set --match-set vpn_domains dst -j MARK --set-xmark $MARK/0xffffffff
-m set --match-set vpn_nets dst -j MARK --set-xmark $MARK/0xffffffff"
# iptables-nft cannot check this obsolete jump until its target exists.
remove_exact_rule mangle PREROUTING -j VPN_ROUTER_LAN
host_dns_rules=""
for resolver in "${DNS_UPSTREAMS[@]}"; do
  host_dns_rules+="-d $resolver/32 -p udp -m udp --dport 53 -j MARK --set-xmark $MARK/0xffffffff"$'\n'
  host_dns_rules+="-d $resolver/32 -p tcp -m tcp --dport 53 -j RETURN"$'\n'
done
for resolver in "${DNS_DIRECT[@]}"; do
  host_dns_rules+="-d $resolver/32 -p udp -m udp --dport 53 -j RETURN"$'\n'
  host_dns_rules+="-d $resolver/32 -p tcp -m tcp --dport 53 -j RETURN"$'\n'
done
sync_chain mangle VPN_ROUTER_HOST "-d $WG_ENDPOINT_IP/32 -j RETURN
${host_dns_rules}-d 127.0.0.0/8 -j RETURN
-d 192.168.0.0/16 -j RETURN
-d 10.0.0.0/8 -j RETURN
-d 172.16.0.0/12 -j RETURN
-m set --match-set vpn_domains dst -j MARK --set-xmark $MARK/0xffffffff
-m set --match-set vpn_nets dst -j MARK --set-xmark $MARK/0xffffffff"
sync_chain filter VPN_ROUTER_FWD "-s $LAN_NET -i $LAN_IF -o $WG_BRIDGE -j ACCEPT
-d $LAN_NET -i $WG_BRIDGE -o $LAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-s $LAN_NET -i $LAN_IF -o $LAN_IF -j ACCEPT
-d $LAN_NET -i $LAN_IF -o $LAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
sync_chain nat VPN_ROUTER_NAT "-s $LAN_NET ! -d $LAN_NET -o $LAN_IF -j MASQUERADE"

ensure_jump_first mangle PREROUTING VPN_ROUTER_LAN -s "$LAN_NET"
ensure_jump_first mangle OUTPUT VPN_ROUTER_HOST
ensure_jump_first filter FORWARD VPN_ROUTER_FWD
ensure_jump_first nat POSTROUTING VPN_ROUTER_NAT

route_table_is_correct() {
  local output status
  local -a routes fields

  if output="$(ip -4 route show table "$ROUTE_TABLE" 2>&1)"; then
    :
  else
    status=$?
    if [[ "$status" -eq 2 ]] &&
       { [[ "$output" == "Error: ipv4: FIB table does not exist." ]] ||
         [[ "$output" == $'Error: ipv4: FIB table does not exist.\nDump terminated' ]]; }; then
      return 10
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  fi

  [[ -n "$output" ]] || return 1
  mapfile -t routes <<< "$output"
  ((${#routes[@]} == 1)) || return 1
  read -r -a fields <<< "${routes[0]}"
  ((${#fields[@]} == 5)) &&
    [[ "${fields[0]}" == "default" && "${fields[1]}" == "via" &&
       "${fields[2]}" == "$WG_IP" && "${fields[3]}" == "dev" &&
       "${fields[4]}" == "$WG_BRIDGE" ]]
}

if route_table_is_correct; then
  :
else
  route_status=$?
  case "$route_status" in
    1)
      ip -4 route flush table "$ROUTE_TABLE"
      ;;
    10)
      ;;
    *)
      exit "$route_status"
      ;;
  esac
  ip -4 route add default via "$WG_IP" dev "$WG_BRIDGE" table "$ROUTE_TABLE"
  changed "sync routing table $ROUTE_TABLE"
fi

if ! policy_rules="$(ip -4 rule show)"; then
  printf 'error: unable to inspect IPv4 policy rules\n' >&2
  exit 1
fi
rule_count=0
while IFS= read -r rule; do
  policy_rule_matches "$rule" && rule_count=$((rule_count + 1))
done <<< "$policy_rules"
if [[ "$rule_count" -ne 1 ]]; then
  rule_delete_output=""
  while :; do
    if rule_delete_output="$(ip -4 rule del fwmark "$MARK" table "$ROUTE_TABLE" 2>&1)"; then
      continue
    else
      rule_delete_status=$?
      break
    fi
  done
  if [[ "$rule_delete_status" -ne 0 ]] && ! ip_rule_absent "$rule_delete_output"; then
    printf '%s\n' "$rule_delete_output" >&2
    exit 1
  fi
  ip -4 rule add fwmark "$MARK" table "$ROUTE_TABLE"
  changed "sync policy rule"
fi

container_result="$(docker exec -i "$WG_CONTAINER" sh -s -- "$LAN_NET" "$WG_GATEWAY" <<'CONTAINER_RULES'
set -eu
LAN_NET="$1"
WG_GATEWAY="$2"
CHANGED=0

chain_missing() {
  case "$1" in
    *"No chain/target/match by that name"*|*"Chain '"*"' does not exist"*) return 0 ;;
    *) return 1 ;;
  esac
}

rule_absent() {
  case "$1" in
    *"Bad rule"*|*"No chain/target/match by that name"*) return 0 ;;
    *) return 1 ;;
  esac
}

sync_chain() {
  table="$1" chain="$2" desired="$3"
  if ! inspection="$(iptables -t "$table" -S)"; then
    printf 'error: unable to inspect %s chain inventory\n' "$table" >&2
    return 1
  fi
  present=0
  while IFS= read -r declaration; do
    [ "$declaration" = "-N $chain" ] && present=1
  done <<EOF
$inspection
EOF
  if [ "$present" -eq 0 ]; then
    iptables -t "$table" -N "$chain"
    CHANGED=1
  fi
  actual="$(iptables -t "$table" -S "$chain")"
  parsed=""
  while read -r op name rest; do
    if [ "$op" = "-A" ]; then
      parsed="${parsed:+$parsed
}$rest"
    fi
  done <<EOF
$actual
EOF
  [ "$parsed" = "$desired" ] && return
  iptables -t "$table" -F "$chain"
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    set -- $rule
    iptables -t "$table" -A "$chain" "$@"
  done <<EOF
$desired
EOF
  CHANGED=1
}

ensure_jump_first() {
  table="$1" parent="$2" child="$3"
  listing="$(iptables -t "$table" -S "$parent")"
  expected="-A $parent -j $child"
  first="" count=0
  while IFS= read -r line; do
    case "$line" in "-A $parent "*) ;; *) continue ;; esac
    [ -z "$first" ] && first="$line"
    [ "$line" = "$expected" ] && count=$((count + 1))
  done <<EOF
$listing
EOF
  [ "$count" -eq 1 ] && [ "$first" = "$expected" ] && return
  probe=""
  while :; do
    if probe="$(iptables -t "$table" -D "$parent" -j "$child" 2>&1)"; then
      continue
    else
      status=$?
      break
    fi
  done
  if [ "$status" -ne 0 ] && ! rule_absent "$probe"; then
    printf '%s\n' "$probe" >&2
    return 1
  fi
  iptables -t "$table" -I "$parent" 1 -j "$child"
  CHANGED=1
}

remove_exact() {
  table="$1" chain="$2"
  shift 2
  probe=""
  while :; do
    if probe="$(iptables -t "$table" -C "$chain" "$@" 2>&1)"; then
      iptables -t "$table" -D "$chain" "$@"
      CHANGED=1
      continue
    else
      status=$?
      break
    fi
  done
  if [ "$status" -ne 0 ] && ! rule_absent "$probe"; then
    printf '%s\n' "$probe" >&2
    return 1
  fi
}

route_is_correct() {
  if ! route_output="$(ip -4 route show "$LAN_NET")"; then
    return 2
  fi
  set -- $route_output
  [ "$#" -eq 5 ] && [ "$1" = "$LAN_NET" ] && [ "$2" = "via" ] &&
    [ "$3" = "$WG_GATEWAY" ] && [ "$4" = "dev" ] && [ "$5" = "eth0" ]
}

if route_is_correct; then
  :
else
  route_status=$?
  [ "$route_status" -eq 1 ] || exit "$route_status"
  ip route replace "$LAN_NET" via "$WG_GATEWAY" dev eth0
  CHANGED=1
fi

remove_exact nat POSTROUTING -s "$LAN_NET" -o wg0 -j MASQUERADE
remove_exact nat POSTROUTING -s "$WG_GATEWAY/32" -o wg0 -j MASQUERADE
remove_exact filter FORWARD -s "$LAN_NET" -i eth0 -o wg0 -j ACCEPT
remove_exact filter FORWARD -d "$LAN_NET" -i wg0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
remove_exact filter FORWARD -s "$WG_GATEWAY/32" -i eth0 -o wg0 -j ACCEPT
remove_exact filter FORWARD -d "$WG_GATEWAY/32" -i wg0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
remove_exact mangle FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

sync_chain nat VPN_ROUTER_NAT "-s $LAN_NET -o wg0 -j MASQUERADE
-s $WG_GATEWAY/32 -o wg0 -j MASQUERADE"
sync_chain filter VPN_ROUTER_FWD "-s $LAN_NET -i eth0 -o wg0 -j ACCEPT
-d $LAN_NET -i wg0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-s $WG_GATEWAY/32 -i eth0 -o wg0 -j ACCEPT
-d $WG_GATEWAY/32 -i wg0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
sync_chain mangle VPN_ROUTER_MSS "-o wg0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
ensure_jump_first nat POSTROUTING VPN_ROUTER_NAT
ensure_jump_first filter FORWARD VPN_ROUTER_FWD
ensure_jump_first mangle FORWARD VPN_ROUTER_MSS

[ "$CHANGED" -eq 0 ] || printf 'changed\n'
CONTAINER_RULES
)"
if [[ "$container_result" == *changed* ]]; then
  changed "sync rules inside $WG_CONTAINER"
fi

if ! endpoint_route="$(ip -4 route get "$WG_ENDPOINT_IP")"; then
  printf 'error: unable to recheck route to WireGuard endpoint\n' >&2
  exit 1
fi
route_uses_dev "$endpoint_route" "$LAN_IF" || {
  printf 'error: WireGuard endpoint route changed during reconciliation: %s\n' "$endpoint_route" >&2
  exit 1
}

if [[ "$CHANGED" -eq 0 ]]; then
  printf 'OK: routing state already correct (no changes)\n'
else
  printf 'OK: routing state reconciled\n'
fi
