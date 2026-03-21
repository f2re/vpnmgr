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

    # URL-кодируем путь (замена / на %2F не нужна в этом контексте)
    # Формат: vless://uuid@host:port?encryption=none&type=xhttp&path=/xxx#name
    printf 'vless://%s@%s:%s?encryption=none&type=xhttp&path=%s#%s' \
        "$uuid" "$server_ip" "$port" "$xhttp_path" "$user_name"
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

    printf 'hysteria2://%s@%s:%s?insecure=1#%s' \
        "$password" "$server_ip" "$port" "$user_name"
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

    # Строим сообщение
    local msg="=== Подключение: $user_name ===\n\n"

    if [[ -n "$vless_uri" ]]; then
        msg+="VLESS+XHTTP:\n$vless_uri\n\n"
    else
        msg+="VLESS: нет данных (Xray не настроен?)\n\n"
    fi

    if [[ -n "$hysteria_uri" ]]; then
        msg+="Hysteria 2:\n$hysteria_uri"
    else
        msg+="Hysteria 2: нет данных (Hysteria не настроена?)"
    fi

    ui_msgbox "$msg" "Подключение: $user_name"

    # Предлагаем QR если qrencode доступен
    if is_installed "qrencode" && [[ -n "$vless_uri" || -n "$hysteria_uri" ]]; then
        local qr_choice
        qr_choice=$(ui_menu "Показать QR-код:" \
            "1" "QR для VLESS+XHTTP" \
            "2" "QR для Hysteria 2" \
            "0" "Назад") || return

        clear
        case "$qr_choice" in
            1)
                if [[ -n "$vless_uri" ]]; then
                    _show_qr "$vless_uri" "VLESS+XHTTP — $user_name"
                    echo "URI: $vless_uri"
                else
                    echo "VLESS URI недоступен."
                fi
                ;;
            2)
                if [[ -n "$hysteria_uri" ]]; then
                    _show_qr "$hysteria_uri" "Hysteria 2 — $user_name"
                    echo "URI: $hysteria_uri"
                else
                    echo "Hysteria 2 URI недоступен."
                fi
                ;;
            0) return ;;
        esac

        echo ""
        echo "Нажмите Enter для возврата в меню..."
        read -r
    fi
}
