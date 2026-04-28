# VPN Router DNS

Docker-based transparent VPN router for a LAN.

The server acts as a gateway and DNS server for clients. Traffic is split by destination:

- domains/IPs from VPN lists go through a WireGuard client container;
- all other traffic goes directly through the normal LAN router;
- local DNS names can be served from a custom hosts file.

Tested with Debian 12, Docker Compose, `iptables-nft`, `ipset`, `dnsmasq`, and `lscr.io/linuxserver/wireguard`.

## Network model

Example working scheme:

```text
LAN router:        192.168.1.100
VPN-router host:   192.168.1.108
LAN network:       192.168.1.0/24
LAN interface:     ens18

Clients:
  gateway:         192.168.1.108
  DNS:             192.168.1.108
```

Routing logic:

```text
client -> DNS query -> dnsmasq
dnsmasq adds selected domain IPs to ipset vpn_domains

client traffic:
  dst in vpn_domains/vpn_nets -> mark 200 -> table 200 -> WireGuard container -> wg0
  other internet traffic      -> direct NAT via LAN router
  local hostnames             -> custom-hosts.hosts
```

## Repository layout

```text
.
├── docker-compose.yml
├── dnsmasq/
│   └── dnsmasq.conf
├── lists/
│   ├── custom-hosts.hosts
│   ├── vpn-domains.txt
│   └── vpn-nets.txt
├── scripts/
│   ├── apply-rules.sh
│   └── rebuild-lists.sh
├── systemd/
│   └── vpn-router-rules.service
├── wireguard/
│   └── wg0.conf.example
└── .gitignore
```

## Install

```bash
apt update
apt install -y docker.io docker-compose-plugin ipset iptables curl dnsutils git

mkdir -p /opt/stacks
cd /opt/stacks
git clone https://github.com/vtk51/vpn-router-dns.git vpn-router
cd /opt/stacks/vpn-router
```

Create the real WireGuard config:

```bash
cp wireguard/wg0.conf.example wireguard/wg0.conf
nano wireguard/wg0.conf
chmod 600 wireguard/wg0.conf
```

Start containers:

```bash
docker compose up -d
```

Detect the actual WireGuard container IP and Docker bridge:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vpn-router-wg
ip route | grep 172
```

Edit `scripts/apply-rules.sh` if needed:

```bash
LAN_IF="ens18"
LAN_NET="192.168.1.0/24"
TEST_CLIENT="192.168.1.0/24"
```

Then apply:

```bash
chmod +x scripts/*.sh
./scripts/rebuild-lists.sh
./scripts/apply-rules.sh
```

## systemd autostart

```bash
cp systemd/vpn-router-rules.service /etc/systemd/system/vpn-router-rules.service
systemctl daemon-reload
systemctl enable vpn-router-rules.service
systemctl restart vpn-router-rules.service
```

Check:

```bash
systemctl status vpn-router-rules.service --no-pager
docker ps --format 'table {{.Names}}\t{{.Status}}'
ip rule | grep 200
ip route show table 200
ipset list vpn_nets | grep 'Number of entries'
docker exec vpn-router-wg ip route | grep 192.168
```

## Add domains through VPN

Edit:

```bash
nano /opt/stacks/vpn-router/lists/vpn-domains.txt
```

Add one domain per line:

```text
example.com
sub.example.com
```

Apply:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Check:

```bash
dig @127.0.0.1 example.com +short
ipset list vpn_domains | grep -A50 Members
```

## Add IP networks through VPN

Edit:

```bash
nano /opt/stacks/vpn-router/lists/vpn-nets.txt
```

Add one CIDR per line:

```text
1.2.3.0/24
```

Apply:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Check:

```bash
ipset list vpn_nets | grep -E '1.2.3.0|Number of entries'
```

## Add local DNS records

Edit:

```bash
nano /opt/stacks/vpn-router/lists/custom-hosts.hosts
```

Format is `/etc/hosts` style:

```text
192.168.1.107 vv.rclub137.ru vv.local vv
192.168.1.106 proxmox.local proxmox
```

Apply:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Check:

```bash
dig @127.0.0.1 vv.rclub137.ru +short
dig @127.0.0.1 proxmox.local +short
```

## Client settings

Set clients manually or via DHCP:

```text
Gateway: 192.168.1.108
DNS:     192.168.1.108
```

## Windows quick test

```bat
ipconfig /flushdns
curl -4 -I --max-time 10 https://chatgpt.com
curl -4 -I --max-time 10 https://youtube.com
curl -4 -I --max-time 10 https://ya.ru
nslookup vv.rclub137.ru 192.168.1.108
```

Expected:

- `chatgpt.com` and `youtube.com` answer through VPN;
- `ya.ru` answers directly;
- local records return LAN IPs.

## Important security note

Do not commit the real WireGuard config:

```text
wireguard/wg0.conf
```

Only `wireguard/wg0.conf.example` belongs in Git.
