# vpnmgr

Менеджер VPN-сервера с TUI-интерфейсом на bash. Устанавливает, настраивает и управляет протоколами обхода блокировок: VLESS+XHTTP (Xray), Hysteria 2, AmneziaWG, SOCKS5, sing-box. Работает на Debian 11+ / Ubuntu 20.04+.

---

## Быстрый старт

```bash
git clone https://github.com/f2re/vpnmgr.git
cd vpnmgr
sudo bash install.sh   # установка в /opt/vpnmgr, команда vpnmgr
vpnmgr                 # запуск
```

При первом запуске автоматически открывается **мастер настройки**.

---

## Мастер первоначальной настройки

Запускается автоматически при первом старте (если IP не задан), или вручную через главное меню → **«0 — Настройка сервера»** → «Мастер».

### Шаг 1 — IP-адрес

IP определяется автоматически (ipify / ifconfig.me). Можно исправить.

### Шаг 2 — Домен и TLS

| Ситуация | Выбор | Результат |
|---|---|---|
| Есть домен → хочу настоящий HTTPS | Let's Encrypt | Сертификат + автопродление в cron |
| Есть домен + свой сертификат | «Свой сертификат» | Указать пути к `fullchain.pem` / `privkey.pem` |
| Нет домена | «Самоподписанный» | EC P-256, 10 лет; `insecure=1` в URI клиентов |

**Почему важен TLS?**
С сертификатом Xray слушает на порту 443 как обычный HTTPS — DPI не может отличить VPN от легитимного трафика. Без TLS xHTTP-трафик виден в открытом виде и блокируется.

### Шаг 3 — Протоколы и первый пользователь

Checklist протоколов → установка → добавление первого пользователя.

---

## Главное меню

```
vpn.example.com [LE TLS] | users: 3
────────────────────────────────────────────────
0  Настройка сервера (IP, домен, TLS)
1  Статус системы
2  Протоколы
3  Пользователи
4  Мониторинг и логи
5  Бэкап и восстановление
6  Обновления
q  Выход
```

Статус TLS отображается прямо в заголовке: `[LE TLS]` — Let's Encrypt, `[self TLS]` — самоподписанный, `[no TLS]` — без сертификата.

---

## Настройка сервера

```
IP: 1.2.3.4 | Домен: vpn.example.com | TLS: LE (действителен, 87 дн.)
────────────────────────────────────────────────
1  Мастер первоначальной настройки
2  Изменить IP / домен
3  TLS-сертификат
4  Информация о сервере
```

### Подменю TLS

```
1  Let's Encrypt (автоматически, рекомендуется)
2  Свой сертификат (указать пути к файлам)
3  Самоподписанный (работает без домена, insecure)
4  Просмотр текущего сертификата
```

После любого изменения TLS конфиги Xray и Hysteria 2 пересоздаются, сервисы перезапускаются автоматически.

**Let's Encrypt** устанавливает certbot и добавляет в cron:
```
0 3 * * * certbot renew --quiet --post-hook 'systemctl restart xray hysteria'
```

---

## Протоколы

### VLESS + XHTTP (Xray) — порт 443/TCP

Трафик по HTTP/1.1 или HTTP/2. С TLS неотличим от обычного HTTPS.

**URI в зависимости от настроек:**

| Конфигурация | URI |
|---|---|
| Let's Encrypt / свой cert + домен | `vless://UUID@domain:443?encryption=none&security=tls&type=xhttp&path=/xxxxx&sni=domain#name` |
| Самоподписанный + IP | `vless://UUID@ip:443?encryption=none&security=tls&type=xhttp&path=/xxxxx&allowInsecure=1#name` |
| Без сертификата | `vless://UUID@ip:443?encryption=none&security=none&type=xhttp&path=/xxxxx#name` |

Клиенты: v2rayN, NekoBox, sing-box, Shadowrocket, Hiddify.

Меню: `Протоколы → VLESS + XHTTP (Xray)`

```
a  Установить / обновить
b  Запустить / Остановить
c  Перезапустить
d  Просмотреть конфиг
e  Изменить порт
f  Удалить
```

Конфиг: `/etc/xray/config.json`
Сервис: `systemctl status xray`

---

### Hysteria 2 — порт 8443/UDP

QUIC-протокол с salamander-обфускацией. Salamander включён по умолчанию.

