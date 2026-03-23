#!/usr/bin/env bash

# lib/05_setup.sh — Мастер настройки сервера: IP, домен, TLS

# ─── Вспомогательные ────────────────────────────────────────────────────────

_setup_save() {
    local ip="$1" hostname="$2" cert_path="$3" key_path="$4" email="$5"
    local tmp="${SERVER_JSON}.tmp.$$"
    jq -n \
        --arg ip       "$ip"        \
        --arg hostname "$hostname"  \
        --arg cert     "$cert_path" \
        --arg key      "$key_path"  \
        --arg email    "$email"     \
        '{ip:$ip, hostname:$hostname, cert_path:$cert, key_path:$key, email:$email}' \
        > "$tmp" && mv "$tmp" "$SERVER_JSON"
    log_info "server.json обновлён: ip=$ip hostname=$hostname cert=$cert_path"
}

_setup_current() {
    local field="$1" default="${2:-}"
    jq -r --arg f "$field" --arg d "$default" '.[$f] // $d' "$SERVER_JSON" 2>/dev/null || echo "$default"
}

# Перезапускает протоколы после смены сертификата
_setup_apply_certs() {
    if [[ -x "$XRAY_BIN" ]]; then
        xray_generate_config
        users_sync_to_xray 2>/dev/null || true
        if systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; then
            systemctl restart "$XRAY_SERVICE" 2>/dev/null || true
        fi
    fi
    users_sync_to_hysteria 2>/dev/null || true
    
    if singbox_is_installed; then
        singbox_sync_users 2>/dev/null || true
    fi
}

# ─── Определение IP ─────────────────────────────────────────────────────────

_setup_detect_ip() {
    curl -4 -s --max-time 6 https://api.ipify.org    2>/dev/null \
    || curl -4 -s --max-time 6 https://ifconfig.me   2>/dev/null \
    || curl -4 -s --max-time 6 https://icanhazip.com 2>/dev/null \
    || echo ""
}

# ─── TLS: Let's Encrypt ─────────────────────────────────────────────────────

_setup_tls_letsencrypt() {
    local domain="$1" email="$2"

    # Certbot: установка если нужна
    if ! command -v certbot >/dev/null 2>&1; then
        {
            echo "5";  echo "XXX"; echo "Обновление пакетов...";  echo "XXX"
            apt-get update -qq 2>/dev/null || true
            echo "40"; echo "XXX"; echo "Установка certbot...";   echo "XXX"
            apt-get install -y -qq certbot 2>/dev/null
            echo "100"; echo "XXX"; echo "Готово!"; echo "XXX"
        } | ui_progress "Установка certbot..." "Let's Encrypt"
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        ui_error "Не удалось установить certbot."
        return 1
    fi

    # Порт 80 нужен для HTTP-challenge
    if ! check_port_available 80; then
        ui_error "Порт 80 занят. Certbot требует свободный порт 80.\n\nОстановите сервис на порту 80 и повторите."
        return 1
    fi

    local cert_dir="/etc/letsencrypt/live/$domain"
    local ok=0

    {
        echo "20"; echo "XXX"; echo "Запрос сертификата для $domain..."; echo "XXX"

        if certbot certonly --standalone \
            --non-interactive --agree-tos \
            --email "$email" -d "$domain" \
            --quiet 2>/dev/null; then
            ok=1
        fi
        echo "100"; echo "XXX"; echo "Готово!"; echo "XXX"
    } | ui_progress "Let's Encrypt — $domain" "TLS"

    if [[ $ok -eq 0 || ! -f "$cert_dir/fullchain.pem" ]]; then
        ui_error "Не удалось получить сертификат.\n\nПроверьте:\n  • DNS-запись A для $domain указывает на IP сервера\n  • Порт 80 доступен из интернета\n  • Лог: /var/log/letsencrypt/letsencrypt.log"
        return 1
    fi

    # Автопродление через cron
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; \
         echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl restart xray hysteria 2>/dev/null || true'") \
        | crontab -
        log_info "Автопродление certbot добавлено в cron"
    fi

    echo "$cert_dir/fullchain.pem $cert_dir/privkey.pem"
}

# ─── TLS: Самоподписанный ────────────────────────────────────────────────────

