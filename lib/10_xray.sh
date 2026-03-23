#!/usr/bin/env bash

# lib/10_xray.sh - Управление Xray (VLESS+XHTTP)

XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${XRAY_SERVICE}.service"

xray_is_installed() {
    [[ -x "$XRAY_BIN" ]]
}

xray_is_running() {
    systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null
}

# --- Установка ---

xray_install() {
    log_info "Начало установки Xray"

    # Определяем архитектуру
    local arch
    case "$(uname -m)" in
        x86_64)  arch="64"        ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
        *)
            ui_error "Неподдерживаемая архитектура: $(uname -m)"
            return 1
            ;;
    esac

    # Получаем последнюю версию
    local version
    version=$(curl -s --max-time 10 "$XRAY_RELEASES_API" 2>/dev/null | jq -r '.tag_name // empty')
    if [[ -z "$version" ]]; then
        ui_error "Не удалось получить версию Xray.\nПроверьте интернет-соединение."
        return 1
    fi

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Устанавливаем через прогресс-бар
    # Отключаем set -e чтобы ошибка в пайпе не убила весь скрипт молча
    set +eo pipefail
    {
        set -e
        trap 'log_error "Xray: ошибка на шаге: $BASH_COMMAND (код $?)"' ERR

        echo "5"
        echo "XXX"
        echo "Скачивание Xray $version..."
        echo "XXX"

        if ! curl -L --silent --show-error "$download_url" -o "$tmp_dir/xray.zip" 2>"$tmp_dir/curl.err"; then
            log_error "Xray: ошибка скачивания: $(cat "$tmp_dir/curl.err" 2>/dev/null)"
            rm -rf "$tmp_dir"
            exit 1
        fi

        echo "50"
        echo "XXX"
        echo "Распаковка..."
        echo "XXX"

        unzip -q "$tmp_dir/xray.zip" -d "$tmp_dir/"

        echo "65"
        echo "XXX"
        echo "Установка бинарного файла..."
        echo "XXX"

        install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
        mkdir -p "$XRAY_CONFIG_DIR"

        # Устанавливаем GeoData файлы (нужны для правил роутинга geoip:/geosite:)
        local geo_dir="/usr/local/share/xray"
        mkdir -p "$geo_dir"
        [[ -f "$tmp_dir/geoip.dat"   ]] && install -m 644 "$tmp_dir/geoip.dat"   "$geo_dir/"
        [[ -f "$tmp_dir/geosite.dat" ]] && install -m 644 "$tmp_dir/geosite.dat" "$geo_dir/"

        echo "75"
        echo "XXX"
        echo "Создание systemd сервиса..."
        echo "XXX"

        cat > "$XRAY_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload

        echo "85"
        echo "XXX"
        echo "Генерация конфигурации..."
        echo "XXX"

        # Генерируем конфиг только если он не существует
        if [[ ! -f "$XRAY_CONFIG" ]]; then
            xray_generate_config
        fi

        # Синхронизируем пользователей если есть
        users_sync_to_xray 2>/dev/null || true

        echo "90"
        echo "XXX"
        echo "Запуск сервиса..."
        echo "XXX"

        systemctl enable --quiet "$XRAY_SERVICE"
        systemctl start "$XRAY_SERVICE"

        echo "100"
        echo "XXX"
        echo "Готово!"
        echo "XXX"

    } 2>>"$MAIN_LOG" | ui_progress "Установка Xray $version..." "Установка Xray"

    local install_ok=${PIPESTATUS[0]}
    set -eo pipefail
    rm -rf "$tmp_dir"

    if [[ $install_ok -ne 0 ]]; then
        ui_error "Ошибка установки Xray.\nПодробности: $MAIN_LOG"
        return 1
    fi

    # Обновляем protocols.json
    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --arg v "$version" '.xray.enabled = true | .xray.version = $v' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_success "Xray $version установлен"
    ui_success "Xray $version успешно установлен и запущен!\n\nКонфиг: $XRAY_CONFIG\nСервис: systemctl status $XRAY_SERVICE"
}

# --- Генерация конфига ---

