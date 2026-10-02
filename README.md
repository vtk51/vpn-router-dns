# VPN Router DNS

Выборочный **IPv4** VPN-шлюз для LAN и самого Debian-хоста: выбранные домены и
сети идут через WireGuard, остальной трафик — через обычный LAN-роутер.
dnsmasq обслуживает DNS и явные локальные записи в формате `/etc/hosts`.

Это публичная, обезличенная реализация, а не backup конкретного сервера.
Рабочие списки, настройки, WireGuard-конфиг и сгенерированный DNS-конфиг локальны.

## Архитектура

```text
LAN client (gateway + DNS = VPN host)
  -> dnsmasq (host network) -> DNS A response -> ipset vpn_domains
  -> host PREROUTING -> VPN_ROUTER_LAN -> mark 0xc8 for selected destination
host process / dnsmasq upstream
  -> host OUTPUT -> VPN_ROUTER_HOST -> selection + DNS exceptions
mark 0xc8 -> ip rule -> table 200 -> Docker bridge -> WireGuard container
  -> forwarding + NAT + TCP MSS clamp -> wg0 -> Internet
unmarked traffic -> host main routing table -> ordinary LAN router
```

- `vpn_domains`: `hash:ip family inet`, timeout `86400` секунд. dnsmasq добавляет
  IPv4-адреса по DNS-ответам для выбранных доменов и их поддоменов. Нет фонового
  предварительного разрешения всех доменов. Удаление домена из списка не удаляет
  ранее добавленные IP немедленно: они остаются до истечения timeout.
- `vpn_nets`: `hash:net family inet`, статические IPv4-сети. Обновляется через
  временный набор и `ipset swap`, без очистки рабочего набора перед загрузкой.
- IP WireGuard-контейнера, gateway и bridge определяются через Docker.
  Имя Compose project закреплено: `vpn-router`; сеть — `vpn-router_default`.
- WireGuard endpoint исключён из маркировки; его обычный маршрут должен идти
  через `LAN_IF`. Поддерживается один активный peer с IPv4 endpoint.
- Хост использует `VPN_ROUTER_LAN`, `VPN_ROUTER_HOST`, `VPN_ROUTER_FWD`,
  `VPN_ROUTER_NAT`; внутри WireGuard — forwarding/NAT и `VPN_ROUTER_MSS`.
- Все Docker-сети автоматически **не** направляются через этот VPN. Host-network
  процессы используют host policy; остальные контейнеры требуют отдельного дизайна.

### DNS-политика

В `config/router.conf` задаются IPv4-адреса upstream:

- `DNS_UPSTREAMS`: dnsmasq использует их благодаря `no-resolv`. На хосте UDP/53
  к ним принудительно маркируется для VPN, TCP/53 идёт напрямую.
- `DNS_DIRECT`: дополнительные host resolvers; UDP/TCP 53 к ним не маркируется
  проектом независимо от содержимого ipset. По умолчанию — `77.88.8.8`.
- `/etc/resolv.conf` проект не меняет. Это отдельная настройка оператора; для
  domain selection на хосте приложения должны использовать проектный dnsmasq.
- Нет перехвата чужого DNS, блокировки DoH/DoT или гарантии отсутствия DNS leaks.
  Клиенты должны добровольно использовать DNS шлюза. DNS-policy выше относится
  к host OUTPUT, а не ко всем произвольным DNS-запросам LAN-клиентов.

## Требования

- Debian-подобный Linux с systemd, IPv4 LAN и рабочим прямым default route.
- Docker Engine и **Compose v2** (`docker compose` с поддержкой `name:`).
  На Debian 12 установите Compose plugin по инструкции Docker для вашей системы:
  пакет `docker-compose-plugin` есть не во всех стандартных Debian repositories.
- WireGuard в kernel; `ipset`, `iptables` с set/conntrack/MARK/TCPMSS,
  `iproute2`, `python3`, `util-linux` (`flock`), GNU coreutils, Bash, awk, grep.
- Root для применения правил. Для диагностики: `dnsutils`, `curl`.
- Свободный UDP/TCP port 53 на выбранном LAN-интерфейсе и loopback; отсутствие
  конфликтующей DNS-службы. Проверяйте `ss -lntup`, не отключайте службы вслепую.
- Непересекающиеся LAN, Docker subnet и tunnel subnet; согласование с существующим
  firewall. Проект добавляет forwarding rules в начало цепочек, включает
  `net.ipv4.ip_forward` и полностью владеет table `200` и mark `0xc8`.

