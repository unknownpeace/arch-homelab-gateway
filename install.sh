#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[-] Скрипт должен быть запущен с правами root!"
    echo "    Пример: sudo ./install.sh"
    exit 1
fi

exec < /dev/tty

clear
echo "========================================================="
echo "   Universal Homelab & Gateway Quick Setup               "
echo "   (Arch Linux & Debian 13 Trixie)                       "
echo "   (AdGuard, Mihomo TUN, Vaultwarden, qBit, Samba)       "
echo "========================================================="
echo ""

APP_DIR="/opt/homelab"
ENV_FILE="${APP_DIR}/.env"

# ==========================================
# 0. ОПРЕДЕЛЕНИЕ ДИСТРИБУТИВА И ЗАГРУЗКА .ENV
# ==========================================
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID}"
    OS_ID_LIKE="${ID_LIKE:-}"
else
    echo "[-] Не удалось определить дистрибутив Linux!"
    exit 1
fi

if [[ "${OS_ID}" =~ (arch|artix|endeavouros|manjaro) ]] || [[ "${OS_ID_LIKE}" =~ arch ]]; then
    DISTRO_TYPE="arch"
    echo "[+] Обнаружена система семейства Arch Linux"
elif [[ "${OS_ID}" =~ (debian|ubuntu) ]] || [[ "${OS_ID_LIKE}" =~ debian ]]; then
    DISTRO_TYPE="debian"
    echo "[+] Обнаружена система семейства Debian"
else
    echo "[-] Неподдерживаемый дистрибутив: ${OS_ID}. Скрипт рассчитан на Arch Linux и Debian 13."
    exit 1
fi

if [ -f "${ENV_FILE}" ]; then
    echo "[*] Обнаружен файл конфигурации с прошлыми настройками. Значения загружены."
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

# ==========================================
# 1. ПЕРВИЧНАЯ ПОДГОТОВКА И ОПРЕДЕЛЕНИЕ СЕТИ
# ==========================================
echo "[*] Установка базовых диагностических утилит..."
if [ "${DISTRO_TYPE}" = "arch" ]; then
    pacman -Sy --noconfirm --needed python iproute2 cryptsetup exfatprogs ntfs-3g util-linux curl ca-certificates >/dev/null 2>&1 || true
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3 iproute2 cryptsetup exfatprogs ntfs-3g util-linux curl ca-certificates gnupg >/dev/null 2>&1 || true
fi

if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^mihomo$"; then
        docker stop mihomo >/dev/null 2>&1 || true
    fi
fi

PHYS_IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | grep -vE '^(Meta|tun|docker|br-|veth)' | head -n1 || true)
if [ -z "${PHYS_IFACE}" ]; then
    PHYS_IFACE=$(ip -o -4 addr show scope global | awk '{print $2}' | grep -vE '^(Meta|tun|docker|br-|veth)' | head -n1)
fi

