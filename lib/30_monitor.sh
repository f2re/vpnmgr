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

# Строка статуса AmneziaWG (не systemd-сервис, а ip link)
_amnezia_status_line() {
    if ! command -v awg >/dev/null 2>&1; then
        echo "[ ] AmneziaWG           not installed"
    elif ip link show awg0 >/dev/null 2>&1; then
        echo "[●] AmneziaWG           running"
    else
        echo "[⏹] AmneziaWG           stopped"
    fi
}

monitor_status() {
    local xray_line hysteria_line amnezia_line socks5_line singbox_line
    xray_line=$(_service_status_line    "$XRAY_SERVICE"     "VLESS+XHTTP (Xray)")
    hysteria_line=$(_service_status_line "$HYSTERIA_SERVICE" "Hysteria 2        ")
    amnezia_line=$(_amnezia_status_line)
    socks5_line=$(_service_status_line   "3proxy"           "SOCKS5 (3proxy)   ")
    singbox_line=$(_service_status_line  "sing-box"         "sing-box          ")

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

    # Последний бэкап
    local last_backup="нет"
    local latest_bak
    latest_bak=$(ls -1t "$BACKUPS_DIR"/*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_bak" ]]; then
        last_backup=$(basename "$latest_bak" .tar.gz | tr '_' ' ')
    fi

    ui_msgbox "=== Статус сервисов ===\n\n$xray_line\n$hysteria_line\n$amnezia_line\n$socks5_line\n$singbox_line\n\n=== Система ===\n\n  IP:          $server_ip\n  Аптайм:     $uptime_info\n  Диск:       $disk_info\n  RAM:        $mem_info\n  Бэкап:      $last_backup" \
        "Статус системы"
}

# Читает лог: сначала файл, потом journalctl как fallback
_read_log() {
    local log_file="$1"
    local service="${2:-}"
    local lines="${3:-80}"

    # Пробуем файл
    if [[ -f "$log_file" && -s "$log_file" ]]; then
        tail -"$lines" "$log_file" 2>/dev/null
        return 0
    fi

    # Fallback на journalctl для systemd-сервисов
    if [[ -n "$service" ]] && command -v journalctl >/dev/null 2>&1; then
        local jlog
        jlog=$(journalctl -u "$service" -n "$lines" --no-pager 2>/dev/null)
        if [[ -n "$jlog" ]]; then
            echo "(из journalctl -u $service)"
            echo ""
            echo "$jlog"
            return 0
        fi
    fi

    # Файл не существует или пуст
    if [[ ! -f "$log_file" ]]; then
        echo "(лог-файл не найден: $log_file)"
    else
        echo "(лог-файл пуст)"
    fi
    if [[ -n "$service" ]]; then
        echo ""
        echo "Для просмотра логов сервиса:"
        echo "  journalctl -u $service -n 50 --no-pager"
    fi
    return 1
}

monitor_logs() {
    while true; do
        local choice
        choice=$(ui_menu "Просмотр логов" \
            "1" "Логи vpnmgr" \
            "2" "Логи Xray" \
            "3" "Логи Hysteria 2" \
            "4" "Логи 3proxy (SOCKS5)" \
            "5" "Логи sing-box" \
            "6" "Логи watchdog" \
            "0" "Назад") || break

        local log_file service_name title
        case "$choice" in
            1) log_file="$MAIN_LOG"
               service_name=""
               title="vpnmgr.log" ;;
            2) log_file="/var/log/xray/error.log"
               service_name="$XRAY_SERVICE"
               title="Xray" ;;
            3) log_file="/var/log/hysteria/hysteria.log"
               service_name="$HYSTERIA_SERVICE"
               title="Hysteria 2" ;;
            4) log_file="/var/log/3proxy/3proxy.log"
               service_name="3proxy"
               title="3proxy (SOCKS5)" ;;
            5) log_file="/var/log/sing-box/sing-box.log"
               service_name="sing-box"
               title="sing-box" ;;
            6) log_file="$LOGS_DIR/watchdog.log"
               service_name=""
               title="watchdog.log" ;;
            0) return ;;
            *) continue ;;
        esac

        local content
        content=$(_read_log "$log_file" "$service_name" 80)
        ui_msgbox "$content" "Лог: $title (последние 80 строк)"
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

    # AmneziaWG
    if ip link show awg0 >/dev/null 2>&1; then
        local awg_peers
        awg_peers=$(awg show awg0 2>/dev/null | grep -c "^peer:" || echo "0")
        info+="AmneziaWG: $awg_peers подключённых пиров\n"
    else
        info+="AmneziaWG: не запущен\n"
    fi

    # 3proxy (SOCKS5)
    if systemctl is-active --quiet "3proxy" 2>/dev/null; then
        local s5_conn
        s5_conn=$(ss -tnp 2>/dev/null | grep -c 3proxy || echo "0")
        info+="SOCKS5 (3proxy): $s5_conn соединений\n"
    else
        info+="SOCKS5 (3proxy): не запущен\n"
    fi

    # sing-box
    if systemctl is-active --quiet "sing-box" 2>/dev/null; then
        local sb_conn
        sb_conn=$(ss -tnp 2>/dev/null | grep -c sing-box || echo "0")
        info+="sing-box: $sb_conn соединений\n"
    else
        info+="sing-box: не запущен\n"
    fi

    ui_msgbox "=== Активные соединения ===\n\n$info" "Соединения"
}

# Проверка блокировок — curl-тест через каждый протокол
monitor_check_blocks() {
    local test_url="https://www.google.com"
    local info=""

    info+="Тестовый URL: $test_url\n\n"

    # Прямое соединение
    local direct_code
    direct_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
    if [[ "$direct_code" == "200" ]]; then
        info+="Прямое соединение: OK ($direct_code)\n"
    else
        info+="Прямое соединение: НЕДОСТУПЕН (код $direct_code)\n"
    fi

    # Через SOCKS5 — только если Xray запущен и SOCKS5 включён
    if xray_is_running 2>/dev/null && socks5_is_enabled 2>/dev/null; then
        local socks_port
        socks_port=$(socks5_get_port)
        if [[ -n "$socks_port" ]]; then
            local socks_code
            socks_code=$(curl -s --max-time 10 --socks5 "127.0.0.1:$socks_port" -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
            if [[ "$socks_code" == "200" ]]; then
                info+="Через SOCKS5 (:$socks_port): OK ($socks_code)\n"
            else
                info+="Через SOCKS5 (:$socks_port): НЕДОСТУПЕН (код $socks_code)\n"
            fi
        fi
    elif socks5_is_enabled 2>/dev/null; then
        info+="SOCKS5: Xray не запущен\n"
    fi

    ui_msgbox "$info" "Проверка блокировок"
}

monitor_services_manage() {
    while true; do
        # Актуальный статус
        local xray_st hysteria_st amnezia_st socks5_st singbox_st
        xray_st=$(_service_status_line    "$XRAY_SERVICE"     "VLESS+XHTTP (Xray)")
        hysteria_st=$(_service_status_line "$HYSTERIA_SERVICE" "Hysteria 2        ")
        amnezia_st=$(_amnezia_status_line)
        socks5_st=$(_service_status_line   "3proxy"           "SOCKS5 (3proxy)   ")
        singbox_st=$(_service_status_line  "sing-box"         "sing-box          ")

        local choice
        choice=$(ui_menu "Управление сервисами\n\n$xray_st\n$hysteria_st\n$amnezia_st\n$socks5_st\n$singbox_st" \
            "1" "Перезапустить Xray" \
            "2" "Перезапустить Hysteria 2" \
            "3" "Перезапустить AmneziaWG" \
            "4" "Перезапустить 3proxy" \
            "5" "Перезапустить sing-box" \
            "6" "Перезапустить все" \
            "c" "Показать команды (для ручного запуска)" \
            "0" "Назад") || break

        case "$choice" in
            1)
                if systemctl restart "$XRAY_SERVICE" 2>/dev/null; then
                    ui_success "Xray перезапущен."
                else
                    ui_error "Не удалось перезапустить Xray.\n\nПроверьте: journalctl -u $XRAY_SERVICE -n 30 --no-pager"
                fi
                ;;
            2)
                if systemctl restart "$HYSTERIA_SERVICE" 2>/dev/null; then
                    ui_success "Hysteria 2 перезапущена."
                else
                    ui_error "Не удалось перезапустить Hysteria 2.\n\nПроверьте: journalctl -u $HYSTERIA_SERVICE -n 30 --no-pager"
                fi
                ;;
            3)
                awg-quick down awg0 2>/dev/null || true
                if awg-quick up awg0 2>/dev/null; then
                    ui_success "AmneziaWG перезапущен."
                else
                    ui_error "Не удалось перезапустить AmneziaWG.\n\nПроверьте: journalctl -u awg-quick@awg0 -n 30 --no-pager"
                fi
                ;;
            4)
                if systemctl restart "3proxy" 2>/dev/null; then
                    ui_success "3proxy перезапущен."
                else
                    ui_error "Не удалось перезапустить 3proxy.\n\nПроверьте: journalctl -u 3proxy -n 30 --no-pager"
                fi
                ;;
            5)
                if systemctl restart "sing-box" 2>/dev/null; then
                    ui_success "sing-box перезапущен."
                else
                    ui_error "Не удалось перезапустить sing-box.\n\nПроверьте: journalctl -u sing-box -n 30 --no-pager"
                fi
                ;;
            6)
                systemctl restart "$XRAY_SERVICE"     2>/dev/null || true
                systemctl restart "$HYSTERIA_SERVICE"  2>/dev/null || true
                awg-quick down awg0 2>/dev/null || true
                awg-quick up   awg0 2>/dev/null || true
                systemctl restart "3proxy"   2>/dev/null || true
                systemctl restart "sing-box" 2>/dev/null || true
                ui_success "Сервисы перезапущены."
                ;;
            c)
                ui_msgbox "\
=== Команды для Xray ===

  Статус:      systemctl status $XRAY_SERVICE
  Перезапуск:  systemctl restart $XRAY_SERVICE
  Стоп:        systemctl stop $XRAY_SERVICE
  Логи:        journalctl -u $XRAY_SERVICE -n 50 --no-pager

=== Команды для Hysteria 2 ===

  Статус:      systemctl status $HYSTERIA_SERVICE
  Перезапуск:  systemctl restart $HYSTERIA_SERVICE
  Стоп:        systemctl stop $HYSTERIA_SERVICE
  Логи:        journalctl -u $HYSTERIA_SERVICE -n 50 --no-pager

=== Команды для AmneziaWG ===

  Статус:      ip link show awg0
  Статус:      awg show
  Перезапуск:  awg-quick down awg0 && awg-quick up awg0
  Стоп:        awg-quick down awg0
  Логи:        journalctl -u awg-quick@awg0 -n 50 --no-pager

=== Команды для 3proxy (SOCKS5) ===

  Статус:      systemctl status 3proxy
  Перезапуск:  systemctl restart 3proxy
  Стоп:        systemctl stop 3proxy
  Логи:        journalctl -u 3proxy -n 50 --no-pager

=== Команды для sing-box ===

  Статус:      systemctl status sing-box
  Перезапуск:  systemctl restart sing-box
  Стоп:        systemctl stop sing-box
  Логи:        journalctl -u sing-box -n 50 --no-pager

=== Общие команды ===

  Все сервисы: systemctl status $XRAY_SERVICE $HYSTERIA_SERVICE 3proxy sing-box
  Активные:    ss -tlnp | grep -E 'xray|hysteria|3proxy|sing-box'
  Порты:       ss -tlnpu" \
                    "Команды управления сервисами"
                ;;
            0) return ;;
        esac
    done
}

monitor_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Мониторинг и логи" \
            "1" "Статус сервисов" \
            "2" "Активные соединения" \
            "3" "Управление сервисами (перезапуск)" \
            "4" "Просмотр логов" \
            "5" "Проверка блокировок" \
            "0" "Назад") || break

        case "$choice" in
            1) monitor_status           || true ;;
            2) monitor_connections      || true ;;
            3) monitor_services_manage  || true ;;
            4) monitor_logs             || true ;;
            5) monitor_check_blocks     || true ;;
            0) return               ;;
        esac
    done
}
