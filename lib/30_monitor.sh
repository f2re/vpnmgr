#!/usr/bin/env bash

# lib/30_monitor.sh - Статус и мониторинг

monitor_status() {
    local status="● VLESS+XHTTP   ⏹ inactive\n● Hysteria 2    ⏹ inactive\n● AmneziaWG     ⏹ inactive"
    ui_msgbox "Статус системы:\n\n$status" "Мониторинг"
}

monitor_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Мониторинг и логи" \
            "1" "📊 Активные соединения" \
            "2" "📈 Трафик" \
            "3" "📋 Просмотр логов" \
            "0" "Назад") || break

        case "$choice" in
            1) monitor_status ;;
            0) return ;;
            *) ui_msgbox "Функция в разработке" ;;
        esac
    done
}
