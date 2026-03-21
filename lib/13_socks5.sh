#!/usr/bin/env bash

# lib/13_socks5.sh - Полноценный SOCKS5 прокси сервер через dante (danted)

SOCKS5_DEFAULT_PORT=1080
SOCKS5_SERVICE="danted"
SOCKS5_CONFIG="/etc/danted.conf"
SOCKS5_LOG="/var/log/danted.log"
SOCKS5_USERS_JSON="$DATA_DIR/socks5_users.json"

# ─── Вспомогательные ────────────────────────────────────────────────────────

_socks5_users_init() {
    if [[ ! -f "$SOCKS5_USERS_JSON" ]]; then
        mkdir -p "$DATA_DIR"
        echo '{"users":[]}' > "$SOCKS5_USERS_JSON"
    fi
}

_socks5_get_interface() {
    # Определяем внешний сетевой интерфейс
    ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

_socks5_get_port() {
    if [[ -f "$SOCKS5_CONFIG" ]]; then
        grep -oP '(?<=port = )\d+' "$SOCKS5_CONFIG" 2>/dev/null | head -1
    fi
}

socks5_is_installed() {
    command -v danted >/dev/null 2>&1
}

socks5_is_running() {
    systemctl is-active --quiet "$SOCKS5_SERVICE" 2>/dev/null
}

# ─── Установка / Удаление ───────────────────────────────────────────────────

socks5_install() {
    if socks5_is_installed; then
        ui_msgbox "dante-server уже установлен."
        return
    fi

    local port
    port=$(ui_input "Порт SOCKS5:" "$SOCKS5_DEFAULT_PORT" "SOCKS5 установка") || return
    [[ -z "$port" ]] && return

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        ui_error "Некорректный порт."
        return
    fi

    if ! check_port_available "$port"; then
        ui_error "Порт $port уже занят."
        return
    fi

    {
        echo "10"
        echo "XXX"
        echo "Обновление списка пакетов..."
        echo "XXX"
        apt-get update -qq 2>/dev/null
        echo "40"
        echo "XXX"
        echo "Установка dante-server..."
        echo "XXX"
        apt-get install -y dante-server 2>/dev/null
        echo "70"
        echo "XXX"
        echo "Настройка конфигурации..."
        echo "XXX"
        socks5_write_config "$port"
        echo "90"
        echo "XXX"
        echo "Запуск сервиса..."
        echo "XXX"
        systemctl enable "$SOCKS5_SERVICE" 2>/dev/null || true
        systemctl restart "$SOCKS5_SERVICE" 2>/dev/null || true
        _socks5_users_init
        echo "100"
    } | ui_progress "Установка SOCKS5 (dante)"

    log_info "SOCKS5 (danted) установлен на порту $port"
    ui_success "SOCKS5 сервер установлен!\n\nПорт: $port\nАвторизация: username/password\n\nДобавьте пользователей через меню управления."
}

socks5_uninstall() {
    if ! socks5_is_installed; then
        ui_msgbox "dante-server не установлен."
        return
    fi

    if ! ui_confirm "Удалить SOCKS5 сервер (danted) и всех пользователей?"; then
        return
    fi

    # Удаляем всех socks5-пользователей системы
    _socks5_users_init
    local users
    users=$(jq -r '.users[].username' "$SOCKS5_USERS_JSON" 2>/dev/null)
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        userdel "$u" 2>/dev/null || true
    done <<< "$users"

    systemctl stop "$SOCKS5_SERVICE"    2>/dev/null || true
    systemctl disable "$SOCKS5_SERVICE" 2>/dev/null || true
    apt-get remove -y dante-server      2>/dev/null || true
    rm -f "$SOCKS5_CONFIG" "$SOCKS5_USERS_JSON"

    log_info "SOCKS5 (danted) удалён"
    ui_success "SOCKS5 сервер удалён."
}

# ─── Конфигурация ───────────────────────────────────────────────────────────

socks5_write_config() {
    local port="${1:-$SOCKS5_DEFAULT_PORT}"
    local iface
    iface=$(_socks5_get_interface)
    [[ -z "$iface" ]] && iface="eth0"

    cat > "$SOCKS5_CONFIG" <<EOF
logoutput: $SOCKS5_LOG

# Внутренний интерфейс — принимаем подключения
internal: 0.0.0.0 port = $port

# Внешний интерфейс — исходящий трафик
external: $iface

# Метод аутентификации клиентов
clientmethod: none
socksmethod: username

# Пользователи демона
user.privileged: root
user.unprivileged: nobody

# Разрешаем клиентские подключения с любого адреса
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

# SOCKS5 с аутентификацией
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    log: error connect disconnect
}
EOF
}