```bash
apt update
apt install -y git ipset iptables iproute2 python3 util-linux dnsutils curl
docker version
docker compose version
```

Образы пока используют `latest`; это не воспроизводимое pinning по digest.
Перед обновлением образов проверьте WireGuard и поддержку `ipset` в dnsmasq.

## Установка и конфигурация

Пример: LAN `192.168.50.0/24`, обычный роутер `192.168.50.1`, VPN-хост
`192.168.50.2`, интерфейс `eth0`. **Замените значения своими.**
Default route хоста должен оставаться через обычный роутер, не через себя.

```bash
mkdir -p /opt/stacks
git clone https://github.com/vtk51/vpn-router-dns.git /opt/stacks/vpn-router
cd /opt/stacks/vpn-router

install -m 600 config/router.conf.example config/router.conf
cp lists/vpn-domains.txt.example lists/vpn-domains.txt
cp lists/vpn-nets.txt.example lists/vpn-nets.txt
cp lists/custom-hosts.hosts.example lists/custom-hosts.hosts
cp dnsmasq/dnsmasq.conf.example dnsmasq/dnsmasq.conf
install -m 600 wireguard/wg0.conf.example wireguard/wg0.conf
chmod +x scripts/*.sh
```

1. Настройте `LAN_IF`, каноническую IPv4 `LAN_NET` и DNS arrays в
   `config/router.conf`. Это **исполняемый Bash**, держите файл root-owned и
   недоступным для записи непривилегированным пользователям. Используйте только
   IPv4 literals для DNS, без пересечения `DNS_UPSTREAMS` и `DNS_DIRECT`.
2. В bootstrap `dnsmasq/dnsmasq.conf` выставьте тот же `interface` и upstream.
   После первой пересборки файл полностью генерируется из конфигурации и списков;
   ручные дополнительные директивы при пересборке не сохраняются.
3. Замените демонстрационные списки. `198.51.100.0/24` — документационная сеть,
   **не готовая рабочая VPN-политика**. `vpn-nets.txt` должен быть непустым;
   domain list может быть пустым. Не включайте private/LAN-сети и endpoint.
4. Заполните WireGuard placeholders значениями провайдера. Удалите `PresharedKey`,
   если его нет. `AllowedIPs = 0.0.0.0/0` относится к контейнеру, не ко всему хосту.
   Endpoint hostname должен разрешаться до поднятия туннеля в IPv4 address.

`MTU = 1420` — пример, подберите под свой uplink. Реальный конфиг никогда не
добавляйте в Git. В WireGuard directory должны быть только нужные `.conf`;
Compose монтирует directory read-only в `/config/wg_confs`.

### Первый запуск

Сначала подготовьте файлы и проверьте config; **не запускайте rebuild первым**:
он требует существующих ipsets и работающего dnsmasq.

```bash
docker compose config --quiet
docker compose up -d
install -m 644 systemd/vpn-router-rules.service /etc/systemd/system/
install -m 644 systemd/vpn-router-rules.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now vpn-router-rules.timer
systemctl start vpn-router-rules.service
./scripts/rebuild-lists.sh
```

До успеха bootstrap/rebuild не переводите клиентов на новый gateway/DNS.
На клиентах вручную или через существующий DHCP укажите gateway и DNS
`192.168.50.2` (свой адрес шлюза). Проект DHCP не настраивает.

## Автоматическая сверка и обновление списков

`vpn-router-rules.timer`: первый запуск через `30s` после boot, затем через
`60s` после окончания service, с `AccuracySec=5s`. `Persistent=true` не делает
этот monotonic timer календарным механизмом воспроизведения пропущенных запусков.

Service — `oneshot`, после успешного выполнения `inactive (dead)` нормально.
Он не запускает Docker/Compose, не оживляет намеренно остановленные контейнеры.
Container lifecycle принадлежит Compose и `restart: unless-stopped`.
Если Docker неактивен либо контейнер missing/stopped, проверка завершается ошибкой
до сетевой сверки. Готовность wg0/peer ожидается до 120 секунд; это не handshake test.

При cold boot отсутствующий `vpn_nets` создаётся из проверенного локального списка,
`vpn_domains` — пустым. Существующие корректные sets не пересоздаются и не
перезаполняются timer. Неожиданная схема, пустой рабочий `vpn_nets` или missing sets
при наличии transaction record требуют диагностики.

Timer **не скачивает списки, не отслеживает их изменения и не запускает rebuild**.
Reconciler и rebuild разделяют `/run/lock/vpn-router-rebuild.lock`: timer пропускает
занятый lock и повторяет позже; rebuild ждёт exclusive lock.

