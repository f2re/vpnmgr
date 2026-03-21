#!/usr/bin/env bash

# Вывод ошибки с fallback на stderr если whiptail недоступен
_check_error() {
    local msg="$1"
    if is_installed "whiptail"; then
        whiptail --title "ОШИБКА" --backtitle "$WT_BACKTITLE" --msgbox "$msg" 12 70
    else
        echo -e "ОШИБКА: $msg" >&2
    fi
}

check_system_requirements() {
    local missing_deps=()
    local deps=("jq" "whiptail" "curl" "qrencode" "openssl")

    for dep in "${deps[@]}"; do
        if ! is_installed "$dep"; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        _check_error "Отсутствуют необходимые зависимости: ${missing_deps[*]}\n\nУстановите: apt update && apt install -y ${missing_deps[*]}"
        exit 1
    fi
}

check_root_permissions() {
    if ! is_root; then
        _check_error "Для запуска vpnmgr требуются права root."
        exit 1
    fi
}

check_terminal_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)

    if [[ $rows -lt 24 || $cols -lt 80 ]]; then
        # К этому моменту whiptail уже проверен, используем напрямую
        whiptail --title "ПРЕДУПРЕЖДЕНИЕ" --backtitle "$WT_BACKTITLE" \
            --msgbox "Размер терминала слишком мал (${cols}x${rows}).\nРекомендуется минимум 80x24." 10 60 || true
    fi
}

check_disk_space() {
    local min_mb="${1:-200}"
    local available_mb
    available_mb=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$available_mb" && "$available_mb" -lt "$min_mb" ]]; then
        _check_error "Недостаточно места на диске: ${available_mb}MB свободно (минимум ${min_mb}MB)."
        exit 1
    fi
}

check_internet_connection() {
    if ! curl -s --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
        _check_error "Нет подключения к интернету. Проверьте сетевые настройки."
        exit 1
    fi
}
