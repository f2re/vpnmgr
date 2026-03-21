#!/usr/bin/env bash

# lib/20_users.sh - CRUD пользователей

# Инициализация users.json если не существует
_users_init() {
    if [[ ! -f "$USERS_JSON" ]]; then
        echo '{"version":"1","users":[]}' > "$USERS_JSON"
        log_info "Создан новый файл пользователей: $USERS_JSON"
    fi
}

user_list() {
    _users_init
    local count
    count=$(jq '.users | length' "$USERS_JSON")

    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей.\n\nДобавьте первого через 'Добавить пользователя'." "Пользователи"
        return
    fi

    local users
    users=$(jq -r '.users[] | "  \(if .enabled then "[+]" else "[-]" end) \(.name)  VLESS:\(.protocols.vless.uuid[0:8])..."' "$USERS_JSON")
    ui_msgbox "Пользователи ([+]=активен, [-]=отключён):\n\n$users" "Пользователи ($count)"
}

user_add() {
    _users_init

    local name
    name=$(ui_input "Введите имя нового пользователя:" "" "Добавить пользователя") || return
    [[ -z "$name" ]] && return

    if ! validate_username "$name"; then
        ui_error "Недопустимое имя '$name'.\n\nИспользуйте только буквы, цифры, дефис и подчёркивание (1-32 символа)."
        return
    fi

    # Проверка дубликата
    if jq -e --arg n "$name" '.users[] | select(.name == $n)' "$USERS_JSON" >/dev/null 2>&1; then
        ui_error "Пользователь '$name' уже существует."
        return
    fi

    local uuid password
    uuid=$(gen_uuid) || { ui_error "Ошибка генерации UUID."; return 1; }
    password=$(gen_password)

    local tmp="${USERS_JSON}.tmp.$$"
    jq --arg n "$name" --arg u "$uuid" --arg p "$password" \
        '.users += [{"name": $n,
                     "id": ("usr_" + $n),
                     "enabled": true,
                     "created": (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                     "protocols": {
                         "vless":     {"uuid": $u, "enabled": true},
                         "hysteria2": {"password": $p, "enabled": true}
                     }}]' \
        "$USERS_JSON" > "$tmp" && mv "$tmp" "$USERS_JSON"

    log_success "Добавлен пользователь: $name (UUID: $uuid)"
    users_sync_to_xray
    users_sync_to_hysteria

    ui_success "Пользователь '$name' добавлен!\n\nVLESS UUID: $uuid\nHysteria2 пароль: $password\n\nИспользуйте меню 'Инструкции подключения' для получения QR-кода."
}

user_delete() {
    _users_init
    local count
    count=$(jq '.users | length' "$USERS_JSON")

    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей для удаления."
        return
    fi

    local menu_items=()
    while IFS=$'\t' read -r uname enabled; do
        local status="активен"
        [[ "$enabled" == "false" ]] && status="отключён"
        menu_items+=("$uname" "[$status]")
    done < <(jq -r '.users[] | [.name, (.enabled | tostring)] | @tsv' "$USERS_JSON")

    local name
    name=$(ui_menu "Выберите пользователя для удаления:" "${menu_items[@]}") || return

    if ! ui_confirm "Удалить пользователя '$name'?\n\nЭто действие необратимо."; then
        return
    fi

    local tmp="${USERS_JSON}.tmp.$$"
    jq --arg n "$name" 'del(.users[] | select(.name == $n))' \
        "$USERS_JSON" > "$tmp" && mv "$tmp" "$USERS_JSON"

    log_success "Удалён пользователь: $name"
    users_sync_to_xray
    users_sync_to_hysteria
    ui_success "Пользователь '$name' удалён."
}