URI: `hysteria2://user:pass@ip:8443?insecure=1&obfs=salamander&obfs-password=SECRET#name`

Меню: `Протоколы → Hysteria 2`

```
a  Установить / обновить
b  Запустить / Остановить
c  Перезапустить
d  Port hopping ON/OFF    ← диапазон UDP-портов через iptables
e  Изменить masquerade URL
f  Salamander obfs ON/OFF
g  Изменить порт
h  Просмотреть конфиг
i  Удалить
```

**Port hopping** — Hysteria 2 слушает основной порт, а iptables перебрасывает диапазон (напр. 20000–40000) на него. Клиент случайно выбирает порт → тяжело заблокировать.

Конфиг: `/etc/hysteria/config.yaml`
Сервис: `systemctl status hysteria`

---

### AmneziaWG — порт 51820/UDP

WireGuard с обфускацией трафика.

Параметры обфускации: `Jc` (junk-пакеты), `Jmin`/`Jmax` (размер мусора), `S1`/`S2`/`H1`–`H4` (magic bytes заголовков). Все параметры настраиваемы и автоматически синхронизируются с клиентскими конфигами.

Меню: `Протоколы → AmneziaWG`

```
a  Установить
b  Запустить / Остановить
c  Перезапустить
d  Добавить пир (клиента)   ← генерирует клиентский .conf + QR
e  Удалить пир
f  Jitter настройки
g  Просмотреть конфиг
h  Удалить AmneziaWG
```

Клиенты: приложение AmneziaVPN или WireGuard с поддержкой jitter-параметров.

---

### SOCKS5 (3proxy) — порт 1080/TCP

Простой прокси с авторизацией. Собирается из исходников.

URI: `socks5://user:pass@ip:1080`

Меню: `Протоколы → SOCKS5`

---

### sing-box — мультипротокол

Один бинарник, несколько протоколов на разных портах: SOCKS5 (10808), VLESS (10443), Shadowsocks (8388), Hysteria 2 (18443).

Меню: `Протоколы → sing-box`

---

## Управление пользователями

```
1  Список пользователей
2  Добавить пользователя      ← создаёт UUID (VLESS) + пароль (Hysteria 2)
3  Удалить пользователя
4  Включить / отключить       ← горячее обновление конфигов
5  Инструкции подключения     ← URI + QR-код
6  Сбросить счётчик трафика
```

При добавлении/удалении/отключении пользователя конфиги всех запущенных сервисов обновляются автоматически.

---

## Инструкции подключения и QR-коды

`Пользователи → Инструкции подключения` — показывает URI всех протоколов и предлагает QR-код.

Пример для VLESS с Let's Encrypt:
```
vless://550e8400-e29b-41d4-a716-446655440000@vpn.example.com:443?encryption=none&security=tls&type=xhttp&path=/a1b2c3d4&sni=vpn.example.com#alice
```

Пример для Hysteria 2 с salamander:
```
hysteria2://alice:P@ssw0rd@vpn.example.com:8443?insecure=1&obfs=salamander&obfs-password=SuperSecret#alice
```

Для генерации QR нужен `qrencode`:
```bash
apt install -y qrencode
```

---

## Рекомендуемая конфигурация для обхода DPI

| Протокол | Порт | Транспорт | Маскировка | Уровень защиты |
|---|---|---|---|---|
| VLESS+XHTTP + Let's Encrypt | 443/TCP | HTTP/2 over TLS | Настоящий HTTPS-сайт | Максимальный |
| VLESS+XHTTP + самоподписанный | 443/TCP | HTTP/2 over TLS | Шифрование без верификации | Высокий |
| Hysteria 2 + salamander | 8443/UDP | QUIC | Salamander obfs | Высокий |
| AmneziaWG | 51820/UDP | UDP | Jitter-пакеты | Средний |
| SOCKS5 | 1080/TCP | TCP | Нет | Минимальный |

**Оптимальная связка:** VLESS+XHTTP (основной, TCP) + Hysteria 2 (быстрый, UDP) — закрывает большинство сценариев.

---

## Структура проекта

