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
echo "      (Mihomo Native Gateway, Vaultwarden, Samba)        "
echo "========================================================="
echo ""

APP_DIR="/opt/homelab"
ENV_FILE="${APP_DIR}/.env"

# Подгрузка сохраненных значений, если файл существует
if [ -f "${ENV_FILE}" ]; then
    echo "[*] Обнаружен файл сохраненной конфигурации (${ENV_FILE})."
    echo "    Нажмите Enter, чтобы сохранить текущее значение, или введите новое."
    echo ""
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

# 1. Автоопределение локального IP
AUTO_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
AUTO_IP=${AUTO_IP:-192.168.1.1}
DEFAULT_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')

SAVED_LOCAL_IP=${SAVED_LOCAL_IP:-$AUTO_IP}
read -rp "[?] Локальный IP сервера [${SAVED_LOCAL_IP}]: " INPUT_IP
LOCAL_IP=${INPUT_IP:-$SAVED_LOCAL_IP}
echo "[+] Используется IP: ${LOCAL_IP}"
echo ""

# 2. Интерактивный ввод параметров домена и подписки
echo "--- Настройка внешнего доступа (DuckDNS) ---"
read -rp "[?] Поддомен DuckDNS [${SAVED_DUCKDNS_NAME}]: " INPUT_DUCKDNS_NAME
DUCKDNS_NAME=${INPUT_DUCKDNS_NAME:-$SAVED_DUCKDNS_NAME}
while [ -z "$DUCKDNS_NAME" ]; do
    echo "[-] Ошибка: имя поддомена не может быть пустым!"
    read -rp "[?] Поддомен DuckDNS: " DUCKDNS_NAME
done
DUCKDNS_DOMAIN="${DUCKDNS_NAME}.duckdns.org"

# Маскирование токена при выводе подсказки
if [ -n "$SAVED_DUCKDNS_TOKEN" ]; then
    MASKED_TOKEN="${SAVED_DUCKDNS_TOKEN:0:4}...${SAVED_DUCKDNS_TOKEN: -4}"
    TOKEN_PROMPT="[?] Токен DuckDNS [${MASKED_TOKEN}]: "
else
    TOKEN_PROMPT="[?] Токен DuckDNS: "
fi
read -rp "${TOKEN_PROMPT}" INPUT_DUCKDNS_TOKEN
DUCKDNS_TOKEN=${INPUT_DUCKDNS_TOKEN:-$SAVED_DUCKDNS_TOKEN}
while [ -z "$DUCKDNS_TOKEN" ]; do
    echo "[-] Ошибка: токен DuckDNS обязателен для получения HTTPS сертификата!"
    read -rp "[?] Токен DuckDNS: " DUCKDNS_TOKEN
done
echo ""

echo "--- Настройка прокси (Mihomo) ---"
if [ -n "$SAVED_SUB_URL" ]; then
    SUB_PROMPT="[?] Ссылка на Clash-подписку (URL) [сохранена, Enter - оставить]: "
else
    SUB_PROMPT="[?] Ссылка на Clash-подписку (URL): "
fi
read -rp "${SUB_PROMPT}" INPUT_SUB_URL
SUB_URL=${INPUT_SUB_URL:-$SAVED_SUB_URL}
while [ -z "$SUB_URL" ]; do
    echo "[-] Ошибка: ссылка на подписку обязательна!"
    read -rp "[?] Ссылка на Clash-подписку (URL): " SUB_URL
done
echo ""

echo "--- Настройка учетных записей и безопасности ---"
SAVED_TARGET_USER=${SAVED_TARGET_USER:-neko}
read -rp "[?] Имя пользователя системы и Samba [${SAVED_TARGET_USER}]: " INPUT_USER
TARGET_USER=${INPUT_USER:-$SAVED_TARGET_USER}

SAVED_SAMBA_PASS=${SAVED_SAMBA_PASS:-ChangeMe123}
read -rp "[?] Пароль для сетевой папки Samba (${TARGET_USER}) [${SAVED_SAMBA_PASS}]: " INPUT_SAMBA_PASS
SAMBA_PASS=${INPUT_SAMBA_PASS:-$SAVED_SAMBA_PASS}

SAVED_MIHOMO_SECRET=${SAVED_MIHOMO_SECRET:-123456}
read -rp "[?] Секретный ключ (secret) для Mihomo / MetaCubeXD [${SAVED_MIHOMO_SECRET}]: " INPUT_MIHOMO_SECRET
MIHOMO_SECRET=${INPUT_MIHOMO_SECRET:-$SAVED_MIHOMO_SECRET}

SAVE_DIR="/home/${TARGET_USER}/save"

