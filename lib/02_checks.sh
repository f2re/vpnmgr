#!/usr/bin/env bash

check_system_requirements() {
    local missing_deps=()
    local deps=("jq" "whiptail" "curl" "qrencode" "openssl")

    for dep in "${deps[@]}"; do
        if ! is_installed "$dep"; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        ui_error "Отсутствуют необходимые зависимости: ${missing_deps[*]}\n\nПожалуйста, установите их: apt update && apt install -y ${missing_deps[*]}"
        exit 1
    fi
}

check_root_permissions() {
    if ! is_root; then
        ui_error "Для запуска vpnmgr требуются права root."
        exit 1
    fi
}

check_terminal_size() {
    local rows cols
    rows=$(tput lines)
    cols=$(tput cols)

    if [[ $rows -lt 24 || $cols -lt 80 ]]; then
        ui_warn "Размер терминала слишком мал ($cols x $rows). Рекомендуется минимум 80x24 для корректного отображения меню."
    fi
}
