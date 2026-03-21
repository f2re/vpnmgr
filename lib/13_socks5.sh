#!/usr/bin/env bash

# lib/13_socks5.sh - SOCKS5 прокси сервер через 3proxy

SOCKS5_DEFAULT_PORT=1080
SOCKS5_SERVICE="3proxy"
SOCKS5_BIN="/usr/local/bin/3proxy"
SOCKS5_CONFIG_DIR="/etc/3proxy"
SOCKS5_CONFIG="$SOCKS5_CONFIG_DIR/3proxy.cfg"
SOCKS5_PASSWD_FILE="$SOCKS5_CONFIG_DIR/passwd"
SOCKS5_LOG="/var/log/3proxy/3proxy.log"
SOCKS5_PID_FILE="/var/run/3proxy.pid"
SOCKS5_USERS_JSON="$DATA_DIR/socks5_users.json"

# ─── Вспомогательные ────────────────────────────────────────────────────────

_socks5_users_init() {
    if [[ ! -f "$SOCKS5_USERS_JSON" ]]; then
        mkdir -p "$DATA_DIR"
        echo '{"users":[]}' > "$SOCKS5_USERS_JSON"
    fi
}

_socks5_get_port() {
    if [[ -f "$SOCKS5_CONFIG" ]]; then
        grep -oP '(?<=socks -p)\d+' "$SOCKS5_CONFIG" 2>/dev/null | head -1
    fi
}

socks5_is_installed() {
    [[ -x "$SOCKS5_BIN" ]]
}

socks5_is_running() {
    systemctl is-active --quiet "$SOCKS5_SERVICE" 2>/dev/null
}

# ─── Установка / Удаление ───────────────────────────────────────────────────

socks5_install() {
    if socks5_is_installed; then
        ui_msgbox "3proxy уже установлен."
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
        local occupied_by
        occupied_by=$(ss -tlnH 2>/dev/null | awk '{print $4, $6}' | grep -E ":${port}$" | head -1)
        if ! ui_confirm "Порт $port уже занят.\n${occupied_by}\n\nВыбрать другой порт?"; then
            return
        fi
        port=$(ui_input "Введите другой порт:" "1081" "SOCKS5 установка") || return
        [[ -z "$port" ]] && return
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            ui_error "Некорректный порт."
            return
        fi
        if ! check_port_available "$port"; then
            ui_error "Порт $port тоже занят. Освободите порт вручную и повторите."
            return
        fi
    fi

    log_info "SOCKS5: начало установки 3proxy (порт $port)"

    local install_log
    install_log=$(mktemp)

    {
        echo "10"
        echo "XXX"
        echo "Обновление списка пакетов..."
        echo "XXX"
        log_info "SOCKS5: apt-get update..."
        apt-get update -qq >> "$install_log" 2>&1 || true

        echo "20"
        echo "XXX"
        echo "Установка зависимостей для сборки..."
        echo "XXX"
        log_info "SOCKS5: установка build-essential..."
        apt-get install -y build-essential git >> "$install_log" 2>&1 || true

        echo "40"
        echo "XXX"
        echo "Скачивание и сборка 3proxy..."
        echo "XXX"
        log_info "SOCKS5: клонирование 3proxy..."
        local build_dir
        build_dir=$(mktemp -d)
        if git clone --depth 1 https://github.com/3proxy/3proxy.git "$build_dir/3proxy" >> "$install_log" 2>&1; then
            log_info "SOCKS5: сборка 3proxy..."
            cd "$build_dir/3proxy" || true
            make -f Makefile.Linux >> "$install_log" 2>&1 || {
                log_error "SOCKS5: ошибка сборки 3proxy"
            }
            if [[ -f "bin/3proxy" ]]; then
                cp bin/3proxy "$SOCKS5_BIN"
                chmod +x "$SOCKS5_BIN"
                log_info "SOCKS5: бинарник скопирован в $SOCKS5_BIN"
            else
                log_error "SOCKS5: бинарник не найден после сборки"
            fi
            cd "$BASE_DIR" || true
        else
            log_error "SOCKS5: ошибка клонирования 3proxy"
        fi
        rm -rf "$build_dir"

        echo "70"
        echo "XXX"
        echo "Настройка конфигурации..."
        echo "XXX"
        mkdir -p "$SOCKS5_CONFIG_DIR" /var/log/3proxy
        touch "$SOCKS5_PASSWD_FILE"
        chmod 600 "$SOCKS5_PASSWD_FILE"
        socks5_write_config "$port"
        log_info "SOCKS5: конфигурация записана"

        echo "80"
        echo "XXX"
        echo "Создание systemd-сервиса..."
        echo "XXX"
        _socks5_create_systemd_service

        echo "90"
        echo "XXX"
        echo "Запуск сервиса..."
        echo "XXX"
        log_info "SOCKS5: systemctl enable $SOCKS5_SERVICE..."
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable "$SOCKS5_SERVICE" >> "$install_log" 2>&1 || true
        systemctl restart "$SOCKS5_SERVICE" >> "$install_log" 2>&1 || true

        _socks5_users_init
        echo "100"
    } | ui_progress "Установка SOCKS5 (3proxy)"

    if ! socks5_is_installed; then
        local err_tail
        err_tail=$(tail -20 "$install_log" 2>/dev/null)
        log_error "SOCKS5: установка провалилась — 3proxy не обнаружен после установки"
        rm -f "$install_log"
        ui_error "Ошибка установки 3proxy.\n\n${err_tail}\n\nЛог: $MAIN_LOG"
        return
    fi

    rm -f "$install_log"
    log_info "SOCKS5 (3proxy) установлен на порту $port"
    ui_success "SOCKS5 сервер установлен!\n\nПорт: $port\nАвторизация: username/password\n\nДобавьте пользователей через меню управления."
}