# Сохранение учетных данных в защищенный .env файл
mkdir -p "${APP_DIR}"
cat <<EOF > "${ENV_FILE}"
SAVED_LOCAL_IP="${LOCAL_IP}"
SAVED_DUCKDNS_NAME="${DUCKDNS_NAME}"
SAVED_DUCKDNS_TOKEN="${DUCKDNS_TOKEN}"
SAVED_SUB_URL="${SUB_URL}"
SAVED_TARGET_USER="${TARGET_USER}"
SAVED_SAMBA_PASS="${SAMBA_PASS}"
SAVED_MIHOMO_SECRET="${MIHOMO_SECRET}"
EOF
chmod 600 "${ENV_FILE}"
echo "[+] Конфигурация сохранена в ${ENV_FILE} (права 600)."
echo ""

echo "[+] Все параметры получены. Начинаем установку..."
sleep 2

# ==========================================
# 1. ПОДГОТОВКА СИСТЕМЫ И ПАКЕТОВ
# ==========================================
echo "=== [1/7] Установка пакетов и тюнинг сети Arch Linux ==="
pacman -Syu --noconfirm --needed docker docker-compose curl jq ca-certificates iptables-nft unzip

# Освобождаем 53 порт от systemd-resolved для чистоты
mkdir -p /etc/systemd/resolved.conf.d/
cat <<EOF > /etc/systemd/resolved.conf.d/disable-stub.conf
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved || true

# Безопасная страховка локального resolv.conf хоста
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
echo "=== [2/7] Создание каталогов и пользователей ==="
id -u "${TARGET_USER}" &>/dev/null || useradd -m -s /bin/bash "${TARGET_USER}"
usermod -aG docker "${TARGET_USER}" || true

USER_UID=$(id -u "${TARGET_USER}")
USER_GID=$(id -g "${TARGET_USER}")

mkdir -p "${SAVE_DIR}"
mkdir -p "${APP_DIR}/caddy/data" "${APP_DIR}/caddy/config"
mkdir -p "${APP_DIR}/mihomo/ui"
mkdir -p "${APP_DIR}/vaultwarden"

chown -R "${TARGET_USER}:${TARGET_USER}" "${SAVE_DIR}"
chmod 770 "${SAVE_DIR}"

# ==========================================
# 3. СКАЧИВАНИЕ И ПАТЧ METACUBEXD UI
# ==========================================
echo "=== [3/7] Развертывание и патч веб-панели MetaCubeXD ==="
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
echo "=== [4/7] Настройка фонового сервиса обновления DuckDNS ==="
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
# 5. КОНФИГУРАЦИЯ MIHOMO (С DNS REWRITE И 53 ПОРТОМ)
# ==========================================
echo "=== [5/7] Создание конфигурации Mihomo ==="
cat <<EOF > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
secret: "${MIHOMO_SECRET}"
external-controller: 0.0.0.0:9090
external-ui: ui

hosts:
  '${DUCKDNS_DOMAIN}': '${LOCAL_IP}'

dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.duckdns.org"
    - "${DUCKDNS_DOMAIN}"
    - "*.lan"
    - "*.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
  default-nameserver:
    - 77.88.8.8
    - 1.1.1.1
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - 77.88.8.8
    - 1.1.1.1
  direct-nameserver:
    - 77.88.8.8
    - 77.88.8.1

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
  - GEOIP,private,DIRECT,no-resolve
  - GEOIP,lan,DIRECT,no-resolve
  - MATCH,PROXY
EOF

# ==========================================
# 6. CADDYFILE & DOCKER COMPOSE
# ==========================================
echo "=== [6/7] Создание Caddyfile и docker-compose.yml ==="
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

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_INCLUDE_RESTARTING=true
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
# 7. ЗАПУСК ВСЕХ СЕРВИСОВ
# ==========================================
echo "=== [7/7] Загрузка образов и старт стека ==="
cd "${APP_DIR}"
docker compose pull
docker compose up -d

echo ""
echo "========================================================="
echo "   Установка и настройка шлюза успешно завершена!       "
echo "========================================================="
echo ""
echo "  [+] Панель MetaCubeXD:"
echo "      http://${LOCAL_IP}:9090/ui/#/?hostname=${LOCAL_IP}&port=9090&secret=${MIHOMO_SECRET}"
echo ""
echo "  [+] DNS & Прокси-шлюз (Mihomo):"
echo "      DNS-сервер:     ${LOCAL_IP}:53"
echo "      DNS Rewrite:    ${DUCKDNS_DOMAIN} -> ${LOCAL_IP}"
echo ""
echo "  [+] Менеджер паролей Vaultwarden:"
echo "      Адрес:  https://${DUCKDNS_DOMAIN}"
echo ""
echo "  [+] Сетевая папка Samba:"
echo "      Путь:   \\\\${LOCAL_IP}\\save"
echo "      Логин:  ${TARGET_USER}"
echo "      Пароль: ${SAMBA_PASS}"
echo "========================================================="
