#!/usr/bin/env bash

# VPN Manager (vpnmgr) - Главная точка входа
# Автор: Gemini CLI
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

# ... (traps remain same)

# Главное меню
main_menu() {
    while true; do
        local choice
        choice=$(ui_menu "Выберите раздел для управления сервером:" \
            "1" "📊 Статус системы" \
            "2" "🔌 Протоколы" \
            "3" "👥 Пользователи" \
            "4" "📈 Мониторинг и логи" \
            "5" "💾 Бэкап и восстановление" \
            "6" "🔄 Обновления" \
            "0" "Выход") || break

        case "$choice" in
            1) monitor_status ;;
            2) protocols_menu ;;
            3) user_manage ;;
            4) monitor_manage ;;
            5) ui_msgbox "Раздел 'Бэкап' находится в разработке." "Инфо" ;;
            6) ui_msgbox "Раздел 'Обновления' находится в разработке." "Инфо" ;;
            0|*) exit 0 ;;
        esac
    done
}

protocols_menu() {
    while true; do
        local choice
        choice=$(ui_menu "Управление протоколами" \
            "x" "VLESS + XHTTP (Xray)" \
            "h" "Hysteria 2" \
            "a" "AmneziaWG" \
            "0" "Назад") || break

        case "$choice" in
            x) xray_manage ;;
            h) hysteria_manage ;;
            0) return ;;
            *) ui_msgbox "Функция в разработке" ;;
        esac
    done
}

# Инициализация
init() {
    # Создание необходимых файлов если их нет
    mkdir -p "$DATA_DIR" "$LOGS_DIR" "$BACKUPS_DIR" "$TEMPLATES_DIR"
    touch "$MAIN_LOG"

    # Проверки (пропускаем root check если не на Linux для удобства разработки, 
    # но в проде это обязательно)
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        check_root_permissions
        check_system_requirements
    fi
    
    check_terminal_size
    log_info "Запуск vpnmgr v$VPNMGR_VERSION"
}

# Запуск
init
main_menu
