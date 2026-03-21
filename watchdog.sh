#!/usr/bin/env bash

# watchdog.sh - Проверка и автоперезапуск VPN-сервисов
# Запускается через cron каждые 5 минут
# Намеренно НЕ используем set -e — скрипт должен проверять все сервисы,
# даже если один из них не удалось перезапустить

set -uo pipefail

# Разрешаем симлинки
_self="${BASH_SOURCE[0]}"
while [[ -L "$_self" ]]; do
    _dir=$(cd "$(dirname "$_self")" && pwd)
    _self=$(readlink "$_self")
    [[ "$_self" != /* ]] && _self="$_dir/$_self"
done
BASE_DIR=$(cd "$(dirname "$_self")" && pwd)
unset _self _dir
source "$BASE_DIR/lib/00_core.sh"

WATCHDOG_LOG="$LOGS_DIR/watchdog.log"
mkdir -p "$LOGS_DIR"
touch "$WATCHDOG_LOG"

_wd_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"
}

# Проверяем systemd-сервис
check_service() {
    local service="$1"
    local label="$2"
    local json_key="$3"

    # Проверяем включён ли протокол
    local enabled
    enabled=$(jq -r ".${json_key}.enabled // false" "$PROTOCOLS_JSON" 2>/dev/null || echo "false")
    [[ "$enabled" != "true" ]] && return 0

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        return 0
    fi

    _wd_log "WARN: $label не работает, попытка перезапуска..."

    if systemctl restart "$service" 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            _wd_log "OK: $label перезапущен успешно"
            return 0
        fi
    fi

    _wd_log "ERROR: $label не удалось перезапустить. Требуется ручное вмешательство."
    return 1
}

# --- Проверяем каждый включённый протокол ---

check_service "$XRAY_SERVICE"     "Xray"       "xray"       || true
check_service "$HYSTERIA_SERVICE" "Hysteria 2" "hysteria2"  || true

# AmneziaWG — проверяем через ip link
amnezia_enabled=$(jq -r '.amneziawg.enabled // false' "$PROTOCOLS_JSON" 2>/dev/null || echo "false")
if [[ "$amnezia_enabled" == "true" ]]; then
    if ! ip link show awg0 >/dev/null 2>&1; then
        _wd_log "WARN: AmneziaWG не работает, попытка перезапуска..."
        if awg-quick up awg0 2>/dev/null; then
            _wd_log "OK: AmneziaWG перезапущен"
        else
            _wd_log "ERROR: AmneziaWG не удалось перезапустить"
        fi
    fi
fi

# Ротация лога watchdog (>1MB → обрезаем до 500 строк)
if [[ -f "$WATCHDOG_LOG" ]]; then
    local_size=$(stat -c%s "$WATCHDOG_LOG" 2>/dev/null || stat -f%z "$WATCHDOG_LOG" 2>/dev/null || echo "0")
    if [[ "$local_size" -gt 1048576 ]]; then
        tail -500 "$WATCHDOG_LOG" > "${WATCHDOG_LOG}.tmp" && mv "${WATCHDOG_LOG}.tmp" "$WATCHDOG_LOG"
    fi
fi
