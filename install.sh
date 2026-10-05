#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Project: Homelab Appliance & Transparent Gateway (Kaxa Enterprise Edition 2026)
# Enterprise & Homelab Unified Gateway | Linux 2026 Ecosystem & Docker 28+ / 29+
# Supported OS: Debian 13 (Trixie), Ubuntu 26.04 LTS (Resolute Raccoon), Arch Linux
#   (Compatibility Mode: Debian 12+, Ubuntu 24.04+)
# Components: AdGuard Home (v0.107+ Schema 34), Mihomo TUN (Smart Routing & MRS Rulesets),
#             Vaultwarden (Argon2id), Gitea (Git-Server), Samba (WSDD2),
#             qBittorrent (VueTorrent WebUI), MeTube (yt-dlp), Caddy (Internal/DuckDNS SSL),
#             Watchtower (Docker API 1.45+ / 1.50+ Auto-Negotiated)
# =============================================================================

# --- ЦВЕТОВАЯ ПАЛИТРА И СТИЛЬ ОФОРМЛЕНИЯ ---
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_DIM="\033[2m"

CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_WHITE="\033[1;37m"
CLR_MUTED="\033[0;36m"

TAG_INFO="${CLR_BLUE}✦${CLR_RESET}"
TAG_OK="${CLR_GREEN}✔${CLR_RESET}"
TAG_WARN="${CLR_YELLOW}▲${CLR_RESET}"
TAG_ERR="${CLR_RED}✖${CLR_RESET}"

log_info()  { echo -e "  ${TAG_INFO} ${CLR_CYAN}$*${CLR_RESET}"; }
log_ok()    { echo -e "  ${TAG_OK} ${CLR_GREEN}$*${CLR_RESET}"; }
log_warn()  { echo -e "  ${TAG_WARN} ${CLR_YELLOW}$*${CLR_RESET}"; }
log_err()   { echo -e "  ${TAG_ERR} ${CLR_RED}$*${CLR_RESET}" >&2; }

print_step_header() {
    local step_num="$1"
    local step_title="$2"
    echo ""
    echo -e "${CLR_CYAN}╭── ${CLR_WHITE}${CLR_BOLD}[${step_num}]${CLR_RESET} ${CLR_CYAN}${CLR_BOLD}${step_title}${CLR_RESET}"
    echo -e "${CLR_CYAN}╰─────────────────────────────────────────────${CLR_RESET}"
}

CURRENT_SPIN_PID=""
CURRENT_SPIN_LOG=""

