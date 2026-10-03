# Homelab & Transparent Gateway (Debian / Arch Linux)

Комплексный автоматизированный установщик домашнего микросерверного шлюза и локального облака на базе **Docker Compose**[span_0](start_span)[span_0](end_span)[span_1](start_span)[span_1](end_span). 

Скрипт превращает обычный компьютер или одноплатник с **Debian 13 (Trixie)**, **Ubuntu** или **Arch Linux** в отказоустойчивый сетевой роутер-шлюз и сервер приложений, автоматизируя развертывание, сетевую изоляцию, шифрование накопителей и управление SSL-сертификатами[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span).

---

## 💡 Какие проблемы решает скрипт

1. **Рутина настройки Transparent Gateway:**
   Вместо ручного прописывания правил `iptables`, включения форвардинга ячеек ядра (`sysctl`), настройки TUN-интерфейсов и параметров Fake-IP скрипт конфигурирует всю связку автоматически с учетом вашей физической подсети[span_4](start_span)[span_4](end_span)[span_5](start_span)[span_5](end_span).
2. **Защита от сетевых петель и падения шлюза:**
   При развертывании прозрачных прокси на одном физическом интерфейсе часто возникает зацикливание маршрутов по умолчанию[span_6](start_span)[span_6](end_span)[span_7](start_span)[span_7](end_span). Встроенный сторожевой таймер **Watchdog** отслеживает доступность шлюза каждые 15 секунд и восстанавливает физический маршрут роутера при любых аномалиях[span_8](start_span)[span_8](end_span)[span_9](start_span)[span_9](end_span).
3. **Бесконфликтный локальный DNS:**
   Связка AdGuard Home и Mihomo часто страдает от рассинхронизации Fake-IP из-за кеширования[span_10](start_span)[span_10](end_span). Скрипт отключает кеш в AdGuard, направляет его напрямую в Mihomo (`127.0.0.1:1053`) и изолирует локальные доменные зоны (`+.lan`, `+.duckdns.org`), предотвращая подмену IP для внутренних служб[span_11](start_span)[span_11](end_span)[span_12](start_span)[span_12](end_span).
4. **Безопасность и шифрование дисков «из коробки»:**
   Скрипт избавляет от необходимости вручную настраивать криптографические разделы[span_13](start_span)[span_13](end_span). Он умеет самостоятельно форматировать внешние накопители в связку **LUKS2 (Argon2id) + Btrfs**, генерировать ключ авторазблокировки при старте системы и монтировать разделы с прозрачным сжатием `zstd`[span_14](start_span)[span_14](end_span).
5. **SSL и бесшовный доступ:**
   Все веб-интерфейсы сразу оборачиваются в HTTPS через **Caddy**[span_15](start_span)[span_15](end_span). Поддерживается как полностью изолированный внутренний режим с выпуском локального CA-сертификата (`*.lan`), так и интеграция с **DuckDNS** для получения официальных Wildcard-сертификатов Let's Encrypt через DNS-01 Challenge[span_16](start_span)[span_16](end_span).

---

## ⚡ Быстрый старт одной командой

Команда автоматически определяет наличие `curl` или `wget`, при необходимости доустанавливает недостающий инструмент через системный менеджер пакетов (`apt` или `pacman`) и запускает установщик в интерактивном терминале[span_17](start_span)[span_17](end_span):

```bash
sudo bash -c 'URL="https://raw.githubusercontent.com/unknownpeace/arch-homelab-gateway/refs/heads/main/install.sh"; if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y curl; elif command -v pacman &>/dev/null; then pacman -Sy --noconfirm curl; fi; fi; if command -v curl &>/dev/null; then bash <(curl -fsSL "$URL"); elif command -v wget &>/dev/null; then bash <(wget -qO- "$URL"); fi'
```

---

## 🧩 Состав сервисов и их роли