DEFAULT_IFACE="${PHYS_IFACE:-enp0s3}"
LOCAL_IP=$(ip -o -4 addr show dev "${DEFAULT_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
LOCAL_IP=${LOCAL_IP:-$(hostname -I | awk '{print $1}')}

RAW_SUBNET=$(ip -o -f inet addr show dev "${DEFAULT_IFACE}" 2>/dev/null | awk '{print $4}' | head -n1)
if [ -n "${RAW_SUBNET}" ]; then
    LAN_SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${RAW_SUBNET}', strict=False))" 2>/dev/null || echo "${RAW_SUBNET}")
else
    LAN_SUBNET="192.168.1.0/24"
fi

REAL_USER="${SUDO_USER:-$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd)}"
TARGET_USER="${SAVED_TARGET_USER:-${REAL_USER:-neko}}"
USER_UID=$(id -u "${TARGET_USER}" 2>/dev/null || echo 1000)
USER_GID=$(id -g "${TARGET_USER}" 2>/dev/null || echo 1000)

echo "[+] Параметры определены автоматически:"
echo "    • Платформа:        ${DISTRO_TYPE^^}"
echo "    • IP сервера:       ${LOCAL_IP}"
echo "    • LAN интерфейс:   ${DEFAULT_IFACE}"
echo "    • Подсеть сети:    ${LAN_SUBNET}"
echo "    • Пользователь:    ${TARGET_USER} (UID: ${USER_UID})"
echo ""

select_disk_device() {
    echo ""
    echo "[*] Поиск доступных накопителей..."
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed -E 's/p?[0-9]+$//' || true)

    mapfile -t AVAIL_DEVS < <(lsblk -dpbno NAME,SIZE,TYPE,MOUNTPOINT | awk -v root="$ROOT_DEV" '$2 > 0 && $3 != "rom" && $1 !~ root && $4 != "/" {print $1}')

    if [ ${#AVAIL_DEVS[@]} -eq 0 ]; then
        echo "[-] Дополнительные диски с доступным объемом не найдены!"
        echo "    Подключите накопитель и перезапустите скрипт."
        exit 1
    fi

    echo "Доступные накопители:"
    for i in "${!AVAIL_DEVS[@]}"; do
        DEV_NAME="${AVAIL_DEVS[$i]}"
        DEV_INFO=$(lsblk -dno SIZE,MODEL,FSTYPE "${DEV_NAME}" 2>/dev/null | xargs)
        printf "  %d) %-15s [%s]\n" "$((i+1))" "${DEV_NAME}" "${DEV_INFO:-Раздел}"
    done
    echo ""

    read -rp "[?] Выберите номер диска [1-${#AVAIL_DEVS[@]}]: " DEV_IDX
    while [[ ! "$DEV_IDX" =~ ^[0-9]+$ ]] || [ "$DEV_IDX" -lt 1 ] || [ "$DEV_IDX" -gt "${#AVAIL_DEVS[@]}" ]; do
        read -rp "[-] Неверный выбор. Введите номер из списка [1-${#AVAIL_DEVS[@]}]: " DEV_IDX
    done

    CHOSEN_DEV="${AVAIL_DEVS[$((DEV_IDX-1))]}"
    echo "[+] Выбрано устройство: ${CHOSEN_DEV}"
}

# ==========================================
# 2. ВЫБОР РЕЖИМА УСТАНОВКИ
# ==========================================
echo "Выберите вариант развертывания:"
echo "  1) Экспресс-установка (Всё включено, системный диск, *.local) [Enter]"
echo "  2) Расширенная настройка (Выбор дисков, форматирование, LUKS2)"
echo "  3) Начать сначала (Удалить контейнеры и сбросить конфиги без удаления образов)"
read -rp "[?] Ваш выбор [1/2/3] [1]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-1}
echo ""

if [ "$INSTALL_MODE" = "3" ]; then
    echo "[!] ВНИМАНИЕ: Будут остановлены контейнеры и удалены служебные конфиги стека!"
    echo "    Docker-образы и файлы в каталоге save затронуты не будут."
    read -rp "[?] Подтвердите сброс (введите 'yes' или 'YES'): " CONFIRM_RESET
    if [[ ! "${CONFIRM_RESET}" =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "[-] Отмена операции."
        exit 0
    fi

    echo "[*] Остановка контейнеров..."
    if [ -d "${APP_DIR}" ]; then
        (cd "${APP_DIR}" && docker compose down -v 2>/dev/null || true)
        echo "[*] Очистка служебных папок..."
        rm -rf "${APP_DIR}/adguard" "${APP_DIR}/mihomo" "${APP_DIR}/caddy" "${APP_DIR}/qbittorrent" "${APP_DIR}/vaultwarden" "${APP_DIR}/bot" "${ENV_FILE}"
    fi
    echo "[+] Сброс завершен. Запустите скрипт заново."
    exit 0
fi

LUKS_MAP_NAME="homelab_secure_storage"
MOUNT_ROOT="/mnt/homelab_storage"
STORAGE_DEP_LINE=""

if [ "$INSTALL_MODE" = "1" ]; then
    echo "[*] Выбран экспресс-режим."
    STORAGE_MODE="1"
    DEF_SAVE_DIR="${SAVED_SAVE_DIR:-/home/${TARGET_USER}/save}"
    read -rp "[?] Путь к каталогу данных [Enter - ${DEF_SAVE_DIR}]: " INPUT_SAVE_DIR
    SAVE_DIR=${INPUT_SAVE_DIR:-${DEF_SAVE_DIR}}
    mkdir -p "${SAVE_DIR}"

    ENABLE_GATEWAY="Y"
    ENABLE_VAULT="Y"
    ENABLE_SAMBA="Y"
    ENABLE_QBIT="Y"
    SSL_MODE="1"
    QBIT_THEME="1"

    echo "--- Экспресс-параметры ---"
    DEF_SUB="${SAVED_SUB_URL:-none}"
    read -rp "[?] Ссылка на Clash-подписку [Enter - ${DEF_SUB}]: " INPUT_SUB_URL
    SUB_URL=${INPUT_SUB_URL:-${DEF_SUB}}
    if [ -z "$SUB_URL" ] || [ "$SUB_URL" = "none" ] || [ "$SUB_URL" = "skip" ]; then
        SUB_URL="none"
        echo "[+] Режим шлюза: DIRECT (без внешнего прокси)"
    else
        echo "[+] Подписка сохранена"
    fi

    DEF_ADMIN_USER="${SAVED_ADMIN_USER:-${TARGET_USER}}"
    read -rp "[?] Имя пользователя для веб-панелей и Samba [Enter - ${DEF_ADMIN_USER}]: " INPUT_ADMIN_USER
    ADMIN_USER=${INPUT_ADMIN_USER:-${DEF_ADMIN_USER}}

    DEF_PASS="${SAVED_MASTER_PASS:-admin123}"
    read -rp "[?] Единый мастер-пароль для панелей и Samba [Enter - ${DEF_PASS}]: " INPUT_PASS
    MASTER_PASS=${INPUT_PASS:-${DEF_PASS}}
    SAMBA_PASS="${MASTER_PASS}"
    AGH_PASS="${MASTER_PASS}"
    QBIT_PASS="${MASTER_PASS}"
    MIHOMO_SECRET="${MASTER_PASS}"

    VAULT_DOMAIN="vault.local"
    ADGUARD_DOMAIN="adguard.local"
    TORRENT_DOMAIN="torrent.local"
    PROXY_DOMAIN="proxy.local"
else
    echo "--- Настройка хранилища данных ---"
    echo "  1) Путь на системном диске [Enter]"
    echo "  2) Подключить существующий диск БЕЗ шифрования"
    echo "  3) Отформатировать диск в exFAT БЕЗ шифрования (ВСЕ ДАННЫЕ УДАЛЯТСЯ)"
    echo "  4) Подключить существующий зашифрованный LUKS2 диск"
    echo "  5) Отформатировать диск в LUKS2 + exFAT (ВСЕ ДАННЫЕ УДАЛЯТСЯ)"
    DEF_STORAGE_MODE="${SAVED_STORAGE_MODE:-1}"
    read -rp "[?] Выберите вариант хранилища [1/2/3/4/5] [${DEF_STORAGE_MODE}]: " STORAGE_MODE
    STORAGE_MODE=${STORAGE_MODE:-${DEF_STORAGE_MODE}}

    if [ "$STORAGE_MODE" = "2" ]; then
        select_disk_device
        DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}" || true)
        DEV_FSTYPE=$(blkid -s TYPE -o value "${CHOSEN_DEV}" || true)

        mkdir -p "${MOUNT_ROOT}"
        MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=15s"
        if [ "$DEV_FSTYPE" = "exfat" ] || [ "$DEV_FSTYPE" = "ntfs" ] || [ "$DEV_FSTYPE" = "vfat" ]; then
            MOUNT_OPTS="${MOUNT_OPTS},uid=${USER_UID},gid=${USER_GID},umask=000,iocharset=utf8"
        fi

        mountpoint -q "${MOUNT_ROOT}" || mount -o "${MOUNT_OPTS}" "${CHOSEN_DEV}" "${MOUNT_ROOT}"

        if [ -n "${DEV_UUID}" ] && ! grep -q "${DEV_UUID}" /etc/fstab 2>/dev/null; then
            echo "UUID=${DEV_UUID} ${MOUNT_ROOT} ${DEV_FSTYPE:-auto} ${MOUNT_OPTS} 0 0" >> /etc/fstab
        fi

        STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
        DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
        read -rp "[?] Имя подкаталога на диске для данных [${DEF_SUBDIR}]: " SUBDIR_NAME
        SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
        SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
        mkdir -p "${SAVE_DIR}"

    elif [ "$STORAGE_MODE" = "3" ]; then
        select_disk_device
        echo ""
        echo "[!] ВНИМАНИЕ: Все данные на ${CHOSEN_DEV} будут уничтожены!"
        read -rp "[?] Подтвердите форматирование в exFAT (введите 'yes' или 'YES'): " CONFIRM_WIPE
        if [[ ! "${CONFIRM_WIPE}" =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "[-] Отмена операции. Скрипт остановлен."
            exit 1
        fi

        umount "${CHOSEN_DEV}" 2>/dev/null || true
        echo "[*] Очистка старых сигнатур разметки..."
        wipefs -a "${CHOSEN_DEV}"

        echo "[*] Форматирование устройства ${CHOSEN_DEV} в exFAT..."
        mkfs.exfat -L "HOMELAB" "${CHOSEN_DEV}"

        DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}")

        mkdir -p "${MOUNT_ROOT}"
        MOUNT_OPTS="defaults,noatime,nofail,uid=${USER_UID},gid=${USER_GID},umask=000,iocharset=utf8,x-systemd.device-timeout=15s"
        mount -o "${MOUNT_OPTS}" "${CHOSEN_DEV}" "${MOUNT_ROOT}"

        if [ -n "${DEV_UUID}" ] && ! grep -q "${DEV_UUID}" /etc/fstab 2>/dev/null; then
            echo "UUID=${DEV_UUID} ${MOUNT_ROOT} exfat ${MOUNT_OPTS} 0 0" >> /etc/fstab
        fi

        STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
        DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
        read -rp "[?] Имя подкаталога на диске для данных [${DEF_SUBDIR}]: " SUBDIR_NAME
        SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
        SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
        mkdir -p "${SAVE_DIR}"
        echo "[+] Диск отформатирован в exFAT и смонтирован в ${MOUNT_ROOT}"

    elif [ "$STORAGE_MODE" = "4" ] || [ "$STORAGE_MODE" = "5" ]; then
        select_disk_device

        if [ "$STORAGE_MODE" = "5" ]; then
            echo ""
            echo "[!] ВНИМАНИЕ: Все данные на ${CHOSEN_DEV} будут уничтожены!"
            read -rp "[?] Подтвердите форматирование (введите 'yes' или 'YES'): " CONFIRM_WIPE
            if [[ ! "${CONFIRM_WIPE}" =~ ^[Yy][Ee][Ss]$ ]]; then
                echo "[-] Отмена операции. Скрипт остановлен."
                exit 1
            fi

            umount "${CHOSEN_DEV}" 2>/dev/null || true
            cryptsetup close "${LUKS_MAP_NAME}" 2>/dev/null || true

            echo "[*] Очистка старых сигнатур разметки..."
            wipefs -a "${CHOSEN_DEV}"

            echo "[*] Создание крипто-контейнера LUKS2 на ${CHOSEN_DEV}..."
            cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "${CHOSEN_DEV}"

            echo "[*] Открытие созданного тома..."
            cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"

            echo "[*] Форматирование тома в exFAT..."
            mkfs.exfat -L "HOMELAB" "/dev/mapper/${LUKS_MAP_NAME}"
        fi

        if [ "$STORAGE_MODE" = "4" ]; then
            if [ ! -e "/dev/mapper/${LUKS_MAP_NAME}" ]; then
                echo "[*] Введите пароль для расшифровки ${CHOSEN_DEV}:"
                cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"
            fi
        fi

        mkdir -p "${MOUNT_ROOT}"
        mountpoint -q "${MOUNT_ROOT}" || mount -o uid=${USER_UID},gid=${USER_GID},iocharset=utf8,umask=000 "/dev/mapper/${LUKS_MAP_NAME}" "${MOUNT_ROOT}"

        DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
        read -rp "[?] Имя подкаталога на диске для данных [${DEF_SUBDIR}]: " SUBDIR_NAME
        SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
        SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
        mkdir -p "${SAVE_DIR}"

        echo ""
        read -rp "[?] Настроить авторазблокировку при старте через ключ-файл? [Y/n] [Y]: " AUTO_UNLOCK
        AUTO_UNLOCK=${AUTO_UNLOCK:-Y}

        DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}")

        if [[ "${AUTO_UNLOCK}" =~ ^[Yy]$ ]]; then
            KEY_DIR="/etc/cryptsetup-keys.d"
            KEY_FILE="${KEY_DIR}/storage_${LUKS_MAP_NAME}.key"

            mkdir -p "${KEY_DIR}"
            chmod 700 "${KEY_DIR}"

            if [ ! -f "${KEY_FILE}" ]; then
                echo "[*] Генерация ключа авторазблокировки..."
                dd if=/dev/urandom of="${KEY_FILE}" bs=512 count=1 status=none
                chmod 400 "${KEY_FILE}"

                echo "[*] Добавление ключа в слот LUKS2 (введите пароль от диска):"
                cryptsetup luksAddKey "${CHOSEN_DEV}" "${KEY_FILE}"
            fi

            if ! grep -q "${LUKS_MAP_NAME}" /etc/crypttab 2>/dev/null; then
                echo "${LUKS_MAP_NAME} UUID=${DEV_UUID} ${KEY_FILE} luks,nofail,timeout=15" >> /etc/crypttab
            fi

            FSTAB_LINE="/dev/mapper/${LUKS_MAP_NAME} ${MOUNT_ROOT} exfat defaults,noatime,nofail,uid=${USER_UID},gid=${USER_GID},iocharset=utf8,umask=000,x-systemd.device-timeout=15s 0 0"
            if ! grep -q "${MOUNT_ROOT}" /etc/fstab 2>/dev/null; then
                echo "${FSTAB_LINE}" >> /etc/fstab
            fi

            STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
            echo "[+] Авторазблокировка и автомонтирование успешно настроены!"
        fi

        cat << EOF > /usr/local/bin/homelab-unlock
#!/usr/bin/env bash
set -e
if [ "\$EUID" -ne 0 ]; then
    echo "[-] Запустите через sudo: sudo homelab-unlock"
    exit 1
fi
if [ ! -e "/dev/mapper/${LUKS_MAP_NAME}" ]; then
    echo "[*] Разблокировка ${CHOSEN_DEV}..."
    cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"
fi
mkdir -p "${MOUNT_ROOT}"
mountpoint -q "${MOUNT_ROOT}" || mount -o uid=${USER_UID},gid=${USER_GID},iocharset=utf8,umask=000 "/dev/mapper/${LUKS_MAP_NAME}" "${MOUNT_ROOT}"
echo "[*] Перезапуск сервисов..."
cd /opt/homelab && docker compose restart samba qbittorrent
echo "[+] Диск смонтирован, сервисы готовы к работе!"
EOF
        chmod +x /usr/local/bin/homelab-unlock
    else
        DEF_SAVE_DIR="${SAVED_SAVE_DIR:-/home/${TARGET_USER}/save}"
        read -rp "[?] Каталог хранения данных на системном диске [${DEF_SAVE_DIR}]: " INPUT_SAVE_DIR
        SAVE_DIR=${INPUT_SAVE_DIR:-${DEF_SAVE_DIR}}
        mkdir -p "${SAVE_DIR}"
    fi

    echo ""
    echo "--- Выбор компонентов и сети ---"
    read -rp "[?] Установить сетевой шлюз (AdGuard + Mihomo TUN)? [Y/n] [${SAVED_ENABLE_GATEWAY:-Y}]: " ENABLE_GATEWAY
    ENABLE_GATEWAY=${ENABLE_GATEWAY:-${SAVED_ENABLE_GATEWAY:-Y}}

    read -rp "[?] Установить Vaultwarden (Менеджер паролей)? [Y/n] [${SAVED_ENABLE_VAULT:-Y}]: " ENABLE_VAULT
    ENABLE_VAULT=${ENABLE_VAULT:-${SAVED_ENABLE_VAULT:-Y}}

    read -rp "[?] Установить Samba (Сетевая папка Windows)? [Y/n] [${SAVED_ENABLE_SAMBA:-Y}]: " ENABLE_SAMBA
    ENABLE_SAMBA=${ENABLE_SAMBA:-${SAVED_ENABLE_SAMBA:-Y}}

    read -rp "[?] Установить qBittorrent? [Y/n] [${SAVED_ENABLE_QBIT:-Y}]: " ENABLE_QBIT
    ENABLE_QBIT=${ENABLE_QBIT:-${SAVED_ENABLE_QBIT:-Y}}

    echo ""
    echo "--- Настройка SSL ---"
    echo "  1) Caddy Internal (*.local без регистрации в интернете)"
    echo "  2) DuckDNS + Let's Encrypt (валидный публичный Wildcard SSL)"
    read -rp "[?] Выберите режим SSL [1/2] [${SAVED_SSL_MODE:-1}]: " SSL_MODE
    SSL_MODE=${SSL_MODE:-${SAVED_SSL_MODE:-1}}

    if [ "$SSL_MODE" = "2" ]; then
        read -rp "[?] Поддомен DuckDNS [${SAVED_DUCKDNS_NAME}]: " DUCKDNS_NAME
        DUCKDNS_NAME=${DUCKDNS_NAME:-$SAVED_DUCKDNS_NAME}
        while [ -z "$DUCKDNS_NAME" ]; do
            read -rp "[-] Имя обязательно: " DUCKDNS_NAME
        done
        read -rp "[?] Токен DuckDNS [${SAVED_DUCKDNS_TOKEN}]: " DUCKDNS_TOKEN
        DUCKDNS_TOKEN=${DUCKDNS_TOKEN:-$SAVED_DUCKDNS_TOKEN}
        while [ -z "$DUCKDNS_TOKEN" ]; do
            read -rp "[-] Токен обязателен: " DUCKDNS_TOKEN
        done

        BASE_DOMAIN="${DUCKDNS_NAME}.duckdns.org"
        VAULT_DOMAIN="vault.${BASE_DOMAIN}"
        ADGUARD_DOMAIN="adguard.${BASE_DOMAIN}"
        TORRENT_DOMAIN="torrent.${BASE_DOMAIN}"
        PROXY_DOMAIN="proxy.${BASE_DOMAIN}"
    else
        SSL_MODE="1"
        VAULT_DOMAIN="vault.local"
        ADGUARD_DOMAIN="adguard.local"
        TORRENT_DOMAIN="torrent.local"
        PROXY_DOMAIN="proxy.local"
    fi

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        read -rp "[?] Ссылка на Clash-подписку (Enter для DIRECT-режима) [${SAVED_SUB_URL:-none}]: " SUB_URL
        SUB_URL=${SUB_URL:-${SAVED_SUB_URL:-none}}
    fi

    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        read -rp "[?] Тема qBittorrent: 1) VueTorrent 2) Стандартная [${SAVED_QBIT_THEME:-1}]: " QBIT_THEME
        QBIT_THEME=${QBIT_THEME:-${SAVED_QBIT_THEME:-1}}
    fi

    echo ""
    echo "--- Пользователь и пароли ---"
    DEF_ADMIN_USER="${SAVED_ADMIN_USER:-${TARGET_USER}}"
    read -rp "[?] Имя пользователя для веб-панелей и Samba [${DEF_ADMIN_USER}]: " INPUT_ADMIN_USER
    ADMIN_USER=${INPUT_ADMIN_USER:-${DEF_ADMIN_USER}}

    read -rp "[?] Единый мастер-пароль для панелей и Samba [${SAVED_MASTER_PASS:-admin123}]: " INPUT_MASTER_PASS
    MASTER_PASS=${INPUT_MASTER_PASS:-${SAVED_MASTER_PASS:-admin123}}
    SAMBA_PASS="${MASTER_PASS}"
    AGH_PASS="${MASTER_PASS}"
    QBIT_PASS="${MASTER_PASS}"
    MIHOMO_SECRET="${MASTER_PASS}"
fi

SHARE_NAME=$(basename "${SAVE_DIR}")

echo "[+] Рабочий каталог данных: ${SAVE_DIR}"
echo "[+] Имя сетевой папки Samba: ${SHARE_NAME}"
echo "[+] Пользователь для сервисов: ${ADMIN_USER}"
echo ""

mkdir -p "${APP_DIR}"
cat <<EOF > "${ENV_FILE}"
SAVED_LOCAL_IP="${LOCAL_IP}"
SAVED_LAN_SUBNET="${LAN_SUBNET}"
SAVED_ENABLE_GATEWAY="${ENABLE_GATEWAY}"
SAVED_ENABLE_VAULT="${ENABLE_VAULT}"
SAVED_ENABLE_SAMBA="${ENABLE_SAMBA}"
SAVED_ENABLE_QBIT="${ENABLE_QBIT}"
SAVED_SSL_MODE="${SSL_MODE}"
SAVED_DUCKDNS_NAME="${DUCKDNS_NAME}"
SAVED_DUCKDNS_TOKEN="${DUCKDNS_TOKEN}"
SAVED_SUB_URL="${SUB_URL}"
SAVED_QBIT_THEME="${QBIT_THEME}"
SAVED_TARGET_USER="${TARGET_USER}"
SAVED_ADMIN_USER="${ADMIN_USER}"
SAVED_MASTER_PASS="${MASTER_PASS}"
SAVED_STORAGE_MODE="${STORAGE_MODE}"
SAVED_SUBDIR_NAME="${SUBDIR_NAME}"
SAVED_SAVE_DIR="${SAVE_DIR}"
SAVED_SHARE_NAME="${SHARE_NAME}"
EOF
chmod 600 "${ENV_FILE}"

# ==========================================
# 3. УСТАНОВКА DOCKER И НАСТРОЙКА ЗЕРКАЛ
# ==========================================
echo "=== [1/6] Установка Docker CE и системных компонентов ==="

if [ "${DISTRO_TYPE}" = "arch" ]; then
    pacman -Syu --noconfirm --needed docker docker-compose curl jq ca-certificates iptables-nft apache unzip tar python sqlite
else
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    DEB_SUITE="${VERSION_CODENAME:-trixie}"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEB_SUITE} stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        apache2-utils curl jq unzip tar iptables sqlite3 python3
fi

# Зеркала Docker Registry от таймаутов загрузки
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://dockerhub.timeweb.cloud",
    "https://mirror.gcr.io"
  ]
}
EOF

systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker

AGH_HASH=$(htpasswd -B -C 10 -n -b "${ADMIN_USER}" "${AGH_PASS}" | cut -d: -f2)

QBIT_PBKDF2_HASH=$(python3 -c "
import os, base64, hashlib
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac('sha512', b'''${QBIT_PASS}''', salt, 100000, 64)
print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(key).decode()})')
")

if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null || [ -d /etc/systemd/resolved.conf.d ]; then
        mkdir -p /etc/systemd/resolved.conf.d/
        cat <<EOF > /etc/systemd/resolved.conf.d/disable-stub.conf
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved || true
    fi

    if [ -f /run/systemd/resolve/resolv.conf ]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
    fi

    cat <<EOF > /etc/sysctl.d/99-gateway.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system >/dev/null 2>&1

    iptables -P FORWARD ACCEPT 2>/dev/null || true
    if [ -n "${DEFAULT_IFACE}" ]; then
        iptables -t nat -C POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE
    fi
fi

for DOMAIN in "${VAULT_DOMAIN}" "${ADGUARD_DOMAIN}" "${TORRENT_DOMAIN}" "${PROXY_DOMAIN}"; do
    if [ -n "${DOMAIN}" ]; then
        if ! grep -q "${DOMAIN}" /etc/hosts; then
            echo "${LOCAL_IP} ${DOMAIN}" >> /etc/hosts
        else
            sed -i "s/.*${DOMAIN}/${LOCAL_IP} ${DOMAIN}/" /etc/hosts
        fi
    fi