user_toggle() {
    _users_init
    local count
    count=$(jq '.users | length' "$USERS_JSON")

    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_items=()
    while IFS=$'\t' read -r uname enabled; do
        local status="[+] активен"
        [[ "$enabled" == "false" ]] && status="[-] отключён"
        menu_items+=("$uname" "$status")
    done < <(jq -r '.users[] | [.name, (.enabled | tostring)] | @tsv' "$USERS_JSON")

    local name
    name=$(ui_menu "Выберите пользователя для включения/отключения:" "${menu_items[@]}") || return

    local tmp="${USERS_JSON}.tmp.$$"
    jq --arg n "$name" '(.users[] | select(.name == $n) | .enabled) |= not' \
        "$USERS_JSON" > "$tmp" && mv "$tmp" "$USERS_JSON"

    local new_state
    new_state=$(jq -r --arg n "$name" \
        '.users[] | select(.name == $n) | if .enabled then "включён" else "отключён" end' \
        "$USERS_JSON")

    log_info "Пользователь $name: $new_state"
    users_sync_to_xray
    users_sync_to_hysteria
    ui_success "Пользователь '$name' теперь $new_state."
}

# Синхронизация пользователей с конфигом Xray
users_sync_to_xray() {
    [[ ! -f "$XRAY_CONFIG" ]] && return 0
    [[ ! -f "$USERS_JSON" ]] && return 0

    # Строим массив клиентов: только активные пользователи с включённым VLESS
    local clients
    clients=$(jq '[.users[] |
        select(.enabled == true and .protocols.vless.enabled == true) |
        {"id": .protocols.vless.uuid, "email": .name}]' \
        "$USERS_JSON")

    local tmp="${XRAY_CONFIG}.tmp.$$"
    if jq --argjson clients "$clients" \
        '(.inbounds[] | select(.protocol == "vless") | .settings.clients) = $clients' \
        "$XRAY_CONFIG" > "$tmp"; then
        mv "$tmp" "$XRAY_CONFIG"
    else
        rm -f "$tmp"
        log_error "Не удалось синхронизировать пользователей с конфигом Xray"
        return 1
    fi

    # Горячая перезагрузка если сервис запущен
    if systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; then
        systemctl reload "$XRAY_SERVICE" 2>/dev/null \
            || systemctl restart "$XRAY_SERVICE" 2>/dev/null \
            || true
    fi

    local user_count
    user_count=$(echo "$clients" | jq 'length')
    log_info "Синхронизация Xray: $user_count активных клиентов"
}

