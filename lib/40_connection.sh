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

# URL-кодирование строки (для URI)
_urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0; pos<strlen; pos++ )); do
        c="${string:$pos:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) o="$c" ;;
            *) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    printf '%s' "$encoded"
}

# Читает общие параметры Hysteria2 для генерации URI и конфига
_connection_hysteria2_params() {
    local user_name="$1"

    HY2_PASSWORD=$(jq -r --arg n "$user_name" \
        '.users[] | select(.name == $n) | .protocols.hysteria2.password' \
        "$USERS_JSON" 2>/dev/null)
    [[ -z "$HY2_PASSWORD" || "$HY2_PASSWORD" == "null" ]] && return 1

    HY2_SERVER_IP=$(get_server_ip)
    [[ -z "$HY2_SERVER_IP" ]] && HY2_SERVER_IP="YOUR_SERVER_IP"

    HY2_PORT=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON" 2>/dev/null || echo "8443")

    HY2_OBFS=$(jq -r '.hysteria2.obfs // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")
    HY2_OBFS_PASSWORD=$(jq -r '.hysteria2.obfs_password // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")

    HY2_PH_ENABLED=$(jq -r '.hysteria2.port_hopping // false' "$PROTOCOLS_JSON" 2>/dev/null || echo "false")
    HY2_PH_RANGE=""
    if [[ "$HY2_PH_ENABLED" == "true" ]]; then
        HY2_PH_RANGE=$(jq -r '.hysteria2.port_hopping_range // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")
    fi

    return 0
}

# Генерирует Hysteria2 URI для пользователя
_connection_hysteria2_uri() {
    local user_name="$1"

    _connection_hysteria2_params "$user_name" || return 1

    local obfs_params=""
    if [[ "$HY2_OBFS" == "salamander" && -n "$HY2_OBFS_PASSWORD" ]]; then
        obfs_params="&obfs=salamander&obfs-password=$(_urlencode "$HY2_OBFS_PASSWORD")"
    fi

    local mport_params=""
    if [[ "$HY2_PH_ENABLED" == "true" && -n "$HY2_PH_RANGE" ]]; then
        mport_params="&mport=${HY2_PH_RANGE}"
    fi

    printf 'hysteria2://%s:%s@%s:%s/?insecure=1%s%s#%s' \
        "$(_urlencode "$user_name")" "$(_urlencode "$HY2_PASSWORD")" \
        "$HY2_SERVER_IP" "$HY2_PORT" "$obfs_params" "$mport_params" "$user_name"
}

# Генерирует Hysteria2 клиентский конфиг (YAML) для пользователя
_connection_hysteria2_config() {
    local user_name="$1"

    _connection_hysteria2_params "$user_name" || return 1

    local server_addr="${HY2_SERVER_IP}:${HY2_PORT}"

    # Если port hopping — указываем диапазон портов
    if [[ "$HY2_PH_ENABLED" == "true" && -n "$HY2_PH_RANGE" ]]; then
        server_addr="${HY2_SERVER_IP}:${HY2_PORT},${HY2_PH_RANGE}"
    fi

    local config=""
    config+="server: ${server_addr}"$'\n'
    config+=""$'\n'
    config+="auth: ${user_name}:${HY2_PASSWORD}"$'\n'
    config+=""$'\n'
    config+="tls:"$'\n'
    config+="  insecure: true"$'\n'

    if [[ "$HY2_OBFS" == "salamander" && -n "$HY2_OBFS_PASSWORD" ]]; then
        config+=""$'\n'
        config+="obfs:"$'\n'
        config+="  type: salamander"$'\n'
        config+="  salamander:"$'\n'
        config+="    password: ${HY2_OBFS_PASSWORD}"$'\n'
    fi

    printf '%s' "$config"
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

    local vless_uri hysteria_uri hysteria_conf
    vless_uri=$(_connection_vless_uri    "$user_name" 2>/dev/null || echo "")
    hysteria_uri=$(_connection_hysteria2_uri "$user_name" 2>/dev/null || echo "")
    hysteria_conf=$(_connection_hysteria2_config "$user_name" 2>/dev/null || echo "")

    local amnezia_conf=""
    local amnezia_peer_dir="/etc/amneziawg/peers/$user_name"
    if [[ -f "$amnezia_peer_dir/client.conf" ]]; then
        amnezia_conf="$amnezia_peer_dir/client.conf"
    fi

    # Собираем пункты меню действий
    local menu_items=()
    [[ -n "$vless_uri" ]]    && menu_items+=("v" "Показать VLESS+XHTTP ссылку")
    [[ -n "$hysteria_uri" ]] && menu_items+=("h" "Показать Hysteria 2 ссылку (URI)")
    [[ -n "$hysteria_conf" ]] && menu_items+=("H" "Показать Hysteria 2 конфиг (YAML)")
    [[ -n "$amnezia_conf" ]] && menu_items+=("a" "Показать AmneziaWG конфиг")

    local has_qr=false
    is_installed "qrencode" && has_qr=true

    if $has_qr; then
        [[ -n "$vless_uri" ]]    && menu_items+=("1" "QR-код VLESS+XHTTP")
        [[ -n "$hysteria_uri" ]] && menu_items+=("2" "QR-код Hysteria 2 (URI)")
        [[ -n "$hysteria_conf" ]] && menu_items+=("3" "QR-код Hysteria 2 (конфиг)")
        [[ -n "$amnezia_conf" ]] && menu_items+=("4" "QR-код AmneziaWG")
    fi

    [[ -n "$vless_uri" || -n "$hysteria_uri" ]] && menu_items+=("c" "Все ссылки в терминал (для копирования)")
    [[ -n "$hysteria_conf" || -n "$amnezia_conf" ]] && menu_items+=("s" "Сохранить конфиги в файлы")
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
                _connection_show_uri_in_terminal "$hysteria_uri" "Hysteria 2 (URI)" "$user_name"
                ;;
            H)
                _connection_show_config_in_terminal "$hysteria_conf" "Hysteria 2 (YAML конфиг)" "$user_name"
                ;;
            a)
                local awg_content
                awg_content=$(cat "$amnezia_conf" 2>/dev/null)
                _connection_show_config_in_terminal "$awg_content" "AmneziaWG" "$user_name"
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
                _show_qr "$hysteria_uri" "Hysteria 2 (URI) — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            3)
                clear
                _show_qr "$hysteria_conf" "Hysteria 2 (конфиг) — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            4)
                clear
                _show_qr_file "$amnezia_conf" "AmneziaWG — $user_name"
                echo ""
                echo "Нажмите Enter для возврата..."
                read -r
                ;;
            s)
                _connection_save_configs "$user_name" "$hysteria_conf" "$amnezia_conf"
                ;;
            c)
                _connection_print_all_uris "$user_name" "$vless_uri" "$hysteria_uri" "$hysteria_conf"
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