socks5_change_port() {
    if ! socks5_is_installed; then
        ui_msgbox "dante-server не установлен."
        return
    fi

    local current_port
    current_port=$(_socks5_get_port)

    local port
    port=$(ui_input "Новый порт SOCKS5:" "${current_port:-$SOCKS5_DEFAULT_PORT}" "Смена порта") || return
    [[ -z "$port" ]] && return

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        ui_error "Некорректный порт."
        return
    fi

    if [[ "$port" == "$current_port" ]]; then
        ui_msgbox "Порт уже установлен: $port"
        return
    fi

    if ! check_port_available "$port"; then
        ui_error "Порт $port уже занят."
        return
    fi

    socks5_write_config "$port"

    if socks5_is_running; then
        systemctl restart "$SOCKS5_SERVICE" 2>/dev/null || true
    fi

    log_info "SOCKS5: порт изменён с $current_port на $port"
    ui_success "Порт изменён: $port"
}

# ─── Управление сервисом ────────────────────────────────────────────────────

socks5_start_stop() {
    if ! socks5_is_installed; then
        ui_msgbox "dante-server не установлен."
        return
    fi

    if socks5_is_running; then
        if ui_confirm "Остановить SOCKS5 сервер?"; then
            systemctl stop "$SOCKS5_SERVICE"
            ui_success "SOCKS5 сервер остановлен."
        fi
    else
        systemctl start "$SOCKS5_SERVICE" 2>/dev/null
        if socks5_is_running; then
            ui_success "SOCKS5 сервер запущен."
        else
            ui_error "Не удалось запустить SOCKS5.\n\nПроверьте логи:\n  journalctl -u danted -n 30"
        fi
    fi
}

# ─── Пользователи ───────────────────────────────────────────────────────────

socks5_user_add() {
    _socks5_users_init

    local username
    username=$(ui_input "Имя пользователя:" "" "SOCKS5 — новый пользователь") || return
    [[ -z "$username" ]] && return

    if ! validate_username "$username"; then
        ui_error "Некорректное имя пользователя.\n\nДопустимо: a-z, 0-9, _, дефис. От 2 до 32 символов."
        return
    fi

    # Проверяем дубликат
    if jq -e --arg u "$username" '.users[] | select(.username == $u)' "$SOCKS5_USERS_JSON" >/dev/null 2>&1; then
        ui_error "Пользователь '$username' уже существует."
        return
    fi

    local password
    password=$(ui_password "Пароль для '$username':\n(оставьте пустым — сгенерировать автоматически)" "Пароль SOCKS5")
    if [[ -z "$password" ]]; then
        password=$(gen_password 16)
    fi

    # Создаём системного пользователя без домашней директории и без шелла
    if id "$username" &>/dev/null; then
        ui_error "Системный пользователь '$username' уже существует (но не в базе vpnmgr).\nВыберите другое имя."
        return
    fi

    useradd -M -s /usr/sbin/nologin "$username" 2>/dev/null || {
        ui_error "Ошибка создания системного пользователя."
        return
    }

    # Устанавливаем пароль
    echo "${username}:${password}" | chpasswd 2>/dev/null || {
        userdel "$username" 2>/dev/null || true
        ui_error "Ошибка установки пароля."
        return
    }

    # Сохраняем в JSON (пароль в открытом виде для отображения клиенту)
    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
    jq --arg u "$username" --arg p "$password" --arg t "$created_at" \
        '.users += [{"username": $u, "password": $p, "created_at": $t, "enabled": true}]' \
        "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"

    log_info "SOCKS5: пользователь '$username' добавлен"

    local server_ip
    server_ip=$(get_server_ip)
    local port
    port=$(_socks5_get_port)

    ui_success "Пользователь добавлен!\n\nЛогин:  $username\nПароль: $password\n\n--- Подключение ---\n\ncurl:\n  curl --socks5 $username:$password@$server_ip:$port https://example.com\n\nПеременная окружения:\n  export ALL_PROXY=socks5://$username:$password@$server_ip:$port"
}