| Сервис | Образ / База | Назначение и особенности | Адрес по умолчанию |
| :--- | :--- | :--- | :--- |
| **Mihomo**[span_18](start_span)[span_18](end_span)[span_19](start_span)[span_19](end_span) | `metacubex/mihomo`[span_20](start_span)[span_20](end_span) | Прозрачный сетевой шлюз, TUN-режим (`stack: mixed`), автообновляемые базы GeoIP/GeoSite, встроенный веб-интерфейс MetaCubeXD[span_21](start_span)[span_21](end_span)[span_22](start_span)[span_22](end_span). | `https://proxy.lan`[span_23](start_span)[span_23](end_span) (API: порт `9090`[span_24](start_span)[span_24](end_span)) |
| **AdGuard Home**[span_25](start_span)[span_25](end_span)[span_26](start_span)[span_26](end_span) | `adguard/adguardhome`[span_27](start_span)[span_27](end_span) | Блокировка рекламы, защита от трекеров, локальные DNS-переопределения, предустановленные правила исключений[span_28](start_span)[span_28](end_span)[span_29](start_span)[span_29](end_span). | `https://adguard.lan`[span_30](start_span)[span_30](end_span) |
| **Caddy 2**[span_31](start_span)[span_31](end_span) | `serfriz/caddy-duckdns`[span_32](start_span)[span_32](end_span) | Единая входная точка (Reverse Proxy) с автогенерацией SSL и отдачей статики UI[span_33](start_span)[span_33](end_span). | Порты `80`, `443`[span_34](start_span)[span_34](end_span) |
| **Vaultwarden**[span_35](start_span)[span_35](end_span)[span_36](start_span)[span_36](end_span) | `vaultwarden/server`[span_37](start_span)[span_37](end_span) | Легковесный менеджер паролей (совместим с Bitwarden) с автоматическим хешированием токена через Argon2id[span_38](start_span)[span_38](end_span). | `https://vault.lan`[span_39](start_span)[span_39](end_span) |
| **Gitea**[span_40](start_span)[span_40](end_span)[span_41](start_span)[span_41](end_span) | `gitea/gitea`[span_42](start_span)[span_42](end_span) | Локальный сервер контроля версий на базе SQLite3 со встроенным SSH-сервером[span_43](start_span)[span_43](end_span). | `https://git.lan`[span_44](start_span)[span_44](end_span) (SSH: `2222`[span_45](start_span)[span_45](end_span)) |
| **qBittorrent**[span_46](start_span)[span_46](end_span)[span_47](start_span)[span_47](end_span) | `linuxserver/qbittorrent`[span_48](start_span)[span_48](end_span) | Торрент-клиент с предустановленным современным веб-интерфейсом **VueTorrent** и преднастроенным хешем пароля PBKDF2[span_49](start_span)[span_49](end_span). | `https://torrent.lan`[span_50](start_span)[span_50](end_span) |
| **Samba**[span_51](start_span)[span_51](end_span)[span_52](start_span)[span_52](end_span) | `servercontainers/samba`[span_53](start_span)[span_53](end_span) | Сетевой файлообменник для Windows/macOS/Linux с анонсированием через протокол WSDD2[span_54](start_span)[span_54](end_span). | `\\<IP_СЕРВЕРА>\<SHARE_NAME>`[span_55](start_span)[span_55](end_span) |
| **Watchtower**[span_56](start_span)[span_56](end_span) | `containrrr/watchtower`[span_57](start_span)[span_57](end_span) | Фоновый мониторинг и автообновление запущенных Docker-образов раз в сутки[span_58](start_span)[span_58](end_span). | Работает в фоне[span_59](start_span)[span_59](end_span) |

---

## ⚙️ Архитектура и внутренняя логика

### 1. Сетевой конвейер и DNS-маршрутизация
```text
Клиент в LAN (ПК / Смартфон)
       │ (DNS: 53)
       ▼
  AdGuard Home (порт 53)  ──► [Проверка блокировок / Локальные Rewrites]
       │ (Upstream)
       ▼
   Mihomo DNS (127.0.0.1:1053)
       ├──► Домены *.lan / *.duckdns.org  ──► Настоящий IP сервера (DIRECT)
       ├──► Домены РФ (geosite:category-ru) ──► Прямой резолв (Яндекс DNS)
       └──► Внешние адреса                ──► Выдача адреса из Fake-IP пула (198.18.0.0/16)
```
* **Блокировка QUIC:** Скрипт принудительно реджектит UDP-трафик на 443 порт (`- AND,((NETWORK,udp),(DST-PORT,443)),REJECT`), принуждая браузеры и приложения работать через стабильный TCP-туннель[span_60](start_span)[span_60](end_span)[span_61](start_span)[span_61](end_span).
* **Обход РФ-сегмента:** Трафик к государственным сервисам, банкам и российским сайтам направляется напрямую (`DIRECT`), минуя прокси[span_62](start_span)[span_62](end_span).

