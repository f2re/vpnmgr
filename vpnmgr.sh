#!/usr/bin/env bash

# VPN Manager (vpnmgr) - Главная точка входа
# Цель: Управление VPN протоколами через TUI

set -euo pipefail

# Определение базовой директории
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Подключение библиотек
source "$BASE_DIR/lib/00_core.sh"
source "$BASE_DIR/lib/01_utils.sh"
source "$BASE_DIR/lib/02_checks.sh"
source "$BASE_DIR/lib/03_ui.sh"
source "$BASE_DIR/lib/10_xray.sh"
source "$BASE_DIR/lib/11_hysteria.sh"
source "$BASE_DIR/lib/20_users.sh"
source "$BASE_DIR/lib/30_monitor.sh"
source "$BASE_DIR/lib/40_connection.sh"

# --- Обработчики сигналов ---

_on_error() {
    local exit_code=$?
    local line_no="${1:-?}"
    log_error "Критическая ошибка (код $exit_code) в строке $line_no"
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "КРИТИЧЕСКАЯ ОШИБКА" --backtitle "$WT_BACKTITLE" \
            --msgbox "Ошибка в строке $line_no (код: $exit_code).\nПодробности: $MAIN_LOG" 10 65
    else
        echo "КРИТИЧЕСКАЯ ОШИБКА в строке $line_no (код: $exit_code). Лог: $MAIN_LOG" >&2
    fi
}

_on_exit() {
    log_info "Завершение vpnmgr"
}

_on_int() {
    log_warn "Прерывание пользователем (Ctrl+C)"
    exit 130
}

trap '_on_error $LINENO' ERR
trap '_on_exit'          EXIT
trap '_on_int'           INT TERM

# --- Меню ---

protocols_menu() {
    while true; do
        local choice
        choice=$(ui_menu "Управление протоколами" \
            "x" "VLESS + XHTTP (Xray)" \
            "h" "Hysteria 2" \
            "a" "AmneziaWG (в разработке)" \
            "0" "Назад") || break

        case "$choice" in
            x) xray_manage ;;
            h) hysteria_manage ;;
            a) ui_msgbox "AmneziaWG находится в разработке." ;;
            0) return ;;
        esac
    done
}

main_menu() {
    while true; do
        local choice
        choice=$(ui_menu "Выберите раздел для управления сервером:" \
            "1" "Статус системы" \
            "2" "Протоколы" \
            "3" "Пользователи" \
            "4" "Мониторинг и логи" \
            "5" "Бэкап и восстановление (в разработке)" \
            "6" "Обновления (в разработке)" \
            "0" "Выход") || break

        case "$choice" in
            1) monitor_status ;;
            2) protocols_menu ;;
            3) user_manage ;;
            4) monitor_manage ;;
            5) ui_msgbox "Раздел 'Бэкап' находится в разработке." ;;
            6) ui_msgbox "Раздел 'Обновления' находится в разработке." ;;
            0|*) exit 0 ;;
        esac
    done
}

# --- Инициализация ---

init() {
    mkdir -p "$DATA_DIR" "$LOGS_DIR" "$BACKUPS_DIR" "$TEMPLATES_DIR"
    touch "$MAIN_LOG"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        check_root_permissions
        check_system_requirements
        check_disk_space 200
    fi

    check_terminal_size
    log_info "Запуск vpnmgr v$VPNMGR_VERSION"
}

init
main_menu
