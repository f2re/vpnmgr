#!/usr/bin/env bash

# Логирование
log_info()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$MAIN_LOG"; }
log_warn()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$MAIN_LOG"; }
log_error()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$MAIN_LOG"; }
log_success() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >> "$MAIN_LOG"; }

# Генераторы
gen_uuid() {
    if command -v openssl >/dev/null; then
        openssl rand -hex 16 | sed -r 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

gen_password() {
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12
}

# Валидаторы
is_root() {
    [[ $EUID -eq 0 ]]
}

is_installed() {
    command -v "$1" >/dev/null 2>&1
}