# Анимированный спиннер с надежной защитой от утечки курсора при сбоях и сигналах
run_spin() {
    local full_msg="$1"
    shift
    local max_len=40
    local disp_msg="${full_msg:0:$max_len}"
    [ ${#full_msg} -gt $max_len ] && disp_msg="${disp_msg}..."

    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local log_tmp
    log_tmp=$(mktemp)
    CURRENT_SPIN_LOG="${log_tmp}"

    "$@" >"${log_tmp}" 2>&1 &
    local pid=$!
    CURRENT_SPIN_PID="$pid"
    local i=0

    # Скрыть курсор
    printf "\033[?25l"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r\033[2K  ${CLR_CYAN}${spin[i]}${CLR_RESET} ${CLR_WHITE}%-43s${CLR_RESET}" "${disp_msg}"
        i=$(( (i + 1) % 10 ))
        sleep 0.08
    done

    # Безопасный перехват статуса завершения без преждевременного прерывания set -e
    local exit_code=0
    wait "$pid" 2>/dev/null || exit_code=$?
    CURRENT_SPIN_PID=""

    # Всегда восстанавливать курсор
    printf "\033[?25h"

    if [ $exit_code -eq 0 ]; then
        printf "\r\033[2K  ${CLR_GREEN}✔${CLR_RESET} ${CLR_WHITE}%-45s${CLR_RESET} ${CLR_GREEN}[ГОТОВО]${CLR_RESET}\n" "${disp_msg}"
        rm -f "${log_tmp}"
        CURRENT_SPIN_LOG=""
        return 0
    else
        printf "\r\033[2K  ${CLR_RED}✖${CLR_RESET} ${CLR_WHITE}%-45s${CLR_RESET} ${CLR_RED}[СБОЙ]${CLR_RESET}\n" "${disp_msg}"
        echo -e "${CLR_RED}--- Журнал ошибки (${full_msg}): ---${CLR_RESET}" >&2
        tail -n 35 "${log_tmp}" >&2
        echo -e "${CLR_RED}-----------------------------------${CLR_RESET}" >&2
        rm -f "${log_tmp}"
        CURRENT_SPIN_LOG=""
        return $exit_code
    fi
}

# Обработчик непредвиденных ошибок
on_error() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2
    printf "\033[?25h" # Восстановление курсора
    echo ""
    log_err "Критическая ошибка (код ${exit_code}) на строке ${line_no}!"
    echo -e "      ${CLR_DIM}Команда: '${cmd}'${CLR_RESET}"
    exit "${exit_code}"
}

# Восстановление курсора и завершение фоновых подпроцессов при Ctrl+C / SIGINT
cleanup_on_interrupt() {
    printf "\033[?25h\n"
    if [ -n "${CURRENT_SPIN_PID:-}" ] && kill -0 "${CURRENT_SPIN_PID}" 2>/dev/null; then
        kill -9 "${CURRENT_SPIN_PID}" 2>/dev/null || true
    fi
    if [ -n "${CURRENT_SPIN_LOG:-}" ] && [ -f "${CURRENT_SPIN_LOG}" ]; then
        rm -f "${CURRENT_SPIN_LOG}" 2>/dev/null || true
    fi
    echo -e "\n${CLR_YELLOW}Выполнение скрипта прервано пользователем.${CLR_RESET}"
    exit 130
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap cleanup_on_interrupt INT TERM

# Универсальный враппер для Docker Compose v2 (стандарт 2026)
dc() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    elif [ -x /usr/lib/docker/cli-plugins/docker-compose ]; then
        docker compose "$@"
    else
        docker compose "$@"
    fi
}
export -f dc 2>/dev/null || true

# Глобальные переменные окружения
APP_DIR="/opt/homelab"
ENV_FILE="${APP_DIR}/.env"
LUKS_MAP_NAME="homelab_secure_storage"
MOUNT_ROOT="/mnt/homelab_storage"
STORAGE_DEP_LINE=""

REAL_USER="${SUDO_USER:-$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd 2>/dev/null || echo "homelab")}"
TARGET_USER="${REAL_USER:-homelab}"
USER_UID=""
USER_GID=""

MASTER_PASS=""
MIHOMO_SECRET=""
SAMBA_PASS=""
AGH_PASS=""
VAULT_ADMIN_TOKEN=""
ADMIN_USER=""
ADMIN_USER_SAFE=""
DETECTED_DOCKER_API=""
VAULT_DATA_DIR=""
GITEA_DATA_DIR=""
ADGUARD_WORK_DIR=""

show_banner() {
    clear 2>/dev/null || true
    echo -e "${CLR_CYAN}┌────────────────────────────────────────────────────────────────────────────┐${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET} ${CLR_WHITE}${CLR_BOLD}             HOMELAB APPLIANCE & TRANSPARENT GATEWAY (KAXA)                 ${CLR_RESET}${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}├────────────────────────────────────────────────────────────────────────────┤${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_BLUE}┌──────────────┐${CLR_RESET}   ${CLR_GREEN}┌──────────────┐${CLR_RESET}   ${CLR_YELLOW}┌──────────────┐${CLR_RESET}   ${CLR_WHITE}┌──────────────┐${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_BLUE}│ AdGuard Home │${CLR_RESET}   ${CLR_GREEN}│  Mihomo TUN  │${CLR_RESET}   ${CLR_YELLOW}│ Caddy Proxy  │${CLR_RESET}   ${CLR_WHITE}│ Encrypted NAS│${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_BLUE}└──────┬───────┘${CLR_RESET}   ${CLR_GREEN}└──────┬───────┘${CLR_RESET}   ${CLR_YELLOW}└──────┬───────┘${CLR_RESET}   ${CLR_WHITE}└──────┬───────┘${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}         ${CLR_DIM}│                   │                  │                  │${CLR_RESET}         ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_CYAN}┌──────┴───────────────────┴──────────────────┴──────────────────┴──────┐${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}                   ${CLR_WHITE}${CLR_BOLD}Docker Services & Self-Hosted Platform${CLR_RESET}                  ${CLR_CYAN}│${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}│${CLR_RESET}  ${CLR_CYAN}└───────────────────────────────────────────────────────────────────────┘${CLR_RESET}  ${CLR_CYAN}│${CLR_RESET}"
    echo -e "${CLR_CYAN}└────────────────────────────────────────────────────────────────────────────┘${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_CYAN}Автоматизированный комплекс сервисов, прозрачного шлюза и шифрования${CLR_RESET}"
    echo -e "  ${CLR_DIM}Поддержка: Debian 13 (Trixie), Ubuntu 26.04 LTS (Resolute), Arch Linux | 2026${CLR_RESET}"
    echo ""
}

check_privileges() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_err "Скрипт должен быть запущен с правами root (sudo)!"
        echo -e "      ${CLR_WHITE}Запуск: sudo $0${CLR_RESET}"
        exit 1
    fi
    [ -c /dev/tty ] && exec < /dev/tty || true
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_VER_ID="${VERSION_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    else
        log_err "Не удалось определить дистрибутив Linux (/etc/os-release отсутствует)!"
        exit 1
    fi

    DISTRO_FAMILY=""
    if [[ "${OS_ID}" =~ ^(arch|artix|endeavouros|manjaro)$ ]] || [[ "${OS_ID_LIKE}" =~ arch ]]; then
        DISTRO_FAMILY="arch"
        log_ok "Обнаружена ОС семейства Arch Linux: ${CLR_WHITE}${PRETTY_NAME:-Arch Linux}${CLR_RESET}"
    elif [[ "${OS_ID}" =~ ^debian$ ]] || [[ "${OS_ID_LIKE}" =~ debian && ! "${OS_ID}" =~ ubuntu ]]; then
        DISTRO_FAMILY="debian"
        local DEB_VER="${OS_VER_ID%%.*}"
        if [ -n "${DEB_VER}" ] && [ "${DEB_VER}" -lt 12 ]; then
            log_err "Обнаружена устаревшая версия Debian ${OS_VER_ID} (${OS_CODENAME})!"
            log_err "Требуется Debian 12 (Bookworm) или новее. Рекомендуется Debian 13 (Trixie)."
            exit 1
        elif [ -n "${DEB_VER}" ] && [ "${DEB_VER}" -eq 12 ]; then
            log_warn "Обнаружен Debian 12 (Bookworm). Рекомендуется Debian 13 (Trixie), но установка продолжена в режиме совместимости."
        else
            log_ok "Обнаружена ОС семейства Debian: ${CLR_WHITE}${PRETTY_NAME:-Debian 13 (Trixie)}${CLR_RESET}"
        fi
    elif [[ "${OS_ID}" =~ ^ubuntu$ ]] || [[ "${OS_ID_LIKE}" =~ ubuntu ]]; then
        DISTRO_FAMILY="debian"
        local IS_SUPPORTED_UBU=1
        if command -v dpkg >/dev/null 2>&1; then
            if ! dpkg --compare-versions "${OS_VER_ID:-0}" ge "24.04"; then
                IS_SUPPORTED_UBU=0
            fi
        else
            local UBU_NUM
            UBU_NUM=$(echo "${OS_VER_ID:-0}" | awk '{print ($1 >= 24.04) ? 1 : 0}')
            [ "${UBU_NUM}" -eq 1 ] || IS_SUPPORTED_UBU=0
        fi

        if [ "${IS_SUPPORTED_UBU}" -eq 0 ]; then
            log_err "Обнаружена неподдерживаемая версия Ubuntu ${OS_VER_ID:-} (${OS_CODENAME:-})!"
            log_err "Требуется Ubuntu 24.04 LTS или новее. Рекомендуется Ubuntu 26.04 LTS (Resolute Raccoon)."
            exit 1
        fi
        log_ok "Обнаружена ОС семейства Ubuntu: ${CLR_WHITE}${PRETTY_NAME:-Ubuntu 26.04 LTS (Resolute)}${CLR_RESET}"
    else
        log_err "Неподдерживаемый дистрибутив: ${OS_ID}."
        log_err "Поддерживаются: Debian 13/12, Ubuntu 26.04/24.04 LTS, Arch Linux."
        exit 1
    fi
}

load_previous_config() {
    if [ -f "${ENV_FILE}" ]; then
        log_info "Обнаружен файл конфигурации с прошлыми настройками. Значения загружены."
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        if [ -n "${SAVED_MASTER_PASS:-}" ]; then
            MASTER_PASS="${SAVED_MASTER_PASS}"
            MIHOMO_SECRET="${SAVED_MASTER_PASS}"
            SAMBA_PASS="${SAVED_MASTER_PASS}"
            AGH_PASS="${SAVED_MASTER_PASS}"
        fi
    fi
}

sync_time() {
    log_info "Проверка и синхронизация системного времени..."
    local HTTP_DATE=""
    if command -v curl >/dev/null 2>&1; then
        HTTP_DATE=$(curl -sI -m 4 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null | grep -i '^date:' | head -n1 | cut -d' ' -f2- | tr -d '\r' || true)
        [ -z "${HTTP_DATE}" ] && HTTP_DATE=$(curl -sI -m 4 http://deb.debian.org 2>/dev/null | grep -i '^date:' | head -n1 | cut -d' ' -f2- | tr -d '\r' || true)
    elif command -v wget >/dev/null 2>&1; then
        HTTP_DATE=$(wget --server-response --spider --timeout=4 http://deb.debian.org 2>&1 | grep -i '^[[:space:]]*date:' | head -n1 | sed -e 's/^[[:space:]]*[Dd]ate:[[:space:]]*//' | tr -d '\r' || true)
    fi

    if [ -n "${HTTP_DATE}" ]; then
        if date -s "${HTTP_DATE}" >/dev/null 2>&1; then
            log_ok "Системное время синхронизировано: $(date -R)"
        fi
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
    fi

    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl list-unit-files 2>/dev/null | grep -q 'systemd-timesyncd'; then
        systemctl unmask systemd-timesyncd 2>/dev/null || true
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# 1. УСТАНОВКА ЗАВИСИМОСТЕЙ И DOCKER CE
# =============================================================================
install_pkgs() {
    print_step_header "01/10" "УСТАНОВКА ЗАВИСИМОСТЕЙ И СТЕКА DOCKER"

    if [ "${DISTRO_FAMILY}" = "arch" ]; then
        local ARCH_PKGS=(python python-bcrypt iproute2 cryptsetup btrfs-progs ntfs-3g util-linux \
                         curl openssl ca-certificates jq iptables unzip tar sqlite \
                         docker docker-compose argon2 iputils acl zram-generator)
        local MISSING_PKGS=()
        for p in "${ARCH_PKGS[@]}"; do
            pacman -Q "$p" >/dev/null 2>&1 || MISSING_PKGS+=("$p")
        done
        if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
            log_ok "Все системные пакеты Arch Linux уже установлены (пропуск)"
        else
            run_spin "Установка пакетов Arch (${#MISSING_PKGS[@]} шт.)" \
                pacman -S --noconfirm --needed "${MISSING_PKGS[@]}"
        fi
    elif [ "${DISTRO_FAMILY}" = "debian" ]; then
        export DEBIAN_FRONTEND=noninteractive
        run_spin "Обновление индексов пакетов APT" bash -c "apt-get update -o Acquire::Check-Valid-Until=false -y || apt-get update -y"

        run_spin "Установка системных пакетов и утилит" \
            apt-get install -y --no-install-recommends \
                systemd-timesyncd systemd-zram-generator python3 python3-bcrypt iproute2 cryptsetup btrfs-progs ntfs-3g \
                util-linux curl openssl ca-certificates jq iptables apache2-utils \
                unzip tar sqlite3 argon2 iputils-ping

        if ! command -v docker >/dev/null 2>&1; then
            log_info "Установка официального Docker CE..."
            apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

            local REPO_OS="debian"
            [[ "${OS_ID}" =~ ubuntu ]] || [[ "${OS_ID_LIKE}" =~ ubuntu ]] && REPO_OS="ubuntu"
            local CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
            if [ -z "${CODENAME}" ]; then
                [ "${REPO_OS}" = "ubuntu" ] && CODENAME="resolute" || CODENAME="trixie"
            fi

            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${REPO_OS}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc

            local TARGET_CODENAME="${CODENAME}"
            # Проверка доступности Release или InRelease
            if ! curl -fsSL --connect-timeout 5 -m 10 "https://download.docker.com/linux/${REPO_OS}/dists/${TARGET_CODENAME}/Release" -o /dev/null 2>/dev/null && \
               ! curl -fsSL --connect-timeout 5 -m 10 "https://download.docker.com/linux/${REPO_OS}/dists/${TARGET_CODENAME}/InRelease" -o /dev/null 2>/dev/null; then
                [ "${REPO_OS}" = "ubuntu" ] && TARGET_CODENAME="noble" || TARGET_CODENAME="bookworm"
                log_warn "Репозиторий для ${CODENAME} недоступен. Используется совместимый: ${TARGET_CODENAME}"
            fi

            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${REPO_OS} ${TARGET_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
            
            run_spin "Обновление репозиториев с Docker CE" apt-get update -y
            run_spin "Установка компонентов Docker CE и Compose Plugin" \
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi

    # Защита накопителя eMMC/SSD: ограничение системного журнала systemd-journald
    mkdir -p /etc/systemd/journald.conf.d/
    cat <<EOF_JRNL > /etc/systemd/journald.conf.d/00-homelab.conf
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
Storage=persistent
EOF_JRNL
    systemctl restart systemd-journald >/dev/null 2>&1 || true

    # Настройка актуальных зеркал Docker Hub (2026 год, исключен устаревший gcr.io)
    local MODIFIED_DAEMON
    MODIFIED_DAEMON=$(python3 -c "
import json, os
path = '/etc/docker/daemon.json'
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
mirrors = data.get('registry-mirrors', [])
target_mirrors = [
    'https://dockerhub.timeweb.cloud',
    'https://dockerhub.cloud.ru',
    'https://huecker.io'
]
changed = False
for m in target_mirrors:
    if m not in mirrors:
        mirrors.append(m)
        changed = True
if 'https://mirror.gcr.io' in mirrors:
    mirrors.remove('https://mirror.gcr.io')
    changed = True
if 'log-driver' not in data:
    data['log-driver'] = 'json-file'
    data['log-opts'] = {'max-size': '10m', 'max-file': '3'}
    changed = True
if data.get('max-concurrent-downloads') != 2:
    data['max-concurrent-downloads'] = 2
    data['max-concurrent-uploads'] = 2
    changed = True
if changed:
    os.makedirs('/etc/docker', exist_ok=True)
    data['registry-mirrors'] = mirrors
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('1')
else:
    print('0')
" 2>/dev/null || echo "0")

    if ! systemctl is-active --quiet docker 2>/dev/null; then
        run_spin "Активация и запуск службы Docker" bash -c "systemctl daemon-reload >/dev/null 2>&1 || true && systemctl enable --now docker >/dev/null 2>&1 || true"
    elif [ "${MODIFIED_DAEMON}" = "1" ]; then
        run_spin "Обновление конфигурации и перезапуск Docker (актуализированы зеркала)" bash -c "systemctl daemon-reload >/dev/null 2>&1 || true && systemctl restart docker"
    else
        log_ok "Служба Docker активна, зеркала Docker Hub уже настроены"
    fi

    # Остановка потенциально конфликтующих старых контейнеров перед переконфигурацией
    if command -v docker >/dev/null 2>&1; then
        docker stop mihomo adguardhome 2>/dev/null || true
    fi

    # Определение версии Docker API для Watchtower и Compose (контроль минимума 1.45 для Docker 28+/29+)
    DETECTED_DOCKER_API=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "1.45")
    if [ -z "${DETECTED_DOCKER_API}" ]; then
        DETECTED_DOCKER_API="1.45"
    else
        local API_MAJOR_MINOR
        API_MAJOR_MINOR=$(echo "${DETECTED_DOCKER_API}" | cut -d. -f1,2)
        local API_FLOAT
        API_FLOAT=$(python3 -c "import sys; print(float('${API_MAJOR_MINOR}'))" 2>/dev/null || echo "1.45")
        local IS_OLD
        IS_OLD=$(python3 -c "import sys; print(1 if float('${API_FLOAT}') < 1.44 else 0)" 2>/dev/null || echo "0")
        [ "${IS_OLD}" -eq 1 ] && DETECTED_DOCKER_API="1.45"
    fi
    log_info "Определена версия Docker API: ${DETECTED_DOCKER_API}"

    # Гарантия наличия плагина 'docker compose' (включая Arch Linux)
    mkdir -p /usr/lib/docker/cli-plugins
    if command -v docker-compose >/dev/null 2>&1 && [ ! -e /usr/lib/docker/cli-plugins/docker-compose ]; then
        ln -sf "$(command -v docker-compose)" /usr/lib/docker/cli-plugins/docker-compose
    fi

    # Установка системного враппера dc в /usr/local/bin/dc
    cat << 'EOF_DC_BIN' > /usr/local/bin/dc
#!/usr/bin/env bash
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    exec docker compose "$@"
elif command -v docker-compose >/dev/null 2>&1; then
    exec docker-compose "$@"
elif [ -x /usr/lib/docker/cli-plugins/docker-compose ]; then
    exec docker compose "$@"
else
    exec docker compose "$@"
fi
EOF_DC_BIN
    chmod 755 /usr/local/bin/dc 2>/dev/null || true

    log_ok "Стек Docker CE успешно настроен и готов к работе"
}

# =============================================================================
# 2. ИНТЕЛЛЕКТУАЛЬНЫЙ АНАЛИЗ СЕТИ И ПАМЯТИ
# =============================================================================
setup_zram() {
    local TOTAL_RAM_MB
    TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "2048")
    if [ "${TOTAL_RAM_MB}" -le 4096 ]; then
        log_info "Обнаружен компактный объем RAM (${TOTAL_RAM_MB} МБ). Настройка zRAM..."
        mkdir -p /etc/systemd/
        cat << 'EOF_ZRAM_CONF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 2048)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF_ZRAM_CONF

        if systemctl list-unit-files 2>/dev/null | grep -q "systemd-zram-setup"; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl start dev-zram0.swap 2>/dev/null || systemctl start /dev/zram0 2>/dev/null || true
        fi

        if ! swapon --show 2>/dev/null | grep -q "zram"; then
            modprobe zram 2>/dev/null || true
            if command -v zramctl >/dev/null 2>&1; then
                local ZDEV
                ZDEV=$(zramctl --find --size 1024M --algorithm zstd 2>/dev/null || zramctl --find --size 1024M --algorithm lz4 2>/dev/null || zramctl --find --size 1024M 2>/dev/null || true)
                if [ -n "${ZDEV}" ]; then
                    mkswap "${ZDEV}" >/dev/null 2>&1 || true
                    swapon -p 100 "${ZDEV}" 2>/dev/null || true
                    sysctl -w vm.swappiness=150 >/dev/null 2>&1 || true
                    log_ok "zRAM диск успешно активирован: ${ZDEV} (1 ГБ сжатия zstd)"
                fi
            fi
        else
            log_ok "zRAM активен и сконфигурирован через systemd-zram-generator"
        fi
    fi

    # Защита от OOM Killer: гарантируем наличие Swapfile с поддержкой Btrfs
    local TOTAL_SWAP_MB
    TOTAL_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo "0")
    if [ "${TOTAL_SWAP_MB:-0}" -lt 1024 ] && [ "${TOTAL_RAM_MB}" -le 3072 ]; then
        local AVAIL_DISK_MB
        AVAIL_DISK_MB=$(df -m / 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
        if [ ! -f /swapfile ] && [ "${AVAIL_DISK_MB}" -ge 3000 ]; then
            log_info "Создание дополнительного файла подкачки (1.5 ГБ Swapfile) для защиты от OOM..."
            local ROOT_FSTYPE
            ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "ext4")

            if [ "${ROOT_FSTYPE}" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
                btrfs filesystem mkswapfile --size 1536M /swapfile 2>/dev/null || {
                    truncate -s 0 /swapfile
                    chattr +C /swapfile 2>/dev/null || true
                    btrfs property set /swapfile compression none 2>/dev/null || true
                    dd if=/dev/zero of=/swapfile bs=1M count=1536 status=none
                }
            else
                (fallocate -l 1536M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1536 status=none)
            fi

            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            if swapon -p 50 /swapfile >/dev/null 2>&1; then
                if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                    echo "/swapfile none swap defaults,pri=50 0 0" >> /etc/fstab
                fi
                log_ok "Аварийный Swapfile успешно подключен (/swapfile, 1.5 ГБ, добавлен в /etc/fstab)"
            else
                log_warn "Не удалось активировать /swapfile, продолжение работы с zRAM"
            fi
        fi
    fi
}

detect_network() {
    print_step_header "02/10" "ИНТЕЛЛЕКТУАЛЬНЫЙ АНАЛИЗ СЕТЕВОГО ОКРУЖЕНИЯ"

    # Исключение виртуальных, VPN и контейнерных интерфейсов
    PHYS_IFACE=$( (ip -o -4 route show default 2>/dev/null | awk '{print $5}' | grep -vE '^(Meta|tun|tap|docker|br-|veth|wg|tailscale|zt|dummy|bond|lo)' | head -n1) || true )
    if [ -z "${PHYS_IFACE}" ]; then
        PHYS_IFACE=$( (ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | grep -vE '^(Meta|tun|tap|docker|br-|veth|wg|tailscale|zt|dummy|bond|lo)' | head -n1) || true )
    fi
    if [ -z "${PHYS_IFACE}" ]; then
        PHYS_IFACE=$(ls -1 /sys/class/net 2>/dev/null | grep -E '^(eth|en|wl)' | head -n1 || true)
    fi
    DEFAULT_IFACE="${PHYS_IFACE:-eth0}"

    LOCAL_IP=$(ip -o -4 addr show dev "${DEFAULT_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
    if [ -z "${LOCAL_IP}" ] || [ "${LOCAL_IP}" = "127.0.0.1" ]; then
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./) {print $i; exit}}')
        LOCAL_IP=${LOCAL_IP:-192.168.1.100}
    fi

    ROUTER_GATEWAY=$(ip route show default dev "${DEFAULT_IFACE}" 2>/dev/null | awk '/via/ {for(j=1;j<=NF;j++) if($j=="via") {print $(j+1); exit}}' | head -n1 || true)
    if [ -z "${ROUTER_GATEWAY}" ] || [ "${ROUTER_GATEWAY}" = "${LOCAL_IP}" ] || [[ ! "${ROUTER_GATEWAY}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ROUTER_GATEWAY=$(ip neigh show dev "${DEFAULT_IFACE}" 2>/dev/null | grep -E 'REACHABLE|DELAY|STALE' | awk '{print $1}' | grep -v "${LOCAL_IP}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
    fi
    if [ -z "${ROUTER_GATEWAY}" ] || [[ ! "${ROUTER_GATEWAY}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ROUTER_GATEWAY=$(echo "${LOCAL_IP}" | sed 's/\.[0-9]*$/.1/' || echo "192.168.1.1")
    fi

    RAW_SUBNET=$(ip -o -f inet addr show dev "${DEFAULT_IFACE}" 2>/dev/null | awk '{print $4}' | head -n1 || true)
    if [ -n "${RAW_SUBNET}" ]; then
        LAN_SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${RAW_SUBNET}', strict=False))" 2>/dev/null || echo "${RAW_SUBNET}")
    else
        LAN_SUBNET="192.168.1.0/24"
    fi

    REAL_USER="${SUDO_USER:-$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd 2>/dev/null || echo "homelab")}"
    TARGET_USER="${SAVED_TARGET_USER:-${REAL_USER:-homelab}}"
    if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
        useradd -m -U -s /bin/bash "${TARGET_USER}" 2>/dev/null || useradd -m -s /bin/bash "${TARGET_USER}"
    fi
    USER_UID=$(id -u "${TARGET_USER}")
    USER_GID=$(id -g "${TARGET_USER}")

    # БЕЗОПАСНОСТЬ: Добавляем пользователя в группу docker без небезопасных прав 666 на сокет
    getent group docker >/dev/null 2>&1 || groupadd -r docker 2>/dev/null || true
    usermod -aG docker "${TARGET_USER}" 2>/dev/null || true
    if [ -S /var/run/docker.sock ]; then
        chown root:docker /var/run/docker.sock 2>/dev/null || true
        chmod 660 /var/run/docker.sock 2>/dev/null || true
    fi

    log_ok "Сетевые параметры определены:"
    echo -e "      ${CLR_WHITE}• ОС и ядро:        ${PRETTY_NAME:-Linux} ($(uname -r))${CLR_RESET}"
    echo -e "      ${CLR_WHITE}• IP сервера:       ${CLR_GREEN}${LOCAL_IP}${CLR_RESET}"
    echo -e "      ${CLR_WHITE}• Шлюз роутера:     ${CLR_CYAN}${ROUTER_GATEWAY}${CLR_RESET}"
    echo -e "      ${CLR_WHITE}• Интерфейс LAN:    ${CLR_YELLOW}${DEFAULT_IFACE}${CLR_RESET}"
    echo -e "      ${CLR_WHITE}• Подсеть LAN:      ${LAN_SUBNET}${CLR_RESET}"
    echo -e "      ${CLR_WHITE}• Пользователь:     ${TARGET_USER} (UID: ${USER_UID}, GID: ${USER_GID})${CLR_RESET}"
}

# =============================================================================
# 3. ВЫБОР ДИСКОВ И ХРАНИЛИЩА
# =============================================================================
release_device() {
    local dev="$1"
    [ -z "$dev" ] && return 0
    local real_dev
    real_dev=$(readlink -f "$dev" 2>/dev/null || echo "$dev")

    log_info "Освобождение накопителя ${dev} от блокировок ядра и файловых систем..."

    # 1. Завершение процессов и отмонтирование каталога хранилища
    if mountpoint -q "${MOUNT_ROOT}"; then
        fuser -km "${MOUNT_ROOT}" 2>/dev/null || true
        umount -R "${MOUNT_ROOT}" 2>/dev/null || umount -l "${MOUNT_ROOT}" 2>/dev/null || true
    fi

    # 2. Отмонтирование любых несистемных точек монтирования устройства
    while read -r mnt; do
        if [ -n "$mnt" ] && [ "$mnt" != "/" ] && [[ ! "$mnt" =~ ^/(boot|efi|usr|var|home) ]]; then
            fuser -km "$mnt" 2>/dev/null || true
            umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        fi
    done < <(lsblk -rno MOUNTPOINT "${real_dev}" 2>/dev/null | grep -v '^$' || true)

    # 3. Закрытие всех связанных LUKS / dm мапперов
    while read -r crypt_holder; do
        if [ -n "$crypt_holder" ]; then
            cryptsetup close "$crypt_holder" 2>/dev/null || dmsetup remove -f "$crypt_holder" 2>/dev/null || true
        fi
    done < <(lsblk -lno NAME,TYPE "${real_dev}" 2>/dev/null | awk '$2=="crypt" {print $1}')
    cryptsetup close "${LUKS_MAP_NAME}" 2>/dev/null || dmsetup remove -f "${LUKS_MAP_NAME}" 2>/dev/null || true

    # 4. Отключение swap, сброс кэшей буферов и ожидание udev
    swapoff "${real_dev}"* 2>/dev/null || true
    blockdev --flushbufs "${real_dev}" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    # 5. Очистка старых файловых сигнатур (wipefs)
    log_info "Очистка сигнатур разметки (wipefs)..."
    if ! wipefs -af "${real_dev}" 2>/dev/null; then
        dd if=/dev/zero of="${real_dev}" bs=1M count=16 oflag=direct status=none 2>/dev/null || \
        dd if=/dev/zero of="${real_dev}" bs=1M count=16 status=none 2>/dev/null || true
        blockdev --rereadpt "${real_dev}" 2>/dev/null || true
        udevadm settle 2>/dev/null || sleep 1
        wipefs -af "${real_dev}" 2>/dev/null || true
    fi
}

assert_safe_device() {
    local target_dev="$1"
    local real_target
    real_target=$(readlink -f "${target_dev}" 2>/dev/null || echo "${target_dev}")
    local target_name
    target_name=$(basename "${real_target}")
    local target_disk
    target_disk=$(lsblk -lno PKNAME "${real_target}" 2>/dev/null | head -n1 || true)
    [ -z "${target_disk}" ] && target_disk=$(echo "${target_name}" | sed -E 's/p?[0-9]+$//')
    [ -z "${target_disk}" ] && target_disk="${target_name}"

    # 1. Поиск диска с корневой файловой системой (/)
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    root_src="${root_src%%[*}"
    local root_disk
    root_disk=$(lsblk -lno PKNAME "${root_src}" 2>/dev/null | head -n1 || true)
    [ -z "${root_disk}" ] && root_disk=$(basename "${root_src}" | sed -E 's/p?[0-9]+$//')

    if [ -n "${root_disk}" ] && [ "${target_disk}" = "${root_disk}" ]; then
        echo ""
        log_err "КРИТИЧЕСКАЯ БЛОКИРОВКА БЕЗОПАСНОСТИ!"
        log_err "Устройство ${target_dev} является системным накопителем (/dev/${root_disk}) текущей ОС!"
        log_err "Форматирование системного диска категорически запрещено."
        echo -e "      ${CLR_YELLOW}Для хранения на системном диске выберите режим [1] (Системный диск).${CLR_RESET}"
        exit 1
    fi

    # 2. Защита критических системных разделов ОС (/boot, /efi, /usr, /var, /home)
    local sys_mounts
    sys_mounts=$(lsblk -lno MOUNTPOINT "${real_target}" 2>/dev/null | grep -E '^/(boot|efi|usr|var|home)($|/)' || true)
    if [ -n "${sys_mounts}" ]; then
        echo ""
        log_err "КРИТИЧЕСКАЯ БЛОКИРОВКА БЕЗОПАСНОСТИ!"
        log_err "Накопитель ${target_dev} содержит системные разделы ОС:"
        echo -e "      ${CLR_YELLOW}${sys_mounts}${CLR_RESET}"
        log_err "Форматирование диска с системными компонентами запрещено."
        exit 1
    fi

    # 3. Если накопитель был ранее смонтирован как хранилище — освобождаем его
    local cur_mounts
    cur_mounts=$(lsblk -lno MOUNTPOINT "${real_target}" 2>/dev/null | grep -E '^/(mnt|media)' || true)
    if [ -n "${cur_mounts}" ]; then
        log_info "Освобождение диска: отмонтирование разделов хранилища..."
        while read -r mnt_pt; do
            [ -n "$mnt_pt" ] && (umount -R "$mnt_pt" 2>/dev/null || umount -l "$mnt_pt" 2>/dev/null || true)
        done <<< "${cur_mounts}"
        cryptsetup close "${LUKS_MAP_NAME}" 2>/dev/null || true
    fi
}

select_disk_device() {
    log_info "Сканирование доступных физических накопителей..."

    local ROOT_SRC
    ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    ROOT_SRC="${ROOT_SRC%%[*}"
    local ROOT_DISK
    ROOT_DISK=$(lsblk -lno PKNAME "${ROOT_SRC}" 2>/dev/null | head -n1 || true)
    [ -z "${ROOT_DISK}" ] && ROOT_DISK=$(basename "${ROOT_SRC}" | sed -E 's/p?[0-9]+$//')

    local SYSTEM_DISKS=()
    [ -n "${ROOT_DISK}" ] && SYSTEM_DISKS+=("${ROOT_DISK}")

    # Защита системных разделов, включая /home
    for smpt in /boot /boot/efi /efi /usr /var /home; do
        if [ -d "$smpt" ]; then
            local s_src
            s_src=$(findmnt -n -o SOURCE "$smpt" 2>/dev/null || true)
            s_src="${s_src%%[*}"
            if [ -n "$s_src" ]; then
                local s_disk
                s_disk=$(lsblk -lno PKNAME "$s_src" 2>/dev/null | head -n1 || true)
                [ -z "$s_disk" ] && s_disk=$(basename "$s_src" | sed -E 's/p?[0-9]+$//')
                [ -n "$s_disk" ] && SYSTEM_DISKS+=("${s_disk}")
            fi
        fi
    done

    while read -r sw_dev rest; do
        [ -z "$sw_dev" ] || [ "$sw_dev" = "Filename" ] && continue
        local sw_disk
        sw_disk=$(lsblk -lno PKNAME "$sw_dev" 2>/dev/null | head -n1 || true)
        [ -z "$sw_disk" ] && sw_disk=$(basename "$sw_dev" | sed -E 's/p?[0-9]+$//')
        [ -n "$sw_disk" ] && SYSTEM_DISKS+=("${sw_disk}")
    done < /proc/swaps 2>/dev/null || true

    AVAIL_DEVS=()
    while read -r d_name d_size d_type; do
        [ "$d_type" != "disk" ] && continue
        [ -z "$d_name" ] && continue
        [[ "$d_name" =~ ^(loop|zram|ram) ]] && continue
        # Исключение аппаратных boot-разделов eMMC/SBC
        [[ "$d_name" =~ (boot[0-9]|rpmb)$ ]] && continue

        local is_system=0
        for sys_d in "${SYSTEM_DISKS[@]}"; do
            if [ "$d_name" = "$sys_d" ]; then
                is_system=1
                break
            fi
        done
        [ "$is_system" -eq 1 ] && continue

        AVAIL_DEVS+=("/dev/${d_name}")
    done < <(lsblk -lno NAME,SIZE,TYPE 2>/dev/null || true)

    if [ ${#AVAIL_DEVS[@]} -eq 0 ]; then
        echo ""
        log_err "Свободные внешние/дополнительные накопители не найдены!"
        echo -e "      ${CLR_WHITE}Системный диск /dev/${ROOT_DISK:-sda} исключен из списка безопасности.${CLR_RESET}"
        echo -e "      ${CLR_YELLOW}Подключите внешний диск или выберите режим [1] (Хранилище на системном диске).${CLR_RESET}"
        exit 1
    fi

    echo ""
    echo -e "  ${CLR_CYAN}Доступные дополнительные/внешние накопители (системный диск /dev/${ROOT_DISK:-sda} исключен):${CLR_RESET}"
    for i in "${!AVAIL_DEVS[@]}"; do
        local DEV_NAME="${AVAIL_DEVS[$i]}"
        local DEV_INFO
        DEV_INFO=$(lsblk -dno SIZE,MODEL,TRAN "${DEV_NAME}" 2>/dev/null | xargs)
        printf "    ${CLR_WHITE}%d)${CLR_RESET} %-20s ${CLR_YELLOW}[%s]${CLR_RESET}\n" "$((i+1))" "${DEV_NAME}" "${DEV_INFO:-Без метки}"
    done
    echo ""

    read -rp "  [?] Выберите номер диска [1-${#AVAIL_DEVS[@]}]: " DEV_IDX || true
    while [[ ! "${DEV_IDX:-}" =~ ^[0-9]+$ ]] || [ "${DEV_IDX}" -lt 1 ] || [ "${DEV_IDX}" -gt "${#AVAIL_DEVS[@]}" ]; do
        read -rp "  [-] Неверный выбор. Введите номер из списка: " DEV_IDX || true
    done

    CHOSEN_DEV="${AVAIL_DEVS[$((DEV_IDX-1))]}"
    assert_safe_device "${CHOSEN_DEV}"
    log_ok "Выбрано целевое устройство: ${CHOSEN_DEV}"
}

# =============================================================================
# 4. ДИАЛОГ КОНФИГУРАЦИИ
# =============================================================================
prompt_configuration() {
    print_step_header "03/10" "КОНФИГУРАЦИЯ И ВЫБОР РЕЖИМА УСТАНОВКИ"

    echo -e "  ${CLR_WHITE}Выберите вариант развертывания:${CLR_RESET}"
    echo -e "    ${CLR_GREEN}1) Экспресс-установка${CLR_RESET} (Всё включено, авто-настройка, *.lan) ${CLR_DIM}[Enter]${CLR_RESET}"
    echo -e "    ${CLR_YELLOW}2) Расширенная настройка${CLR_RESET} (Выбор дисков, Btrfs, LUKS2 шифрование, DuckDNS)"
    echo -e "    ${CLR_RED}3) Сброс стека${CLR_RESET} (Остановка контейнеров, очистка конфигов и запуск с нуля)"
    echo ""
    read -rp "  [?] Ваш выбор [1/2/3] [1]: " INSTALL_MODE || true
    INSTALL_MODE=${INSTALL_MODE:-1}
    while [[ ! "${INSTALL_MODE}" =~ ^[123]$ ]]; do
        read -rp "  [-] Пожалуйста, выберите 1, 2 или 3 [1]: " INSTALL_MODE || true
        INSTALL_MODE=${INSTALL_MODE:-1}
    done
    echo ""

    if [ "$INSTALL_MODE" = "3" ]; then
        echo ""
        log_warn "РЕЖИМ ПОЛНОГО СБРОСА: Будут остановлены все контейнеры и удалены конфигурации стека!"
        read -rp "  [?] Подтвердите сброс (введите 'yes'): " CONFIRM_RESET || true
        if [[ ! "${CONFIRM_RESET:-}" =~ ^[Yy][Ee][Ss]$ ]]; then
            log_info "Операция отменена."
            exit 0
        fi

        log_info "Остановка системных служб и таймеров..."
        systemctl disable --now homelab.service 2>/dev/null || true
        systemctl disable --now network-gateway-watchdog.timer 2>/dev/null || true
        systemctl disable --now network-gateway-watchdog.service 2>/dev/null || true
        systemctl disable --now vaultwarden-backup.timer 2>/dev/null || true
        systemctl disable --now vaultwarden-backup.service 2>/dev/null || true
        systemctl disable --now gitea-backup.timer 2>/dev/null || true
        systemctl disable --now gitea-backup.service 2>/dev/null || true

        log_info "Остановка и удаление контейнеров Docker..."
        if [ -d "${APP_DIR}" ]; then
            (cd "${APP_DIR}" && dc down --remove-orphans 2>/dev/null || true)
        fi
        docker stop adguardhome mihomo caddy vaultwarden gitea qbittorrent metube samba watchtower 2>/dev/null || true
        docker rm -f adguardhome mihomo caddy vaultwarden gitea qbittorrent metube samba watchtower 2>/dev/null || true

        log_info "Очистка служебных файлов и конфигураций..."
        local BACKUP_CERTS="/tmp/caddy_certificates_backup_$$"
        rm -rf "${BACKUP_CERTS}"
        if [ -d "${APP_DIR}/caddy/data/caddy/certificates" ]; then
            log_info "Сохранение существующих SSL-сертификатов Caddy..."
            cp -r "${APP_DIR}/caddy/data/caddy/certificates" "${BACKUP_CERTS}" 2>/dev/null || true
        fi

        rm -rf "${APP_DIR}/adguard" "${APP_DIR}/mihomo" "${APP_DIR}/caddy" "${APP_DIR}/metube" "${APP_DIR}/vaultwarden" "${APP_DIR}/gitea" "${APP_DIR}/qbittorrent" "${ENV_FILE}"

        if [ -d "${BACKUP_CERTS}" ]; then
            mkdir -p "${APP_DIR}/caddy/data/caddy"
            cp -r "${BACKUP_CERTS}" "${APP_DIR}/caddy/data/caddy/certificates" 2>/dev/null || true
            rm -rf "${BACKUP_CERTS}"
            log_ok "SSL-сертификаты успешно сохранены для последующего использования"
        fi

        rm -f /usr/local/bin/gateway-watchdog.sh /usr/local/bin/homelab-unlock
        rm -f /etc/systemd/system/homelab.service /etc/systemd/system/network-gateway-watchdog.* /etc/systemd/system/vaultwarden-backup.* /etc/systemd/system/gitea-backup.*
        rm -f /opt/homelab/diagnostic_report.log
        local USER_HOME
        USER_HOME=$(eval echo ~"${TARGET_USER}" 2>/dev/null || echo "/home/${TARGET_USER}")
        rm -f "${USER_HOME}/diagnostic_report.log" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true

        log_info "Восстановление стандартных записей в /etc/hosts..."
        sed -i '/\.lan$/d' /etc/hosts 2>/dev/null || true

        echo ""
        log_ok "Сброс стека успешно завершен! Все компоненты очищены."
        log_ok "Теперь вы можете заново запустить скрипт и настроить систему с нуля."
        exit 0
    fi

    if [ "$INSTALL_MODE" = "1" ]; then
        log_info "Выбран режим 'Экспресс-установка' (Zero-Touch): все сервисы будут включены."
        STORAGE_MODE="1"
        SUBDIR_NAME=""
        local USER_HOME
        USER_HOME=$(eval echo ~"${TARGET_USER}" 2>/dev/null || echo "/home/${TARGET_USER}")
        DEF_SAVE_DIR="${SAVED_SAVE_DIR:-${USER_HOME}/save}"
        read -rp "  [?] Путь к каталогу данных [Enter - ${DEF_SAVE_DIR}]: " INPUT_SAVE_DIR || true
        SAVE_DIR=${INPUT_SAVE_DIR:-${DEF_SAVE_DIR}}
        mkdir -p "${SAVE_DIR}"

        ENABLE_GATEWAY="Y"
        ENABLE_VAULT="Y"
        ENABLE_GITEA="Y"
        ENABLE_SAMBA="Y"
        ENABLE_QBIT="Y"
        ENABLE_METUBE="Y"
        SSL_MODE="1"

        echo ""
        echo -e "  ${CLR_CYAN}--- Экспресс-параметры шлюза и учетных записей ---${CLR_RESET}"
        DEF_SUB="${SAVED_SUB_URL:-none}"
        read -rp "  [?] Ссылка на Clash/Mihomo подписку [Enter - ${DEF_SUB}]: " INPUT_SUB_URL || true
        SUB_URL=${INPUT_SUB_URL:-${DEF_SUB}}
        if [ -z "$SUB_URL" ] || [ "$SUB_URL" = "none" ] || [ "$SUB_URL" = "skip" ] || [ "$SUB_URL" = "direct" ] || [ "$SUB_URL" = "-" ]; then
            SUB_URL="none"
            log_ok "Режим шлюза: DIRECT (чистая маршрутизация, без прокси)"
        else
            log_ok "Подписка сохранена"
        fi

        DEF_ADMIN_USER="${SAVED_ADMIN_USER:-${TARGET_USER}}"
        read -rp "  [?] Имя пользователя для веб-панелей и Samba [Enter - ${DEF_ADMIN_USER}]: " INPUT_ADMIN_USER || true
        ADMIN_USER=${INPUT_ADMIN_USER:-${DEF_ADMIN_USER}}
        ADMIN_USER=$(echo "${ADMIN_USER}" | tr -cd "[:alnum:]_-")
        [ -z "${ADMIN_USER}" ] && ADMIN_USER="admin"
        ADMIN_USER_SAFE=$(echo "${ADMIN_USER}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')

        GEN_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(12))" 2>/dev/null || echo "SecurePass$(date +%s)")
        if [ -n "${SAVED_MASTER_PASS:-}" ]; then
            PROMPT_PASS_MSG="Enter - оставить прежний: ${SAVED_MASTER_PASS}"
        else
            PROMPT_PASS_MSG="Enter - сгенерировать: ${GEN_PASS}"
        fi
        DEF_PASS="${SAVED_MASTER_PASS:-${GEN_PASS}}"
        read -rp "  [?] Единый мастер-пароль [${PROMPT_PASS_MSG}]: " INPUT_PASS || true
        MASTER_PASS=${INPUT_PASS:-${DEF_PASS}}
        MIHOMO_SECRET="${MASTER_PASS}"
        SAMBA_PASS="${MASTER_PASS}"
        AGH_PASS="${MASTER_PASS}"
        VAULT_ADMIN_TOKEN="${SAVED_VAULT_ADMIN_TOKEN:-${MASTER_PASS}}"

        DUCKDNS_NAME=""
        DUCKDNS_TOKEN=""
        BASE_DOMAIN=""
        VAULT_DOMAIN="vault.lan"
        GITEA_DOMAIN="git.lan"
        ADGUARD_DOMAIN="adguard.lan"
        TORRENT_DOMAIN="torrent.lan"
        METUBE_DOMAIN="metube.lan"
        PROXY_DOMAIN="proxy.lan"
    else
        echo -e "  ${CLR_CYAN}--- Настройка дискового хранилища ---${CLR_RESET}"
        echo "    1) Системный диск [Enter]"
        echo "    2) Подключить существующий раздел БЕЗ шифрования"
        echo "    3) Отформатировать диск в Btrfs (ДАННЫЕ БУДУТ УНИЧТОЖЕНЫ)"
        echo "    4) Подключить существующий диск LUKS2"
        echo "    5) Отформатировать диск в LUKS2 + Btrfs (ДАННЫЕ БУДУТ УНИЧТОЖЕНЫ)"
        DEF_STORAGE_MODE="${SAVED_STORAGE_MODE:-1}"
        read -rp "  [?] Выберите вариант [1-5] [${DEF_STORAGE_MODE}]: " STORAGE_MODE || true
        STORAGE_MODE=${STORAGE_MODE:-${DEF_STORAGE_MODE}}

        if [ "$STORAGE_MODE" = "2" ]; then
            select_disk_device
            DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}" || true)
            DEV_FSTYPE=$(blkid -s TYPE -o value "${CHOSEN_DEV}" || true)

            mkdir -p "${MOUNT_ROOT}"
            MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=15s"
            if [[ "$DEV_FSTYPE" =~ ^(exfat|ntfs|vfat)$ ]]; then
                MOUNT_OPTS="${MOUNT_OPTS},uid=${USER_UID},gid=${USER_GID},umask=000,iocharset=utf8"
            elif [ "$DEV_FSTYPE" = "btrfs" ]; then
                MOUNT_OPTS="${MOUNT_OPTS},compress=zstd,discard=async"
            fi

            mountpoint -q "${MOUNT_ROOT}" || mount -o "${MOUNT_OPTS}" "${CHOSEN_DEV}" "${MOUNT_ROOT}"
            [ "$DEV_FSTYPE" = "btrfs" ] && chown -R "${USER_UID}:${USER_GID}" "${MOUNT_ROOT}" 2>/dev/null || true

            if [ -n "${DEV_UUID}" ] && ! grep -q "${DEV_UUID}" /etc/fstab 2>/dev/null; then
                echo "UUID=${DEV_UUID} ${MOUNT_ROOT} ${DEV_FSTYPE:-auto} ${MOUNT_OPTS} 0 0" >> /etc/fstab
            fi

            STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
            DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
            read -rp "  [?] Имя подкаталога для данных [${DEF_SUBDIR}]: " SUBDIR_NAME || true
            SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
            SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
            mkdir -p "${SAVE_DIR}"

        elif [ "$STORAGE_MODE" = "3" ]; then
            select_disk_device
            echo ""
            log_warn "Все данные на ${CHOSEN_DEV} будут уничтожены!"
            read -rp "  [?] Подтвердите форматирование (введите 'yes'): " CONFIRM_WIPE || true
            if [[ ! "${CONFIRM_WIPE:-}" =~ ^[Yy][Ee][Ss]$ ]]; then
                log_info "Отмена операции."
                exit 1
            fi

            assert_safe_device "${CHOSEN_DEV}"
            release_device "${CHOSEN_DEV}"
            mkfs.btrfs -f -L "HOMELAB" "${CHOSEN_DEV}"
            DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}")

            mkdir -p "${MOUNT_ROOT}"
            MOUNT_OPTS="defaults,noatime,compress=zstd,discard=async,nofail,x-systemd.device-timeout=15s"
            mount -o "${MOUNT_OPTS}" "${CHOSEN_DEV}" "${MOUNT_ROOT}"
            chown -R "${USER_UID}:${USER_GID}" "${MOUNT_ROOT}"

            if [ -n "${DEV_UUID}" ] && ! grep -q "${DEV_UUID}" /etc/fstab 2>/dev/null; then
                echo "UUID=${DEV_UUID} ${MOUNT_ROOT} btrfs ${MOUNT_OPTS} 0 0" >> /etc/fstab
            fi

            STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
            DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
            read -rp "  [?] Имя подкаталога для данных [${DEF_SUBDIR}]: " SUBDIR_NAME || true
            SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
            SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
            mkdir -p "${SAVE_DIR}"

        elif [ "$STORAGE_MODE" = "4" ] || [ "$STORAGE_MODE" = "5" ]; then
            select_disk_device

            if [ "$STORAGE_MODE" = "5" ]; then
                echo ""
                log_warn "Накопитель ${CHOSEN_DEV} будет полностью зашифрован LUKS2 (Argon2id) и отформатирован в Btrfs!"
                read -rp "  [?] Подтвердите форматирование (введите 'yes'): " CONFIRM_WIPE || true
                if [[ ! "${CONFIRM_WIPE:-}" =~ ^[Yy][Ee][Ss]$ ]]; then
                    log_info "Отмена операции."
                    exit 1
                fi

                assert_safe_device "${CHOSEN_DEV}"
                release_device "${CHOSEN_DEV}"

                log_info "Создание крипто-тома LUKS2 (задайте пароль диска):"
                cryptsetup luksFormat --type luks2 --pbkdf argon2id "${CHOSEN_DEV}"

                log_info "Открытие тома..."
                cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"

                log_info "Создание файловой системы Btrfs..."
                mkfs.btrfs -f -L "HOMELAB" "/dev/mapper/${LUKS_MAP_NAME}"
            fi

            if [ "$STORAGE_MODE" = "4" ]; then
                if [ ! -e "/dev/mapper/${LUKS_MAP_NAME}" ]; then
                    log_info "Введите пароль для расшифровки ${CHOSEN_DEV}:"
                    cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"
                fi
            fi

            MAPPER_DEV="/dev/mapper/${LUKS_MAP_NAME}"
            DEV_FSTYPE=$(blkid -s TYPE -o value "${MAPPER_DEV}" || echo "btrfs")

            MOUNT_OPTS="defaults,noatime,nofail,x-systemd.device-timeout=15s"
            [ "$DEV_FSTYPE" = "btrfs" ] && MOUNT_OPTS="${MOUNT_OPTS},compress=zstd,discard=async"

            mkdir -p "${MOUNT_ROOT}"
            mountpoint -q "${MOUNT_ROOT}" || mount -o "${MOUNT_OPTS}" "${MAPPER_DEV}" "${MOUNT_ROOT}"
            [ "$DEV_FSTYPE" = "btrfs" ] && chown -R "${USER_UID}:${USER_GID}" "${MOUNT_ROOT}" 2>/dev/null || true

            DEF_SUBDIR="${SAVED_SUBDIR_NAME:-save}"
            read -rp "  [?] Имя подкаталога для данных [${DEF_SUBDIR}]: " SUBDIR_NAME || true
            SUBDIR_NAME=${SUBDIR_NAME:-${DEF_SUBDIR}}
            SAVE_DIR="${MOUNT_ROOT}/${SUBDIR_NAME}"
            mkdir -p "${SAVE_DIR}"

            log_info "Настройка безопасной авторазблокировки при старте через ключ-файл..."
            DEV_UUID=$(blkid -s UUID -o value "${CHOSEN_DEV}")

            KEY_DIR="/etc/cryptsetup-keys.d"
            KEY_FILE="${KEY_DIR}/storage_${LUKS_MAP_NAME}.key"

            mkdir -p "${KEY_DIR}"
            chmod 700 "${KEY_DIR}"

            if [ ! -f "${KEY_FILE}" ]; then
                log_info "Генерация случайного крипто-ключа авторазблокировки..."
                dd if=/dev/urandom of="${KEY_FILE}" bs=512 count=1 status=none
                chmod 400 "${KEY_FILE}"

                log_info "Добавление ключа в слот LUKS2 (введите пароль диска):"
                cryptsetup luksAddKey "${CHOSEN_DEV}" "${KEY_FILE}"
            fi

            if ! grep -q "${LUKS_MAP_NAME}" /etc/crypttab 2>/dev/null; then
                echo "${LUKS_MAP_NAME} UUID=${DEV_UUID} ${KEY_FILE} luks,discard,nofail,timeout=15" >> /etc/crypttab
            fi

            if ! grep -q "${MOUNT_ROOT}" /etc/fstab 2>/dev/null; then
                echo "${MAPPER_DEV} ${MOUNT_ROOT} ${DEV_FSTYPE} ${MOUNT_OPTS} 0 0" >> /etc/fstab
            fi

            STORAGE_DEP_LINE="RequiresMountsFor=${MOUNT_ROOT}"
            log_ok "Авторазблокировка успешно настроена в crypttab и fstab!"

            cat << EOF_UNLOCK > /usr/local/bin/homelab-unlock
#!/usr/bin/env bash
set -euo pipefail
if [ "\${EUID:-\$(id -u)}" -ne 0 ]; then
    echo "[-] Запустите через sudo: sudo homelab-unlock"
    exit 1
fi
if [ ! -e "${MAPPER_DEV}" ]; then
    echo "[*] Разблокировка ${CHOSEN_DEV}..."
    cryptsetup open "${CHOSEN_DEV}" "${LUKS_MAP_NAME}"
fi
mkdir -p "${MOUNT_ROOT}"
mountpoint -q "${MOUNT_ROOT}" || mount -o "${MOUNT_OPTS}" "${MAPPER_DEV}" "${MOUNT_ROOT}"
echo "[*] Запуск сервисов Docker..."
cd "${APP_DIR}" && (command -v dc >/dev/null 2>&1 && dc up -d || docker compose up -d)
echo "[+] Диск смонтирован, сервисы готовы к работе!"
EOF_UNLOCK
            chmod 750 /usr/local/bin/homelab-unlock
        else
            SUBDIR_NAME=""
            local USER_HOME
            USER_HOME=$(eval echo ~"${TARGET_USER}" 2>/dev/null || echo "/home/${TARGET_USER}")
            DEF_SAVE_DIR="${SAVED_SAVE_DIR:-${USER_HOME}/save}"
            read -rp "  [?] Каталог данных на системном диске [${DEF_SAVE_DIR}]: " INPUT_SAVE_DIR || true
            SAVE_DIR=${INPUT_SAVE_DIR:-${DEF_SAVE_DIR}}
            mkdir -p "${SAVE_DIR}"
        fi

        echo ""
        echo -e "  ${CLR_CYAN}--- Выбор устанавливаемых компонентов ---${CLR_RESET}"
        read -rp "  [?] Установить сетевой шлюз (AdGuard + Mihomo TUN)? [Y/n] [${SAVED_ENABLE_GATEWAY:-Y}]: " ENABLE_GATEWAY || true
        ENABLE_GATEWAY=${ENABLE_GATEWAY:-${SAVED_ENABLE_GATEWAY:-Y}}

        read -rp "  [?] Установить Vaultwarden (Менеджер паролей)? [Y/n] [${SAVED_ENABLE_VAULT:-Y}]: " ENABLE_VAULT || true
        ENABLE_VAULT=${ENABLE_VAULT:-${SAVED_ENABLE_VAULT:-Y}}

        read -rp "  [?] Установить Gitea (Git-сервер)? [Y/n] [${SAVED_ENABLE_GITEA:-Y}]: " ENABLE_GITEA || true
        ENABLE_GITEA=${ENABLE_GITEA:-${SAVED_ENABLE_GITEA:-Y}}

        read -rp "  [?] Установить Samba (Сетевая папка с WSDD2)? [Y/n] [${SAVED_ENABLE_SAMBA:-Y}]: " ENABLE_SAMBA || true
        ENABLE_SAMBA=${ENABLE_SAMBA:-${SAVED_ENABLE_SAMBA:-Y}}

        read -rp "  [?] Установить qBittorrent + VueTorrent (Торренты/Загрузки)? [Y/n] [${SAVED_ENABLE_QBIT:-Y}]: " ENABLE_QBIT || true
        ENABLE_QBIT=${ENABLE_QBIT:-${SAVED_ENABLE_QBIT:-Y}}

        read -rp "  [?] Установить MeTube (Web-загрузчик yt-dlp)? [Y/n] [${SAVED_ENABLE_METUBE:-Y}]: " ENABLE_METUBE || true
        ENABLE_METUBE=${ENABLE_METUBE:-${SAVED_ENABLE_METUBE:-Y}}

        echo ""
        echo -e "  ${CLR_CYAN}--- Настройка SSL сертификатов ---${CLR_RESET}"
        echo "    1) Локальный Caddy (*.lan, доверие через CA сертификат root.crt)"
        echo "    2) DuckDNS + Let's Encrypt (публичный Wildcard SSL через DNS-01)"
        read -rp "  [?] Режим SSL [1/2] [${SAVED_SSL_MODE:-1}]: " SSL_MODE || true
        SSL_MODE=${SSL_MODE:-${SAVED_SSL_MODE:-1}}

        if [ "$SSL_MODE" = "2" ]; then
            read -rp "  [?] Поддомен DuckDNS [${SAVED_DUCKDNS_NAME:-}]: " DUCKDNS_NAME || true
            DUCKDNS_NAME=${DUCKDNS_NAME:-${SAVED_DUCKDNS_NAME:-}}
            DUCKDNS_NAME=$(echo "${DUCKDNS_NAME}" | sed "s/\.duckdns\.org$//")
            while [ -z "$DUCKDNS_NAME" ]; do
                read -rp "  [-] Имя обязательно: " DUCKDNS_NAME || true
            done
            read -rp "  [?] Токен DuckDNS [${SAVED_DUCKDNS_TOKEN:-}]: " DUCKDNS_TOKEN || true
            DUCKDNS_TOKEN=${DUCKDNS_TOKEN:-${SAVED_DUCKDNS_TOKEN:-}}
            while [ -z "$DUCKDNS_TOKEN" ]; do
                read -rp "  [-] Токен обязателен: " DUCKDNS_TOKEN || true
            done

            BASE_DOMAIN="${DUCKDNS_NAME}.duckdns.org"
            VAULT_DOMAIN="vault.${BASE_DOMAIN}"
            GITEA_DOMAIN="git.${BASE_DOMAIN}"
            ADGUARD_DOMAIN="adguard.${BASE_DOMAIN}"
            TORRENT_DOMAIN="torrent.${BASE_DOMAIN}"
            METUBE_DOMAIN="metube.${BASE_DOMAIN}"
            PROXY_DOMAIN="proxy.${BASE_DOMAIN}"
        else
            SSL_MODE="1"
            DUCKDNS_NAME=""
            DUCKDNS_TOKEN=""
            BASE_DOMAIN=""
            VAULT_DOMAIN="vault.lan"
            GITEA_DOMAIN="git.lan"
            ADGUARD_DOMAIN="adguard.lan"
            TORRENT_DOMAIN="torrent.lan"
            METUBE_DOMAIN="metube.lan"
            PROXY_DOMAIN="proxy.lan"
        fi

        SUB_URL="${SAVED_SUB_URL:-none}"
        if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
            read -rp "  [?] Ссылка на Clash/Mihomo подписку (Enter для DIRECT) [${SAVED_SUB_URL:-none}]: " SUB_URL || true
            SUB_URL=${SUB_URL:-${SAVED_SUB_URL:-none}}
            if [ -z "$SUB_URL" ] || [ "$SUB_URL" = "none" ] || [ "$SUB_URL" = "skip" ] || [ "$SUB_URL" = "direct" ] || [ "$SUB_URL" = "-" ]; then
                SUB_URL="none"
                log_ok "Режим шлюза: DIRECT (чистая маршрутизация, без прокси)"
            else
                log_ok "Подписка сохранена"
            fi
        fi

        echo ""
        echo -e "  ${CLR_CYAN}--- Пользователь и пароли ---${CLR_RESET}"
        DEF_ADMIN_USER="${SAVED_ADMIN_USER:-${TARGET_USER}}"
        read -rp "  [?] Имя пользователя для веб-панелей и Samba [${DEF_ADMIN_USER}]: " INPUT_ADMIN_USER || true
        ADMIN_USER=${INPUT_ADMIN_USER:-${DEF_ADMIN_USER}}
        ADMIN_USER=$(echo "${ADMIN_USER}" | tr -cd "[:alnum:]_-")
        [ -z "${ADMIN_USER}" ] && ADMIN_USER="admin"
        ADMIN_USER_SAFE=$(echo "${ADMIN_USER}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')

        GEN_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(12))" 2>/dev/null || echo "SecurePass$(date +%s)")
        if [ -n "${SAVED_MASTER_PASS:-}" ]; then
            PROMPT_PASS_MSG="Enter - оставить прежний: ${SAVED_MASTER_PASS}"
        else
            PROMPT_PASS_MSG="Enter - сгенерировать: ${GEN_PASS}"
        fi
        read -rp "  [?] Единый мастер-пароль [${PROMPT_PASS_MSG}]: " INPUT_MASTER_PASS || true
        MASTER_PASS=${INPUT_MASTER_PASS:-${SAVED_MASTER_PASS:-${GEN_PASS}}}
        SAMBA_PASS="${MASTER_PASS}"
        AGH_PASS="${MASTER_PASS}"
        MIHOMO_SECRET="${MASTER_PASS}"

        if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
            DEF_VAULT_TOKEN="${SAVED_VAULT_ADMIN_TOKEN:-${MASTER_PASS}}"
            read -rp "  [?] Токен администратора Vaultwarden (/admin) [${DEF_VAULT_TOKEN}]: " INPUT_VAULT_TOKEN || true
            VAULT_ADMIN_TOKEN=${INPUT_VAULT_TOKEN:-${DEF_VAULT_TOKEN}}
        else
            VAULT_ADMIN_TOKEN="${SAVED_VAULT_ADMIN_TOKEN:-${MASTER_PASS}}"
        fi
    fi

    SHARE_NAME=$(basename "${SAVE_DIR}" | tr -cd '[:alnum:]_-')
    [ -z "${SHARE_NAME}" ] && SHARE_NAME="storage"

    # Определение размещения каталогов данных
    local ROOT_DEV
    ROOT_DEV=$(df -P / 2>/dev/null | awk 'NR==2{print $1}' || echo "/dev/root")
    local SAVE_DEV
    SAVE_DEV=$(df -P "${SAVE_DIR}" 2>/dev/null | awk 'NR==2{print $1}' || echo "${ROOT_DEV}")

    if [ "${ROOT_DEV}" != "${SAVE_DEV}" ] || [ -n "${STORAGE_DEP_LINE}" ]; then
        VAULT_DATA_DIR="${SAVE_DIR}/services/vaultwarden"
        GITEA_DATA_DIR="${SAVE_DIR}/services/gitea"
        ADGUARD_WORK_DIR="${SAVE_DIR}/services/adguard_work"
    else
        VAULT_DATA_DIR="${APP_DIR}/vaultwarden"
        GITEA_DATA_DIR="${APP_DIR}/gitea"
        ADGUARD_WORK_DIR="${APP_DIR}/adguard/work"
    fi

    mkdir -p "${APP_DIR}"
    {
        printf "SAVED_PHYS_IFACE=%q\n" "${DEFAULT_IFACE}"
        printf "SAVED_LOCAL_IP=%q\n" "${LOCAL_IP}"
        printf "SAVED_ROUTER_GATEWAY=%q\n" "${ROUTER_GATEWAY}"
        printf "SAVED_LAN_SUBNET=%q\n" "${LAN_SUBNET}"
        printf "SAVED_ENABLE_GATEWAY=%q\n" "${ENABLE_GATEWAY}"
        printf "SAVED_ENABLE_VAULT=%q\n" "${ENABLE_VAULT}"
        printf "SAVED_ENABLE_GITEA=%q\n" "${ENABLE_GITEA}"
        printf "SAVED_ENABLE_SAMBA=%q\n" "${ENABLE_SAMBA}"
        printf "SAVED_ENABLE_QBIT=%q\n" "${ENABLE_QBIT}"
        printf "SAVED_ENABLE_METUBE=%q\n" "${ENABLE_METUBE}"
        printf "SAVED_SSL_MODE=%q\n" "${SSL_MODE}"
        printf "SAVED_DUCKDNS_NAME=%q\n" "${DUCKDNS_NAME}"
        printf "SAVED_DUCKDNS_TOKEN=%q\n" "${DUCKDNS_TOKEN}"
        printf "SAVED_SUB_URL=%q\n" "${SUB_URL}"
        printf "SAVED_TARGET_USER=%q\n" "${TARGET_USER}"
        printf "SAVED_ADMIN_USER=%q\n" "${ADMIN_USER}"
        printf "SAVED_MASTER_PASS=%q\n" "${MASTER_PASS}"
        printf "SAVED_MIHOMO_SECRET=%q\n" "${MIHOMO_SECRET}"
        printf "SAVED_VAULT_ADMIN_TOKEN=%q\n" "${VAULT_ADMIN_TOKEN}"
        printf "SAVED_STORAGE_MODE=%q\n" "${STORAGE_MODE}"
        printf "SAVED_SUBDIR_NAME=%q\n" "${SUBDIR_NAME}"
        printf "SAVED_SAVE_DIR=%q\n" "${SAVE_DIR}"
        printf "SAVED_SHARE_NAME=%q\n" "${SHARE_NAME}"
        printf "SAVED_VAULT_DATA_DIR=%q\n" "${VAULT_DATA_DIR}"
        printf "SAVED_GITEA_DATA_DIR=%q\n" "${GITEA_DATA_DIR}"
        printf "SAVED_ADGUARD_WORK_DIR=%q\n" "${ADGUARD_WORK_DIR}"
    } > "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    chown root:root "${ENV_FILE}" 2>/dev/null || true
    log_ok "Конфигурация успешно сохранена в ${ENV_FILE}"
}

# =============================================================================
# 5. ХЭШИРОВАНИЕ И СЕТЕВОЙ СТЕК
# =============================================================================
setup_credentials() {
    print_step_header "04/10" "ГЕНЕРАЦИЯ КРИПТОГРАФИЧЕСКИХ ХЭШЕЙ"

    modprobe tun 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo "tun" > /etc/modules-load.d/tun.conf

    log_info "Хэширование пароля AdGuard Home (Bcrypt)..."
    AGH_HASH=""
    
    # 1. Python bcrypt с передачей через stdin
    AGH_HASH=$(python3 -c "
import sys, warnings
warnings.simplefilter('ignore')
pw = sys.stdin.read().rstrip('\r\n')
try:
    import bcrypt
    print(bcrypt.hashpw(pw.encode('utf-8'), bcrypt.gensalt(10)).decode('utf-8'))
    sys.exit(0)
except Exception:
    pass
try:
    import passlib.hash
    print(passlib.hash.bcrypt.hash(pw))
    sys.exit(0)
except Exception:
    pass
sys.exit(1)
" <<< "${AGH_PASS}" 2>/dev/null || true)

    # 2. Fallback на htpasswd
    if [ -z "${AGH_HASH}" ] && command -v htpasswd >/dev/null 2>&1; then
        AGH_HASH=$(printf '%s\n' "${AGH_PASS}" | htpasswd -B -C 10 -n -i "${ADMIN_USER}" 2>/dev/null | cut -d: -f2 || true)
    fi

    # 3. Fallback на Docker Caddy
    if [ -z "${AGH_HASH}" ] && command -v docker >/dev/null 2>&1; then
        AGH_HASH=$(docker run --rm "caddy:alpine" caddy hash-password --plaintext "${AGH_PASS}" 2>/dev/null | tr -d '\r\n' || true)
    fi

    # 3. Fallback на Docker Caddy (передача пароля через stdin без утечки в ps aux)
    if [ -z "${AGH_HASH}" ] && command -v docker >/dev/null 2>&1; then
        AGH_HASH=$(printf '%s' "${AGH_PASS}" | docker run -i --rm "caddy:alpine" caddy hash-password 2>/dev/null | tr -d '
' || true)
    fi

    if [ -z "${AGH_HASH}" ]; then
        log_err "Критическая ошибка: Не удалось сформировать Bcrypt-хэш пароля для AdGuard Home!"
        log_err "AdGuard Home строго требует формат Bcrypt ($2a$ / $2b$). Убедитесь в наличии python3-bcrypt, apache2-utils или Docker."
        exit 1
    else
        log_ok "Bcrypt-хэш для AdGuard Home успешно сформирован"
    fi

    VAULT_ADMIN_HASH_ESCAPED=""
    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        log_info "Хэширование токена Vaultwarden /admin (Argon2id)..."
        local SALT_VAL
        SALT_VAL=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || echo "homelabdefaults123")
        
        if command -v argon2 >/dev/null 2>&1; then
            VAULT_ADMIN_HASH=$(printf '%s' "${VAULT_ADMIN_TOKEN}" | argon2 "${SALT_VAL}" -e -id -k 65540 -t 3 -p 4 2>/dev/null || true)
        fi

        # Fallback через контейнер Vaultwarden (гарантия стандарта Argon2id 2026)
        if [ -z "${VAULT_ADMIN_HASH:-}" ] && command -v docker >/dev/null 2>&1; then
            VAULT_ADMIN_HASH=$(echo "${VAULT_ADMIN_TOKEN}" | docker run -i --rm vaultwarden/server:alpine /vaultwarden hash 2>/dev/null | tr -d '\r\n' || true)
        fi

        if [ -z "${VAULT_ADMIN_HASH:-}" ]; then
            VAULT_ADMIN_HASH="${VAULT_ADMIN_TOKEN}"
        fi
        VAULT_ADMIN_HASH_ESCAPED="${VAULT_ADMIN_HASH//\$/\$\$}"
    fi
    log_ok "Криптографические хэши сервисов подготовлены"
}

setup_gateway_networking() {
    print_step_header "05/10" "МАРШРУТИЗАЦИЯ, IPTABLES И ЗАЩИТА ОТ ПЕТЕЛЬ"

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        log_info "Освобождение порта 53 (отключение DNSStubListener в systemd-resolved)..."
        if systemctl is-active --quiet systemd-resolved 2>/dev/null || [ -d /etc/systemd/resolved.conf.d ]; then
            mkdir -p /etc/systemd/resolved.conf.d/
            cat <<EOF_RESOLVED > /etc/systemd/resolved.conf.d/disable-stub.conf
[Resolve]
DNSStubListener=no
DNS=77.88.8.8 1.1.1.1
EOF_RESOLVED
            systemctl restart systemd-resolved 2>/dev/null || true
        fi

        # Защита от перезаписи DNS NetworkManager'ом
        if [ -d /etc/NetworkManager/conf.d ]; then
            cat <<EOF_NM > /etc/NetworkManager/conf.d/99-homelab-dns.conf
[main]
dns=none
EOF_NM
            systemctl reload NetworkManager 2>/dev/null || true
        fi

        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        cat <<EOF_DNS > /etc/resolv.conf
nameserver 77.88.8.8
nameserver 1.1.1.1
EOF_DNS

        # Загрузка модуля TCP BBR
        modprobe tcp_bbr 2>/dev/null || true
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

        log_info "Настройка sysctl: IP-форвардинг, BBR и loose rp_filter для TUN-маршрутизации..."
        cat <<EOF_SYSCTL > /etc/sysctl.d/99-gateway.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${DEFAULT_IFACE}.rp_filter = 2
EOF_SYSCTL
        sysctl --system >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

        if command -v nmcli >/dev/null 2>&1 && [ -n "${DEFAULT_IFACE}" ]; then
            nmcli connection modify "${DEFAULT_IFACE}" ipv6.method disabled 2>/dev/null || true
        fi
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        if [ -n "${DEFAULT_IFACE}" ]; then
            iptables -t nat -C POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE
            # Блокировка прямого незашифрованного доступа к AdGuard 8083 из LAN (доступ строго через Caddy)
            iptables -C INPUT -i "${DEFAULT_IFACE}" -p tcp --dport 8083 -j DROP 2>/dev/null || \
            iptables -A INPUT -i "${DEFAULT_IFACE}" -p tcp --dport 8083 -j DROP 2>/dev/null || true
        fi

        log_info "Установка сторожевого таймера защиты от петель маршрутизации..."
        cat << 'EOF_WATCHDOG' > /usr/local/bin/gateway-watchdog.sh
#!/usr/bin/env bash
set -euo pipefail

[ -f /opt/homelab/.env ] && source /opt/homelab/.env

IFACE="${SAVED_PHYS_IFACE:-${PHYS_IFACE:-}}"
[ -z "$IFACE" ] && IFACE=$( (ip -o -4 route show default 2>/dev/null | awk '{print $5}' | grep -vE '^(Meta|tun|tap|docker|br-|veth|wg|tailscale|zt|dummy|bond|lo)' | head -n1) || true )
[ -z "$IFACE" ] && IFACE=$( (ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(en|eth|wl)' | head -n1) || true )
[ -z "$IFACE" ] && exit 0

SERVER_IP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
ROUTER_IP="${SAVED_ROUTER_GATEWAY:-}"

if [ -z "$ROUTER_IP" ] || [ "$ROUTER_IP" = "$SERVER_IP" ] || [[ ! "$ROUTER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ROUTER_IP=$(ip route show default dev "$IFACE" 2>/dev/null | awk '/via/ {for(j=1;j<=NF;j++) if($j=="via") {print $(j+1); exit}}' | head -n1 || true)
fi

if [ -z "$ROUTER_IP" ] || [ "$ROUTER_IP" = "$SERVER_IP" ] || [[ ! "$ROUTER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ROUTER_IP=$(ip neigh show dev "$IFACE" 2>/dev/null | grep -E 'REACHABLE|DELAY|STALE' | awk '{print $1}' | grep -v "$SERVER_IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
fi

if [ -z "$ROUTER_IP" ] || [ "$ROUTER_IP" = "$SERVER_IP" ] || [[ ! "$ROUTER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ROUTER_IP=$(echo "$SERVER_IP" | sed 's/\.[0-9]*$/.1/' || true)
fi

if [ -n "$ROUTER_IP" ] && [ "$ROUTER_IP" != "$SERVER_IP" ] && [[ "$ROUTER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CURRENT_MAIN_GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '/via/ {for(j=1;j<=NF;j++) if($j=="via") {print $(j+1); exit}}' | head -n1 || true)
    if [ "$CURRENT_MAIN_GW" = "$SERVER_IP" ] || [ -z "$CURRENT_MAIN_GW" ]; then
        logger -t gateway-watchdog "Восстановление корректного маршрута default через ${ROUTER_IP} на ${IFACE}" 2>/dev/null || true
        ip route replace default via "$ROUTER_IP" dev "$IFACE" metric 100 2>/dev/null || true
    fi
fi

sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
if [ -n "$IFACE" ]; then
    iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true

    # Поддержание постоянной защиты порта 8083 AdGuard от прямого доступа из LAN
    iptables -C INPUT -i "$IFACE" -p tcp --dport 8083 -j DROP 2>/dev/null || \
    iptables -A INPUT -i "$IFACE" -p tcp --dport 8083 -j DROP 2>/dev/null || true
fi
EOF_WATCHDOG
        chmod 750 /usr/local/bin/gateway-watchdog.sh

        cat <<EOF_WD_SVC > /etc/systemd/system/network-gateway-watchdog.service
[Unit]
Description=Gateway Auto-Discovery and Loop Recovery Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gateway-watchdog.sh
EOF_WD_SVC

        cat <<EOF_WD_TMR > /etc/systemd/system/network-gateway-watchdog.timer
[Unit]
Description=Run Gateway Loop Watchdog periodically

[Timer]
OnBootSec=15s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF_WD_TMR

        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now network-gateway-watchdog.timer >/dev/null 2>&1 || true
    fi

    log_info "Регистрация локальных доменов в /etc/hosts..."
    for DOMAIN in "${VAULT_DOMAIN}" "${GITEA_DOMAIN}" "${ADGUARD_DOMAIN}" "${TORRENT_DOMAIN}" "${METUBE_DOMAIN}" "${PROXY_DOMAIN}"; do
        if [ -n "${DOMAIN}" ]; then
            local ESCAPED_DOMAIN
            ESCAPED_DOMAIN=$(printf '%s\n' "${DOMAIN}" | sed -e 's/[]\/$*.^[]/\\&/g')
            if ! grep -q "[[:space:]]${ESCAPED_DOMAIN}$" /etc/hosts; then
                echo "${LOCAL_IP} ${DOMAIN}" >> /etc/hosts
            else
                sed -i "s/.*[[:space:]]${ESCAPED_DOMAIN}$/${LOCAL_IP} ${DOMAIN}/" /etc/hosts
            fi
        fi
    done
    log_ok "Сетевой стек и сторож маршрутизации настроены"
}

# =============================================================================
# 6. СТРУКТУРА КАТАЛОГОВ И BTRFS NO-COW
# =============================================================================
setup_directories() {
    print_step_header "06/10" "СТРУКТУРА КАТАЛОГОВ И BTRFS NO-COW"

    mkdir -p "${APP_DIR}/caddy/data" "${APP_DIR}/caddy/config"
    mkdir -p "${SAVE_DIR}/certificates" "${SAVE_DIR}/backups/vaultwarden" "${SAVE_DIR}/backups/gitea"
    mkdir -p "${VAULT_DATA_DIR}" "${GITEA_DATA_DIR}" "${ADGUARD_WORK_DIR}"
    chown -R "${USER_UID}:${USER_GID}" "${GITEA_DATA_DIR}" 2>/dev/null || true

    apply_nocow_helper() {
        local target_dir="$1"
        mkdir -p "${target_dir}"
        chattr +C "${target_dir}" 2>/dev/null || true
        # На файловой системе Btrfs атрибут +C применяется только к новым файлам, обрабатываем существующие
        find "${target_dir}" -maxdepth 2 -type f -exec chattr +C {} + 2>/dev/null || true
    }

    log_info "Применение Btrfs No-COW к каталогам баз данных и медиа-потоков..."
    apply_nocow_helper "${ADGUARD_WORK_DIR}"
    apply_nocow_helper "${VAULT_DATA_DIR}"
    apply_nocow_helper "${GITEA_DATA_DIR}"
    mkdir -p "${APP_DIR}/adguard/conf" 

    # Подготовка каталогов для MeTube с No-COW на пути сохранения
    if [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]; then
        mkdir -p "${SAVE_DIR}/metube"
        apply_nocow_helper "${SAVE_DIR}/metube"
        chown -R "${USER_UID}:${USER_GID}" "${SAVE_DIR}/metube" 2>/dev/null || true
    fi

    # Подготовка каталогов для qBittorrent и VueTorrent
    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        mkdir -p "${APP_DIR}/qbittorrent/config/qBittorrent" "${APP_DIR}/qbittorrent/vuetorrent"
        mkdir -p "${SAVE_DIR}/temp"
        apply_nocow_helper "${SAVE_DIR}/temp"
        chown -R "${USER_UID}:${USER_GID}" "${SAVE_DIR}/temp" 2>/dev/null || true

        local VUETORRENT_OK=0
        if [ -f "${APP_DIR}/qbittorrent/vuetorrent/index.html" ]; then
            log_ok "Веб-интерфейс VueTorrent уже установлен (пропуск загрузки)"
            VUETORRENT_OK=1
        else
            log_info "Загрузка и распаковка веб-интерфейса VueTorrent..."
            python3 -c "
import urllib.request, zipfile, os

urls = [
    'https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip',
    'https://mirror.ghproxy.com/https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip',
    'https://ghproxy.net/https://github.com/VueTorrent/VueTorrent/releases/latest/download/vuetorrent.zip'
]
zip_p = '/tmp/vuetorrent.zip'
dest = '${APP_DIR}/qbittorrent/vuetorrent'
os.makedirs(dest, exist_ok=True)

for u in urls:
    try:
        req = urllib.request.Request(u, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=15) as resp, open(zip_p, 'wb') as f:
            f.write(resp.read())
        if os.path.isfile(zip_p) and os.path.getsize(zip_p) > 50000:
            break
    except Exception:
        pass

if os.path.isfile(zip_p) and os.path.getsize(zip_p) > 50000:
    with zipfile.ZipFile(zip_p, 'r') as z:
        names = [n for n in z.namelist() if not n.endswith('/')]
        has_public = any('public/' in n for n in names)
        for m in names:
            if has_public:
                if 'public/' in m:
                    rel = m.split('public/', 1)[1]
                else:
                    continue
            else:
                parts = m.split('/', 1)
                rel = parts[1] if len(parts) > 1 and parts[0].lower() in ('vuetorrent', 'vuetorrent-main') else m
            target = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as out_f:
                out_f.write(z.read(m))
            pub_target = os.path.join(dest, 'public', rel)
            os.makedirs(os.path.dirname(pub_target), exist_ok=True)
            with open(pub_target, 'wb') as pub_f:
                pub_f.write(z.read(m))
    try:
        os.remove(zip_p)
    except Exception:
        pass
" 2>/dev/null || true
            [ -f "${APP_DIR}/qbittorrent/vuetorrent/index.html" ] && VUETORRENT_OK=1
        fi

        chown -R "${USER_UID}:${USER_GID}" "${APP_DIR}/qbittorrent" 2>/dev/null || true
        log_info "Генерация конфигурации qBittorrent с мастер-паролем..."
        
        # Безопасное вычисление хэша пароля без строковой инъекции
        local QBIT_HASH
        QBIT_HASH=$(python3 -c "
import sys, hashlib, os, base64
pw = sys.stdin.read().rstrip('\r\n').encode('utf-8')
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 100000, dklen=64)
print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')
" <<< "${MASTER_PASS}" 2>/dev/null || echo "")
        
        local ALT_UI_FLAG="false"
        [ "${VUETORRENT_OK}" -eq 1 ] && ALT_UI_FLAG="true"

        cat <<EOF_QBIT_CONF > "${APP_DIR}/qbittorrent/config/qBittorrent/qBittorrent.conf"
[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Connection\PortRangeMin=6881
Downloads\DiskWriteCacheSize=32
Downloads\SavePath=/downloads/
Downloads\ScanDirsV2=@Invalid()
Downloads\TempPath=/downloads/temp/
Queueing\QueueingEnabled=false
WebUI\Address=0.0.0.0
WebUI\AlternativeUIEnabled=${ALT_UI_FLAG}
WebUI\AuthSubnetWhitelist=
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\BanDuration=3600
WebUI\CSRFProtection=false
WebUI\ClickjackingProtection=true
WebUI\CustomHTTPHeaders=
WebUI\CustomHTTPHeadersEnabled=false
WebUI\HostHeaderValidation=false
WebUI\LocalHostAuth=false
WebUI\MaxAuthenticationFailCount=5
WebUI\Password_PBKDF2="${QBIT_HASH}"
WebUI\Port=8080
WebUI\ReverseProxySupportEnabled=true
WebUI\RootFolder=/vuetorrent
WebUI\SecureCookie=false
WebUI\ServerDomains=*
WebUI\SessionTimeout=86400
WebUI\TrustedProxiesList=0.0.0.0/0
WebUI\UseUPnP=false
WebUI\Username=${ADMIN_USER}
EOF_QBIT_CONF
        chown -R "${USER_UID}:${USER_GID}" "${APP_DIR}/qbittorrent" 2>/dev/null || true
    fi

    chown -R "${USER_UID}:${USER_GID}" "${SAVE_DIR}" 2>/dev/null || true

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        mkdir -p "${APP_DIR}/mihomo/ui" "${APP_DIR}/mihomo/providers"
        [ ! -f "${APP_DIR}/mihomo/providers/proxies.yaml" ] && echo "proxies: []" > "${APP_DIR}/mihomo/providers/proxies.yaml"

        if [ -f "${APP_DIR}/mihomo/ui/index.html" ]; then
            log_ok "Веб-интерфейс MetaCubeXD уже установлен (пропуск загрузки)"
        else
            fetch_metacubexd() {
                local urls=(
                    'https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz'
                    'https://mirror.ghproxy.com/https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz'
                    'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz'
                    'https://mirror.ghproxy.com/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz'
                    'https://ghproxy.net/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz'
                )
                local tar_tmp="/tmp/metacubexd.tar.gz"
                for u in "${urls[@]}"; do
                    if curl -fsSL --connect-timeout 8 -m 30 "$u" -o "$tar_tmp" 2>/dev/null && [ -s "$tar_tmp" ]; then
                        if [[ "$u" =~ compressed-dist ]]; then
                            tar -xzf "$tar_tmp" -C "${APP_DIR}/mihomo/ui" 2>/dev/null && rm -f "$tar_tmp" && return 0
                        else
                            tar -xzf "$tar_tmp" -C "${APP_DIR}/mihomo/ui" --strip-components=1 2>/dev/null && rm -f "$tar_tmp" && return 0
                        fi
                        rm -f "$tar_tmp"
                    fi
                done
                return 1
            }
            run_spin "Загрузка веб-интерфейса MetaCubeXD (с зеркалами)" fetch_metacubexd || true
        fi

        # Предотвращение Mixed Content в UI при работе через HTTPS
        find "${APP_DIR}/mihomo/ui" -type f \( -name "*.js" -o -name "*.html" -o -name "*.json" \) -exec sed -i \
            -e "s|http://127.0.0.1:9090|https://${PROXY_DOMAIN}/api|g" \
            -e "s|127.0.0.1:9090|${PROXY_DOMAIN}/api|g" {} + 2>/dev/null || true

        mkdir -p "${APP_DIR}/mihomo/ruleset"
        fetch_mrs_rulesets() {
            local CDN_BASE="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo"
            local RAW_BASE="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo"
            local GHPROXY_BASE="https://mirror.ghproxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo"

            local RULES=(
                "geosite/category-ru.mrs"
                "geosite/google-gemini.mrs"
                "geosite/category-ai-chat-!cn.mrs"
                "geosite/youtube.mrs"
                "geosite/telegram.mrs"
                "geosite/meta.mrs"
                "geosite/twitter.mrs"
                "geosite/discord.mrs"
                "geosite/steam.mrs"
                "geosite/github.mrs"
                "geoip/ru.mrs"
            )

            for rel_path in "${RULES[@]}"; do
                local fname
                fname=$(basename "$rel_path")
                local target="${APP_DIR}/mihomo/ruleset/${fname}"
                if [ ! -s "$target" ]; then
                    curl -fsSL --connect-timeout 6 -m 15 "${CDN_BASE}/${rel_path}" -o "${target}.tmp" 2>/dev/null || \
                    curl -fsSL --connect-timeout 6 -m 15 "${GHPROXY_BASE}/${rel_path}" -o "${target}.tmp" 2>/dev/null || \
                    curl -fsSL --connect-timeout 6 -m 15 "${RAW_BASE}/${rel_path}" -o "${target}.tmp" 2>/dev/null || true
                    [ -s "${target}.tmp" ] && mv -f "${target}.tmp" "$target" || rm -f "${target}.tmp"
                fi
            done
            return 0
        }
        run_spin "Предзагрузка ультралегких правил Meta Rule-Set (.mrs)" fetch_mrs_rulesets
    fi

    log_ok "Структура каталогов и параметры No-COW подготовлены"
}

# =============================================================================
# 7. КОНФИГУРАЦИЯ ADGUARD HOME И MIHOMO TUN
# =============================================================================
configure_gateway_services() {
    print_step_header "07/10" "ГЕНЕРАЦИЯ КОНФИГУРАЦИЙ ADGUARD HOME И MIHOMO TUN"

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        log_info "Формирование DNS-переопределений и фильтров AdGuard Home (Schema 34)..."
        local REWRITE_ENTRIES=""
        [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${VAULT_DOMAIN}
      answer: ${LOCAL_IP}"
        [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${GITEA_DOMAIN}
      answer: ${LOCAL_IP}"
        REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${ADGUARD_DOMAIN}
      answer: ${LOCAL_IP}
    - domain: ${PROXY_DOMAIN}
      answer: ${LOCAL_IP}"
        [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${TORRENT_DOMAIN}
      answer: ${LOCAL_IP}"
        [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]] && REWRITE_ENTRIES="${REWRITE_ENTRIES}
    - domain: ${METUBE_DOMAIN}
      answer: ${LOCAL_IP}"

        cat <<EOF_AGH > "${APP_DIR}/adguard/conf/AdGuardHome.yaml"
schema_version: 34
http:
  address: 0.0.0.0:8083
  session_ttl: 720h
users:
  - name: ${ADMIN_USER}
    password: "${AGH_HASH}"
auth_attempts: 5
block_auth_min: 15
language: "ru"
theme: auto
dns:
  bind_host: 0.0.0.0
  port: 53
  block_ipv6: true
  anonymize_client_ip: true
  ratelimit: 0
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:1053
  fallback_dns:
    - tls://common.dot.dns.yandex.net
    - tls://1.1.1.1
  upstream_timeout: 2s
  bootstrap_dns:
    - 77.88.8.8
    - 1.1.1.1
  upstream_mode: load_balance
  cache_enabled: false
  cache_size: 0
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  enable_dnssec: false
querylog:
  enabled: true
  interval: 24h
  anonymize_client_ip: true
stats:
  enabled: true
  interval: 24h
filtering:
  filtering_enabled: true
  protection_enabled: true
  rewrites_enabled: true
  filters_update_interval: 24
  rewrites:${REWRITE_ENTRIES}
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdGuard Tracking Protection filter
    id: 2
whitelist_filters: []
user_rules:
  - '@@||whoer.net^\$important'
  - '@@||aniliberty.top^\$important'
  - '@@||anilibria.top^\$important'
  - '@@||*.libria.fun^\$important'
EOF_AGH

        # Экранирование секрета для YAML
        local ESCAPED_MIHOMO_SECRET
        ESCAPED_MIHOMO_SECRET=$(python3 -c "import sys, json; print(json.dumps(sys.stdin.read().rstrip('\r\n')))" <<< "${MIHOMO_SECRET}")

        log_info "Формирование конфигурации Mihomo TUN (маршрутизация РФ и обход замедлений)..."
        if [ "${SUB_URL}" = "none" ]; then
            cat <<EOF_MIHOMO > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: direct
log-level: info
ipv6: false
secret: ${ESCAPED_MIHOMO_SECRET}
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
  respect-rules: true
  fake-ip-filter:
    - "+.lan"
    - "+.duckdns.org"
    - "+.pool.ntp.org"
    - "time.windows.com"
    - "time.apple.com"
    - "time.google.com"
    - "time.cloudflare.com"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "detectportal.firefox.com"
  nameserver:
    - 77.88.8.8
    - 1.1.1.1

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  route-exclude-address:
    - "${LAN_SUBNET}"
    - "${ROUTER_GATEWAY}/32"
    - "${LOCAL_IP}/32"
    - "192.168.0.0/16"
    - "172.16.0.0/12"
    - "10.0.0.0/8"

rules:
  - IP-CIDR,${ROUTER_GATEWAY}/32,DIRECT,no-resolve
  - IP-CIDR,${LOCAL_IP}/32,DIRECT,no-resolve
  - MATCH,DIRECT
EOF_MIHOMO
        else
            cat <<EOF_MIHOMO > "${APP_DIR}/mihomo/config.yaml"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
secret: ${ESCAPED_MIHOMO_SECRET}
external-controller: 0.0.0.0:9090
external-ui: ui
external-controller-cors:
  allow-origins:
    - "*"
  allow-private-network: true

rule-providers:
  ru_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/category-ru.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ru.mrs"
    interval: 86400

  gemini_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/google-gemini.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/google-gemini.mrs"
    interval: 86400

  ai_chat:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/category-ai-chat-!cn.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ai-chat-!cn.mrs"
    interval: 86400

  youtube_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/youtube.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/youtube.mrs"
    interval: 86400

  telegram_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/telegram.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/telegram.mrs"
    interval: 86400

  meta_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/meta.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/meta.mrs"
    interval: 86400

  twitter_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/twitter.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/twitter.mrs"
    interval: 86400

  discord_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/discord.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/discord.mrs"
    interval: 86400

  steam_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/steam.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/steam.mrs"
    interval: 86400

  github_site:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/github.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/github.mrs"
    interval: 86400

  ru_ip:
    type: http
    behavior: ipcidr
    format: mrs
    path: ./ruleset/ru.mrs
    url: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/ru.mrs"
    interval: 86400

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  respect-rules: true
  fake-ip-filter:
    - "+.lan"
    - "+.duckdns.org"
    - "+.pool.ntp.org"
    - "time.windows.com"
    - "time.apple.com"
    - "time.google.com"
    - "time.cloudflare.com"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "detectportal.firefox.com"
  default-nameserver:
    - 77.88.8.8
    - 1.1.1.1
  proxy-server-nameserver:
    - 77.88.8.8
    - 1.1.1.1
  direct-nameserver:
    - 77.88.8.8
    - 77.88.8.1
  nameserver:
    - 77.88.8.8
    - https://dns.google/dns-query

tcp-concurrent: true

sniffer:
  enable: true
  parse-pure-ip: true
  sniff:
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, "8080-8880"]
    QUIC:
      ports: [443]
  force-domain:
    - "+.google.com"
    - "+.youtube.com"
    - "+.googlevideo.com"
    - "+.gvt1.com"
  skip-domain:
    - "Mijia Cloud"
    - "dlg.io.mi.com"

tun:
  enable: true
  stack: mixed
  mtu: 1400
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  route-exclude-address:
    - "${LAN_SUBNET}"
    - "${ROUTER_GATEWAY}/32"
    - "${LOCAL_IP}/32"
    - "192.168.0.0/16"
    - "172.16.0.0/12"
    - "10.0.0.0/8"

proxy-providers:
  my-sub:
    type: http
    url: "${SUB_URL}"
    path: ./providers/proxies.yaml
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - AUTO
      - DIRECT
    use:
      - my-sub
  - name: AUTO
    type: url-test
    use:
      - my-sub
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50

rules:
  # Блокировка QUIC (UDP 443) для форсирования TCP/HTTP2 через прокси (YouTube/браузеры)
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  # Прямой трафик локального шлюза и сервера
  - IP-CIDR,${ROUTER_GATEWAY}/32,DIRECT,no-resolve
  - IP-CIDR,${LOCAL_IP}/32,DIRECT,no-resolve
  # Локальные и динамические DNS
  - DOMAIN-SUFFIX,lan,DIRECT
  - DOMAIN-SUFFIX,duckdns.org,DIRECT
  - IP-CIDR,${LAN_SUBNET},DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - GEOIP,private,DIRECT,no-resolve
  - GEOIP,lan,DIRECT,no-resolve
  # Торрент-пиры и трекеры — напрямую на полной скорости провайдера
  - DST-PORT,6881,DIRECT
  - SRC-PORT,6881,DIRECT

  # Зарубежные сервисы, игры и репозитории — напрямую (минимальный пинг, без капч)
  - RULE-SET,steam_site,DIRECT
  - RULE-SET,github_site,DIRECT

  # Google Gemini, AI Studio и LLM (OpenAI, Claude, Anthropic) — строго через PROXY
  - DOMAIN-SUFFIX,gemini.google.com,PROXY
  - DOMAIN-SUFFIX,aistudio.google.com,PROXY
  - DOMAIN-SUFFIX,alkali.google.com,PROXY
  - DOMAIN-SUFFIX,alkalimakersuite-pa.googleapis.com,PROXY
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com,PROXY
  - DOMAIN-SUFFIX,proactivebackend-pa.googleapis.com,PROXY
  - DOMAIN-SUFFIX,makersuite.google.com,PROXY
  - DOMAIN-SUFFIX,bard.google.com,PROXY
  - DOMAIN-SUFFIX,ai.google.dev,PROXY
  - DOMAIN-SUFFIX,deepmind.google,PROXY
  - DOMAIN-KEYWORD,gemini.google,PROXY
  - RULE-SET,gemini_site,PROXY
  - RULE-SET,ai_chat,PROXY

  # YouTube, видео-CDN и соцсети — через PROXY
  - RULE-SET,youtube_site,PROXY
  - RULE-SET,telegram_site,PROXY
  - RULE-SET,meta_site,PROXY
  - RULE-SET,twitter_site,PROXY
  - RULE-SET,discord_site,PROXY

  # Российские зоны, ресурсы и гео-базы — 100% напрямую без прокси (Госуслуги, банки)
  - DOMAIN-SUFFIX,ru,DIRECT
  - DOMAIN-SUFFIX,su,DIRECT
  - DOMAIN-SUFFIX,xn--p1ai,DIRECT
  - RULE-SET,ru_site,DIRECT
  - RULE-SET,ru_ip,DIRECT,no-resolve

  # Весь остальной внешний трафик — через прокси
  - MATCH,PROXY
EOF_MIHOMO
        fi
    fi
    log_ok "Конфигурации шлюза AdGuard и Mihomo сгенерированы"
}

# =============================================================================
# 8. CADDYFILE И DOCKER COMPOSE СТЕК
# =============================================================================
configure_caddy_and_compose() {
    print_step_header "08/10" "ГЕНЕРАЦИЯ CADDYFILE И DOCKER-COMPOSE.YML"
    local SAMBA_PASS_COMPOSE="${SAMBA_PASS//\$/\$\$}"

    # Динамическая актуализация версии Docker API для Watchtower (Docker 28+/29+)
    local RUNTIME_API_VER
    RUNTIME_API_VER=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "${DETECTED_DOCKER_API:-1.45}")
    [ -n "${RUNTIME_API_VER}" ] && DETECTED_DOCKER_API="${RUNTIME_API_VER}"

    # Стандарты безопасности Caddy 2026: X-XSS-Protection "0" (актуальный OWASP), строгий HSTS
    cat <<EOF_CADDY > "${APP_DIR}/caddy/Caddyfile"
{
    admin off
}

(security_headers) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "0"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "interest-cohort=(), camera=(), microphone=(), geolocation=()"
    }
}
EOF_CADDY

    if [ "$SSL_MODE" = "2" ]; then
        cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
*.${BASE_DOMAIN}, ${BASE_DOMAIN} {
    tls {
        dns duckdns {env.DUCKDNS_API_TOKEN}
    }
    import security_headers
    encode zstd gzip
EOF_CADDY

        if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
    @vault host ${VAULT_DOMAIN}
    handle @vault {
        reverse_proxy vaultwarden:80
    }
EOF_CADDY
        fi

        if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
    @gitea host ${GITEA_DOMAIN}
    handle @gitea {
        reverse_proxy gitea:3000
    }
EOF_CADDY
        fi

        if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
    @torrent host ${TORRENT_DOMAIN}
    handle @torrent {
        reverse_proxy qbittorrent:8080
    }
EOF_CADDY
        fi

        if [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
    @metube host ${METUBE_DOMAIN}
    handle @metube {
        reverse_proxy metube:8081
    }
EOF_CADDY
        fi

        if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
    @adguard host ${ADGUARD_DOMAIN}
    handle @adguard {
        reverse_proxy host.docker.internal:8083
    }

    @proxy host ${PROXY_DOMAIN}
    handle @proxy {
        handle_path /api* {
            reverse_proxy host.docker.internal:9090
        }

        handle {
            root * /srv/mihomo-ui
            file_server
            try_files {path} {path}/ /index.html
        }
    }
EOF_CADDY
        fi
        echo "}" >> "${APP_DIR}/caddy/Caddyfile"

    else
        # Локальный SSL (*.lan)
        if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
${VAULT_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip
    reverse_proxy vaultwarden:80
}
EOF_CADDY
        fi

        if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
${GITEA_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip
    reverse_proxy gitea:3000
}
EOF_CADDY
        fi

        if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
${TORRENT_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip
    reverse_proxy qbittorrent:8080
}
EOF_CADDY
        fi

        if [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
${METUBE_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip
    reverse_proxy metube:8081
}
EOF_CADDY
        fi

        if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
            cat <<EOF_CADDY >> "${APP_DIR}/caddy/Caddyfile"
${ADGUARD_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip
    reverse_proxy host.docker.internal:8083
}

${PROXY_DOMAIN} {
    tls internal
    import security_headers
    encode zstd gzip

    handle_path /api* {
        reverse_proxy host.docker.internal:9090
    }

    handle {
        root * /srv/mihomo-ui
        file_server
        try_files {path} {path}/ /index.html
    }
}
EOF_CADDY
        fi
    fi

    local CADDY_IMAGE="serfriz/caddy-duckdns:latest"
    [ "$SSL_MODE" = "1" ] && CADDY_IMAGE="caddy:alpine"

    local GITEA_IMAGE="gitea/gitea:latest"

    local GITEA_TZ_MOUNT=""
    if [ -f /etc/timezone ]; then
        GITEA_TZ_MOUNT="- /etc/timezone:/etc/timezone:ro"
    fi

    cat <<EOF_COMPOSE > "${APP_DIR}/docker-compose.yml"
services:
EOF_COMPOSE

    if [[ "${ENABLE_SAMBA}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
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
      - ACCOUNT_${ADMIN_USER_SAFE}=${SAMBA_PASS_COMPOSE}
      - UID_${ADMIN_USER_SAFE}=${USER_UID}
      - SAMBA_VOLUME_CONFIG_${SHARE_NAME}=[${SHARE_NAME}]; path=/shares/${SHARE_NAME}; valid users=${ADMIN_USER_SAFE}; force user=${ADMIN_USER_SAFE}; guest ok=no; read only=no; browseable=yes; create mask=0664; directory mask=0775
    volumes:
      - ${SAVE_DIR}:/shares/${SHARE_NAME}

EOF_COMPOSE
    fi

    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${ADGUARD_WORK_DIR}:/opt/adguardhome/work
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

EOF_COMPOSE
    fi

    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  vaultwarden:
    image: vaultwarden/server:alpine
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      - DOMAIN=https://${VAULT_DOMAIN}
      - ADMIN_TOKEN=${VAULT_ADMIN_HASH_ESCAPED}
    volumes:
      - ${VAULT_DATA_DIR}:/data

EOF_COMPOSE
    fi

    if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  gitea:
    image: ${GITEA_IMAGE}
    container_name: gitea
    restart: unless-stopped
    environment:
      - USER_UID=${USER_UID}
      - USER_GID=${USER_GID}
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
      - GITEA__server__ROOT_URL=https://${GITEA_DOMAIN}/
      - GITEA__server__DOMAIN=${GITEA_DOMAIN}
      - GITEA__server__SSH_DOMAIN=${LOCAL_IP}
      - GITEA__server__SSH_PORT=2222
      - GITEA__server__SSH_LISTEN_PORT=22
      - GITEA__server__LFS_START_SERVER=true
      - GITEA__service__DISABLE_REGISTRATION=false
      - GITEA__security__INSTALL_LOCK=true
      - GITEA__security__PASSWORD_COMPLEXITY=off
    ports:
      - "2222:22"
    volumes:
      - ${GITEA_DATA_DIR}:/data
      - ${SAVE_DIR}/backups/gitea:/backup
      - /etc/localtime:/etc/localtime:ro
      ${GITEA_TZ_MOUNT}

EOF_COMPOSE
    fi

    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  qbittorrent:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      - PUID=${USER_UID}
      - PGID=${USER_GID}
      - TZ=Etc/UTC
      - WEBUI_PORT=8080
      - TORRENTING_PORT=6881
    ports:
      - "127.0.0.1:8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - ./qbittorrent/config:/config
      - ./qbittorrent/vuetorrent:/vuetorrent:ro
      - ${SAVE_DIR}:/downloads

EOF_COMPOSE
    fi

    if [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]; then
        cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  metube:
    image: alexta69/metube:latest
    container_name: metube
    restart: unless-stopped
    dns:
      - 77.88.8.8
      - 1.1.1.1
      - 8.8.8.8
    ports:
      - "127.0.0.1:8081:8081"
    environment:
      - UID=${USER_UID}
      - GID=${USER_GID}
      - ALLOW_PRIVATE_ADDRESSES=true
      - DOWNLOAD_DIR=/downloads
      - STATE_DIR=/downloads/.metube
      - TEMP_DIR=/downloads/tmp
    volumes:
      - ${SAVE_DIR}/metube:/downloads

EOF_COMPOSE
    fi

    local CADDY_UI_VOLUME=""
    [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]] && CADDY_UI_VOLUME="- ./mihomo/ui:/srv/mihomo-ui:ro"

    cat <<EOF_COMPOSE >> "${APP_DIR}/docker-compose.yml"
  caddy:
    image: ${CADDY_IMAGE}
    container_name: caddy
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DUCKDNS_API_TOKEN=${DUCKDNS_TOKEN}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
      ${CADDY_UI_VOLUME}

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - DOCKER_API_VERSION=${DETECTED_DOCKER_API:-1.45}
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_TIMEOUT=30s
EOF_COMPOSE

    local WATCHDOG_EXEC_LINE=""
    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        WATCHDOG_EXEC_LINE="ExecStartPre=/usr/local/bin/gateway-watchdog.sh
ExecStartPre=/bin/sh -c 'iptables -P FORWARD ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -t nat -C POSTROUTING -o \"${DEFAULT_IFACE}\" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o \"${DEFAULT_IFACE}\" -j MASQUERADE'"
    fi

    cat <<EOF_HOMELAB_SVC > /etc/systemd/system/homelab.service
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
${WATCHDOG_EXEC_LINE}
ExecStart=/usr/local/bin/dc up -d
ExecStop=/usr/local/bin/dc stop
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF_HOMELAB_SVC

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable homelab.service >/dev/null 2>&1 || true
    log_ok "Caddyfile, docker-compose.yml и homelab.service успешно сформированы"
}

# =============================================================================
# 9. РЕЗЕРВНОЕ КОПИРОВАНИЕ, СТАРТ И АВТОМАТИЗАЦИЯ ПОСТ-УСТАНОВКИ
# =============================================================================
setup_backups_and_start() {
    print_step_header "09/10" "РЕЗЕРВНОЕ КОПИРОВАНИЕ, СТАРТ И АВТО-ИНИЦИАЛИЗАЦИЯ"

    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        log_info "Настройка автоматического горячего бэкапа Vaultwarden (SQLite3)..."
        cat << 'EOF_BACKUP' > "${APP_DIR}/backup_vaultwarden.sh"
#!/usr/bin/env bash
set -euo pipefail

[ -f /opt/homelab/.env ] && source /opt/homelab/.env
SAVE_DIR="${SAVED_SAVE_DIR:-/opt/homelab/save}"
BACKUP_DIR="${SAVE_DIR}/backups/vaultwarden"
DB_SRC="${SAVED_VAULT_DATA_DIR:-/opt/homelab/vaultwarden}/db.sqlite3"
[ ! -f "${DB_SRC}" ] && DB_SRC="${SAVE_DIR}/services/vaultwarden/db.sqlite3"
DATA_DIR=$(dirname "${DB_SRC}")
DATE_TAG=$(date +"%Y%m%d_%H%M%S")
TEMP_DIR=$(mktemp -d)

trap 'rm -rf "${TEMP_DIR}"' EXIT

mkdir -p "${BACKUP_DIR}"

if [ -f "${DB_SRC}" ]; then
    sqlite3 "${DB_SRC}" ".backup '${TEMP_DIR}/db.sqlite3'"
    [ -d "${DATA_DIR}/attachments" ] && cp -r "${DATA_DIR}/attachments" "${TEMP_DIR}/"
    [ -d "${DATA_DIR}/sends" ] && cp -r "${DATA_DIR}/sends" "${TEMP_DIR}/"
    [ -f "${DATA_DIR}/rsa_key.pem" ] && cp -f "${DATA_DIR}/rsa_key.pem" "${TEMP_DIR}/"
    [ -f "${DATA_DIR}/config.json" ] && cp -f "${DATA_DIR}/config.json" "${TEMP_DIR}/"

    tar -czf "${BACKUP_DIR}/vaultwarden_backup_${DATE_TAG}.tar.gz" -C "${TEMP_DIR}" .
    chmod 600 "${BACKUP_DIR}/vaultwarden_backup_${DATE_TAG}.tar.gz" 2>/dev/null || true
    chmod 700 "${BACKUP_DIR}" 2>/dev/null || true
    chown -R "${SAVED_TARGET_USER:-root}:" "${BACKUP_DIR}" 2>/dev/null || true
    find "${BACKUP_DIR}" -type f -name "vaultwarden_backup_*.tar.gz" -mtime +14 -delete
fi
EOF_BACKUP
        chmod 750 "${APP_DIR}/backup_vaultwarden.sh"

        cat <<EOF_BKP_SVC > /etc/systemd/system/vaultwarden-backup.service
[Unit]
Description=Vaultwarden Database Backup
After=network.target

[Service]
Type=oneshot
ExecStart=${APP_DIR}/backup_vaultwarden.sh
EOF_BKP_SVC

        cat <<EOF_BKP_TMR > /etc/systemd/system/vaultwarden-backup.timer
[Unit]
Description=Daily Vaultwarden Database Backup Timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_BKP_TMR

        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now vaultwarden-backup.timer >/dev/null 2>&1 || true
    fi

    if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
        log_info "Настройка автоматического горячего бэкапа Gitea (dump в шару)..."
        mkdir -p "${SAVE_DIR}/backups/gitea"
        chown -R "${USER_UID}:${USER_GID}" "${SAVE_DIR}/backups/gitea" 2>/dev/null || true

        cat << 'EOF_GITEA_BKP' > "${APP_DIR}/backup_gitea.sh"
#!/usr/bin/env bash
set -euo pipefail

[ -f /opt/homelab/.env ] && source /opt/homelab/.env
SAVE_DIR="${SAVED_SAVE_DIR:-/opt/homelab/save}"
BACKUP_DIR="${SAVE_DIR}/backups/gitea"
DATE_TAG=$(date +"%Y%m%d_%H%M%S")
DUMP_NAME="gitea_backup_${DATE_TAG}.zip"

mkdir -p "${BACKUP_DIR}"

if docker inspect -f '{{.State.Status}}' gitea 2>/dev/null | grep -q "running"; then
    # Нативный dump напрямую в примонтированный том /backup (без двойного копирования на диск)
    docker exec -u "${USER_UID:-1000}:${USER_GID:-1000}" gitea gitea dump -f "/backup/${DUMP_NAME}" -c /data/gitea/conf/app.ini >/dev/null 2>&1 || \
    docker exec -u git gitea gitea dump -f "/backup/${DUMP_NAME}" -c /data/gitea/conf/app.ini >/dev/null 2>&1 || true

    chown -R "${SAVED_TARGET_USER:-root}:" "${BACKUP_DIR}" 2>/dev/null || true
    chmod 640 "${BACKUP_DIR}"/gitea_backup_*.zip 2>/dev/null || true
    chmod 750 "${BACKUP_DIR}" 2>/dev/null || true
    find "${BACKUP_DIR}" -type f -name "gitea_backup_*.zip" -mtime +14 -delete 2>/dev/null || true
fi
EOF_GITEA_BKP
        chmod 750 "${APP_DIR}/backup_gitea.sh"

        cat <<EOF_GITEA_BKP_SVC > /etc/systemd/system/gitea-backup.service
[Unit]
Description=Gitea Repositories & Database Backup
After=network.target docker.service

[Service]
Type=oneshot
ExecStart=${APP_DIR}/backup_gitea.sh
EOF_GITEA_BKP_SVC

        cat <<EOF_GITEA_BKP_TMR > /etc/systemd/system/gitea-backup.timer
[Unit]
Description=Daily Gitea Database and Repositories Backup Timer

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_GITEA_BKP_TMR

        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now gitea-backup.timer >/dev/null 2>&1 || true
    fi

    cd "${APP_DIR}"

    run_spin "Загрузка Docker-образов стека" bash -c '
        if dc config --images >/dev/null 2>&1; then
            for img in $(dc config --images 2>/dev/null); do
                docker pull "${img}" >/dev/null 2>&1 || true
            done
        else
            dc pull -q 2>/dev/null || dc pull
        fi
    '
    run_spin "Запуск контейнеров стека (Docker Compose)" bash -c "dc up -d --quiet-pull 2>/dev/null || dc up -d"

    # АВТОМАТИЗАЦИЯ: Пре-создание учетной записи администратора в Gitea
    if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
        log_info "Автоматическая инициализация администратора Gitea (${ADMIN_USER})..."
        local GITEA_READY=0
        for i in {1..40}; do
            if docker inspect -f '{{.State.Status}}' gitea 2>/dev/null | grep -q "running"; then
                if docker exec gitea wget -q -O - http://localhost:3000/api/v1/version >/dev/null 2>&1 || \
                   docker exec gitea curl -sf http://localhost:3000/api/v1/version >/dev/null 2>&1 || \
                   [ $i -ge 12 ]; then
                    
                    if docker exec -i -e GITEA_ADMIN_PWD="${MASTER_PASS}" -u "${USER_UID}:${USER_GID}" gitea sh -c 'gitea admin user create --config /data/gitea/conf/app.ini --admin --username "$1" --password "$GITEA_ADMIN_PWD" --email "$1@example.lan" --must-change-password=false' _ "${ADMIN_USER}" >/dev/null 2>&1 || \
                       docker exec -i -e GITEA_ADMIN_PWD="${MASTER_PASS}" -u git gitea sh -c 'gitea admin user create --config /data/gitea/conf/app.ini --admin --username "$1" --password "$GITEA_ADMIN_PWD" --email "$1@example.lan" --must-change-password=false' _ "${ADMIN_USER}" >/dev/null 2>&1; then
                        log_ok "Администратор Gitea (${ADMIN_USER}) успешно создан с мастер-паролем"
                        GITEA_READY=1
                    elif docker exec -i -e GITEA_ADMIN_PWD="${MASTER_PASS}" -u git gitea sh -c 'gitea admin user change-password --config /data/gitea/conf/app.ini --username "$1" --password "$GITEA_ADMIN_PWD"' _ "${ADMIN_USER}" >/dev/null 2>&1; then
                        log_ok "Пароль администратора Gitea (${ADMIN_USER}) успешно обновлен на мастер-пароль"
                        GITEA_READY=1
                    fi

                    if [ "${GITEA_READY}" -eq 1 ]; then
                        python3 -c "
import sqlite3, glob, sys
db_paths = glob.glob('${GITEA_DATA_DIR}/**/gitea.db', recursive=True) + glob.glob('${SAVE_DIR}/**/gitea.db', recursive=True)
for p in set(db_paths):
    try:
        conn = sqlite3.connect(p)
        conn.execute('UPDATE user SET must_change_password = 0;')
        conn.commit()
        conn.close()
    except Exception:
        pass
" 2>/dev/null || true
                        break
                    fi
                fi
            fi
            sleep 2
        done
        [ $GITEA_READY -eq 0 ] && log_warn "Не удалось инициализировать админа Gitea (контейнер запускается в фоновом режиме)"
    fi

    if [ "$SSL_MODE" = "1" ]; then
        log_info "Экспорт локального корневого сертификата CA Caddy..."
        local CADDY_ROOT_CERT="${APP_DIR}/caddy/data/caddy/pki/authorities/local/root.crt"
        for _ in {1..30}; do
            if [ -f "${CADDY_ROOT_CERT}" ]; then
                mkdir -p "${SAVE_DIR}/certificates"
                cp -f "${CADDY_ROOT_CERT}" "${SAVE_DIR}/certificates/caddy-root.crt"
                chown -R "${USER_UID}:${USER_GID}" "${SAVE_DIR}/certificates" 2>/dev/null || true
                chmod 644 "${SAVE_DIR}/certificates/caddy-root.crt" 2>/dev/null || true
                log_ok "Сертификат CA сохранен: ${SAVE_DIR}/certificates/caddy-root.crt"
                break
            fi
            sleep 1
        done
    fi

    log_ok "Сервисы комплекса успешно запущены и готовы к работе"
    log_ok "Службы автозапуска и горячего резервного копирования активированы"
}

# =============================================================================
# 10. АВТОМАТИЧЕСКАЯ ДИАГНОСТИКА И САМОПРОВЕРКА СИСТЕМЫ
# =============================================================================
diagnose_and_verify_system() {
    print_step_header "10/10" "АВТОМАТИЧЕСКАЯ ДИАГНОСТИКА СЕРВИСОВ И СИСТЕМЫ"

    local DIAG_LOG="/opt/homelab/diagnostic_report.log"
    local USER_HOME
    USER_HOME=$(eval echo ~"${TARGET_USER}" 2>/dev/null || echo "/home/${TARGET_USER}")
    local USER_DIAG_LOG="${USER_HOME}/diagnostic_report.log"
    local HAS_ISSUES=0

    mkdir -p /opt/homelab
    cat <<EOF_DIAG > "${DIAG_LOG}"
=============================================================================
                  ОТЧЕТ ДИАГНОСТИКИ СИСТЕМЫ HOMELAB (KAXA)
                  Дата и время: $(date '+%Y-%m-%d %H:%M:%S %Z')
=============================================================================
Дистрибутив:       ${PRETTY_NAME:-Linux} ($(uname -r))
IP сервера:        ${LOCAL_IP}
Шлюз:              ${ROUTER_GATEWAY}
Интерфейс:         ${DEFAULT_IFACE}
Подсеть:           ${LAN_SUBNET}
Каталог данных:    ${SAVE_DIR}
-----------------------------------------------------------------------------
EOF_DIAG

    echo -e "  ${CLR_CYAN}Проверка статуса запущенных сервисов и сетевых портов...${CLR_RESET}"
    echo ""

    if docker info >/dev/null 2>&1; then
        echo -e "    ${TAG_OK} Docker Daemon:           ${CLR_GREEN}[РАБОТАЕТ]${CLR_RESET}"
        echo "Docker Daemon: OK" >> "${DIAG_LOG}"
    else
        echo -e "    ${TAG_ERR} Docker Daemon:           ${CLR_RED}[НЕ ОТВЕЧАЕТ]${CLR_RESET}"
        echo "Docker Daemon: FAILED" >> "${DIAG_LOG}"
        HAS_ISSUES=1
    fi

    declare -A EXPECTED_SERVICES
    [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]] && EXPECTED_SERVICES["adguardhome"]="AdGuard Home (DNS 53)"
    [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]] && EXPECTED_SERVICES["mihomo"]="Mihomo TUN (Ядро маршрутизации)"
    [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]   && EXPECTED_SERVICES["vaultwarden"]="Vaultwarden (Пароли)"
    [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]   && EXPECTED_SERVICES["gitea"]="Gitea (Git-сервер)"
    [[ "${ENABLE_SAMBA}" =~ ^[Yy]$ ]]   && EXPECTED_SERVICES["samba"]="Samba (Сетевой доступ)"
    [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]    && EXPECTED_SERVICES["qbittorrent"]="qBittorrent (VueTorrent)"
    [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]  && EXPECTED_SERVICES["metube"]="MeTube (yt-dlp)"
    EXPECTED_SERVICES["caddy"]="Caddy Reverse Proxy"
    EXPECTED_SERVICES["watchtower"]="Watchtower (Автообновления)"

    echo "" >> "${DIAG_LOG}"
    echo "--- СТАТУС КОНТЕЙНЕРОВ DOCKER ---" >> "${DIAG_LOG}"

    for c_name in "${!EXPECTED_SERVICES[@]}"; do
        local c_desc="${EXPECTED_SERVICES[$c_name]}"
        local c_status="not_found"

        for _ in {1..5}; do
            c_status=$(docker inspect -f '{{.State.Status}}' "${c_name}" 2>/dev/null || echo "not_found")
            [ "${c_status}" = "running" ] && break
            sleep 1
        done

        if [ "${c_status}" = "running" ]; then
            printf "    ${TAG_OK} %-32s ${CLR_GREEN}[ОНЛАЙН]${CLR_RESET}\n" "${c_desc}"
            echo "[OK] Container ${c_name} (${c_desc}): RUNNING" >> "${DIAG_LOG}"
        else
            printf "    ${TAG_ERR} %-32s ${CLR_RED}[ОШИБКА: %s]${CLR_RESET}\n" "${c_desc}" "${c_status}"
            echo "[FAIL] Container ${c_name} (${c_desc}): STATUS=${c_status}" >> "${DIAG_LOG}"
            HAS_ISSUES=1

            echo "--- Логи контейнера ${c_name} (последние 40 строк): ---" >> "${DIAG_LOG}"
            docker logs --tail 40 "${c_name}" >> "${DIAG_LOG}" 2>&1 || true
            echo "--------------------------------------------------------" >> "${DIAG_LOG}"
        fi
    done

    echo ""
    echo -e "  ${CLR_CYAN}Проверка сетевых функций шлюза и прав доступа...${CLR_RESET}"

    local IP_FWD
    IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [ "${IP_FWD}" = "1" ]; then
        echo -e "    ${TAG_OK} IPv4 Forwarding:          ${CLR_GREEN}[АКТИВЕН]${CLR_RESET}"
        echo "IPv4 Forwarding: OK (1)" >> "${DIAG_LOG}"
    else
        echo -e "    ${TAG_ERR} IPv4 Forwarding:          ${CLR_RED}[ОТКЛЮЧЕН]${CLR_RESET}"
        echo "IPv4 Forwarding: DISABLED (0)" >> "${DIAG_LOG}"
        HAS_ISSUES=1
    fi

    # Проверка DNS-резолвинга на локальном порту 53 (AdGuard Home)
    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        local DNS_TEST=0
        if python3 -c "import socket, sys; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2); s.sendto(b'\xaa\xaa\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01', ('127.0.0.1', 53)); data, _ = s.recvfrom(512); sys.exit(0 if len(data) > 12 else 1)" 2>/dev/null; then
            DNS_TEST=1
        fi
        if [ "${DNS_TEST}" -eq 1 ]; then
            echo -e "    ${TAG_OK} DNS Резолвер (порт 53):   ${CLR_GREEN}[ОТВЕЧАЕТ]${CLR_RESET}"
            echo "DNS Port 53 Check: OK" >> "${DIAG_LOG}"
        else
            echo -e "    ${TAG_WARN} DNS Резолвер (порт 53):   ${CLR_YELLOW}[ОЖИДАНИЕ ИНИЦИАЛИЗАЦИИ]${CLR_RESET}"
            echo "DNS Port 53 Check: PENDING" >> "${DIAG_LOG}"
        fi
    fi

    # Проверка каталога хранилища
    local STORAGE_OK=0
    if [ -d "${SAVE_DIR}" ]; then
        if su -s /bin/sh "${TARGET_USER}" -c "test -w '${SAVE_DIR}'" 2>/dev/null || [ -w "${SAVE_DIR}" ]; then
            STORAGE_OK=1
        fi
    fi
    if [ "${STORAGE_OK}" -eq 1 ]; then
        echo -e "    ${TAG_OK} Каталог хранилища:        ${CLR_GREEN}[ДОСТУПЕН ДЛЯ ЗАПИСИ]${CLR_RESET}"
        echo "Storage directory ${SAVE_DIR}: OK" >> "${DIAG_LOG}"
    else
        echo -e "    ${TAG_ERR} Каталог хранилища:        ${CLR_RED}[НЕДОСТУПЕН]${CLR_RESET}"
        echo "Storage directory ${SAVE_DIR}: PERMISSION/MOUNT ERROR" >> "${DIAG_LOG}"
        HAS_ISSUES=1
    fi

    cat <<EOF_SYS_INFO >> "${DIAG_LOG}"

--- СИСТЕМНЫЕ РЕСУРСЫ ---
Дисковое пространство:
$(df -h "${SAVE_DIR}" / 2>/dev/null)

Оперативная память:
$(free -h 2>/dev/null)

Сетевые маршруты:
$(ip route show 2>/dev/null)

Сетевые адреса:
$(ip -o -4 addr show 2>/dev/null)
EOF_SYS_INFO

    cp -f "${DIAG_LOG}" "${USER_DIAG_LOG}" 2>/dev/null || true
    chmod 640 "${DIAG_LOG}" "${USER_DIAG_LOG}" 2>/dev/null || true
    chown "${USER_UID}:${USER_GID}" "${USER_DIAG_LOG}" 2>/dev/null || true

    echo ""
    if [ "${HAS_ISSUES}" -eq 0 ]; then
        echo -e "  ${CLR_GREEN}${CLR_BOLD}✔  ДИАГНОСТИКА: Все сервисы функционируют нормально, сбоев не обнаружено!${CLR_RESET}"
        echo ""
    else
        echo -e "  ${CLR_RED}${CLR_BOLD}▲  ДИАГНОСТИКА: Обнаружены отклонения в работе сервисов!${CLR_RESET}"
        echo -e "  ${CLR_YELLOW}Подробный журнал диагностики и логов сбоев сохранен в:${CLR_RESET}"
        echo ""
        echo -e "      ${CLR_WHITE}${CLR_BOLD}cat ${DIAG_LOG}${CLR_RESET}"
        echo -e "      ${CLR_DIM}или в домашнем каталоге:${CLR_RESET} ${CLR_WHITE}cat ${USER_DIAG_LOG}${CLR_RESET}"
        echo ""
    fi
}

# =============================================================================
# 11. ФИНАЛЬНЫЙ ДАШБОРД И СВОДКА ДАННЫХ
# =============================================================================
show_summary_dashboard() {
    echo ""
    echo -e "${CLR_GREEN}╭── ${CLR_WHITE}${CLR_BOLD}HOMELAB APPLIANCE & TRANSPARENT GATEWAY УСПЕШНО РАЗВЕРНУТ${CLR_RESET}"
    echo -e "${CLR_GREEN}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""

    echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── СЕТЕВОЙ ШЛЮЗ И МАРШРУТИЗАЦИЯ ────────────────────────────${CLR_RESET}"
    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• AdGuard Home (DNS & AdBlock):${CLR_RESET} ${CLR_CYAN}https://${ADGUARD_DOMAIN}${CLR_RESET}"
        echo -e "  ${CLR_WHITE}• Mihomo Smart Routing UI:${CLR_RESET}      ${CLR_CYAN}https://${PROXY_DOMAIN}${CLR_RESET}"
        echo -e "  ${CLR_WHITE}• Секрет панели управления:${CLR_RESET}     ${CLR_YELLOW}${MIHOMO_SECRET}${CLR_RESET}"
    else
        echo -e "  ${CLR_MUTED}• Прозрачный шлюз отключен в конфигурации${CLR_RESET}"
    fi
    echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""

    echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── ВЕБ-СЕРВИСЫ И ОБЛАЧНЫЕ ПРИЛОЖЕНИЯ (HTTPS) ────────────────${CLR_RESET}"
    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• Vaultwarden (Пароли):${CLR_RESET}         ${CLR_CYAN}https://${VAULT_DOMAIN}${CLR_RESET}"
        echo -e "  ${CLR_WHITE}• Панель администратора:${CLR_RESET}        ${CLR_CYAN}https://${VAULT_DOMAIN}/admin${CLR_RESET}"
    fi
    if [[ "${ENABLE_GITEA}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• Gitea (Git-сервер):${CLR_RESET}        ${CLR_CYAN}https://${GITEA_DOMAIN}${CLR_RESET} ${CLR_MUTED}(SSH порт: 2222)${CLR_RESET}"
    fi
    if [[ "${ENABLE_QBIT}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• qBittorrent (VueTorrent):${CLR_RESET}     ${CLR_CYAN}https://${TORRENT_DOMAIN}${CLR_RESET}"
    fi
    if [[ "${ENABLE_METUBE}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• MeTube (Медиа-загрузчик):${CLR_RESET}     ${CLR_CYAN}https://${METUBE_DOMAIN}${CLR_RESET}"
    fi
    echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""

    echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── ЕДИНЫЕ УЧЕТНЫЕ ДАННЫЕ ────────────────────────────────────${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Имя администратора:${CLR_RESET}           ${CLR_GREEN}${ADMIN_USER}${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Единый мастер-пароль:${CLR_RESET}         ${CLR_GREEN}${MASTER_PASS}${CLR_RESET}"
    if [[ "${ENABLE_VAULT}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• Токен Vaultwarden /admin:${CLR_RESET}     ${CLR_YELLOW}${VAULT_ADMIN_TOKEN}${CLR_RESET}"
    fi
    echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""

    if [ "$SSL_MODE" = "1" ]; then
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── ДОВЕРИЕ СЕРТИФИКАТАМ (ROOT CA CERTIFICATE) ───────────────${CLR_RESET}"
        echo -e "  ${CLR_WHITE}• Сертификат CA на сервере:${CLR_RESET}     ${CLR_YELLOW}${SAVE_DIR}/certificates/caddy-root.crt${CLR_RESET}"
        printf "  ${CLR_WHITE}• Сетевой путь (SMB):${CLR_RESET}           ${CLR_YELLOW}\\\\\\\\%s\\\\%s\\\\certificates\\\\caddy-root.crt${CLR_RESET}\n" "${LOCAL_IP}" "${SHARE_NAME}"
        echo -e "  ${CLR_MUTED}(Установите в 'Доверенные корневые центры' на ПК/смартфоне для зелёного замка)${CLR_RESET}"
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
        echo ""
    fi

    if [[ "${ENABLE_SAMBA}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── СЕТЕВОЕ ХРАНИЛИЩЕ SAMBA (WINDOWS / MAC / LINUX) ───────────${CLR_RESET}"
        printf "  ${CLR_WHITE}• Сетевой адрес шары:${CLR_RESET}           ${CLR_GREEN}\\\\\\\\%s\\\\%s${CLR_RESET}\n" "${LOCAL_IP}" "${SHARE_NAME}"
        echo -e "  ${CLR_WHITE}• Логин / Пароль:${CLR_RESET}               ${ADMIN_USER} / ${SAMBA_PASS}"
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
        echo ""
    fi

    if [ "$STORAGE_MODE" != "1" ]; then
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── ДИСКОВОЕ ХРАНИЛИЩЕ И РАЗДЕЛЫ ─────────────────────────────${CLR_RESET}"
        echo -e "  ${CLR_WHITE}• Точка монтирования:${CLR_RESET}           ${MOUNT_ROOT}"
        echo -e "  ${CLR_WHITE}• Каталог данных:${CLR_RESET}               ${SAVE_DIR}"
        if [ "$STORAGE_MODE" = "4" ] || [ "$STORAGE_MODE" = "5" ]; then
            echo -e "  ${CLR_WHITE}• Ручная разблокировка LUKS:${CLR_RESET}    sudo homelab-unlock"
        fi
        echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
        echo ""
    fi

    echo -e "  ${CLR_GREEN}${CLR_BOLD}╭── НАСТРОЙКА ДОМАШНЕГО РОУТЕРА (1 ДЕЙСТВИЕ ДЛЯ ВСЕХ УСТРОЙСТВ) ──────────┐${CLR_RESET}"
    echo -e "  ${CLR_WHITE}В параметрах DHCP вашего роутера укажите:${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Первичный DNS-сервер:${CLR_RESET}         ${CLR_GREEN}${LOCAL_IP}${CLR_RESET}"
    if [[ "${ENABLE_GATEWAY}" =~ ^[Yy]$ ]]; then
        echo -e "  ${CLR_WHITE}• Основной шлюз (Gateway):${CLR_RESET}      ${CLR_GREEN}${LOCAL_IP}${CLR_RESET}"
    fi
    echo -e "  ${CLR_MUTED}После этого все смартфоны, ПК и Smart TV в сети сразу получат фильтрацию${CLR_RESET}"
    echo -e "  ${CLR_MUTED}рекламы, доступ к локальным *.lan доменам и интеллектуальную маршрутизацию!${CLR_RESET}"
    echo -e "  ${CLR_GREEN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""

    echo -e "  ${CLR_CYAN}${CLR_BOLD}╭── БЫСТРЫЕ КОМАНДЫ УПРАВЛЕНИЯ ───────────────────────────────${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Статус контейнеров:${CLR_RESET}           ${CLR_CYAN}dc ps${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Просмотр логов в реалтайме:${CLR_RESET}   ${CLR_CYAN}dc logs -f [сервис]${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Перезапуск всего комплекса:${CLR_RESET}   ${CLR_CYAN}sudo systemctl restart homelab.service${CLR_RESET}"
    echo -e "  ${CLR_WHITE}• Отчет диагностики:${CLR_RESET}            ${CLR_CYAN}cat /opt/homelab/diagnostic_report.log${CLR_RESET}"
    echo -e "  ${CLR_CYAN}${CLR_BOLD}╰─────────────────────────────────────────────────────────────${CLR_RESET}"
    echo ""
}

main() {
    show_banner
    check_privileges
    detect_os
    load_previous_config
    sync_time
    install_pkgs
    setup_zram
    detect_network
    prompt_configuration
    setup_credentials
    setup_gateway_networking
    setup_directories
    configure_gateway_services
    configure_caddy_and_compose
    setup_backups_and_start
    diagnose_and_verify_system
    show_summary_dashboard
}

main "$@"