done

# ==========================================
# 4. ДИРЕКТОРИИ И СТРУКТУРА СЕРВИСОВ
# ==========================================
echo "=== [2/6] Создание файловой структуры ==="
id -u "${TARGET_USER}" &>/dev/null || useradd -m -s /bin/bash "${TARGET_USER}"
usermod -aG docker "${TARGET_USER}" || true

mkdir -p "${SAVE_DIR}/torrent/incomplete"
mkdir -p "${SAVE_DIR}/backups/vaultwarden"
mkdir -p "${SAVE_DIR}/certificates"
mkdir -p "${APP_DIR}/caddy/data" "${APP_DIR}/caddy/config"
mkdir -p "${APP_DIR}/mihomo/ui"
mkdir -p "${APP_DIR}/adguard/work" "${APP_DIR}/adguard/conf"
mkdir -p "${APP_DIR}/vaultwarden"
mkdir -p "${APP_DIR}/qbittorrent/config/qBittorrent"
mkdir -p "${APP_DIR}/qbittorrent/vuetorrent"

chown -R "${TARGET_USER}:${TARGET_USER}" "${SAVE_DIR}" 2>/dev/null || true
chown -R "${USER_UID}:${USER_GID}" "${APP_DIR}/qbittorrent"

if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
    curl -sL "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" -o /tmp/metacubexd.zip
    mkdir -p /tmp/metacubexd-extract
    unzip -qo /tmp/metacubexd.zip -d /tmp/metacubexd-extract
    cp -rf /tmp/metacubexd-extract/*/* "${APP_DIR}/mihomo/ui/"
    rm -rf /tmp/metacubexd.zip /tmp/metacubexd-extract

    find "${APP_DIR}/mihomo/ui" -type f \( -name "*.js" -o -name "*.html" \) -exec sed -i \
      -e "s|http://127.0.0.1:9090|https://${PROXY_DOMAIN}/api|g" \
      -e "s|127.0.0.1:9090|${PROXY_DOMAIN}/api|g" \
      -e "s|http://localhost:9090|https://${PROXY_DOMAIN}/api|g" \
      -e "s|localhost:9090|${PROXY_DOMAIN}/api|g" \
      -e "s|http://198.18.0.1:9090|https://${PROXY_DOMAIN}/api|g" {} + 2>/dev/null || true
fi

USE_ALT_UI="false"
if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]] && [ "${QBIT_THEME}" = "1" ]; then
    echo "[+] Загрузка темы VueTorrent..."
    VUETORRENT_URL=$(curl -s https://api.github.com/repos/VueTorrent/VueTorrent/releases/latest | jq -r '.assets[] | select(.name=="vuetorrent.zip") | .browser_download_url')
    if [ -n "$VUETORRENT_URL" ] && [ "$VUETORRENT_URL" != "null" ]; then
        curl -sL "$VUETORRENT_URL" -o /tmp/vuetorrent.zip
        mkdir -p /tmp/vuetorrent-temp
        unzip -qo /tmp/vuetorrent.zip -d /tmp/vuetorrent-temp
        if [ -d "/tmp/vuetorrent-temp/vuetorrent" ]; then
            cp -rf /tmp/vuetorrent-temp/vuetorrent/* "${APP_DIR}/qbittorrent/vuetorrent/"
        else
            cp -rf /tmp/vuetorrent-temp/* "${APP_DIR}/qbittorrent/vuetorrent/"
        fi
        rm -rf /tmp/vuetorrent.zip /tmp/vuetorrent-temp
        chown -R "${USER_UID}:${USER_GID}" "${APP_DIR}/qbittorrent/vuetorrent"
        USE_ALT_UI="true"
    fi
fi

if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
    for CONF_PATH in "${APP_DIR}/qbittorrent/config/qBittorrent/qBittorrent.conf" "${APP_DIR}/qbittorrent/config/qBittorrent.conf"; do
        cat <<EOF > "${CONF_PATH}"
[BitTorrent]
Session\DefaultSavePath=/downloads/torrent
Session\TempPath=/downloads/torrent/incomplete
Session\TempPathEnabled=true

[LegalNotice]
Accepted=true

[Preferences]
General\Locale=ru
WebUI\Address=*
WebUI\AlternativeUIEnabled=${USE_ALT_UI}
WebUI\AuthSubnetWhitelist=${LAN_SUBNET}
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\CSRFProtection=false
WebUI\HostHeaderValidation=false
WebUI\Password_PBKDF2="${QBIT_PBKDF2_HASH}"
WebUI\Port=8080
WebUI\RootFolder=/vuetorrent
WebUI\Username=${ADMIN_USER}
EOF
    done
    chown -R "${USER_UID}:${USER_GID}" "${APP_DIR}/qbittorrent/config"
fi

# ==========================================
# 5. КОНФИГУРАЦИЯ ADGUARD И MIHOMO
# ==========================================
if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
    echo "=== [3/6] Конфигурация AdGuard Home (schema 34) ==="
    REWRITE_ENTRIES=""
    [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${VAULT_DOMAIN}
      answer: ${LOCAL_IP}
      enabled: true"
    REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${ADGUARD_DOMAIN}
      answer: ${LOCAL_IP}
      enabled: true
    - domain: ${PROXY_DOMAIN}
      answer: ${LOCAL_IP}
      enabled: true"
    [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${TORRENT_DOMAIN}
      answer: ${LOCAL_IP}
      enabled: true"

    cat <<EOF > "${APP_DIR}/adguard/conf/AdGuardHome.yaml"
schema_version: 34
http:
  address: 0.0.0.0:8083
  session_ttl: 720h
users:
  - name: ${ADMIN_USER}
    password: ${AGH_HASH}
auth_attempts: 5
block_auth_min: 15
language: "ru"
theme: auto
dns:
  bind_host: 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 0
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:1053
  fallback_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - 1.1.1.1
    - 8.8.8.8
  upstream_timeout: 2s
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  upstream_mode: load_balance
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 300
  cache_optimistic: false
  enable_dnssec: false
  rewrites:${REWRITE_ENTRIES}
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
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_34.txt
    name: HaGeZi Normal Blocklist
    id: 1789156608
filtering:
  filtering_enabled: true
  protection_enabled: true
EOF

    echo "=== [4/6] Конфигурация Mihomo (с поддержкой CORS) ==="
    if [ "${SUB_URL}" = "none" ]; then
        cat <<EOF > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: direct
log-level: info
ipv6: false
secret: "${MIHOMO_SECRET}"
external-controller: 0.0.0.0:9090
external-ui: ui
external-controller-cors:
  allow-origins:
    - "*"
  allow-private-network: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.local"
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  route-exclude-address:
    - "${LAN_SUBNET}"

rules:
  - MATCH,DIRECT
EOF
    else
        cat <<EOF > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
secret: "${MIHOMO_SECRET}"
external-controller: 0.0.0.0:9090
external-ui: ui
external-controller-cors:
  allow-origins:
    - "*"
  allow-private-network: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.local"
    - "*.duckdns.org"
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - 1.1.1.1
    - 8.8.8.8

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  route-exclude-address:
    - "${LAN_SUBNET}"

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
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,duckdns.org,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOIP,lan,DIRECT,no-resolve
  - MATCH,PROXY
EOF
    fi
fi

# ==========================================
# 6. CADDYFILE И DOCKER COMPOSE СТЕК
# ==========================================
echo "=== [5/6] Генерация Caddyfile и docker-compose.yml ==="

cat <<EOF > "${APP_DIR}/caddy/Caddyfile"
{
    admin off
}
EOF

if [ "$SSL_MODE" = "2" ]; then
    # Wildcard-режим для DuckDNS (один сертификат сразу для всех сервисов без конфликта TXT)
    cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
*.${BASE_DOMAIN} {
    tls {
        dns duckdns ${DUCKDNS_TOKEN}
    }
EOF

    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
    @vault host ${VAULT_DOMAIN}
    handle @vault {
        reverse_proxy vaultwarden:80
    }
EOF
    fi

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
    @adguard host ${ADGUARD_DOMAIN}
    handle @adguard {
        reverse_proxy host.docker.internal:8083
    }

    @proxy host ${PROXY_DOMAIN}
    handle @proxy {
        handle_path /api/* {
            reverse_proxy host.docker.internal:9090
        }
        handle {
            root * /srv/mihomo-ui
            file_server
            try_files {path} {path}/ /index.html
        }
    }
EOF
    fi

    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
    @torrent host ${TORRENT_DOMAIN}
    handle @torrent {
        reverse_proxy qbittorrent:8080
    }
EOF
    fi

    echo "}" >> "${APP_DIR}/caddy/Caddyfile"

else
    # Режим внутреннего центра сертификации (*.local)
    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
${VAULT_DOMAIN} {
    tls internal
    reverse_proxy vaultwarden:80
}
EOF
    fi

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
${ADGUARD_DOMAIN} {
    tls internal
    reverse_proxy host.docker.internal:8083
}

${PROXY_DOMAIN} {
    tls internal

    handle_path /api/* {
        reverse_proxy host.docker.internal:9090
    }

    handle {
        root * /srv/mihomo-ui
        file_server
        try_files {path} {path}/ /index.html
    }
}
EOF
    fi

    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "${APP_DIR}/caddy/Caddyfile"
${TORRENT_DOMAIN} {
    tls internal
    reverse_proxy qbittorrent:8080
}
EOF
    fi
fi

cat <<EOF > "${APP_DIR}/docker-compose.yml"
services:
EOF

if [[ "${ENABLE_SAMBA}" =~ ^[Yy]$ ]]; then
    cat <<EOF >> "${APP_DIR}/docker-compose.yml"
  samba:
    image: servercontainers/samba:latest
    container_name: samba
    restart: unless-stopped
    network_mode: host
    environment:
      - SAMBA_CONF_WORKGROUP=WORKGROUP
      - SAMBA_CONF_SERVER_STRING=Homelab Storage
      - AVAHI_DISABLE=true
      - WSDD2_DISABLE=false
      - ACCOUNT_${ADMIN_USER}=${SAMBA_PASS}
      - UID_${ADMIN_USER}=${USER_UID}
      - SAMBA_VOLUME_CONFIG_${SHARE_NAME}=[${SHARE_NAME}]; path=/shares/${SHARE_NAME}; valid users=${ADMIN_USER}; guest ok=no; read only=no; browseable=yes; create mask=0664; directory mask=0775
    volumes:
      - ${SAVE_DIR}:/shares/${SHARE_NAME}

EOF
fi

if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
    cat <<EOF >> "${APP_DIR}/docker-compose.yml"
  qbittorrent:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    environment:
      - PUID=${USER_UID}
      - PGID=${USER_GID}
      - TZ=Europe/Moscow
      - WEBUI_PORT=8080
    volumes:
      - ./qbittorrent/config:/config
      - ./qbittorrent/vuetorrent:/vuetorrent
      - ${SAVE_DIR}:/downloads

EOF
fi

if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
    cat <<EOF >> "${APP_DIR}/docker-compose.yml"
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

EOF
fi

if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
    cat <<EOF >> "${APP_DIR}/docker-compose.yml"
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - WEBSOCKET_ENABLED=true
    volumes:
      - ./vaultwarden:/data

EOF
fi

cat <<EOF >> "${APP_DIR}/docker-compose.yml"
  caddy:
    image: serfriz/caddy-duckdns:latest
    container_name: caddy
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
      - ./mihomo/ui:/srv/mihomo-ui:ro

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - DOCKER_API_VERSION=1.44
EOF

cat <<EOF > /etc/systemd/system/homelab.service
[Unit]
Description=Homelab Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
${STORAGE_DEP_LINE}

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStartPre=/usr/sbin/iptables -P FORWARD ACCEPT
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
# 7. АВТОБЭКАП И ЗАПУСК
# ==========================================
if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
    echo "=== [6/6] Настройка ежедневных бэкапов Vaultwarden ==="
    cat << 'EOF' > "${APP_DIR}/backup_vaultwarden.sh"
#!/usr/bin/env bash
set -e

BACKUP_DIR="__SAVE_DIR__/backups/vaultwarden"
DB_SRC="/opt/homelab/vaultwarden/db.sqlite3"
DATA_DIR="/opt/homelab/vaultwarden"
DATE_TAG=$(date +"%Y%m%d_%H%M%S")
TEMP_DIR=$(mktemp -d)

mkdir -p "${BACKUP_DIR}"

if [ -f "${DB_SRC}" ]; then
    sqlite3 "${DB_SRC}" ".backup '${TEMP_DIR}/db.sqlite3'"
    [ -d "${DATA_DIR}/attachments" ] && cp -r "${DATA_DIR}/attachments" "${TEMP_DIR}/"
    [ -f "${DATA_DIR}/rsa_key.pem" ] && cp -f "${DATA_DIR}/rsa_key.pem" "${TEMP_DIR}/"

    tar -czf "${BACKUP_DIR}/vaultwarden_backup_${DATE_TAG}.tar.gz" -C "${TEMP_DIR}" .
    chown -R __TARGET_USER__:__TARGET_USER__ "${BACKUP_DIR}" 2>/dev/null || true

    find "${BACKUP_DIR}" -type f -name "vaultwarden_backup_*.tar.gz" -mtime +14 -delete
fi

rm -rf "${TEMP_DIR}"
EOF

    sed -i "s|__SAVE_DIR__|${SAVE_DIR}|g" "${APP_DIR}/backup_vaultwarden.sh"
    sed -i "s|__TARGET_USER__|${TARGET_USER}|g" "${APP_DIR}/backup_vaultwarden.sh"
    chmod +x "${APP_DIR}/backup_vaultwarden.sh"

    cat <<EOF > /etc/systemd/system/vaultwarden-backup.service
[Unit]
Description=Vaultwarden Database Backup
After=network.target

[Service]
Type=oneshot
ExecStart=${APP_DIR}/backup_vaultwarden.sh
EOF

    cat <<EOF > /etc/systemd/system/vaultwarden-backup.timer
[Unit]
Description=Daily Vaultwarden Database Backup Timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vaultwarden-backup.timer
fi

echo "=== Запуск Docker Compose ==="
cd "${APP_DIR}"
docker compose pull
docker compose up -d

if [ "$SSL_MODE" = "1" ]; then
    echo "[*] Экспорт корневого CA сертификата..."
    sleep 5
    CADDY_ROOT_CERT="${APP_DIR}/caddy/data/caddy/pki/authorities/local/root.crt"
    if [ -f "${CADDY_ROOT_CERT}" ]; then
        mkdir -p "${SAVE_DIR}/certificates"
        cp -f "${CADDY_ROOT_CERT}" "${SAVE_DIR}/certificates/caddy-root.crt"
        chown -R "${TARGET_USER}:${TARGET_USER}" "${SAVE_DIR}/certificates" 2>/dev/null || true
        chmod 644 "${SAVE_DIR}/certificates/caddy-root.crt" 2>/dev/null || true
    fi
fi

QUICK_PROXY_URL="https://${PROXY_DOMAIN}/#/setup?protocol=https:&hostname=${PROXY_DOMAIN}&port=443&path=api&secret=${MIHOMO_SECRET}"
SAMBA_PATH="\\\\${LOCAL_IP}\\${SHARE_NAME}"
CA_PATH="\\\\${LOCAL_IP}\\${SHARE_NAME}\\certificates\\caddy-root.crt"

echo ""
echo "========================================================="
echo "   Установка и настройка успешно завершена!             "
echo "========================================================="
echo ""
echo "  [+] Адреса веб-сервисов (HTTPS):"
[[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]] && echo "      • Менеджер паролей: https://${VAULT_DOMAIN}"
if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
echo "      • AdGuard Home:     https://${ADGUARD_DOMAIN}"
echo "      • Mihomo UI:        https://${PROXY_DOMAIN}"
echo "      • Быстрый вход UI:  ${QUICK_PROXY_URL}"
fi
[[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]] && echo "      • qBittorrent:      https://${TORRENT_DOMAIN}"
echo ""
echo "  [+] Доступы и аутентификация:"
echo "      • Логин (веб-панели и SMB): ${ADMIN_USER}"
echo "      • Пароль (панели и SMB):    ${MASTER_PASS}"
echo "      • Секрет Mihomo:            ${MIHOMO_SECRET}"
echo ""
if [ "$SSL_MODE" = "1" ]; then
echo "  [+] Корневой сертификат CA для устройств:"
echo "      ${CA_PATH}"
echo ""
fi
if [[ "${ENABLE_SAMBA}" =~ ^[Yy]$ ]]; then
echo "  [+] Сетевое хранилище Samba:"
echo "      Путь:   ${SAMBA_PATH}"
echo "      Логин:  ${ADMIN_USER}"
echo "      Пароль: ${SAMBA_PASS}"
echo ""
fi
if [ "$STORAGE_MODE" != "1" ]; then
echo "  [+] Управление подключенным накопителем:"
echo "      Точка монтирования:  ${MOUNT_ROOT}"
echo "      Каталог сервисов:   ${SAVE_DIR}"
[ "$STORAGE_MODE" = "4" ] || [ "$STORAGE_MODE" = "5" ] && echo "      Ручная разблокировка: sudo homelab-unlock"
echo ""
fi
echo "========================================================="