### Добавить домен или сеть

```bash
nano lists/vpn-domains.txt
nano lists/vpn-nets.txt
./scripts/rebuild-lists.sh
```

- Одна запись на строку, пустые строки и полнострочные `#` comments разрешены;
  inline comments не поддерживаются.
- Домены: ASCII/punycode, без URL, wildcard и port. Нормализуются в lower-case,
  trailing dot удаляется, дубликаты исключаются; поддомены включены dnsmasq.
- Сети: IPv4 address или CIDR; host bits нормализуются, дубликаты исключаются.
  Широкие CDN-сети могут отправить через VPN посторонние сайты.

### Локальные DNS-записи

```text
192.168.50.10 server.home.arpa server
```

Редактируйте `lists/custom-hosts.hosts` и запускайте `./scripts/rebuild-lists.sh`.
Имена явные: нет `expand-hosts` или `domain=local`. Для private LAN names
предпочтителен `home.arpa`, а не конфликтующий с mDNS `.local`.

Rebuild валидирует inputs и DNS candidate, атомарно меняет `vpn_nets`, устанавливает
generated DNS config, затем выполняет **`docker compose up -d --no-deps
--force-recreate dnsmasq`**: короткий перерыв DNS ожидаем. Recreate нужен, поскольку
атомарная замена bind-mounted файла меняет inode; простой restart недостаточен.
Далее применяются routing rules и проверки, старый набор удаляется только после
успешной финализации. `vpn_domains` не очищается. Это не единая атомарная операция
для DNS + firewall + routing; при позднем сбое возможен частичный commit.

## Проверка и диагностика

Все команды ниже — для оператора после установки, не автоматические гарантии.

```bash
docker compose ps
systemctl status vpn-router-rules.timer --no-pager
journalctl -u vpn-router-rules.service -n 50 --no-pager
docker exec vpn-router-dns dnsmasq --version
docker exec vpn-router-dns dnsmasq --test --conf-file=/etc/dnsmasq.conf
docker logs --tail 50 vpn-router-dns
docker exec vpn-router-wg wg show wg0 latest-handshakes
ss -lntup

# DNS response и membership: подставьте выбранный домен и полученный IPv4.
dig @127.0.0.1 example.com A +short
ipset test vpn_domains SELECTED_IPV4
ipset list -t vpn_domains
ipset list -t vpn_nets
dig @127.0.0.1 server.home.arpa A +short

ip -4 rule show
ip -4 route show table 200
ip -4 route get SELECTED_IPV4 mark 0xc8
ip -4 route get NON_SELECTED_IPV4
ip -4 route get ENDPOINT_IPV4
iptables -t mangle -L VPN_ROUTER_HOST -nv
iptables -t mangle -L VPN_ROUTER_LAN -nv
iptables -L VPN_ROUTER_FWD -nv
docker exec vpn-router-wg ip -4 rule show
docker exec vpn-router-wg ip -4 route show table all
```

`ip route get ... mark 0xc8` проверяет policy table, **не доказывает**, что iptables
действительно пометил пакет. Проверьте счётчики и реальные HTTPS-запросы с хоста
и LAN-клиента; сравните внешний IP для выбранного и невыбранного направления.
Выбранный тестовый сервис должен быть в списках и разрешаться через этот DNS.
Используйте `curl -4 --connect-timeout 5 --max-time 15`; HTTP 401/403/404 может
подтвердить соединение/TLS, но не правильный внешний IP.

Отдельно проверяйте IPv6 (`ip -6 addr`, `ip -6 route`, `dig ... AAAA`, `curl -6`).
Проект не управляет IPv6 routing, не фильтрует AAAA и не предотвращает IPv6 bypass.
Не отключайте IPv6 вслепую; согласуйте отдельную политику.

## Ошибки и восстановление

Перед сетевыми изменениями сохраните локальные config/source files и снимки
`ip rule`, table `200`, `iptables-save`, `ipset save`; храните backup приватно.
Нужен альтернативный доступ к хосту. Не очищайте глобальные firewall/routing tables.

1. После Docker/container restart timer восстановит правила, когда prerequisites
   станут готовы. Если контейнер остановлен намеренно, запускайте его явно:
   `docker compose up -d`, затем `systemctl start vpn-router-rules.service`.
2. При ошибке rebuild сначала прочитайте stderr, журнал service и
   `/run/vpn-router/rebuild.transaction` (если существует). Record содержит phase,
   hashes, candidate set и work directory; рядом могут лежать старый конфиг и snapshots.
