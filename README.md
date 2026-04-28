# VPN Router DNS

Прозрачный VPN-шлюз для локальной сети на Docker.

Что делает:

- выбранные домены и IP-подсети отправляет через WireGuard VPN;
- остальной интернет выпускает напрямую через обычный роутер;
- раздаёт DNS через `dnsmasq`;
- умеет локальные DNS-записи в стиле `/etc/hosts`.

## Пример схемы

```text
Роутер:       192.168.1.100
VPN-шлюз:     192.168.1.108
Сеть:         192.168.1.0/24
Интерфейс:    ens18

Клиенты:
  Gateway:    192.168.1.108
  DNS:        192.168.1.108
```

## Состав

```text
docker-compose.yml              контейнеры WireGuard и dnsmasq
wireguard/wg0.conf.example      пример WireGuard-конфига
lists/vpn-domains.txt           домены через VPN
lists/vpn-nets.txt              IP/подсети через VPN
lists/custom-hosts.hosts        локальные DNS-записи
scripts/rebuild-lists.sh        пересобрать DNS/IP-списки
scripts/apply-rules.sh          применить маршруты и iptables
systemd/vpn-router-rules.service автозапуск правил
```

## Установка

```bash
apt update
apt install -y docker.io docker-compose-plugin ipset iptables curl dnsutils git

mkdir -p /opt/stacks
cd /opt/stacks
git clone https://github.com/vtk51/vpn-router-dns.git vpn-router
cd /opt/stacks/vpn-router
```

## Настройка WireGuard

```bash
cp wireguard/wg0.conf.example wireguard/wg0.conf
nano wireguard/wg0.conf
chmod 600 wireguard/wg0.conf
```

Пример:

```ini
[Interface]
PrivateKey = CHANGE_ME
Address = 10.8.0.8/24
DNS = 8.8.8.8, 1.1.1.1
MTU = 1420

[Peer]
PublicKey = CHANGE_ME
PresharedKey = CHANGE_ME
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
Endpoint = example.com:51820
```

## Запуск

```bash
docker compose up -d
```

Проверить VPN:

```bash
docker exec vpn-router-wg wg show
docker exec vpn-router-wg curl -4 --max-time 10 ifconfig.me
```

## Настройка переменных

В `scripts/apply-rules.sh` проверь параметры под свою сеть:

```bash
WG_CONT_IP="172.18.0.2"
WG_BR="br-de01a1582803"
LAN_IF="ens18"
LAN_NET="192.168.1.0/24"
TEST_CLIENT="192.168.1.0/24"
```

Узнать IP контейнера и bridge:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vpn-router-wg
ip route | grep 172
```

## Применить правила

```bash
chmod +x scripts/*.sh
./scripts/rebuild-lists.sh
./scripts/apply-rules.sh
```

## Автозапуск

```bash
cp systemd/vpn-router-rules.service /etc/systemd/system/vpn-router-rules.service
systemctl daemon-reload
systemctl enable vpn-router-rules.service
systemctl restart vpn-router-rules.service
```

Проверить:

```bash
systemctl status vpn-router-rules.service --no-pager
docker ps
ip rule | grep 200
ip route show table 200
```

## Добавить домен через VPN

```bash
nano /opt/stacks/vpn-router/lists/vpn-domains.txt
```

Пример:

```text
chatgpt.com
youtube.com
example.com
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

## Добавить IP/подсеть через VPN

```bash
nano /opt/stacks/vpn-router/lists/vpn-nets.txt
```

Пример:

```text
1.2.3.0/24
8.8.8.8/32
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

## Локальные DNS-записи

```bash
nano /opt/stacks/vpn-router/lists/custom-hosts.hosts
```

Формат как `/etc/hosts`:

```text
192.168.1.107 vv.example.local vv
192.168.1.106 proxmox.local proxmox
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Проверить:

```bash
dig @127.0.0.1 vv.example.local +short
```

## Настройка клиентов

На клиентах вручную или через DHCP указать:

```text
Gateway: 192.168.1.108
DNS:     192.168.1.108
```

## Быстрая проверка с Windows

```bat
ipconfig /flushdns
curl -4 -I --max-time 10 https://chatgpt.com
curl -4 -I --max-time 10 https://youtube.com
curl -4 -I --max-time 10 https://ya.ru
nslookup vv.example.local 192.168.1.108
```

## Диагностика

```bash
# DNS и ipset
dig @127.0.0.1 youtube.com +short
ipset list vpn_domains | head -80
ipset list vpn_nets | head -80

# policy routing
ip rule
ip route show table 200

# счётчики iptables
iptables -t mangle -L PREROUTING -v -n | grep vpn_
iptables -L FORWARD -v -n | head -20
iptables -t nat -L POSTROUTING -v -n

# WireGuard-контейнер
docker exec vpn-router-wg wg show
docker exec vpn-router-wg ip route
```

## Важно

Реальный WireGuard-конфиг не хранить в репозитории:

```text
wireguard/wg0.conf
```

В репозитории должен быть только пример:

```text
wireguard/wg0.conf.example
```
