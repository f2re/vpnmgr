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
            connect_to="$hostname"
            extra_params="&sni=${hostname}"
        else
            extra_params="&allowInsecure=1"
        fi
        # NB: flow НЕ указываем — xtls-rprx-vision несовместим с xhttp транспортом
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

    # Port hopping: добавляем mport если включён
    local mport_params=""
    local ph_enabled
    ph_enabled=$(jq -r '.hysteria2.port_hopping // false' "$PROTOCOLS_JSON" 2>/dev/null || echo "false")
    if [[ "$ph_enabled" == "true" ]]; then
        local ph_range
        ph_range=$(jq -r '.hysteria2.port_hopping_range // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")
        if [[ -n "$ph_range" ]]; then
            mport_params="&mport=${ph_range}"
        fi
    fi

    printf 'hysteria2://%s:%s@%s:%s/?insecure=1%s%s#%s' \
        "$user_name" "$password" "$server_ip" "$port" "$obfs_params" "$mport_params" "$user_name"
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

    if ! jq -e --arg n "$user_name" '.users[] | select(.name == $n)' \
            "$USERS_JSON" >/dev/null 2>&1; then
        ui_error "Пользователь '$user_name' не найден."
        return 1
    fi

    local vless_uri hysteria_uri
    vless_uri=$(_connection_vless_uri    "$user_name" 2>/dev/null || echo "")
    hysteria_uri=$(_connection_hysteria2_uri "$user_name" 2>/dev/null || echo "")

    local amnezia_conf=""
    local amnezia_peer_dir="/etc/amneziawg/peers/$user_name"
    if [[ -f "$amnezia_peer_dir/client.conf" ]]; then
        amnezia_conf="$amnezia_peer_dir/client.conf"
    fi

    # Собираем пункты меню действий
    local menu_items=()
    [[ -n "$vless_uri" ]]    && menu_items+=("v" "Показать VLESS+XHTTP ссылку")
    [[ -n "$hysteria_uri" ]] && menu_items+=("h" "Показать Hysteria 2 ссылку")
    [[ -n "$amnezia_conf" ]] && menu_items+=("a" "Показать AmneziaWG конфиг")

    local has_qr=false
    is_installed "qrencode" && has_qr=true

    if $has_qr; then
        [[ -n "$vless_uri" ]]    && menu_items+=("1" "QR-код VLESS+XHTTP")
        [[ -n "$hysteria_uri" ]] && menu_items+=("2" "QR-код Hysteria 2")
        [[ -n "$amnezia_conf" ]] && menu_items+=("3" "QR-код AmneziaWG")
    fi

    [[ -n "$vless_uri" || -n "$hysteria_uri" ]] && menu_items+=("c" "Все ссылки в терминал (для копирования)")
    menu_items+=("0" "Назад")

    if [[ ${#menu_items[@]} -eq 2 ]]; then
        # Только кнопка "Назад" — ничего не настроено
        ui_msgbox "Нет доступных протоколов для '$user_name'.\n\nУстановите и настройте протоколы через меню." \
            "Подключение: $user_name"
        return
    fi

    while true; do
        local choice
        choice=$(ui_menu "Подключение: $user_name" "${menu_items[@]}") || return

        case "$choice" in
            v)
                _connection_show_uri_in_terminal "$vless_uri" "VLESS+XHTTP" "$user_name"
                ;;
            h)
                _connection_show_uri_in_terminal "$hysteria_uri" "Hysteria 2" "$user_name"
                ;;
            a)
                clear
                echo "═══ AmneziaWG — $user_name ═══"
                echo ""
                cat "$amnezia_conf"
                echo ""
                echo "───────────────────────────────────"
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            1)
                clear
                _show_qr "$vless_uri" "VLESS+XHTTP — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            2)
                clear
                _show_qr "$hysteria_uri" "Hysteria 2 — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            3)
                clear
                _show_qr_file "$amnezia_conf" "AmneziaWG — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            c)
                _connection_print_all_uris "$user_name" "$vless_uri" "$hysteria_uri"
                ;;
            0) return ;;
        esac
    done
}

# Показывает одну URI в терминале для удобного копирования
_connection_show_uri_in_terminal() {
    local uri="$1" label="$2" user_name="$3"
    clear
    echo "═══ $label — $user_name ═══"
    echo ""
    echo "Скопируйте ссылку ниже (выделите мышью или тройной клик):"
    echo ""
    echo "────────────────────────────────────────"
    echo "$uri"
    echo "────────────────────────────────────────"
    echo ""
    # Попытка скопировать в буфер обмена
    if command -v xclip >/dev/null 2>&1; then
        printf '%s' "$uri" | xclip -selection clipboard 2>/dev/null && echo "[Скопировано в буфер обмена]"
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$uri" | xsel --clipboard 2>/dev/null && echo "[Скопировано в буфер обмена]"
    elif command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$uri" | pbcopy 2>/dev/null && echo "[Скопировано в буфер обмена]"
    fi
    echo ""
    echo "Нажмите Enter для возврата..."
    read -r
}

# Выводит все ссылки в терминал
_connection_print_all_uris() {
    local user_name="$1" vless_uri="$2" hysteria_uri="$3"
    clear
    echo "═══ Все ссылки подключения: $user_name ═══"
    echo ""
    if [[ -n "$vless_uri" ]]; then
        echo "── VLESS+XHTTP ──"
        echo "$vless_uri"
        echo ""
    fi
    if [[ -n "$hysteria_uri" ]]; then
        echo "── Hysteria 2 ──"
        echo "$hysteria_uri"
        echo ""
    fi
    echo "────────────────────────────────────────"
    echo "Выделите нужную ссылку мышью для копирования."
    echo ""
    echo "Нажмите Enter для возврата..."
    read -r
}
