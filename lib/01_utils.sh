#!/usr/bin/env bash

# Логирование
log_info()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"    >> "$MAIN_LOG"; }
log_warn()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1"    >> "$MAIN_LOG"; }
log_error()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1"   >> "$MAIN_LOG"; }
log_success() { echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >> "$MAIN_LOG"; }

# Генерация UUID v4 (RFC 4122: version=4, variant=10xx)
gen_uuid() {
    if command -v openssl >/dev/null 2>&1; then
        local hex
        hex=$(openssl rand -hex 16)
        # Устанавливаем вариант: верхние 2 бита = 10 (значения 8,9,a,b)
        local variant
        variant=$(printf '%x' $(( (16#${hex:16:1} & 0x3) | 0x8 )))
        # Формат: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        printf '%s-%s-4%s-%s%s-%s\n' \
            "${hex:0:8}"  \
            "${hex:8:4}"  \
            "${hex:13:3}" \
            "${variant}"  \
            "${hex:17:3}" \
            "${hex:20:12}"
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        log_error "Невозможно сгенерировать UUID: нет openssl или /proc/sys/kernel/random/uuid"
        return 1
    fi
}

# Генерация пароля — 16 символов (SIGPIPE от head обрабатывается subshell)
gen_password() {
    ( set +o pipefail; openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 16 )
}

# Получение внешнего IP сервера
get_server_ip() {
    # Сначала пробуем из server.json
    if [[ -f "$SERVER_JSON" ]]; then
        local ip
        ip=$(jq -r '.ip // empty' "$SERVER_JSON" 2>/dev/null)
        [[ -n "$ip" ]] && echo "$ip" && return
    fi
    # Запрашиваем у внешних сервисов
    curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null \
        || echo ""
}

# Валидаторы
is_root() {
    [[ $EUID -eq 0 ]]
}

is_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Валидация имени пользователя: только буквы, цифры, дефис, подчёркивание, 1-32 символа
validate_username() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

# Проверка доступности порта (TCP и UDP)
check_port_available() {
    local port="$1"
    ! ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && \
    ! ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
}