# Показывает конфиг в терминале для удобного копирования
_connection_show_config_in_terminal() {
    local config_content="$1" label="$2" user_name="$3"
    clear
    echo "═══ $label — $user_name ═══"
    echo ""
    echo "Скопируйте конфиг ниже (выделите мышью):"
    echo ""
    echo "────────────────────────────────────────"
    echo "$config_content"
    echo "────────────────────────────────────────"
    echo ""
    # Попытка скопировать в буфер обмена
    if command -v xclip >/dev/null 2>&1; then
        printf '%s' "$config_content" | xclip -selection clipboard 2>/dev/null && echo "[Скопировано в буфер обмена]"
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$config_content" | xsel --clipboard 2>/dev/null && echo "[Скопировано в буфер обмена]"
    elif command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$config_content" | pbcopy 2>/dev/null && echo "[Скопировано в буфер обмена]"
    fi
    echo ""
    echo "Нажмите Enter для возврата..."
    read -r
}

# Сохраняет конфиги в файлы для скачивания (scp/sftp)
_connection_save_configs() {
    local user_name="$1" hysteria_conf="$2" amnezia_conf_path="$3"
    local save_dir="/tmp/vpnmgr_configs_${user_name}"
    mkdir -p "$save_dir"
    local saved_files=()

    if [[ -n "$hysteria_conf" ]]; then
        printf '%s\n' "$hysteria_conf" > "$save_dir/hysteria2_${user_name}.yaml"
        saved_files+=("$save_dir/hysteria2_${user_name}.yaml")
    fi

    if [[ -n "$amnezia_conf_path" && -f "$amnezia_conf_path" ]]; then
        cp "$amnezia_conf_path" "$save_dir/amneziawg_${user_name}.conf"
        saved_files+=("$save_dir/amneziawg_${user_name}.conf")
    fi

    if [[ ${#saved_files[@]} -eq 0 ]]; then
        ui_msgbox "Нет конфигов для сохранения."
        return
    fi

    local msg="Конфиги сохранены:\n\n"
    for f in "${saved_files[@]}"; do
        msg+="  $f\n"
    done
    msg+="\nСкачайте через scp:\n"
    msg+="  scp root@$(get_server_ip):${save_dir}/* ."
    ui_msgbox "$msg" "Сохранённые конфиги"
}

# Выводит все ссылки и конфиги в терминал
_connection_print_all_uris() {
    local user_name="$1" vless_uri="$2" hysteria_uri="$3" hysteria_conf="${4:-}"
    clear
    echo "═══ Все ссылки подключения: $user_name ═══"
    echo ""
    if [[ -n "$vless_uri" ]]; then
        echo "── VLESS+XHTTP (URI) ──"
        echo "$vless_uri"
        echo ""
    fi
    if [[ -n "$hysteria_uri" ]]; then
        echo "── Hysteria 2 (URI) ──"
        echo "$hysteria_uri"
        echo ""
    fi
    if [[ -n "$hysteria_conf" ]]; then
        echo "── Hysteria 2 (YAML конфиг) ──"
        echo "$hysteria_conf"
        echo ""
    fi
    echo "────────────────────────────────────────"
    echo "Выделите нужную ссылку/конфиг мышью для копирования."
    echo ""
    echo "Нажмите Enter для возврата..."
    read -r
}
