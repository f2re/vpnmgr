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
source "$BASE_DIR/lib/12_amnezia.sh"
source "$BASE_DIR/lib/13_socks5.sh"
source "$BASE_DIR/lib/20_users.sh"
source "$BASE_DIR/lib/30_monitor.sh"
source "$BASE_DIR/lib/40_connection.sh"
source "$BASE_DIR/lib/50_backup.sh"
source "$BASE_DIR/lib/51_updater.sh"

# --- Обработка аргументов CLI (до проверки root/whiptail — для cron) ---

case "${1:-}" in
    --backup-silent)
        mkdir -p "$LOGS_DIR"
        touch "$MAIN_LOG"
        backup_create_silent
        exit 0
        ;;
    --check-cert)
        mkdir -p "$LOGS_DIR"
        touch "$MAIN_LOG"
        _cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
        if [[ -n "$_cert_path" && -f "$_cert_path" ]]; then
            _expiry=$(openssl x509 -enddate -noout -in "$_cert_path" 2>/dev/null | cut -d= -f2)
            _expiry_epoch=$(date -d "$_expiry" +%s 2>/dev/null || echo "0")
            _now_epoch=$(date +%s)
            _days_left=$(( (_expiry_epoch - _now_epoch) / 86400 ))
            if [[ "$_days_left" -lt 14 ]]; then
                log_warn "TLS сертификат истекает через $_days_left дней: $_cert_path"
            fi
        fi
        exit 0
        ;;
esac

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
    local _saved_backtitle="$WT_BACKTITLE"
    WT_BACKTITLE="$WT_BACKTITLE  >  Протоколы"
    while true; do
        local choice
        choice=$(ui_menu "Управление протоколами" \
            "x" "VLESS + XHTTP (Xray)" \
            "h" "Hysteria 2" \
            "a" "AmneziaWG" \
            "s" "SOCKS5 (локальный прокси)" \
            "0" "Назад") || break

        case "$choice" in
            x) xray_manage     ;;
            h) hysteria_manage ;;
            a) amnezia_manage  ;;
            s) socks5_manage   ;;
            0) break           ;;
        esac
    done
    WT_BACKTITLE="$_saved_backtitle"
}

main_menu() {
    while true; do
        # Актуальная информация для шапки
        local user_count=0
        [[ -f "$USERS_JSON" ]] && user_count=$(jq '.users | length' "$USERS_JSON" 2>/dev/null || echo 0)
        local server_ip
        server_ip=$(jq -r '.ip // ""' "$SERVER_JSON" 2>/dev/null || echo "")
        [[ -z "$server_ip" ]] && server_ip="не задан"

        local header="Сервер: $server_ip | Пользователей: $user_count"

        local choice
        choice=$(ui_menu "$header" \
            "1" "Статус системы" \
            "2" "Протоколы" \
            "3" "Пользователи" \
            "4" "Мониторинг и логи" \
            "5" "Бэкап и восстановление" \
            "6" "Обновления" \
            "0" "Выход") || break

        case "$choice" in
            1) monitor_status  ;;
            2) protocols_menu  ;;
            3) user_manage     ;;
            4) monitor_manage  ;;
            5) backup_manage   ;;
            6) updater_manage  ;;
            0|*) exit 0        ;;
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
