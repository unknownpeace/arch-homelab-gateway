#!/usr/bin/env bash
set -e

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Скрипт должен быть запущен от имени root!"
    echo "    Пример: curl -sSL <url> | sudo bash"
    exit 1
fi

# Убеждаемся, что интерактивный ввод работает даже через curl | bash
exec < /dev/tty

clear
echo "========================================================="
echo "   Arch Linux Minimal Homelab & Network Gateway Setup    "
echo "        (AdGuard Home, Mihomo, Vaultwarden, Samba)       "
echo "========================================================="
echo ""

# 1. Автоопределение локального IP
AUTO_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
AUTO_IP=${AUTO_IP:-192.168.1.1}
DEFAULT_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')

read -rp "[?] Локальный IP сервера [$AUTO_IP] (Enter для подтверждения): " INPUT_IP
LOCAL_IP=${INPUT_IP:-$AUTO_IP}
echo "[+] Используется IP: ${LOCAL_IP}"
echo ""

# 2. Интерактивный ввод параметров домена и подписки
echo "--- Настройка внешнего доступа (DuckDNS) ---"
read -rp "[?] Поддомен DuckDNS (например, myserver для myserver.duckdns.org): " DUCKDNS_NAME
while [ -z "$DUCKDNS_NAME" ]; do
    echo "[-] Ошибка: имя поддомена не может быть пустым!"
    read -rp "[?] Поддомен DuckDNS: " DUCKDNS_NAME
done
DUCKDNS_DOMAIN="${DUCKDNS_NAME}.duckdns.org"

read -rp "[?] Токен DuckDNS (токен из личного кабинета): " DUCKDNS_TOKEN
while [ -z "$DUCKDNS_TOKEN" ]; do
    echo "[-] Ошибка: токен DuckDNS обязателен для получения HTTPS сертификата!"
    read -rp "[?] Токен DuckDNS: " DUCKDNS_TOKEN
done
echo ""

echo "--- Настройка прокси (Mihomo) ---"
read -rp "[?] Ссылка на Clash-подписку (URL): " SUB_URL
while [ -z "$SUB_URL" ]; do
    echo "[-] Ошибка: ссылка на подписку обязательна!"
    read -rp "[?] Ссылка на Clash-подписку (URL): " SUB_URL
done
echo ""

echo "--- Настройка учетных записей и безопасности ---"
read -rp "[?] Имя пользователя системы и Samba [neko]: " INPUT_USER
TARGET_USER=${INPUT_USER:-neko}

read -rp "[?] Пароль для сетевой папки Samba (${TARGET_USER}) [ChangeMe123]: " INPUT_SAMBA_PASS
SAMBA_PASS=${INPUT_SAMBA_PASS:-ChangeMe123}

read -rsp "[?] Пароль для AdGuard Home (admin) [admin123]: " INPUT_AGH_PASS
echo ""
AGH_PASS=${INPUT_AGH_PASS:-admin123}

read -rp "[?] Секретный ключ (secret) для Mihomo / MetaCubeXD [123456]: " INPUT_MIHOMO_SECRET
MIHOMO_SECRET=${INPUT_MIHOMO_SECRET:-123456}

SAVE_DIR="/home/${TARGET_USER}/save"
APP_DIR="/opt/homelab"

echo ""
echo "[+] Все параметры получены. Начинаем установку..."
sleep 2

# ==========================================
# 1. ПОДГОТОВКА СИСТЕМЫ И ПАКЕТОВ
# ==========================================
echo "=== [1/8] Установка пакетов и тюнинг сети Arch Linux ==="
pacman -Syu --noconfirm --needed docker docker-compose curl jq ca-certificates iptables-nft apache unzip

# Генерация bcrypt хеша пароля для AdGuard Home
echo "[+] Хеширование пароля AdGuard Home..."
AGH_HASH=$(htpasswd -B -C 10 -n -b admin "${AGH_PASS}" | cut -d: -f2)

# Освобождаем 53 порт от systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d/
cat <<EOF > /etc/systemd/resolved.conf.d/disable-stub.conf
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved || true

# Безопасная страховка локального resolv.conf
if [ -f /run/systemd/resolve/resolv.conf ]; then
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

# Включаем сетевой форвардинг ядра для роли шлюза
cat <<EOF > /etc/sysctl.d/99-gateway.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system

# Включаем NAT (Masquerade) для LAN клиентов
if [ -n "${DEFAULT_IFACE}" ]; then
    iptables -t nat -C POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE
fi

# Локальный хост должен знать свой собственный домен напрямую
if ! grep -q "${DUCKDNS_DOMAIN}" /etc/hosts; then
    echo "${LOCAL_IP} ${DUCKDNS_DOMAIN}" >> /etc/hosts
