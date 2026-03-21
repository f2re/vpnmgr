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
            "0" "Назад") || break

        case "$choice" in
            1) user_list ;;
            2) user_add ;;
            3) user_delete ;;
            4) user_toggle ;;
            5) user_show_connection ;;
            0) return ;;
        esac
    done
}
