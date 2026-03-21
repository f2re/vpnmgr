#!/usr/bin/env bash

# lib/30_monitor.sh - Статус и мониторинг

# Возвращает строку статуса для systemd-сервиса
_service_status_line() {
    local service="$1"
    local label="$2"

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "[●] $label  running"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "[⏹] $label  stopped"
    else
        echo "[ ] $label  not installed"
    fi
}

monitor_status() {
    local xray_line hysteria_line
    xray_line=$(_service_status_line    "$XRAY_SERVICE"     "VLESS+XHTTP (Xray)")
    hysteria_line=$(_service_status_line "$HYSTERIA_SERVICE" "Hysteria 2        ")

    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null \
        || uptime | sed 's/.*up /up /' | cut -d',' -f1-2)

    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s использовано из %s (%s)", $3, $2, $5}' \
        || echo "н/д")

    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {printf "%s использовано из %s", $3, $2}' \
        || echo "н/д")

    local server_ip
    server_ip=$(jq -r '.ip // "не задан"' "$SERVER_JSON" 2>/dev/null || echo "не задан")

    ui_msgbox "=== Статус сервисов ===\n\n$xray_line\n$hysteria_line\n\n=== Система ===\n\n  IP:      $server_ip\n  Аптайм: $uptime_info\n  Диск:   $disk_info\n  RAM:    $mem_info" \
        "Мониторинг"
}

monitor_logs() {
    while true; do
        local choice
        choice=$(ui_menu "Просмотр логов" \
            "1" "Логи vpnmgr" \
            "2" "Логи Xray" \
            "3" "Логи Hysteria 2" \
            "0" "Назад") || break

        local log_file
        case "$choice" in
            1) log_file="$MAIN_LOG" ;;
            2) log_file="/var/log/xray/error.log" ;;
            3) log_file="/var/log/hysteria/hysteria.log" ;;
            0) return ;;
            *) continue ;;
        esac

        if [[ ! -f "$log_file" ]]; then
            ui_msgbox "Лог-файл не найден:\n$log_file" "Логи"
            continue
        fi

        local content
        content=$(tail -80 "$log_file" 2>/dev/null || echo "(пусто)")
        ui_msgbox "$content" "Лог: $(basename "$log_file") (последние 80 строк)"
    done
}

monitor_connections() {
    local info=""

    # Xray
    if xray_is_running 2>/dev/null; then
        local xray_conn
        xray_conn=$(ss -tnp 2>/dev/null | grep -c xray || echo "0")
        info+="VLESS+XHTTP (Xray): $xray_conn соединений\n"
    else
        info+="VLESS+XHTTP (Xray): сервис не запущен\n"
    fi

    # Hysteria
    if systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null; then
        local h2_conn
        h2_conn=$(ss -unp 2>/dev/null | grep -c hysteria || echo "0")
        info+="Hysteria 2: $h2_conn соединений\n"
    else
        info+="Hysteria 2: сервис не запущен\n"
    fi

    ui_msgbox "=== Активные соединения ===\n\n$info" "Соединения"
}

monitor_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Мониторинг и логи" \
            "1" "Статус сервисов" \
            "2" "Активные соединения" \
            "3" "Просмотр логов" \
            "0" "Назад") || break

        case "$choice" in
            1) monitor_status      ;;
            2) monitor_connections ;;
            3) monitor_logs        ;;
            0) return              ;;
        esac
    done
}