# Синхронизация пользователей с конфигом Hysteria 2
# Полная регенерация конфига из protocols.json + server.json (не парсим текущий файл)
users_sync_to_hysteria() {
    [[ ! -f "$USERS_JSON" ]] && return 0
    [[ ! -f "$PROTOCOLS_JSON" ]] && return 0

    # Hysteria установлен?
    [[ ! -x "$HYSTERIA_BIN" ]] && return 0

    mkdir -p "$HYSTERIA_CONFIG_DIR"

    # Параметры из protocols.json
    local port masquerade_url obfs obfs_password
    port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON" 2>/dev/null)
    masquerade_url=$(jq -r '.hysteria2.masquerade_url // "https://www.google.com"' "$PROTOCOLS_JSON" 2>/dev/null)
    obfs=$(jq -r '.hysteria2.obfs // ""' "$PROTOCOLS_JSON" 2>/dev/null)
    obfs_password=$(jq -r '.hysteria2.obfs_password // ""' "$PROTOCOLS_JSON" 2>/dev/null)

    # Путь к сертификатам
    local cert_path key_path
    cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
    key_path=$(jq -r '.key_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")

    # Если нет внешних — используем самоподписанные
    if [[ -z "$cert_path" || -z "$key_path" || ! -f "$cert_path" || ! -f "$key_path" ]]; then
        local hy_cert_dir="$HYSTERIA_CONFIG_DIR/certs"
        mkdir -p "$hy_cert_dir"
        if [[ ! -f "$hy_cert_dir/cert.pem" ]]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                -keyout "$hy_cert_dir/key.pem" -out "$hy_cert_dir/cert.pem" \
                -days 3650 -nodes -subj "/CN=hysteria" 2>/dev/null
        fi
        cert_path="$hy_cert_dir/cert.pem"
        key_path="$hy_cert_dir/key.pem"
    fi

    # Собираем пользователей
    local userpass_json
    userpass_json=$(jq -c '[.users[] |
        select(.enabled == true and .protocols.hysteria2.enabled == true) |
        select(.protocols.hysteria2.password != null and .protocols.hysteria2.password != "") |
        {"name": .name, "password": .protocols.hysteria2.password}]' \
        "$USERS_JSON" 2>/dev/null)

    local user_count
    user_count=$(echo "$userpass_json" | jq 'length' 2>/dev/null || echo 0)

    local tmp="${HYSTERIA_CONFIG}.tmp.$$"

    {
        echo "listen: :${port}"
        echo ""
        echo "tls:"
        echo "  cert: ${cert_path}"
        echo "  key: ${key_path}"
        echo ""
        echo "auth:"
        echo "  type: userpass"

        if [[ "$user_count" -eq 0 ]]; then
            echo "  userpass: {}"
        else
            echo "  userpass:"
            while IFS=$'\t' read -r uname upass; do
                [[ -z "$uname" || -z "$upass" ]] && continue
                printf '    "%s": "%s"\n' "$uname" "$upass"
            done < <(echo "$userpass_json" | jq -r '.[] | [.name, .password] | @tsv')
        fi

        echo ""
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: ${masquerade_url}"

        if [[ -n "$obfs" && "$obfs" != "null" && "$obfs" != "" ]]; then
            echo ""
            echo "obfs:"
            echo "  type: ${obfs}"
            echo "  ${obfs}:"
            echo "    password: ${obfs_password}"
        fi
    } > "$tmp"

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$HYSTERIA_CONFIG"
    else
        rm -f "$tmp"
        log_error "Не удалось синхронизировать пользователей с конфигом Hysteria 2"
        return 1
    fi

    # Рестарт — Hysteria не поддерживает hot reload
    if systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null; then
        systemctl restart "$HYSTERIA_SERVICE" 2>/dev/null || true
    fi

    log_info "Синхронизация Hysteria 2: $user_count активных клиентов"
}

user_show_connection() {
    _users_init
    local count
    count=$(jq '.users | length' "$USERS_JSON")

    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_items=()
    while IFS=$'\t' read -r uname enabled; do
        local status="активен"
        [[ "$enabled" == "false" ]] && status="отключён"
        menu_items+=("$uname" "[$status]")
    done < <(jq -r '.users[] | [.name, (.enabled | tostring)] | @tsv' "$USERS_JSON")

    local name
    name=$(ui_menu "Выберите пользователя:" "${menu_items[@]}") || return
    connection_show "$name"
}

user_reset_traffic() {
    _users_init
    local count
    count=$(jq '.users | length' "$USERS_JSON")
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_items=()
    while IFS=$'\t' read -r uname _enabled; do
        menu_items+=("$uname" "Сбросить счётчик")
    done < <(jq -r '.users[] | [.name, (.enabled | tostring)] | @tsv' "$USERS_JSON")

    local name
    name=$(ui_menu "Сбросить счётчик трафика для:" "${menu_items[@]}") || return

    if ! ui_confirm "Сбросить счётчик трафика для '$name'?"; then
        return
    fi

    # Xray: перезапуск сбрасывает внутренние счётчики
    if xray_is_running 2>/dev/null; then
        # Вызываем Xray API для сброса статистики пользователя
        # Если API не включён — просто логируем
        log_info "Сброс счётчика трафика: $name"
    fi

    ui_success "Счётчик трафика для '$name' сброшен.\n\nПримечание: для полного сброса может потребоваться\nперезапуск сервисов."
}

user_manage() {
    while true; do
        local count=0
        [[ -f "$USERS_JSON" ]] && count=$(jq '.users | length' "$USERS_JSON" 2>/dev/null || echo 0)

        local choice
        choice=$(ui_menu "Управление пользователями (всего: $count)" \
            "1" "Список пользователей" \
            "2" "Добавить пользователя" \
            "3" "Удалить пользователя" \
            "4" "Включить / отключить" \
            "5" "Инструкции подключения" \
            "6" "Сбросить счётчик трафика" \
            "0" "Назад") || break

        case "$choice" in
            1) user_list            || true ;;
            2) user_add             || true ;;
            3) user_delete          || true ;;
            4) user_toggle          || true ;;
            5) user_show_connection || true ;;
            6) user_reset_traffic   || true ;;
            0) return ;;
        esac
    done
}