xray_generate_config() {
    mkdir -p "$XRAY_CONFIG_DIR"
    mkdir -p /var/log/xray

    local port
    port=$(jq -r '.xray.port // 443' "$PROTOCOLS_JSON" 2>/dev/null || echo "443")

    # Сохраняем существующий путь если конфиг уже есть
    local xhttp_path=""
    if [[ -f "$XRAY_CONFIG" ]]; then
        xhttp_path=$(jq -r \
            '.inbounds[0].streamSettings.xhttpSettings.path // ""' \
            "$XRAY_CONFIG" 2>/dev/null || echo "")
    fi
    [[ -z "$xhttp_path" ]] && xhttp_path="/$(openssl rand -hex 8)"

    # TLS: берём сертификат из server.json
    local cert_path key_path
    cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
    key_path=$(jq -r  '.key_path  // ""' "$SERVER_JSON" 2>/dev/null || echo "")

    local security="none"
    local tls_section=""

    if [[ -n "$cert_path" && -n "$key_path" && -f "$cert_path" && -f "$key_path" ]]; then
        security="tls"
        tls_section=$(printf ',
      "tlsSettings": {
        "minVersion": "1.2",
        "alpn": ["h2", "http/1.1"],
        "certificates": [
          {
            "certificateFile": "%s",
            "keyFile": "%s"
          }
        ]
      }' "$cert_path" "$key_path")
    fi

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "$security"${tls_section},
        "xhttpSettings": {
          "path": "$xhttp_path",
          "mode": "stream-up"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom",   "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
    log_info "Сгенерирован конфиг Xray: $XRAY_CONFIG (порт=$port, путь=$xhttp_path, TLS=$security)"
}

# --- Управление сервисом ---

xray_start_stop() {
    if ! xray_is_installed; then
        ui_error "Xray не установлен. Сначала выполните установку."
        return
    fi

    if xray_is_running; then
        if ui_confirm "Xray запущен. Остановить?"; then
            systemctl stop "$XRAY_SERVICE"
            log_info "Xray остановлен"
            ui_success "Xray остановлен."
        fi
    else
        if systemctl start "$XRAY_SERVICE"; then
            log_info "Xray запущен"
            ui_success "Xray запущен."
        else
            ui_error "Не удалось запустить Xray.\n\nПроверьте журнал:\njournalctl -u $XRAY_SERVICE -n 30"
        fi
    fi
}

xray_restart() {
    if ! xray_is_installed; then
        ui_error "Xray не установлен."
        return
    fi

    if systemctl restart "$XRAY_SERVICE"; then
        log_info "Xray перезапущен"
        ui_success "Xray перезапущен."
    else
        ui_error "Не удалось перезапустить Xray.\n\nПроверьте: journalctl -u $XRAY_SERVICE -n 30"
    fi
}

# --- Конфигурация ---

xray_show_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        ui_error "Конфиг не найден: $XRAY_CONFIG\n\nВыполните установку Xray."
        return
    fi
    local config
    config=$(cat "$XRAY_CONFIG")
    ui_msgbox "$config" "Конфиг Xray ($XRAY_CONFIG)"
}

xray_change_port() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите Xray."
        return
    fi

    local current_port
    current_port=$(jq -r '.xray.port // 443' "$PROTOCOLS_JSON")

    local new_port
    new_port=$(ui_input "Введите новый порт для Xray (текущий: $current_port):" \
        "$current_port" "Изменить порт") || return
    [[ -z "$new_port" ]] && return

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 || "$new_port" -gt 65535 ]]; then
        ui_error "Некорректный номер порта: $new_port\n\nДопустимый диапазон: 1-65535."
        return
    fi

    if [[ "$new_port" != "$current_port" ]] && ! check_port_available "$new_port"; then
        if ! ui_confirm "Порт $new_port уже занят другим процессом.\nПродолжить?"; then
            return
        fi
    fi

    # Обновляем конфиг Xray
    local tmp="${XRAY_CONFIG}.tmp.$$"
    jq --argjson p "$new_port" '(.inbounds[0].port) = $p' \
        "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"

    # Обновляем protocols.json
    tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --argjson p "$new_port" '.xray.port = $p' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "Порт Xray изменён: $current_port → $new_port"
    xray_restart
    ui_success "Порт Xray изменён на $new_port."
}

# --- Удаление ---

xray_uninstall() {
    if ! ui_confirm "Удалить Xray?\n\nСервис будет остановлен,\nбинарный файл и конфиг — удалены."; then
        return
    fi

    systemctl stop    "$XRAY_SERVICE" 2>/dev/null || true
    systemctl disable "$XRAY_SERVICE" 2>/dev/null || true
    rm -f "$XRAY_BIN" "$XRAY_SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload

    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq '.xray.enabled = false' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "Xray удалён"
    ui_success "Xray удалён."
}

# --- Главное меню Xray ---

xray_manage() {
    while true; do
        # Динамическая строка статуса
        local status_line="не установлен"
        if xray_is_installed; then
            if xray_is_running; then
                status_line="запущен [●]"
            else
                status_line="остановлен [⏹]"
            fi
        fi

        local choice
        choice=$(ui_menu "Управление Xray — $status_line" \
            "a" "Установить / обновить" \
            "b" "Запустить / Остановить" \
            "c" "Перезапустить" \
            "d" "Просмотреть конфиг" \
            "e" "Изменить порт" \
            "f" "Удалить" \
            "0" "Назад") || break

        case "$choice" in
            a) xray_install     || true ;;
            b) xray_start_stop  || true ;;
            c) xray_restart     || true ;;
            d) xray_show_config || true ;;
            e) xray_change_port || true ;;
            f) xray_uninstall   || true ;;
            0) return           ;;
        esac
    done
}