```
vpnmgr/
├── vpnmgr.sh              # Точка входа, главное меню
├── install.sh             # Установщик (/opt/vpnmgr + команда vpnmgr)
├── watchdog.sh            # Watchdog (запускается cron каждые 5 мин)
├── lib/
│   ├── 00_core.sh         # Константы и пути
│   ├── 01_utils.sh        # UUID, пароли, IP, валидация
│   ├── 02_checks.sh       # Проверки: root, зависимости, диск, терминал
│   ├── 03_ui.sh           # Обёртки whiptail (msgbox, menu, input, progress)
│   ├── 05_setup.sh        # Мастер настройки: IP, домен, TLS
│   ├── 10_xray.sh         # VLESS+XHTTP (Xray)
│   ├── 11_hysteria.sh     # Hysteria 2
│   ├── 12_amnezia.sh      # AmneziaWG
│   ├── 13_socks5.sh       # SOCKS5 (3proxy)
│   ├── 14_singbox.sh      # sing-box
│   ├── 20_users.sh        # CRUD пользователей + синхронизация конфигов
│   ├── 30_monitor.sh      # Мониторинг, статус сервисов, логи
│   ├── 40_connection.sh   # Генерация URI (TLS-aware) и QR-кодов
│   ├── 50_backup.sh       # Бэкап и восстановление
│   └── 51_updater.sh      # Самообновление из git
├── data/
│   ├── server.json        # IP, домен, пути к TLS-сертификатам
│   ├── protocols.json     # Настройки протоколов (порты, obfs, etc.)
│   └── users.json         # Пользователи и их credentials
└── templates/             # Шаблоны конфигов
```

---

## Зависимости

```bash
apt update && apt install -y jq whiptail curl openssl qrencode
```

| Пакет | Назначение |
|---|---|
| `jq` | Работа с JSON-конфигами |
| `whiptail` | TUI-интерфейс |
| `curl` | Скачивание бинарников, определение IP |
| `openssl` | UUID, самоподписанные сертификаты |
| `qrencode` | QR-коды для подключения (опционально) |
| `certbot` | Let's Encrypt (устанавливается автоматически) |

---

## CLI-аргументы

```bash
vpnmgr --backup-silent   # Тихий бэкап (для cron)
vpnmgr --check-cert      # Проверить срок TLS-сертификата (для cron)
```

---

## Cron-задачи

Настраиваются автоматически при установке (`install.sh`).

| Расписание | Задача |
|---|---|
| Каждые 5 минут | Watchdog — проверка и перезапуск упавших сервисов |
| 03:00 ежедневно | Автобэкап |
| 09:00 ежедневно | Проверка срока TLS-сертификата |
| 03:00 ежедневно | Автопродление Let's Encrypt (если использован certbot) |

---

## Данные и логи

| Путь | Содержимое |
|---|---|
| `/opt/vpnmgr/data/` | JSON-базы данных (пользователи, протоколы, сервер) |
| `/opt/vpnmgr/logs/vpnmgr.log` | Основной лог vpnmgr |
| `/opt/vpnmgr/backups/` | Автоматические бэкапы |
| `/etc/vpnmgr/certs/` | Самоподписанные сертификаты |
| `/var/log/xray/` | Логи Xray |
| `/var/log/hysteria/` | Логи Hysteria 2 |

---

## Устранение неполадок

**Сервис не запускается:**
```bash
journalctl -u xray -n 50
journalctl -u hysteria -n 50
cat /opt/vpnmgr/logs/vpnmgr.log | tail -50
```

**Let's Encrypt не выдаёт сертификат:**
- DNS-запись A для домена должна указывать на IP сервера
- Порт 80 должен быть доступен из интернета
- Лог certbot: `/var/log/letsencrypt/letsencrypt.log`

**Клиент не подключается к VLESS:**
- Проверить URI в меню «Инструкции подключения» — там актуальный путь и security
- При `security=tls` с самоподписанным: включить `allowInsecure=1` в клиенте
- `ss -tlnp | grep 443` — убедиться, что xray слушает

**Клиент не подключается к Hysteria 2:**
- Обязательно обновить URI после изменения obfs — пароль шифрования должен совпадать
- Проверить UDP: `ss -ulnp | grep 8443`
- `cat /var/log/hysteria/hysteria.log`

---

## Требования

- Debian 11+ или Ubuntu 20.04+
- Root / sudo
- Терминал 80×24 минимум
- Интернет для установки бинарников

---

## Лицензия

MIT
