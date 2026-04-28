#!/usr/bin/env bash
set -e

BASE="/opt/stacks/vpn-router"
DOMAINS_FILE="$BASE/lists/vpn-domains.txt"
NETS_FILE="$BASE/lists/vpn-nets.txt"
DNSMASQ_CONF="$BASE/dnsmasq/dnsmasq.conf"

echo "[1/5] rebuild dnsmasq.conf"

cat > "$DNSMASQ_CONF" <<'EOF'
port=53
bind-interfaces
interface=ens18

no-resolv
server=8.8.8.8
server=1.1.1.1

cache-size=10000
min-cache-ttl=300

addn-hosts=/etc/custom-hosts.hosts
expand-hosts
domain=local

EOF

grep -vE '^\s*#|^\s*$' "$DOMAINS_FILE" | sort -u | while read -r domain; do
  echo "ipset=/$domain/vpn_domains" >> "$DNSMASQ_CONF"
done

echo "[2/5] recreate vpn_nets ipset"
ipset create vpn_nets hash:net -exist
ipset flush vpn_nets

grep -vE '^\s*#|^\s*$' "$NETS_FILE" | sort -u | while read -r net; do
  ipset add vpn_nets "$net" -exist
done

echo "[3/5] keep vpn_domains ipset"
ipset create vpn_domains hash:ip timeout 86400 -exist

echo "[4/5] restart dnsmasq"
cd "$BASE"
docker compose restart dnsmasq

echo "[5/5] apply routing rules"
"$BASE/scripts/apply-rules.sh"

echo "OK"
