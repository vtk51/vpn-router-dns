#!/usr/bin/env bash
set -e

WG_CONT_NAME="vpn-router-wg"
WG_CONT_IP="172.18.0.2"
WG_BR="br-de01a1582803"

LAN_IF="ens18"
LAN_NET="192.168.1.0/24"
TEST_CLIENT="192.168.1.0/24"

NETS_FILE="/opt/stacks/vpn-router/lists/vpn-nets.txt"

echo "[1/7] enable forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "[2/7] create ipsets"
ipset create vpn_domains hash:ip timeout 86400 -exist
ipset create vpn_nets hash:net -exist

echo "[3/7] fill static vpn_nets from file"
if [ -f "$NETS_FILE" ]; then
  grep -vE '^\s*#|^\s*$' "$NETS_FILE" | sort -u | while read -r net; do
    ipset add vpn_nets "$net" -exist
  done
fi

echo "[4/7] host policy route"
ip route replace default via "$WG_CONT_IP" dev "$WG_BR" table 200

while ip rule del fwmark 200 table 200 2>/dev/null; do
  true
done

ip rule add fwmark 200 table 200

echo "[5/7] host mangle rules"
iptables -t mangle -C PREROUTING -s "$TEST_CLIENT" -m set --match-set vpn_domains dst -j MARK --set-mark 200 2>/dev/null || \
iptables -t mangle -A PREROUTING -s "$TEST_CLIENT" -m set --match-set vpn_domains dst -j MARK --set-mark 200

iptables -t mangle -C PREROUTING -s "$TEST_CLIENT" -m set --match-set vpn_nets dst -j MARK --set-mark 200 2>/dev/null || \
iptables -t mangle -A PREROUTING -s "$TEST_CLIENT" -m set --match-set vpn_nets dst -j MARK --set-mark 200

echo "[6/7] host docker forwarding"
iptables -C DOCKER-USER -i "$LAN_IF" -o "$WG_BR" -s "$TEST_CLIENT" -j ACCEPT 2>/dev/null || \
iptables -I DOCKER-USER 1 -i "$LAN_IF" -o "$WG_BR" -s "$TEST_CLIENT" -j ACCEPT

iptables -C DOCKER-USER -i "$WG_BR" -o "$LAN_IF" -d "$TEST_CLIENT" -j ACCEPT 2>/dev/null || \
iptables -I DOCKER-USER 2 -i "$WG_BR" -o "$LAN_IF" -d "$TEST_CLIENT" -j ACCEPT

echo "[6.5/7] host direct forwarding/NAT"
iptables -t nat -C POSTROUTING -s "$TEST_CLIENT" -o "$LAN_IF" ! -d "$LAN_NET" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$TEST_CLIENT" -o "$LAN_IF" ! -d "$LAN_NET" -j MASQUERADE

iptables -C FORWARD -i "$LAN_IF" -o "$LAN_IF" -s "$TEST_CLIENT" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -i "$LAN_IF" -o "$LAN_IF" -s "$TEST_CLIENT" -j ACCEPT

iptables -C FORWARD -i "$LAN_IF" -o "$LAN_IF" -d "$TEST_CLIENT" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 2 -i "$LAN_IF" -o "$LAN_IF" -d "$TEST_CLIENT" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "[7/7] rules inside WireGuard container"
docker exec "$WG_CONT_NAME" sh -c "
ip route replace $LAN_NET via 172.18.0.1 dev eth0

iptables -t nat -C POSTROUTING -s $LAN_NET -o wg0 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s $LAN_NET -o wg0 -j MASQUERADE

iptables -C FORWARD -i eth0 -o wg0 -s $LAN_NET -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i eth0 -o wg0 -s $LAN_NET -j ACCEPT

iptables -C FORWARD -i wg0 -o eth0 -d $LAN_NET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i wg0 -o eth0 -d $LAN_NET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
"

echo "OK"