_socks5_create_systemd_service() {
    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy - tiny free proxy server
After=network.target

[Service]
Type=simple
ExecStart=$SOCKS5_BIN $SOCKS5_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    log_info "SOCKS5: systemd-сервис создан"
}

socks5_uninstall() {
    if ! socks5_is_installed; then
        ui_msgbox "3proxy не установлен."
        return
    fi

    if ! ui_confirm "Удалить SOCKS5 сервер (3proxy) и всех пользователей?"; then
        return
    fi

    log_info "SOCKS5: начало удаления 3proxy"

    systemctl stop "$SOCKS5_SERVICE" 2>/dev/null || true
    systemctl disable "$SOCKS5_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/3proxy.service
    systemctl daemon-reload 2>/dev/null || true

    rm -f "$SOCKS5_BIN"
    rm -rf "$SOCKS5_CONFIG_DIR"
    rm -f "$SOCKS5_USERS_JSON"
    rm -rf /var/log/3proxy

    log_info "SOCKS5 (3proxy) удалён"
    ui_success "SOCKS5 сервер удалён."
}

# ─── Конфигурация ───────────────────────────────────────────────────────────

socks5_write_config() {
    local port="${1:-$SOCKS5_DEFAULT_PORT}"
    mkdir -p "$SOCKS5_CONFIG_DIR" /var/log/3proxy

    log_info "SOCKS5: запись $SOCKS5_CONFIG (порт $port)"

    cat > "$SOCKS5_CONFIG" <<EOF
# 3proxy configuration
daemon
pidfile $SOCKS5_PID_FILE

# Логирование
log $SOCKS5_LOG D
logformat "L%d-%m-%Y %H:%M:%S %N.%p %E %C:%c %R:%r %O %I %h %T"
rotate 30

# Безопасность
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60

# Авторизация через файл паролей
auth strong
users \$/etc/3proxy/passwd

# Разрешаем всем аутентифицированным пользователям
allow *

# SOCKS5 прокси
socks -p${port}
EOF
    log_info "SOCKS5: конфигурация записана (порт $port)"
}

# Синхронизируем файл паролей из JSON
_socks5_sync_passwd() {
    _socks5_users_init
    local tmp="${SOCKS5_PASSWD_FILE}.tmp.$$"
    > "$tmp"

    while IFS=$'\t' read -r username password enabled; do
        [[ -z "$username" ]] && continue
        [[ "$enabled" == "false" ]] && continue
        # Формат: user:CL:password (CL = clear text)
        echo "${username}:CL:${password}" >> "$tmp"
    done < <(jq -r '.users[] | [.username, .password, (.enabled | tostring)] | @tsv' "$SOCKS5_USERS_JSON" 2>/dev/null)

    mv "$tmp" "$SOCKS5_PASSWD_FILE"
    chmod 600 "$SOCKS5_PASSWD_FILE"
}

