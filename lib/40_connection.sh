#!/usr/bin/env bash

# lib/40_connection.sh - Инструкции и QR-коды подключения

# Генерирует VLESS URI для пользователя
_connection_vless_uri() {
    local user_name="$1"

    local uuid
    uuid=$(jq -r --arg n "$user_name" \
        '.users[] | select(.name == $n) | .protocols.vless.uuid' \
        "$USERS_JSON" 2>/dev/null)
    [[ -z "$uuid" || "$uuid" == "null" ]] && return 1

    local server_ip
    server_ip=$(get_server_ip)
    [[ -z "$server_ip" ]] && server_ip="YOUR_SERVER_IP"

    local port
    port=$(jq -r '.xray.port // 443' "$PROTOCOLS_JSON" 2>/dev/null || echo "443")

    local xhttp_path="/"
    if [[ -f "$XRAY_CONFIG" ]]; then
        xhttp_path=$(jq -r \
            '.inbounds[0].streamSettings.xhttpSettings.path // "/"' \
            "$XRAY_CONFIG" 2>/dev/null || echo "/")
    fi

    # Определяем security: tls если сертификат настроен
    local security="none"
    local extra_params=""
    local connect_to="$server_ip"

    local cert_path hostname
    cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
    hostname=$(jq -r '.hostname // ""' "$SERVER_JSON" 2>/dev/null || echo "")

    if [[ -n "$cert_path" && -f "$cert_path" ]]; then
        security="tls"
        if [[ -n "$hostname" && "$hostname" != "null" ]]; then
            # Подключаемся по домену — правильный SNI, сертификат валиден
            connect_to="$hostname"
            extra_params="&sni=${hostname}"
        else
            # Самоподписанный без домена — нужен insecure
            extra_params="&allowInsecure=1"
        fi
        # VLESS Vision требует TLS
        extra_params="&flow=xtls-rprx-vision${extra_params}"
    fi

    printf 'vless://%s@%s:%s?encryption=none&security=%s&type=xhttp&path=%s%s#%s' \
        "$uuid" "$connect_to" "$port" "$security" "$xhttp_path" "$extra_params" "$user_name"
}

# Генерирует Hysteria2 URI для пользователя
_connection_hysteria2_uri() {
    local user_name="$1"

    local password
    password=$(jq -r --arg n "$user_name" \
        '.users[] | select(.name == $n) | .protocols.hysteria2.password' \
        "$USERS_JSON" 2>/dev/null)
    [[ -z "$password" || "$password" == "null" ]] && return 1

    local server_ip
    server_ip=$(get_server_ip)
    [[ -z "$server_ip" ]] && server_ip="YOUR_SERVER_IP"

    local port
    port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON" 2>/dev/null || echo "8443")

    local obfs obfs_password obfs_params=""
    obfs=$(jq -r '.hysteria2.obfs // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")
    obfs_password=$(jq -r '.hysteria2.obfs_password // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")
    if [[ "$obfs" == "salamander" && -n "$obfs_password" ]]; then
        obfs_params="&obfs=salamander&obfs-password=${obfs_password}"
    fi

    printf 'hysteria2://%s:%s@%s:%s?insecure=1%s#%s' \
        "$user_name" "$password" "$server_ip" "$port" "$obfs_params" "$user_name"
}

# Показывает QR-код в терминале
_show_qr() {
    local uri="$1"
    local label="${2:-}"

    if ! is_installed "qrencode"; then
        echo "(qrencode не установлен — QR недоступен)"
        return
    fi

    [[ -n "$label" ]] && echo "=== $label ==="
    qrencode -t ANSIUTF8 -o - "$uri" 2>/dev/null || echo "(ошибка генерации QR)"
    echo ""
}

# Показывает QR-код из файла
_show_qr_file() {
    local file="$1"
    local label="${2:-}"

    if ! is_installed "qrencode"; then
        echo "(qrencode не установлен — QR недоступен)"
        return
    fi

    [[ -n "$label" ]] && echo "=== $label ==="
    qrencode -t ANSIUTF8 -o - < "$file" 2>/dev/null || echo "(ошибка генерации QR)"
    echo ""
}

connection_show() {
    local user_name="$1"

    if [[ ! -f "$USERS_JSON" ]]; then
        ui_error "Файл пользователей не найден."
        return 1
    fi

    # Проверяем что пользователь существует
    if ! jq -e --arg n "$user_name" '.users[] | select(.name == $n)' \
            "$USERS_JSON" >/dev/null 2>&1; then
        ui_error "Пользователь '$user_name' не найден."
        return 1
    fi

    local vless_uri hysteria_uri
    vless_uri=$(_connection_vless_uri    "$user_name" 2>/dev/null || echo "")
    hysteria_uri=$(_connection_hysteria2_uri "$user_name" 2>/dev/null || echo "")

    # Проверяем AmneziaWG пир
    local amnezia_conf=""
    local amnezia_peer_dir="/etc/amneziawg/peers/$user_name"
    if [[ -f "$amnezia_peer_dir/client.conf" ]]; then
        amnezia_conf="$amnezia_peer_dir/client.conf"
    fi

    # Строим сообщение
    local msg="=== Подключение: $user_name ===\n\n"

    if [[ -n "$vless_uri" ]]; then
        msg+="VLESS+XHTTP:\n$vless_uri\n\n"
    else
        msg+="VLESS: нет данных (Xray не настроен?)\n\n"
    fi

    if [[ -n "$hysteria_uri" ]]; then
        msg+="Hysteria 2:\n$hysteria_uri\n\n"
    else
        msg+="Hysteria 2: нет данных (Hysteria не настроена?)\n\n"
    fi

    if [[ -n "$amnezia_conf" ]]; then
        msg+="AmneziaWG: конфиг доступен (показать через QR)"
    else
        msg+="AmneziaWG: пир не создан"
    fi

    ui_msgbox "$msg" "Подключение: $user_name"

    # Предлагаем QR
    local has_qr=false
    is_installed "qrencode" && has_qr=true

    if $has_qr && [[ -n "$vless_uri" || -n "$hysteria_uri" || -n "$amnezia_conf" ]]; then
        # Собираем доступные варианты QR
        local qr_items=()
        [[ -n "$vless_uri" ]]    && qr_items+=("1" "QR для VLESS+XHTTP")
        [[ -n "$hysteria_uri" ]] && qr_items+=("2" "QR для Hysteria 2")
        [[ -n "$amnezia_conf" ]] && qr_items+=("3" "QR для AmneziaWG")
        qr_items+=("0" "Назад")

        local qr_choice
        qr_choice=$(ui_menu "Показать QR-код:" "${qr_items[@]}") || return

        clear
        case "$qr_choice" in
            1)
                if [[ -n "$vless_uri" ]]; then
                    _show_qr "$vless_uri" "VLESS+XHTTP — $user_name"
                    echo "URI: $vless_uri"
                fi
                ;;
            2)
                if [[ -n "$hysteria_uri" ]]; then
                    _show_qr "$hysteria_uri" "Hysteria 2 — $user_name"
                    echo "URI: $hysteria_uri"
                fi
                ;;
            3)
                if [[ -n "$amnezia_conf" ]]; then
                    _show_qr_file "$amnezia_conf" "AmneziaWG — $user_name"
                    echo ""
                    cat "$amnezia_conf"
                fi
                ;;
            0) return ;;
        esac

        echo ""
        echo "Нажмите Enter для возврата в меню..."
        read -r
    fi
}
