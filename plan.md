# VPN Manager — План реализации

## Текущее состояние

### Реализовано
- [x] `lib/00_core.sh` — константы, пути, версия
- [x] `lib/01_utils.sh` — логгер, генераторы UUID/паролей, валидаторы
- [x] `lib/02_checks.sh` — проверка зависимостей, прав, окружения
- [x] `lib/03_ui.sh` — whiptail-обёртки (menu, input, confirm, progress)
- [x] `lib/10_xray.sh` — полное управление Xray (VLESS+XHTTP)
- [x] `lib/20_users.sh` — CRUD пользователей, sync к Xray
- [x] `lib/30_monitor.sh` — статус, логи, соединения
- [x] `lib/40_connection.sh` — генерация URI, QR-коды
- [x] `vpnmgr.sh` — точка входа, главное меню
- [x] `install.sh` — базовый установщик
- [x] `templates/xray-vless-xhttp.json.tpl`
- [x] `templates/hysteria2.yaml.tpl` (шаблон есть, не используется)
- [x] `templates/amneziawg.conf.tpl` (шаблон есть, не используется)
- [x] `data/users.json`, `data/protocols.json`, `data/server.json`

---

## Этап 1: Hysteria 2 — полная реализация

### 1.1 `lib/11_hysteria.sh`
- [x] `hysteria_is_installed()` — проверка `/usr/local/bin/hysteria`
- [x] `hysteria_is_running()` — `systemctl is-active hysteria`
- [x] `hysteria_install()` — скачать с GitHub API, создать systemd unit, сгенерировать конфиг, запустить
- [x] `hysteria_generate_config()` — из `protocols.json` + `users.json` → `/etc/hysteria/config.yaml`
- [x] `hysteria_start_stop()` — toggle start/stop с подтверждением
- [x] `hysteria_restart()` — перезапуск сервиса
- [x] `hysteria_show_config()` — показать текущий config.yaml
- [x] `hysteria_change_port()` — смена порта с валидацией
- [x] `hysteria_port_hopping()` — вкл/выкл port hopping (iptables DNAT диапазон портов)
- [x] `hysteria_masquerade()` — изменить masquerade URL
- [x] `hysteria_salamander()` — вкл/выкл salamander obfs с генерацией пароля
- [x] `hysteria_uninstall()` — остановка, удаление бинарника, конфига, systemd unit
- [x] `hysteria_manage()` — главное меню Hysteria (заменить заглушку)

### 1.2 Интеграция с пользователями
- [x] `users_sync_to_hysteria()` в `lib/20_users.sh` — синхронизация паролей в config.yaml
- [x] Вызов `users_sync_to_hysteria` из `user_add()`, `user_delete()`, `user_toggle()`

### 1.3 Обновление данных
- [x] `data/protocols.json` — добавить поля: `masquerade_url`, `obfs_password`, `port_hopping_range`
- [x] Исправить опечатку в `templates/hysteria2.yaml.tpl`: `masquarade` → `masquerade`

### 1.4 Подключение
- [x] Проверить/обновить `_connection_hysteria2_uri()` в `lib/40_connection.sh`
- [x] Убедиться что QR для Hysteria2 работает корректно

---

## Этап 2: Бэкап и восстановление (`lib/50_backup.sh`)

- [x] `backup_create()` — tar.gz архив: `data/`, `templates/`, `/etc/xray/`, `/etc/hysteria/`, `/etc/amneziawg/`
- [x] `backup_list()` — список бэкапов в `backups/` с датами и размерами
- [x] `backup_restore()` — выбор из списка → распаковка → рестарт всех активных сервисов
- [x] `backup_schedule()` — настройка cron (ежедневно 03:00 / еженедельно / отключить)
- [x] `backup_export_users()` — экспорт `users.json` отдельным файлом
- [x] `backup_manage()` — меню раздела
- [x] Ротация: удалять бэкапы старше 30 дней (в backup_create_silent)
- [x] Интеграция в `vpnmgr.sh` — убрать заглушку в `main_menu`

---

## Этап 3: Обновления (updater)

- [x] `updater_check_versions()` — проверить GitHub API для xray-core, hysteria, vpnmgr
- [x] `updater_update_xray()` — скачать новую версию → бэкап бинарника → замена → рестарт
- [x] `updater_update_hysteria()` — аналогично xray
- [x] `updater_update_vpnmgr()` — скачать tar из репозитория, обновить скрипты без затрагивания data/
- [x] `updater_manage()` — меню с отображением текущих и доступных версий
- [x] Интеграция в `vpnmgr.sh` — убрать заглушку в `main_menu`