### 2. Дисковая подсистема и безопасность данных
Мастер установки предлагает 5 вариантов конфигурации хранилища[span_63](start_span)[span_63](end_span):
* **Системный диск:** Создание директории данных в домашнем каталоге пользователя[span_64](start_span)[span_64](end_span).
* **Внешний диск без шифрования:** Монтирование с оптимизированными опциями (`noatime`, `zstd`-компрессия для Btrfs или маппинг UID/GID для NTFS/exFAT) и добавлением в `/etc/fstab`[span_65](start_span)[span_65](end_span).
* **Шифрование LUKS2 + Btrfs:** Автоматическое форматирование накопителя с использованием стойкого KDF **Argon2id**, генерация случайного 512-байтного ключ-файла в `/etc/cryptsetup-keys.d/` и настройка цепочки `crypttab` $\to$ `fstab` для прозрачного монтирования при загрузке[span_66](start_span)[span_66](end_span).
* **Утилита разблокировки:** В систему добавляется исполняемый скрипт `/usr/local/bin/homelab-unlock` для удобного монтирования тома вручную[span_67](start_span)[span_67](end_span).
* **Отключение CoW:** Для папок с базами данных (Gitea, Vaultwarden) и торрент-загрузок автоматически выставляется атрибут `+C` (No-Copy-on-Write), защищающий Btrfs от деградации производительности из-за фрагментации[span_68](start_span)[span_68](end_span).

### 3. Автоматическое резервное копирование
Если включен Vaultwarden, в системе активируется ежедневный Systemd-таймер (`vaultwarden-backup.timer` на 03:00)[span_69](start_span)[span_69](end_span). Скрипт выполняет «горячий» бэкап базы данных через вызов `sqlite3 .backup`, пакует вложения и ключи шифрования в архив `.tar.gz`, сохраняет в хранилище и удаляет архивы старше 14 дней[span_70](start_span)[span_70](end_span).

---

## 🔑 Подключение по SSH к Gitea (VS Code / CLI)

Сервис Gitea проброшен на порт **`2222`**, чтобы не конфликтовать со стандартным SSH-демоном хостовой ОС[span_71](start_span)[span_71](end_span).

1. **Генерация ключа на рабочем компьютере:**
   ```bash
   ssh-keygen -t ed25519 -C "homelab-client"
   ```
2. **Добавление ключа в профиль:**
   Скопируйте вывод `cat ~/.ssh/id_ed25519.pub` и вставьте его в Gitea: **Профиль** $\to$ **Настройки** $\to$ **Ключи SSH / GPG** $\to$ **Добавить ключ**[span_72](start_span)[span_72](end_span). Окно верификации подписи можно пропустить (нажать «Отмена») — ключ сразу станет активным[span_73](start_span)[span_73](end_span).
3. **Настройка файла конфигурации SSH (`~/.ssh/config`):**
   ```text
   Host git.lan
       HostName 192.168.1.X     # Локальный IP вашего сервера
       Port 2222
       User git
       IdentityFile ~/.ssh/id_ed25519
   ```
4. **Проверка авторизации:**
   ```bash
   ssh -T git@git.lan
   ```
   В ответ сервер выдаст приветственное сообщение: `Hi there, <пользователь>! You've successfully authenticated...`

---

## 📁 Структура расположения файлов

* `/opt/homelab/` — корневой каталог стека Docker Compose[span_74](start_span)[span_74](end_span).
* `/opt/homelab/.env` — сохраненные переменные конфигурации и учетные данные[span_75](start_span)[span_75](end_span).
* `/opt/homelab/{adguard,mihomo,caddy,qbittorrent,vaultwarden,gitea}/` — конфигурационные файлы и данные сервисов[span_76](start_span)[span_76](end_span).
* `/etc/systemd/system/homelab.service` — юнит автозапуска всего стека после старта Docker и монтирования дисков[span_77](start_span)[span_77](end_span).
* `/etc/systemd/system/network-gateway-watchdog.service` — служба сторожевого таймера шлюза[span_78](start_span)[span_78](end_span).
* `/usr/local/bin/homelab-unlock` — скрипт ручной расшифровки и старта стека для LUKS-накопителей[span_79](start_span)[span_79](end_span).