socks5_user_delete() {
    _socks5_users_init

    local count
    count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    # Формируем список для меню
    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SOCKS5_USERS_JSON")

    local username
    username=$(ui_menu "Выберите пользователя для удаления:" "${menu_args[@]}") || return
    [[ -z "$username" ]] && return

    if ! ui_confirm "Удалить пользователя '$username'?"; then
        return
    fi

    # Удаляем системного пользователя
    userdel "$username" 2>/dev/null || true

    # Удаляем из JSON
    local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
    jq --arg u "$username" 'del(.users[] | select(.username == $u))' \
        "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"

    log_info "SOCKS5: пользователь '$username' удалён"
    ui_success "Пользователь '$username' удалён."
}

socks5_user_toggle() {
    _socks5_users_init

    local count
    count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SOCKS5_USERS_JSON")

    local username
    username=$(ui_menu "Выберите пользователя:" "${menu_args[@]}") || return
    [[ -z "$username" ]] && return

    local current_enabled
    current_enabled=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .enabled' "$SOCKS5_USERS_JSON")

    if [[ "$current_enabled" == "true" ]]; then
        # Блокируем: меняем шелл на /bin/false и блокируем пароль
        usermod -s /bin/false "$username" 2>/dev/null || true
        passwd -l "$username" 2>/dev/null || true

        local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = false' \
            "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"
        ui_success "Пользователь '$username' отключён."
    else
        # Разблокируем
        usermod -s /usr/sbin/nologin "$username" 2>/dev/null || true
        passwd -u "$username" 2>/dev/null || true

        local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = true' \
            "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"
        ui_success "Пользователь '$username' включён."
    fi

    log_info "SOCKS5: пользователь '$username' — статус изменён"
}

socks5_users_list() {
    _socks5_users_init

    local count
    count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Пользователей нет.\n\nДобавьте первого пользователя через меню."
        return
    fi

    local info="Пользователи SOCKS5 ($count):\n\n"
    while IFS=$'\t' read -r username password enabled created; do
        local status="вкл"
        [[ "$enabled" == "false" ]] && status="ВЫКЛ"
        info+="  ● $username [$status]\n"
        info+="    Пароль: $password\n"
        info+="    Добавлен: $created\n\n"
    done < <(jq -r '.users[] | [.username, .password, (.enabled | tostring), .created_at] | @tsv' "$SOCKS5_USERS_JSON")

    local server_ip
    server_ip=$(get_server_ip)
    local port
    port=$(_socks5_get_port)

    info+="─────────────────────────────\n"
    info+="Сервер: $server_ip:$port\n"
    info+="Пример: curl --socks5 USER:PASS@$server_ip:$port https://example.com"

    ui_msgbox "$info" "Пользователи SOCKS5"
}

