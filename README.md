# VPN Router DNS

Docker-схема для прозрачного шлюза в локальной сети с раздельной маршрутизацией:

- выбранные домены и IP-подсети идут через WireGuard VPN;
- остальной трафик идёт напрямую через обычный роутер;
- локальные DNS-записи обслуживаются через `dnsmasq`.

Проверено на Debian 12, Docker Compose, `iptables-nft`, `ipset`, `dnsmasq` и контейнере `lscr.io/linuxserver/wireguard`.

## Схема сети

Пример рабочей конфигурации:

```text
Роутер LAN:        192.168.1.100
VPN-router host:   192.168.1.108
Локальная сеть:    192.168.1.0/24
LAN-интерфейс:     ens18

Клиенты:
  шлюз:            192.168.1.108
  DNS:             192.168.1.108
```

Логика маршрутизации:

```text
клиент -> DNS-запрос -> dnsmasq
dnsmasq добавляет IP выбранных доменов в ipset vpn_domains

трафик клиента:
  dst в vpn_domains/vpn_nets -> mark 200 -> table 200 -> WireGuard container -> wg0
  остальной интернет         -> прямой NAT через LAN-роутер
  локальные имена            -> custom-hosts.hosts
```

## Структура репозитория

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

## Что за что отвечает

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | Запускает WireGuard-клиент и `dnsmasq` |
| `wireguard/wg0.conf` | Реальный WireGuard-конфиг, не хранится в Git |
| `wireguard/wg0.conf.example` | Безопасный пример WireGuard-конфига |
| `lists/vpn-domains.txt` | Домены, которые должны идти через VPN |
| `lists/vpn-nets.txt` | IP/подсети, которые должны идти через VPN |
| `lists/custom-hosts.hosts` | Локальные DNS-записи в формате `/etc/hosts` |
| `scripts/rebuild-lists.sh` | Пересобирает `dnsmasq.conf`, обновляет ipset и применяет правила |
| `scripts/apply-rules.sh` | Применяет маршруты, NAT и iptables-правила |
| `systemd/vpn-router-rules.service` | Автозапуск правил после перезагрузки |

## Установка

```bash
apt update
apt install -y docker.io docker-compose-plugin ipset iptables curl dnsutils git

mkdir -p /opt/stacks
cd /opt/stacks
git clone https://github.com/vtk51/vpn-router-dns.git vpn-router
cd /opt/stacks/vpn-router
```

## WireGuard-конфиг

Создать реальный конфиг из примера:

```bash
cp wireguard/wg0.conf.example wireguard/wg0.conf
nano wireguard/wg0.conf
chmod 600 wireguard/wg0.conf
```

Пример структуры:

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

Реальный файл `wireguard/wg0.conf` не должен попадать в GitHub.

## Запуск контейнеров

```bash
docker compose up -d
```

Проверить WireGuard:

```bash
docker exec vpn-router-wg wg show
docker exec vpn-router-wg curl -4 --max-time 10 ifconfig.me
```

## Проверка Docker bridge и IP контейнера