socks5_change_port() {
    if ! socks5_is_installed; then
        ui_msgbox "3proxy не установлен."
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
        local occupied_by
        occupied_by=$(ss -tlnH 2>/dev/null | awk '{print $4, $6}' | grep -E ":${port}$" | head -1)
        if ! ui_confirm "Порт $port уже занят.\n${occupied_by}\n\nВыбрать другой порт?"; then
            return
        fi
        port=$(ui_input "Введите другой порт:" "$((port + 1))" "Смена порта") || return
        [[ -z "$port" ]] && return
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            ui_error "Некорректный порт."
            return
        fi
        if ! check_port_available "$port"; then
            ui_error "Порт $port тоже занят. Освободите порт вручную и повторите."
            return
        fi
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
        ui_msgbox "3proxy не установлен."
        return
    fi

    if socks5_is_running; then
        if ui_confirm "Остановить SOCKS5 сервер?"; then
            log_info "SOCKS5: systemctl stop $SOCKS5_SERVICE"
            if systemctl stop "$SOCKS5_SERVICE" 2>/dev/null; then
                log_info "SOCKS5: сервис остановлен"
                ui_success "SOCKS5 сервер остановлен."
            else
                log_error "SOCKS5: systemctl stop — ошибка (код $?)"
                ui_error "Не удалось остановить SOCKS5.\n\nСм. journalctl -u 3proxy -n 30"
            fi
        fi
    else
        log_info "SOCKS5: systemctl start $SOCKS5_SERVICE"
        systemctl start "$SOCKS5_SERVICE" 2>/dev/null
        if socks5_is_running; then
            log_info "SOCKS5: сервис запущен"
            ui_success "SOCKS5 сервер запущен."
        else
            local journal_tail
            journal_tail=$(journalctl -u "$SOCKS5_SERVICE" -n 20 --no-pager 2>/dev/null || true)
            log_error "SOCKS5: сервис не запустился"
            log_error "SOCKS5: journal: $journal_tail"
            ui_error "Не удалось запустить SOCKS5.\n\nПроверьте логи:\n  journalctl -u 3proxy -n 30"
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

    # Сохраняем в JSON
    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
    jq --arg u "$username" --arg p "$password" --arg t "$created_at" \
        '.users += [{"username": $u, "password": $p, "created_at": $t, "enabled": true}]' \
        "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"

    # Синхронизируем passwd-файл 3proxy
    _socks5_sync_passwd

    # Перезагружаем 3proxy если запущен
    if socks5_is_running; then
        systemctl restart "$SOCKS5_SERVICE" 2>/dev/null || true
    fi

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

    # Удаляем из JSON
    local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
    jq --arg u "$username" 'del(.users[] | select(.username == $u))' \
        "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"

    # Синхронизируем passwd-файл
    _socks5_sync_passwd

    if socks5_is_running; then
        systemctl restart "$SOCKS5_SERVICE" 2>/dev/null || true
    fi

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

    local tmp="${SOCKS5_USERS_JSON}.tmp.$$"
    if [[ "$current_enabled" == "true" ]]; then
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = false' \
            "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"
        ui_success "Пользователь '$username' отключён."
    else
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = true' \
            "$SOCKS5_USERS_JSON" > "$tmp" && mv "$tmp" "$SOCKS5_USERS_JSON"
        ui_success "Пользователь '$username' включён."
    fi

    # Синхронизируем passwd-файл
    _socks5_sync_passwd

    if socks5_is_running; then
        systemctl restart "$SOCKS5_SERVICE" 2>/dev/null || true
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

    local info
    info="SOCKS5 (3proxy): $status_str\n\n"
    info+="Адрес:         $server_ip:$port\n"
    info+="Авторизация:   username/password\n"
    info+="Пользователей: $user_count\n\n"
    info+="─── Пример подключения ─────────────────\n"
    info+="curl --socks5 USER:PASS@$server_ip:$port https://example.com\n\n"
    info+="─── Лог ────────────────────────────────\n"
    info+="journalctl -u 3proxy -n 30 -f"

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
        choice=$(ui_menu "SOCKS5 сервер (3proxy) — $status_str" \
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
