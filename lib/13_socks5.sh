#!/usr/bin/env bash

# lib/13_socks5.sh - SOCKS5 локальный прокси (через Xray)

SOCKS5_DEFAULT_PORT=1080

socks5_is_enabled() {
    [[ -f "$XRAY_CONFIG" ]] && \
        jq -e '.inbounds[] | select(.protocol == "socks")' "$XRAY_CONFIG" >/dev/null 2>&1
}

socks5_get_port() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        jq -r '.inbounds[] | select(.protocol == "socks") | .port // empty' "$XRAY_CONFIG" 2>/dev/null
    fi
}

# Добавить SOCKS5 inbound в Xray
socks5_enable_xray() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        ui_error "Xray не установлен.\nСначала установите Xray через раздел Протоколы."
        return
    fi

    if socks5_is_enabled; then
        local current_port
        current_port=$(socks5_get_port)
        ui_msgbox "SOCKS5 уже включён в Xray.\n\nПорт: $current_port\nАдрес: 127.0.0.1:$current_port"
        return
    fi

    local port
    port=$(ui_input "Порт SOCKS5 (рекомендуется 1080):" "$SOCKS5_DEFAULT_PORT" "SOCKS5") || return
    [[ -z "$port" ]] && return

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        ui_error "Некорректный порт."
        return
    fi

    # Добавляем SOCKS5 inbound в конфиг Xray
    local tmp="${XRAY_CONFIG}.tmp.$$"
    jq --argjson p "$port" '.inbounds += [{
        "port": $p,
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {
            "auth": "noauth",
            "udp": true
        },
        "tag": "socks-in"
    }]' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

    log_info "SOCKS5 включён на 127.0.0.1:$port"

    if xray_is_running 2>/dev/null; then
        systemctl restart "$XRAY_SERVICE" 2>/dev/null || true
    fi

    ui_success "SOCKS5 прокси включён!\n\nАдрес: 127.0.0.1:$port\n\nИспользование:\n  curl --socks5 127.0.0.1:$port https://example.com\n  export ALL_PROXY=socks5://127.0.0.1:$port"
}

# Отключить SOCKS5
socks5_disable() {
    if ! socks5_is_enabled; then
        ui_msgbox "SOCKS5 не включён."
        return
    fi

    if ! ui_confirm "Отключить SOCKS5 прокси?"; then
        return
    fi

    local tmp="${XRAY_CONFIG}.tmp.$$"
    jq 'del(.inbounds[] | select(.protocol == "socks"))' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

    log_info "SOCKS5 отключён"

    if xray_is_running 2>/dev/null; then
        systemctl restart "$XRAY_SERVICE" 2>/dev/null || true
    fi

    ui_success "SOCKS5 прокси отключён."
}

socks5_show_status() {
    if socks5_is_enabled; then
        local port
        port=$(socks5_get_port)
        ui_msgbox "SOCKS5 прокси: ВКЛЮЧЁН\n\nАдрес: 127.0.0.1:$port\n\n--- Использование ---\n\ncurl:\n  curl --socks5 127.0.0.1:$port https://example.com\n\nПеременная окружения:\n  export ALL_PROXY=socks5://127.0.0.1:$port\n\nFirefox:\n  Настройки → Сеть → SOCKS5 → 127.0.0.1:$port\n\nSSH тоннель (с удалённого клиента):\n  ssh -D $port -N user@server" \
            "SOCKS5 статус"
    else
        ui_msgbox "SOCKS5 прокси: ОТКЛЮЧЁН\n\nВключите через меню ниже." "SOCKS5 статус"
    fi
}

# --- Меню ---

socks5_manage() {
    while true; do
        local status="отключён"
        socks5_is_enabled && status="включён (порт $(socks5_get_port))"

        local choice
        choice=$(ui_menu "SOCKS5 локальный прокси — $status" \
            "1" "Включить в Xray" \
            "2" "Отключить" \
            "3" "Статус и инструкция" \
            "0" "Назад") || break

        case "$choice" in
            1) socks5_enable_xray || true ;;
            2) socks5_disable     || true ;;
            3) socks5_show_status || true ;;
            0) return             ;;
        esac
    done
}