3. До routing reconcile скрипт пытается восстановить DNS/ipset по проверенным
   fingerprints; восстановление может не пройти, в том числе при изменении числа
   доменных правил. После reconcile failure безусловный routing rollback не выполняется.
4. Незавершённая transaction блокирует следующий rebuild. **Не удаляйте record или
   candidate set вслепую.** Сравните реальные fingerprints с record, текущий и старый
   config, references и membership наборов. Выберите подтверждённую согласованную
   пару DNS config + networks, восстановите её под общим lock и проверьте маршруты.
   Если состояние неоднозначно, остановитесь и сохраните артефакты для разбора.
5. `/run` volatile: record и rollback artifacts не переживают reboot. До reboot
   сохраните их приватно; после boot наборы строятся из локальных файлов, а не backup.

После успешного rebuild/reconcile проверьте direct Internet, VPN, DNS, LAN-клиентов,
доступ к WireGuard endpoint и SSH. Одной строки `OK` недостаточно для egress test.
Для отката обновления кода остановите timer на время согласованного обслуживания,
верните предыдущий Git commit и сохранённые локальные inputs/config, затем явно
проведите reconcile/rebuild и проверки. Откат Git сам по себе не откатывает runtime.

### Обновление старого snapshot

Не применяйте этот commit поверх работающего шлюза без backup и окна обслуживания.
Старый service имел `ExecStartPre=docker compose up -d` и direct enablement:
замените unit, уберите direct enablement service и включите timer; сохраните
рабочие списки/config локально до перехода на `.example` layout. Отключите старый
`docker-vpn-rules.service`, если он установлен, и отдельно проверьте его правила.
Новый код не делает широкую очистку `DOCKER-USER`; старые Docker-wide правила
нужно удалять только адресно после review. Точные старые правила проекта и
`VPN_HOST_OUT` обрабатываются reconciler; сторонние правила не являются его целью.

При смене `LAN_NET` старый subnet-qualified jump в `PREROUTING` автоматически
не удаляется. В окно обслуживания остановите timer, сохраните правила и под общим
lock удалите только подтверждённый старый project jump:
`iptables -t mangle -D PREROUTING -s OLD_LAN_CIDR -j VPN_ROUTER_LAN`.
Не удаляйте чужие jumps. Затем примените новый config, выполните reconcile,
возобновите timer, запустите rebuild и проверьте старую и новую LAN. Успешная
финализация rebuild требует включённого и активного timer.

## Локальные файлы и безопасность

В Git хранится только reusable code и examples:

```text
config/router.conf.example
dnsmasq/dnsmasq.conf.example
lists/vpn-domains.txt.example
lists/vpn-nets.txt.example
lists/custom-hosts.hosts.example
wireguard/wg0.conf.example
scripts/*.sh
systemd/vpn-router-rules.service
systemd/vpn-router-rules.timer
docker-compose.yml
```

Рабочие файлы без `.example`, WireGuard directory, `.env`, backups, logs,
transaction candidates и cache исключены `.gitignore`. `dnsmasq.conf` generated,
а списки и `router.conf` — локальные source files, не generated. История прежнего
публичного репозитория не переписывается; новые локальные данные не публикуйте.

- `NET_ADMIN`, `SYS_MODULE`, Docker access и host-network DNS имеют высокие
  привилегии. Доверяйте образам и root-owned configuration.
- Публичный Compose запускает dnsmasq напрямую: webproc/UI port 8080 не нужен.
  Firewall должен ограничивать доступ к port 53 доверенной LAN, иначе возможен
  открытый resolver. Этот проект не устанавливает полный host security firewall.
- Нет гарантированного kill-switch: при неисправности policy routing возможен
  direct fallback, при неисправности туннеля — потеря selected connectivity.
- Сохраняется TCP-direct DNS fallback; это не DNS leak prevention.
- Не публикуйте keys, endpoint/tunnel credentials, private hosts, реальные списки,
  `wg showconf`, `wg show ... dump`, environment dumps и backup snapshots.
- dnsmasq cache TTL и timeout ipset — разные механизмы; удаление DNS selection
  не является немедленной блокировкой трафика.

Static checks:

```bash
for f in scripts/*.sh config/router.conf.example; do bash -n "$f" || exit; done
docker compose config --quiet
systemd-analyze verify systemd/vpn-router-rules.*
```

Последняя команда может требовать штатного пути установки для проверки ExecStart.
Полноценные DNS/egress/cold-boot tests выполняйте на отдельном тестовом хосте.
