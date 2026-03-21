#!/usr/bin/env bash

# lib/20_users.sh - CRUD пользователей

user_list() {
    # Чтение из users.json через jq
    local users
    users=$(jq -r '.users[] | "\(.name) [\(.enabled)]"' "$USERS_JSON")
    ui_msgbox "Список пользователей:\n\n$users" "Пользователи"
}

user_add() {
    local name
    name=$(ui_input "Введите имя нового пользователя:" "user_$(date +%s)")
    [[ -z "$name" ]] && return

    # Генерация данных
    local uuid=$(gen_uuid)
    local password=$(gen_password)

    # Запись в JSON
    jq --arg n "$name" --arg u "$uuid" --arg p "$password" \
       '.users += [{"name": $n, "id": "usr_"+($n), "enabled": true, "protocols": {"vless": {"uuid": $u, "enabled": true}, "hysteria2": {"password": $p, "enabled": true}}}]' \
       "$USERS_JSON" > "${USERS_JSON}.tmp" && mv "${USERS_JSON}.tmp" "$USERS_JSON"

    ui_msgbox "Пользователь $name добавлен успешно!"
}

user_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Управление пользователями" \
            "1" "Список пользователей" \
            "2" "Добавить пользователя" \
            "3" "Удалить пользователя" \
            "0" "Назад") || break

        case "$choice" in
            1) user_list ;;
            2) user_add ;;
            0) return ;;
            *) ui_msgbox "Функция в разработке" ;;
        esac
    done
}