else
    sed -i "s/.*${DUCKDNS_DOMAIN}/${LOCAL_IP} ${DUCKDNS_DOMAIN}/" /etc/hosts
fi

# ==========================================
# 2. ПОЛЬЗОВАТЕЛИ И ДИРЕКТОРИИ
# ==========================================
echo "=== [2/8] Создание каталогов и пользователей ==="
id -u "${TARGET_USER}" &>/dev/null || useradd -m -s /bin/bash "${TARGET_USER}"
usermod -aG docker "${TARGET_USER}" || true

USER_UID=$(id -u "${TARGET_USER}")
USER_GID=$(id -g "${TARGET_USER}")

mkdir -p "${SAVE_DIR}"
mkdir -p "${APP_DIR}/caddy/data" "${APP_DIR}/caddy/config"
mkdir -p "${APP_DIR}/mihomo/ui"
mkdir -p "${APP_DIR}/adguard/work" "${APP_DIR}/adguard/conf"
mkdir -p "${APP_DIR}/vaultwarden"

chown -R "${TARGET_USER}:${TARGET_USER}" "${SAVE_DIR}"
chmod 770 "${SAVE_DIR}"

# ==========================================
# 3. СКАЧИВАНИЕ И ПАТЧ METACUBEXD UI
# ==========================================
echo "=== [3/8] Развертывание и патч веб-панели MetaCubeXD ==="
curl -sL "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" -o /tmp/metacubexd.zip
mkdir -p /tmp/metacubexd-extract
unzip -qo /tmp/metacubexd.zip -d /tmp/metacubexd-extract
cp -rf /tmp/metacubexd-extract/*/* "${APP_DIR}/mihomo/ui/"
rm -rf /tmp/metacubexd.zip /tmp/metacubexd-extract

# Заменяем зашитый 127.0.0.1 на локальный IP в бандлах панели
find "${APP_DIR}/mihomo/ui" -type f \( -name "*.js" -o -name "*.html" \) -exec sed -i "s|127.0.0.1:9090|${LOCAL_IP}:9090|g" {} + 2>/dev/null || true
find "${APP_DIR}/mihomo/ui" -type f \( -name "*.js" -o -name "*.html" \) -exec sed -i "s|localhost:9090|${LOCAL_IP}:9090|g" {} + 2>/dev/null || true

# ==========================================
# 4. НАСТРОЙКА DUCKDNS DDNS ТАЙМЕРА
# ==========================================
echo "=== [4/8] Настройка фонового сервиса обновления DuckDNS ==="
cat <<EOF > /etc/systemd/system/duckdns.service
[Unit]
Description=DuckDNS DDNS Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/curl -sS --retry 3 "https://www.duckdns.org/update?domains=${DUCKDNS_NAME}&token=${DUCKDNS_TOKEN}&ip="
EOF

cat <<EOF > /etc/systemd/system/duckdns.timer
[Unit]
Description=Run DuckDNS updater every 15 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now duckdns.timer

# ==========================================
# 5. КОНФИГУРАЦИЯ ADGUARD HOME
# ==========================================
echo "=== [5/8] Генерация конфигурации AdGuardHome.yaml ==="
cat << 'EOF' > "${APP_DIR}/adguard/conf/AdGuardHome.yaml.template"
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
      - GET /dns-query
      - POST /dns-query
      - GET /dns-query/{ClientID}
      - POST /dns-query/{ClientID}
    insecure_enabled: false
  address: 0.0.0.0:8083
  session_ttl: 30d
users:
  - name: admin
    password: __AGH_HASH__
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: "ru"
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:1053
    - https://dns10.quad9.net/dns-query
    - quic://dns.adguard-dns.com
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
    - https://common.dot.dns.yandex.net/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 90d
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 1d
  enabled: true
  ignored_enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt
    name: 1Hosts (Lite)
    id: 1789156606
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_34.txt
    name: HaGeZi's Normal Blocklist
    id: 1789156608
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt
    name: HaGeZi's Pro Blocklist
    id: 1789156609
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt
    name: HaGeZi's Ultimate Blocklist
    id: 1789156610
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 1789156611
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt
    name: AWAvenue Ads Rule
    id: 1789156612
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt
    name: Dan Pollock's List
    id: 1789156613
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_51.txt
    name: HaGeZi's Pro++ Blocklist
    id: 1789156614
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_5.txt
    name: OISD Blocklist Small
    id: 1789156615
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_33.txt
    name: Steven Black's List
    id: 1789156616
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_69.txt
    name: ShadowWhisperer Tracking List
    id: 1789156617
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt
    name: Peter Lowe's Blocklist
    id: 1789156618
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt
    name: OISD Blocklist Big
    id: 1789156619
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_70.txt
    name: 1Hosts (Xtra)
    id: 1789156620
whitelist_filters: []
user_rules:
  - '@@||www.whoer.net^$important'
  - '@@||www.aniliberty.top^$important'
  - '@@||whoer.net^$important'
  - '@@||aniliberty.top^$important'
dhcp:
  enabled: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites:
    - domain: whoer.net
      answer: 192.168.1.1
      enabled: true
    - domain: __DUCKDNS_DOMAIN__
      answer: __LOCAL_IP__
      enabled: true
  max_http_size: 256MB
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: false
  rewrites_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
EOF

sed -e "s|__DUCKDNS_DOMAIN__|${DUCKDNS_DOMAIN}|g" \
    -e "s|__LOCAL_IP__|${LOCAL_IP}|g" \
    -e "s|__AGH_HASH__|${AGH_HASH}|g" \
    "${APP_DIR}/adguard/conf/AdGuardHome.yaml.template" > "${APP_DIR}/adguard/conf/AdGuardHome.yaml"
rm -f "${APP_DIR}/adguard/conf/AdGuardHome.yaml.template"

# ==========================================
# 6. КОНФИГУРАЦИЯ MIHOMO
# ==========================================
echo "=== [6/8] Создание конфигурации Mihomo ==="
cat <<EOF > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
secret: "${MIHOMO_SECRET}"
external-controller: 0.0.0.0:9090
external-ui: ui

dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.duckdns.org"
    - "${DUCKDNS_DOMAIN}"
    - "whoer.net"
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true

proxy-providers:
  my-sub:
    type: http
    url: "${SUB_URL}"
    path: ./proxies.yaml
    interval: 86400
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: PROXY
    type: select
    use:
      - my-sub
  - name: AUTO
    type: url-test
    use:
      - my-sub
    url: http://www.gstatic.com/generate_204
    interval: 300

rules:
  - DOMAIN,${DUCKDNS_DOMAIN},DIRECT
  - DOMAIN-SUFFIX,duckdns.org,DIRECT
  - GEOIP,lan,DIRECT,no-resolve
  - MATCH,PROXY
EOF

# ==========================================
# 7. CADDYFILE & DOCKER COMPOSE
# ==========================================
echo "=== [7/8] Создание Caddyfile и docker-compose.yml ==="
cat <<EOF > "${APP_DIR}/caddy/Caddyfile"
${DUCKDNS_DOMAIN} {
    tls {
        dns duckdns ${DUCKDNS_TOKEN}
    }
    reverse_proxy vaultwarden:80
}
EOF

cat <<EOF > "${APP_DIR}/docker-compose.yml"
services:
  samba:
    image: dperson/samba
    container_name: samba
    restart: unless-stopped
    ports:
      - "139:139"
      - "445:445"
    volumes:
      - ${SAVE_DIR}:/mount/save
    environment:
      - USERID=${USER_UID}
      - GROUPID=${USER_GID}
    command: -u "${TARGET_USER};${SAMBA_PASS}" -s "save;/mount/save;yes;no;no;${TARGET_USER}"

  adguard:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf

  mihomo:
    image: metacubex/mihomo:latest
    container_name: mihomo
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - ./mihomo:/root/.config/mihomo

  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - WEBSOCKET_ENABLED=true
    volumes:
      - ./vaultwarden:/data

  caddy:
    image: serfriz/caddy-duckdns:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
EOF

# Создание сервиса автозапуска при загрузке
cat <<EOF > /etc/systemd/system/homelab.service
[Unit]
Description=Homelab Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now docker
systemctl enable homelab.service

# ==========================================
# 8. ЗАПУСК ВСЕХ СЕРВИСОВ
# ==========================================
echo "=== [8/8] Загрузка образов и старт стека ==="
cd "${APP_DIR}"
docker compose pull
docker compose up -d

echo ""
echo "========================================================="
echo "   Установка и настройка шлюза успешно завершена!       "
echo "========================================================="
echo ""
echo "  [+] Панель MetaCubeXD (вход в 1 клик без ввода IP):"
echo "      http://${LOCAL_IP}:9090/ui/#/?hostname=${LOCAL_IP}&port=9090&secret=${MIHOMO_SECRET}"
echo ""
echo "  [+] AdGuard Home:"
echo "      Адрес:  http://${LOCAL_IP}:8083"
echo "      Логин:  admin"
echo "      Пароль: ${AGH_PASS}"
echo ""
echo "  [+] Менеджер паролей Vaultwarden:"
echo "      Адрес:  https://${DUCKDNS_DOMAIN}"
echo ""
echo "  [+] Сетевая папка Samba:"
echo "      Путь:   \\\\${LOCAL_IP}\\save"
echo "      Логин:  ${TARGET_USER}"
echo "      Пароль: ${SAMBA_PASS}"
echo ""
echo "  [+] DNS-сервер для локальной сети: ${LOCAL_IP}"
echo "========================================================="