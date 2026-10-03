# ★ IBLIAT :: Arch Homelab & Smart Gateway ★

[![Arch Linux](https://img.shields.io/badge/Arch_Linux-Ready-1793D1?logo=arch-linux&logoColor=white)](https://archlinux.org/)
[![Debian](https://img.shields.io/badge/Debian_12%2F13-Ready-A81D33?logo=debian&logoColor=white)](https://debian.org/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu_22.04%2F24.04-Ready-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Docker CE](https://img.shields.io/badge/Docker_CE-Automated-2496ED?logo=docker&logoColor=white)](https://docker.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**IBLIAT** — это полностью автоматизированный комплекс для развёртывания домашнего сервера «всё-в-одном» и умного сетевого шлюза с прозрачным проксированием, DNS-фильтрацией рекламы, шифрованием дисков, автономными медиа-сервисами и доверенным HTTPS без необходимости открывать порты наружу.

В один клик превращает любой ПК, мини-ПК или сервер на **Arch Linux, Debian или Ubuntu** в защищённую домашнюю станцию без сложной ручной настройки сетей, сертификатов и конфигов.

---

## 🚀 Быстрый старт (One-line Install)

Выполните команду в терминале вашего сервера (требуются права root/sudo). Команда автоматически определит наличие `curl` или `wget`:

```bash
(command -v curl >/dev/null 2>&1 && curl -fsSL "https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh" -o install.sh || wget -qO install.sh "https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh") && chmod +x install.sh && sudo ./install.sh
```

### Раздельные команды (если хотите скачать вручную)

#### Через curl:
```bash
curl -fsSL "[https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh](https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh)" -o install.sh
chmod +x install.sh
sudo ./install.sh
```

#### Через wget:
```bash
wget -qO install.sh "[https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh](https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh)"
chmod +x install.sh
sudo ./install.sh
```

> **Совет:** Для сохранения конфигурации и удобного повторного запуска все параметры сохраняются в `/opt/homelab/.env`.

---

## 🌟 Возможности и стек сервисов

| Сервис | Назначение | Интерфейс | Особенности реализации |
| :--- | :--- | :--- | :--- |
| **Mihomo TUN** | Ядро маршрутизации и обход блокировок | `https://proxy.domain` | TUN-режим, Fake-IP (`198.18.0.0/16`), разделение гео-трафика (РФ напрямую, остальное через прокси), автообновление GeoSite/GeoIP |
| **MetaCubeXD** | Веб-панель управления шлюзом | Встроена в прокси-домен | Полный контроль узлов, задержек, правил маршрутизации |
| **AdGuard Home** | DNS-фильтрация и родительский контроль | `https://adguard.domain` | Порт 53, апстрим в Mihomo (`127.0.0.1:1053`), встроенный DoH, фильтрация рекламы и трекеров |
| **Caddy** | Реверс-прокси и автоматический SSL | Порты 80 / 443 | Поддержка локального CA (`*.lan`) и публичного Wildcard Let's Encrypt через **DuckDNS DNS-01 Challenge** (без открытых портов на роутере!) |
| **qBittorrent** | Торрент-клиент | `https://torrent.domain` | Версия 5.x с интерфейсом **VueTorrent**, автоматическая генерация безопасного PBKDF2-HMAC-SHA512 пароля |
| **VueTorrent** | Современный WebUI для qBittorrent | Встроен в торрент | Автономная локальная установка без внешних задержек, адаптивный тёмный мобильный UI |
| **MeTube** | Загрузчик YouTube, VK, Rutube, TikTok (yt-dlp) | `https://metube.domain` | Защита от SSRF совместима с Fake-IP (`ALLOW_PRIVATE_ADDRESSES=true`), автоматический обход замедления через TUN |
| **Vaultwarden** | Менеджер паролей (Bitwarden API) | `https://vault.domain` | SQLite3 с ежедневным горячим бэкапом по таймеру systemd, совместим с официальными клиентами |
| **Gitea** | Локальный Git-хостинг | `https://git.domain` | Автоматическая инициализация учетной записи администратора без веб-визарда, SSH на порту 2222 |
| **Samba (SMB)** | Сетевой файлообмен (NAS) | `\\IP\save` | Интеграция с WSDD2 (мгновенное обнаружение в сетевом окружении Windows), права доступа под системного пользователя |
| **Watchtower** | Автообновление контейнеров | Фоновый | Регулярная проверка обновлений образов с очисткой устаревших слоёв |

---

## 🛠 Архитектура и ключевые инженерные решения

### 1. Сетевой шлюз и защита от петель (Routing & Watchdog)
* **Ядро маршрутизации:** Трафик обрабатывается через Linux TUN-интерфейс ядра Mihomo. Входящие DNS-запросы принимает AdGuard Home на `:53`, передает их в Mihomo на `:1053` для резолва с разделением гео-зон (РФ напрямую, остальное через прокси).
* **Watchdog маршрутизации:** Автоматический таймер `network-gateway-watchdog.timer` каждые несколько секунд проверяет таблицу маршрутизации ядра и состояние шлюза по умолчанию. При падении или зависании прокси-интерфейса шлюз моментально восстанавливает маршрут через физический интерфейс, защищая сервер от потери SSH-доступа.
* **Сетевой стек:** Включен `ip_forward = 1`, отключены ICMP-редиректы и активирован loose reverse path filtering (`rp_filter = 2`) для многопутевой маршрутизации.

### 2. Дисковая подсистема и безопасность данных
* **Поддержка любых дисков:** Системный диск, выделенный раздел или автоматическая разметка в современную файловую систему **Btrfs**.
* **Шифрование LUKS2:** Опциональное посекторное шифрование диска данных с парольной защитой и утилитой ручной разблокировки `homelab-unlock`.
* **Btrfs No-COW:** Автоматическое применение атрибута `+C` (No Copy-on-Write) к каталогам баз данных SQLite (Gitea, Vaultwarden) и папкам активных загрузок торрентов, что исключает фрагментацию диска и снижает износ накопителя.
* **Горячий бэкап Vaultwarden:** Системный таймер `vaultwarden-backup.timer` каждую ночь создает резервную копию базы данных без остановки контейнера и ротирует архив (хранение 14 дней).

### 3. Автоматизация SSL без открытых портов (DNS-01 ACME)
* В режиме DuckDNS скрипт запрашивает бесплатный Wildcard-сертификат (`*.yourdomain.duckdns.org`) через протокол **ACME DNS-01 Challenge**.
* Caddy подтверждает владение доменом напрямую через API DuckDNS с помощью TXT-записей.
* **На домашнем роутере не требуется открывать порты 80 и 443 наружу в интернет.** Сервер остается полностью защищенным внутри локальной сети, получая при этом настоящий доверенный «зеленый замок» SSL на смартфонах и ПК.

---

## 📱 Как подключить домашнюю сеть к шлюзу

Чтобы на всех смартфонах, ноутбуках, Smart TV и приставках автоматически заработал блокировщик рекламы и обход замедления:

1. Откройте панель управления вашего домашнего роутера (обычно `192.168.1.1` или `192.168.0.1`).
2. В настройках **DHCP** укажите:
   * **DNS-сервер:** `<IP_ВАШЕГО_СЕРВЕРА>` (например, `192.168.1.47`)
   * *(Опционально для шлюза всего трафика)* **Основной шлюз (Gateway):** `<IP_ВАШЕГО_СЕРВЕРА>`
3. Переподключите Wi-Fi на устройствах. Никаких дополнительных приложений на клиентские устройства ставить не нужно!

---

## 📂 Управление сервисами

Все службы управляются через единый юнит systemd и Docker Compose:

```bash
# Проверить статус всех контейнеров
cd /opt/homelab && docker compose ps

# Перезапустить определенный сервис
cd /opt/homelab && docker compose restart <имя_сервиса>

# Просмотреть логи сервиса в реальном времени
cd /opt/homelab && docker compose logs -f <имя_сервиса>

# Проверить статус системной службы автозапуска
systemctl status homelab.service
```

Каталог конфигураций и данных:
* `/opt/homelab/` — конфигурационные файлы сервисов (`docker-compose.yml`, `.env`, `caddy/`, `mihomo/`, `adguard/`, `qbittorrent/`).
* `/home/<user>/save/` (или выбранная точка монтирования) — каталог загрузок, бэкапов и сетевого хранилища Samba.

---

## 📄 Лицензия

Проект распространяется под свободной лицензией [MIT](LICENSE). Разработано для энтузиастов self-hosted систем и домашней автоматизации.