socks5_user_show_connection() {
    _socks5_users_init

    local count
    count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SOCKS5_USERS_JSON")

    local username
    username=$(ui_menu "Показать данные подключения:" "${menu_args[@]}") || return

    local password
    password=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .password' "$SOCKS5_USERS_JSON")

    local server_ip
    server_ip=$(get_server_ip)
    local port
    port=$(_socks5_get_port)

    local info
    info="Пользователь: $username\n"
    info+="Пароль:       $password\n"
    info+="Сервер:       $server_ip\n"
    info+="Порт:         $port\n\n"
    info+="─── curl ───────────────────────────────\n"
    info+="curl --socks5 $username:$password@$server_ip:$port https://example.com\n\n"
    info+="─── Переменная окружения ────────────────\n"
    info+="export ALL_PROXY=socks5://$username:$password@$server_ip:$port\n\n"
    info+="─── Telegram / приложения ───────────────\n"
    info+="socks5://$server_ip:$port\n"
    info+="Логин: $username  Пароль: $password"

    ui_msgbox "$info" "Подключение SOCKS5 — $username"

    # Показываем QR если есть qrencode
    if command -v qrencode >/dev/null 2>&1; then
        if ui_confirm "Показать QR-код с данными подключения?"; then
            local uri="socks5://$username:$password@$server_ip:$port"
            local qr
            qr=$(qrencode -t UTF8 -m 2 "$uri" 2>/dev/null)
            ui_msgbox "$qr\n\n$uri" "QR — $username"
        fi
    fi
}

# ─── Статус ─────────────────────────────────────────────────────────────────

socks5_show_status() {
    if ! socks5_is_installed; then
        ui_msgbox "SOCKS5: НЕ УСТАНОВЛЕН\n\nУстановите через меню ниже." "Статус SOCKS5"
        return
    fi

    local status_str="ОСТАНОВЛЕН"
    socks5_is_running && status_str="РАБОТАЕТ"

    local port
    port=$(_socks5_get_port)

    local server_ip
    server_ip=$(get_server_ip)

    local user_count
    _socks5_users_init
    user_count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)

    local iface
    iface=$(_socks5_get_interface)

    local info
    info="SOCKS5 (dante): $status_str\n\n"
    info+="Адрес:      $server_ip:$port\n"
    info+="Интерфейс:  $iface\n"
    info+="Авторизация: username/password\n"
    info+="Пользователей: $user_count\n\n"
    info+="─── Пример подключения ─────────────────\n"
    info+="curl --socks5 USER:PASS@$server_ip:$port https://example.com\n\n"
    info+="─── Лог ────────────────────────────────\n"
    info+="journalctl -u danted -n 30 -f"

    ui_msgbox "$info" "Статус SOCKS5"
}

# ─── Меню ───────────────────────────────────────────────────────────────────

socks5_users_manage() {
    while true; do
        _socks5_users_init
        local count
        count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)

        local choice
        choice=$(ui_menu "Пользователи SOCKS5 (всего: $count)" \
            "1" "Список пользователей" \
            "2" "Добавить пользователя" \
            "3" "Удалить пользователя" \
            "4" "Включить / Отключить пользователя" \
            "5" "Показать данные подключения" \
            "0" "Назад") || break

        case "$choice" in
            1) socks5_users_list          || true ;;
            2) socks5_user_add            || true ;;
            3) socks5_user_delete         || true ;;
            4) socks5_user_toggle         || true ;;
            5) socks5_user_show_connection|| true ;;
            0) return ;;
        esac
    done
}

socks5_manage() {
    while true; do
        local status_str="не установлен"
        if socks5_is_installed; then
            if socks5_is_running; then
                local port
                port=$(_socks5_get_port)
                local count
                _socks5_users_init
                count=$(jq '.users | length' "$SOCKS5_USERS_JSON" 2>/dev/null)
                status_str="работает, порт $port, пользователей: $count"
            else
                status_str="установлен, остановлен"
            fi
        fi

        local choice
        choice=$(ui_menu "SOCKS5 сервер (dante) — $status_str" \
            "1" "Статус" \
            "2" "Установить" \
            "3" "Запустить / Остановить" \
            "4" "Пользователи" \
            "5" "Сменить порт" \
            "6" "Удалить" \
            "0" "Назад") || break

        case "$choice" in
            1) socks5_show_status    || true ;;
            2) socks5_install        || true ;;
            3) socks5_start_stop     || true ;;
            4) socks5_users_manage   || true ;;
            5) socks5_change_port    || true ;;
            6) socks5_uninstall      || true ;;
            0) return ;;
        esac
    done
}