На новом сервере Docker bridge и IP контейнера могут отличаться. Проверить:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vpn-router-wg
ip route | grep 172
```

Если значения отличаются, поправить в `scripts/apply-rules.sh`:

```bash
WG_CONT_IP="172.18.0.2"
WG_BR="br-de01a1582803"
LAN_IF="ens18"
LAN_NET="192.168.1.0/24"
TEST_CLIENT="192.168.1.0/24"
```

Где:

| Переменная | Что означает |
|---|---|
| `WG_CONT_IP` | IP контейнера `vpn-router-wg` в Docker-сети |
| `WG_BR` | bridge-интерфейс Docker-сети проекта |
| `LAN_IF` | сетевой интерфейс сервера в локальной сети |
| `LAN_NET` | локальная сеть |
| `TEST_CLIENT` | кого маршрутизировать; для всей сети — `192.168.1.0/24` |

## Применение правил

```bash
chmod +x scripts/*.sh
./scripts/rebuild-lists.sh
./scripts/apply-rules.sh
```

Проверка:

```bash
ip rule | grep 200
ip route show table 200
iptables -t mangle -L PREROUTING -v -n | grep vpn_
iptables -L FORWARD -v -n | head -20
iptables -t nat -L POSTROUTING -v -n | grep 192.168.1
docker exec vpn-router-wg ip route | grep 192.168
```

## Автозапуск через systemd

```bash
cp systemd/vpn-router-rules.service /etc/systemd/system/vpn-router-rules.service
systemctl daemon-reload
systemctl enable vpn-router-rules.service
systemctl restart vpn-router-rules.service
```

Проверка:

```bash
systemctl status vpn-router-rules.service --no-pager
docker ps --format 'table {{.Names}}\t{{.Status}}'
ip rule | grep 200
ip route show table 200
ipset list vpn_nets | grep 'Number of entries'
docker exec vpn-router-wg ip route | grep 192.168
```

Ожидаемо:

```text
vpn-router-rules.service: active (exited)
vpn-router-wg:            Up
vpn-router-dns:           Up
fwmark 0xc8 -> table 200: есть
table 200 -> WireGuard:   есть
```

## Добавление доменов через VPN

Редактировать:

```bash
nano /opt/stacks/vpn-router/lists/vpn-domains.txt
```

Формат — один домен на строку:

```text
example.com
sub.example.com
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Проверить:

```bash
dig @127.0.0.1 example.com +short
ipset list vpn_domains | grep -A50 Members
```

Важно: `vpn-domains.txt` — основной файл для доменов. `dnsmasq/dnsmasq.conf` генерируется автоматически, руками его обычно не править.

## Добавление IP/подсетей через VPN

Редактировать:

```bash
nano /opt/stacks/vpn-router/lists/vpn-nets.txt
```

Формат — один CIDR на строку:

```text
1.2.3.0/24
8.8.8.8/32
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Проверить:

```bash
ipset list vpn_nets | grep -E '1.2.3.0|Number of entries'
```

## Локальные DNS-записи

Файл:

```bash
nano /opt/stacks/vpn-router/lists/custom-hosts.hosts
```

Формат как у `/etc/hosts`:

```text
192.168.1.107 vv.rclub137.ru vv.local vv
192.168.1.106 proxmox.local proxmox
192.168.1.109 mon.rclub137.ru
```

Применить:

```bash
/opt/stacks/vpn-router/scripts/rebuild-lists.sh
```

Проверить:

```bash
dig @127.0.0.1 vv.rclub137.ru +short
dig @127.0.0.1 proxmox.local +short
```

Ожидаемый ответ:

```text
192.168.1.107
192.168.1.106
```

## Пользовательские DNS-серверы для зон

Если нужно не статическую запись, а пересылку зоны на другой DNS, используется директива `server=/zone/dns_ip`.

Пример для внутренней зоны:

```ini
server=/office.local/192.168.1.100
server=/corp.local/192.168.1.100
server=/1.168.192.in-addr.arpa/192.168.1.100
```

Сейчас такая логика не вынесена в отдельный файл. Если нужно — можно добавить отдельный список `lists/custom-dns.txt` и генерацию в `rebuild-lists.sh`.

## Настройка клиентов

На клиенте вручную или через DHCP нужно указать:

```text
Шлюз: 192.168.1.108
DNS:   192.168.1.108
```

Если в DHCP роутера оставить шлюз `192.168.1.100`, устройства продолжат ходить мимо VPN-router.

## Быстрая проверка на Windows

```bat
ipconfig /flushdns
curl -4 -I --max-time 10 https://chatgpt.com
curl -4 -I --max-time 10 https://youtube.com
curl -4 -I --max-time 10 https://ya.ru
nslookup vv.rclub137.ru 192.168.1.108
```

Ожидаемо:

- `chatgpt.com` и `youtube.com` отвечают через VPN;
- `ya.ru` отвечает напрямую;
- локальные записи возвращают LAN IP.

## Диагностика

Проверить, наполняется ли доменный ipset:

```bash
dig @127.0.0.1 youtube.com +short
ipset list vpn_domains | head -80
```

Проверить маршруты:

```bash
ip rule
ip route show table 200
```

Проверить счётчики маркировки:

```bash
iptables -t mangle -L PREROUTING -v -n | grep vpn_
```

Проверить прямой NAT:

```bash
iptables -t nat -L POSTROUTING -v -n | grep 192.168.1
iptables -L FORWARD -v -n | head -20
```

Проверить контейнер WireGuard:

```bash
docker exec vpn-router-wg wg show
docker exec vpn-router-wg ip route
docker exec vpn-router-wg iptables -L FORWARD -v -n
docker exec vpn-router-wg iptables -t nat -L POSTROUTING -v -n | grep MASQUERADE
```

## Перенос на другой сервер

На старом сервере:

```bash
cd /opt/stacks
tar czf /root/vpn-router-backup.tar.gz vpn-router
```

На новом сервере:

```bash
apt update
apt install -y docker.io docker-compose-plugin ipset iptables curl dnsutils git
mkdir -p /opt/stacks
cd /opt/stacks
tar xzf /root/vpn-router-backup.tar.gz
cd /opt/stacks/vpn-router
docker compose up -d
```

После переноса обязательно проверить и при необходимости поправить:

```bash
ip -br a
ip route
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' vpn-router-wg
ip route | grep 172
```

Затем обновить переменные в `scripts/apply-rules.sh`, применить правила и включить systemd.

## Безопасность

Не коммитить реальный WireGuard-конфиг:

```text
wireguard/wg0.conf
```

В Git должен попадать только пример:

```text
wireguard/wg0.conf.example
```

Также не рекомендуется публиковать полный список внутренних DNS-записей, если репозиторий станет публичным.