> Решение: реализовано как отдельный `lib/51_updater.sh`

---

## Этап 4: AmneziaWG (`lib/12_amnezia.sh`)

- [x] `amnezia_is_installed()` — проверка `awg` / `awg-quick`
- [x] `amnezia_install()` — установка из репозитория AmneziaWG, генерация серверных ключей
- [x] `amnezia_generate_config()` — серверный конфиг с jitter-параметрами (Jc, Jmin, Jmax, S1, S2, H1-H4)
- [x] `amnezia_start_stop()` — `awg-quick up/down`
- [x] `amnezia_restart()` — перезапуск интерфейса
- [x] `amnezia_add_peer()` — генерация клиентского конфига + QR
- [x] `amnezia_remove_peer()` — удаление пира из серверного конфига
- [x] `amnezia_jitter_settings()` — UI для настройки jitter-параметров
- [x] `amnezia_show_config()` — показать серверный конфиг
- [x] `amnezia_uninstall()` — полное удаление
- [x] `amnezia_manage()` — меню
- [x] Интеграция в `protocols_menu()` — убрать заглушку
- [x] Обновить `data/protocols.json` — поля для AmneziaWG

---

## Этап 5: SOCKS5 (`lib/13_socks5.sh`)

- [x] `socks5_enable_xray()` — добавить SOCKS5 inbound в конфиг Xray (127.0.0.1:1080)
- [ ] `socks5_enable_hysteria()` — добавить SOCKS5 в Hysteria (не реализовано — Hysteria не поддерживает SOCKS5 inbound нативно)
- [x] `socks5_disable()` — убрать SOCKS5 inbound
- [x] `socks5_show_status()` — показать порт и инструкцию использования
- [x] `socks5_manage()` — меню
- [x] Интеграция в `protocols_menu()`
- [x] Подключить в `vpnmgr.sh`

---

## Этап 6: Watchdog и автоматизация

- [x] `watchdog.sh` — cron-скрипт: проверка каждого активного сервиса, 1 попытка рестарта, лог
- [x] `/etc/cron.d/vpnmgr` — watchdog */5 мин, ночной бэкап, проверка TLS (в install.sh)
- [x] logrotate конфиг — ротация логов vpnmgr и watchdog (в install.sh)
- [x] Интеграция установки cron в `install.sh`

---

## Этап 7: Полировка и доводка

- [x] Обновить `install.sh` — проверка версий, создание data-файлов, установка cron, logrotate
- [x] Breadcrumbs в заголовках whiptail (WT_BACKTITLE > Протоколы)
- [x] Актуальный статус в шапке главного меню (IP, кол-во пользователей, последний бэкап)
- [x] Проверка блокировок (curl-тест через прямое/SOCKS5 в мониторинге)
- [x] Сброс счётчика трафика в меню пользователей
- [ ] Трафик за 24ч / 7 дней / месяц в мониторинге (требует Xray stats API)
- [x] Edge cases: пустые конфиги, битый JSON — обработаны через `2>/dev/null || default`
- [ ] Тестирование на чистом Debian 11

---

## Аудит и исправления

- [x] `users_sync_to_hysteria()` — исправлен YAML (пустой пароль → `password: {}`)
- [x] `amnezia_remove_peer()` — убран мёртвый awk, исправлен sed → awk для корректного удаления блока
- [x] `hysteria_salamander()` — исправлено удаление obfs-блока (sed → awk)
- [x] `updater_check_versions()` — убран сломанный фоновый ui_progress
- [x] `grep -oP` → `grep -oE` — POSIX-совместимость (без PCRE)
- [x] `data/server.json` — добавлено поле `key_path`
- [x] `30_monitor.sh` — добавлен AmneziaWG в статус, соединения, логи watchdog
- [x] `40_connection.sh` — добавлен AmneziaWG QR-код в инструкции подключения
- [x] `watchdog.sh` — убран `set -e` (скрипт не должен прерываться при сбое одного сервиса)
- [x] `vpnmgr.sh` — CLI-аргументы через case, убран `local` вне функции
- [x] Bash syntax check — все 16 файлов проходят `bash -n`

---

## Расхождения с PRD (решено)

- [x] `users_sync_to_hysteria()` — реализовано в `20_users.sh`
- [x] `protocols.json` — добавлены поля masquerade, obfs, port hopping
- [x] Опечатка `masquarade` — исправлена в `templates/hysteria2.yaml.tpl`
- [x] Шаблоны (`templates/`) не используются — конфиги генерируются inline (решение: оставить inline, проще поддерживать)