_setup_tls_selfsigned() {
    local cn="${1:-server}"
    local cert_dir="/etc/vpnmgr/certs"
    mkdir -p "$cert_dir"
    chmod 700 "$cert_dir"

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
        -days 3650 -nodes -subj "/CN=$cn" 2>/dev/null

    chmod 600 "$cert_dir/key.pem" "$cert_dir/cert.pem"
    log_info "Самоподписанный сертификат: $cert_dir/cert.pem (CN=$cn)"
    echo "$cert_dir/cert.pem $cert_dir/key.pem"
}

# ─── TLS: Информация о сертификате ──────────────────────────────────────────

_setup_tls_info() {
    local cert_path="$1"
    if [[ -z "$cert_path" || ! -f "$cert_path" ]]; then
        echo "нет"
        return
    fi
    local expiry expiry_epoch now_epoch days_left
    expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry" ]]; then echo "файл найден, не удалось прочитать"; return; fi
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if [[ "$days_left" -lt 0 ]]; then
        echo "ИСТЁК ($days_left дн.)"
    else
        echo "действителен, истекает через $days_left дн."
    fi
}

# ─── TLS: Управление ────────────────────────────────────────────────────────

setup_tls_manage() {
    while true; do
        local cert_path tls_status tls_type
        cert_path=$(_setup_current "cert_path")
        tls_status=$(_setup_tls_info "$cert_path")
        tls_type="нет"
        [[ "$cert_path" == *letsencrypt* ]] && tls_type="Let's Encrypt"
        [[ "$cert_path" == */vpnmgr/certs/* ]] && tls_type="самоподписанный"
        [[ "$tls_type" == "нет" && -n "$cert_path" && "$cert_path" != "null" ]] && tls_type="свой"

        local choice
        choice=$(ui_menu "TLS-сертификат [$tls_type — $tls_status]" \
            "1" "Let's Encrypt (автоматически, рекомендуется)" \
            "2" "Свой сертификат (указать пути к файлам)" \
            "3" "Самоподписанный (работает без домена, insecure)" \
            "4" "Просмотр текущего сертификата" \
            "0" "Назад") || break

        case "$choice" in
            1) _setup_tls_action_letsencrypt ;;
            2) _setup_tls_action_custom ;;
            3) _setup_tls_action_selfsigned ;;
            4) _setup_tls_action_show ;;
            0) return ;;
        esac
    done
}

_setup_tls_action_letsencrypt() {
    local domain email
    domain=$(_setup_current "hostname")
    if [[ -z "$domain" || "$domain" == "null" ]]; then
        domain=$(ui_input "Доменное имя (напр. vpn.example.com):" "" "Let's Encrypt") || return
        [[ -z "$domain" ]] && return
    fi

    email=$(_setup_current "email" "admin@example.com")
    email=$(ui_input "Email для уведомлений:" "$email" "Let's Encrypt") || return
    [[ -z "$email" ]] && return

    local result
    result=$(_setup_tls_letsencrypt "$domain" "$email") || return

    local cert_path key_path
    cert_path=$(awk '{print $1}' <<< "$result")
    key_path=$(awk  '{print $2}' <<< "$result")

    _setup_save "$(_setup_current "ip")" "$domain" "$cert_path" "$key_path" "$email"
    _setup_apply_certs
    ui_success "Let's Encrypt сертификат установлен!\n\nДомен: $domain\nAutorenewal: cron 3:00 ежедневно"
}

_setup_tls_action_custom() {
    local cert_path key_path

    cert_path=$(ui_input "Путь к сертификату (fullchain.pem / cert.pem):" \
        "/etc/ssl/certs/fullchain.pem" "Свой сертификат") || return
    [[ -z "$cert_path" ]] && return
    [[ ! -f "$cert_path" ]] && { ui_error "Файл не найден: $cert_path"; return; }

    key_path=$(ui_input "Путь к приватному ключу (privkey.pem):" \
        "/etc/ssl/private/privkey.pem" "Свой сертификат") || return
    [[ -z "$key_path" ]] && return
    [[ ! -f "$key_path" ]] && { ui_error "Файл не найден: $key_path"; return; }

    # Пытаемся прочитать CN из сертификата
    local cn
    cn=$(openssl x509 -noout -subject -in "$cert_path" 2>/dev/null \
        | grep -oP '(?i)CN\s*=\s*\K[^\s,/]+' | head -1 || echo "")

    local domain
    domain=$(ui_input "Доменное имя (для SNI):" \
        "${cn:-$(_setup_current "hostname")}" "Свой сертификат") || return

    _setup_save "$(_setup_current "ip")" "$domain" "$cert_path" "$key_path" \
        "$(_setup_current "email" "admin@example.com")"
    _setup_apply_certs
    ui_success "Сертификат сохранён.\n\nCert: $cert_path\nKey:  $key_path"
}

_setup_tls_action_selfsigned() {
    if ! ui_confirm "Сгенерировать самоподписанный сертификат (10 лет)?\n\nВ URI клиентов будет добавлен параметр insecure=1.\nТрафик всё равно шифруется — DPI не видит содержимое."; then
        return
    fi

    local cn
    cn=$(_setup_current "hostname")
    [[ -z "$cn" || "$cn" == "null" ]] && cn=$(_setup_current "ip" "server")

    local result
    result=$(_setup_tls_selfsigned "$cn")
    local cert_path key_path
    cert_path=$(awk '{print $1}' <<< "$result")
    key_path=$(awk  '{print $2}' <<< "$result")

    _setup_save "$(_setup_current "ip")" "$(_setup_current "hostname")" \
        "$cert_path" "$key_path" "$(_setup_current "email" "admin@example.com")"
    _setup_apply_certs
    ui_success "Самоподписанный сертификат создан.\n\nФайл: $cert_path\nСрок: 10 лет"
}

_setup_tls_action_show() {
    local cert_path
    cert_path=$(_setup_current "cert_path")

    if [[ -z "$cert_path" || "$cert_path" == "null" || ! -f "$cert_path" ]]; then
        ui_msgbox "Сертификат не настроен или файл не найден.\n\nПуть: ${cert_path:-не задан}" "TLS"
        return
    fi

    local info
    info=$(openssl x509 -noout -text -in "$cert_path" 2>/dev/null \
        | grep -E "Subject:|Issuer:|Not Before|Not After|DNS:" \
        | head -12 || echo "Не удалось прочитать сертификат")

    ui_msgbox "Сертификат: $cert_path\n\n$info" "TLS — информация"
}

# ─── IP и домен ─────────────────────────────────────────────────────────────

setup_server_identity() {
    local current_ip current_hostname

    # Если IP не задан — автоопределяем
    current_ip=$(_setup_current "ip")
    if [[ -z "$current_ip" || "$current_ip" == "null" ]]; then
        current_ip=$(_setup_detect_ip)
    fi
    current_hostname=$(_setup_current "hostname")
    [[ "$current_hostname" == "null" ]] && current_hostname=""

    local ip
    ip=$(ui_input "IP-адрес сервера:" "$current_ip" "Настройка сервера") || return
    [[ -z "$ip" ]] && return

    local hostname
    hostname=$(ui_input "Доменное имя (оставьте пустым, если нет):" \
        "$current_hostname" "Настройка сервера") || return

    _setup_save "$ip" "$hostname" \
        "$(_setup_current "cert_path")" "$(_setup_current "key_path")" \
        "$(_setup_current "email" "admin@example.com")"

    ui_success "Сохранено!\n\nIP:    $ip\nДомен: ${hostname:-не задан}"
}

# ─── Показ информации ────────────────────────────────────────────────────────

_setup_show_info() {
    local ip hostname cert_path key_path email tls_status tls_type
    ip=$(_setup_current "ip" "не задан")
    hostname=$(_setup_current "hostname" "нет")
    cert_path=$(_setup_current "cert_path" "нет")
    key_path=$(_setup_current "key_path" "нет")
    email=$(_setup_current "email" "нет")

    tls_status=$(_setup_tls_info "$cert_path")
    tls_type="нет"
    [[ "$cert_path" == *letsencrypt*  ]] && tls_type="Let's Encrypt"
    [[ "$cert_path" == */vpnmgr/certs/* ]] && tls_type="самоподписанный"
    [[ "$tls_type" == "нет" && -n "$cert_path" && "$cert_path" != "нет" && "$cert_path" != "null" ]] && tls_type="свой"

    ui_msgbox \
"═══ Сервер ═══

IP-адрес : $ip
Домен    : $hostname
Email    : $email

═══ TLS ═══

Тип      : $tls_type
Статус   : $tls_status
Cert     : $cert_path
Key      : $key_path" \
    "Информация о сервере"
}

# ─── Мастер первоначальной настройки ────────────────────────────────────────

setup_wizard() {
    if ! whiptail --title "Добро пожаловать в vpnmgr" --backtitle "$WT_BACKTITLE" \
        --yesno \
"Запущен мастер первоначальной настройки.

Шаги:
  1. IP-адрес сервера
  2. Домен и TLS-сертификат
  3. Выбор и установка протоколов VPN
  4. Добавление первого пользователя

Начать настройку?" \
        20 70; then
        return
    fi

    # ── Шаг 1: IP ──────────────────────────────────────────────────────────
    local detected_ip
    detected_ip=$(_setup_detect_ip)

    local server_ip
    server_ip=$(ui_input \
        "Шаг 1/3 — IP-адрес сервера\n\nОпределён автоматически. Проверьте и при необходимости исправьте:" \
        "$detected_ip" "Мастер настройки") || return
    [[ -z "$server_ip" ]] && server_ip="$detected_ip"

    # ── Шаг 2: Домен и TLS ─────────────────────────────────────────────────
    local hostname="" cert_path="" key_path=""
    local email="admin@example.com"

    if whiptail --title "Мастер настройки" --backtitle "$WT_BACKTITLE" \
        --yesno \
"Шаг 2/3 — Домен и TLS

Есть ли у вас доменное имя, указывающее на IP $server_ip?

Домен позволяет:
  • Получить бесплатный TLS (Let's Encrypt)
  • Лучше маскировать трафик под HTTPS
  • Использовать SNI для обхода DPI

Без домена — самоподписанный сертификат (всё равно шифрует трафик)." \
        22 72; then

        hostname=$(ui_input \
            "Доменное имя сервера (напр. vpn.example.com):" \
            "" "Мастер настройки — Домен") || hostname=""

        if [[ -n "$hostname" ]]; then
            email=$(ui_input "Email для Let's Encrypt:" "admin@example.com" \
                "Мастер настройки — TLS") || email="admin@example.com"

            local tls_choice
            tls_choice=$(whiptail --title "Мастер настройки — TLS" --backtitle "$WT_BACKTITLE" \
                --menu "Способ получения TLS-сертификата:" 16 72 3 \
                "1" "Let's Encrypt — автоматически (рекомендуется)" \
                "2" "Свой сертификат — указать пути к файлам" \
                "3" "Самоподписанный — без проверки (insecure=1)" \
                3>&1 1>&2 2>&3) || tls_choice="3"

            case "$tls_choice" in
                1)
                    # Сохраняем частично и пробуем Let's Encrypt
                    _setup_save "$server_ip" "$hostname" "" "" "$email"
                    local le_result
                    if le_result=$(_setup_tls_letsencrypt "$hostname" "$email" 2>/dev/null); then
                        cert_path=$(awk '{print $1}' <<< "$le_result")
                        key_path=$(awk  '{print $2}' <<< "$le_result")
                    else
                        ui_warn "Не удалось получить Let's Encrypt сертификат.\nИспользуется самоподписанный."
                        local ss_r; ss_r=$(_setup_tls_selfsigned "$hostname")
                        cert_path=$(awk '{print $1}' <<< "$ss_r")
                        key_path=$(awk  '{print $2}' <<< "$ss_r")
                    fi
                    ;;
                2)
                    cert_path=$(ui_input "Путь к fullchain.pem:" \
                        "/etc/ssl/certs/fullchain.pem" "TLS") || cert_path=""
                    key_path=$(ui_input "Путь к privkey.pem:"   \
                        "/etc/ssl/private/privkey.pem" "TLS") || key_path=""
                    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                        ui_warn "Файлы не найдены. Используется самоподписанный сертификат."
                        local ss_r; ss_r=$(_setup_tls_selfsigned "$hostname")
                        cert_path=$(awk '{print $1}' <<< "$ss_r")
                        key_path=$(awk  '{print $2}' <<< "$ss_r")
                    fi
                    ;;
                3|*)
                    local ss_r; ss_r=$(_setup_tls_selfsigned "$hostname")
                    cert_path=$(awk '{print $1}' <<< "$ss_r")
                    key_path=$(awk  '{print $2}' <<< "$ss_r")
                    ;;
            esac
        fi
    fi

    # Нет домена или не введён → самоподписанный
    if [[ -z "$cert_path" ]]; then
        local ss_r; ss_r=$(_setup_tls_selfsigned "${hostname:-server}")
        cert_path=$(awk '{print $1}' <<< "$ss_r")
        key_path=$(awk  '{print $2}' <<< "$ss_r")
    fi

    _setup_save "$server_ip" "$hostname" "$cert_path" "$key_path" "$email"

    # ── Шаг 3: Протоколы ───────────────────────────────────────────────────
    local chosen
    chosen=$(whiptail --title "Мастер настройки" --backtitle "$WT_BACKTITLE" \
        --checklist "Шаг 3/3 — Выберите протоколы для установки:" 20 74 4 \
        "xray"     "VLESS+XHTTP (Xray)  — TCP, TLS, обход DPI"        ON \
        "hysteria" "Hysteria 2          — UDP QUIC, salamander obfs"   ON \
        "amnezia"  "AmneziaWG           — WireGuard с обфускацией"     OFF \
        "socks5"   "SOCKS5 (3proxy)     — простой TCP прокси"          OFF \
        3>&1 1>&2 2>&3) || chosen=""

    local errors=()
    echo "$chosen" | grep -q '"xray"'     && { xray_install     || errors+=("Xray");      }
    echo "$chosen" | grep -q '"hysteria"' && { hysteria_install  || errors+=("Hysteria 2");}
    echo "$chosen" | grep -q '"amnezia"'  && { amnezia_install   || errors+=("AmneziaWG"); }
    echo "$chosen" | grep -q '"socks5"'   && { socks5_install    || errors+=("SOCKS5");    }

    # ── Первый пользователь ────────────────────────────────────────────────
    if [[ -n "$chosen" ]]; then
        if whiptail --title "Мастер настройки" --backtitle "$WT_BACKTITLE" \
            --yesno "Протоколы установлены!\n\nДобавить первого пользователя?" 12 60; then
            user_add
        fi
    fi

    # ── Итог ───────────────────────────────────────────────────────────────
    local tls_label="самоподписанный"
    [[ "$cert_path" == *letsencrypt* ]] && tls_label="Let's Encrypt"

    local summary
    summary="Настройка завершена!\n\n"
    summary+="IP сервера : $server_ip\n"
    [[ -n "$hostname" ]] && summary+="Домен      : $hostname\n"
    summary+="TLS        : $tls_label\n"
    [[ ${#errors[@]} -gt 0 ]] && summary+="\nОшибки при установке: ${errors[*]}\n(установите вручную через меню Протоколы)"

    ui_success "$summary"
}

# ─── Главное меню настройки ──────────────────────────────────────────────────

setup_server_menu() {
    while true; do
        local ip hostname cert_path tls_status tls_type
        ip=$(_setup_current "ip" "не задан")
        hostname=$(_setup_current "hostname" "")
        [[ -z "$hostname" || "$hostname" == "null" ]] && hostname="нет"
        cert_path=$(_setup_current "cert_path" "")
        tls_status=$(_setup_tls_info "$cert_path")
        tls_type="нет"
        [[ "$cert_path" == *letsencrypt*    ]] && tls_type="LE"
        [[ "$cert_path" == */vpnmgr/certs/* ]] && tls_type="self"
        [[ "$tls_type" == "нет" && -n "$cert_path" && "$cert_path" != "null" ]] && tls_type="custom"

        local choice
        choice=$(ui_menu "IP: $ip | Домен: $hostname | TLS: $tls_type ($tls_status)" \
            "1" "Мастер первоначальной настройки" \
            "2" "Изменить IP / домен" \
            "3" "TLS-сертификат" \
            "4" "Информация о сервере" \
            "0" "Назад") || break

        case "$choice" in
            1) setup_wizard          ;;
            2) setup_server_identity ;;
            3) setup_tls_manage      ;;
            4) _setup_show_info      ;;
            0) return ;;
        esac
    done
}

# ─── Нужен ли мастер при первом запуске? ────────────────────────────────────

setup_needs_wizard() {
    local ip
    ip=$(jq -r '.ip // ""' "$SERVER_JSON" 2>/dev/null || echo "")
    [[ -z "$ip" || "$ip" == "null" ]]
}
