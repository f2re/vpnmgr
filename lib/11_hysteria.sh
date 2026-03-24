#!/usr/bin/env bash

# lib/11_hysteria.sh - Управление Hysteria 2

HYSTERIA_RELEASES_API="https://api.github.com/repos/apernet/hysteria/releases/latest"
HYSTERIA_SYSTEMD_SERVICE_FILE="/etc/systemd/system/${HYSTERIA_SERVICE}.service"
HYSTERIA_LOG_DIR="/var/log/hysteria"

hysteria_is_installed() {
    [[ -x "$HYSTERIA_BIN" ]]
}

hysteria_is_running() {
    systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null
}

# --- Установка ---

hysteria_install() {
    log_info "Начало установки Hysteria 2"

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64"   ;;
        aarch64) arch="arm64"   ;;
        armv7l)  arch="armv7"   ;;
        *)
            ui_error "Неподдерживаемая архитектура: $(uname -m)"
            return 1
            ;;
    esac

    # Получаем последнюю версию
    local version download_url
    version=$(curl -s --max-time 10 "$HYSTERIA_RELEASES_API" 2>/dev/null | jq -r '.tag_name // empty')
    if [[ -z "$version" ]]; then
        ui_error "Не удалось получить версию Hysteria 2.\nПроверьте интернет-соединение."
        return 1
    fi

    # Формат имени: hysteria-linux-amd64 (без расширения, бинарник)
    download_url="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${arch}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    set +eo pipefail
    {
        set -e
        trap 'log_error "Hysteria: ошибка на шаге: $BASH_COMMAND (код $?)"' ERR

        echo "5"
        echo "XXX"
        echo "Скачивание Hysteria $version..."
        echo "XXX"

        if ! curl -L --silent --show-error "$download_url" -o "$tmp_dir/hysteria" 2>"$tmp_dir/curl.err"; then
            log_error "Hysteria: ошибка скачивания: $(cat "$tmp_dir/curl.err" 2>/dev/null)"
            rm -rf "$tmp_dir"
            exit 1
        fi

        echo "40"
        echo "XXX"
        echo "Установка бинарного файла..."
        echo "XXX"

        install -m 755 "$tmp_dir/hysteria" "$HYSTERIA_BIN"
        mkdir -p "$HYSTERIA_CONFIG_DIR"
        mkdir -p "$HYSTERIA_LOG_DIR"

        echo "60"
        echo "XXX"
        echo "Создание systemd сервиса..."
        echo "XXX"

        cat > "$HYSTERIA_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Unit]
Description=Hysteria 2 Service
Documentation=https://hysteria.network
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536
StandardOutput=append:/var/log/hysteria/hysteria.log
StandardError=append:/var/log/hysteria/hysteria.log

[Install]
WantedBy=multi-user.target
UNIT

        systemctl daemon-reload

        echo "75"
        echo "XXX"
        echo "Генерация конфигурации..."
        echo "XXX"

        # Всегда генерируем конфиг при установке (чтобы сбросить старый сломанный)
        hysteria_generate_config

        # Синхронизируем пользователей если есть
        users_sync_to_hysteria 2>/dev/null || true

        echo "90"
        echo "XXX"
        echo "Запуск сервиса..."
        echo "XXX"

        systemctl enable --quiet "$HYSTERIA_SERVICE"
        systemctl start "$HYSTERIA_SERVICE"

        echo "100"
        echo "XXX"
        echo "Готово!"
        echo "XXX"

    } 2>>"$MAIN_LOG" | ui_progress "Установка Hysteria $version..." "Установка Hysteria 2"

    local install_ok=${PIPESTATUS[0]}
    set -eo pipefail
    rm -rf "$tmp_dir"

    if [[ $install_ok -ne 0 ]]; then
        ui_error "Ошибка установки Hysteria 2.\nПодробности: $MAIN_LOG"
        return 1
    fi

    # Обновляем protocols.json
    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --arg v "$version" '.hysteria2.enabled = true | .hysteria2.version = $v' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_success "Hysteria $version установлен"
    ui_success "Hysteria $version успешно установлен и запущен!\n\nКонфиг: $HYSTERIA_CONFIG\nСервис: systemctl status $HYSTERIA_SERVICE"
}

# --- Генерация конфига ---

hysteria_generate_config() {
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    mkdir -p "$HYSTERIA_LOG_DIR"

    local port masquerade_url obfs obfs_password
    port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON" 2>/dev/null || echo "8443")
    masquerade_url=$(jq -r '.hysteria2.masquerade_url // "https://www.google.com"' "$PROTOCOLS_JSON" 2>/dev/null || echo "https://www.google.com")
    obfs=$(jq -r '.hysteria2.obfs // "salamander"' "$PROTOCOLS_JSON" 2>/dev/null || echo "salamander")
    obfs_password=$(jq -r '.hysteria2.obfs_password // ""' "$PROTOCOLS_JSON" 2>/dev/null || echo "")

    # Генерируем пароль обфускации если пуст
    if [[ -z "$obfs_password" ]]; then
        obfs_password=$(gen_password)
        local tmp="${PROTOCOLS_JSON}.tmp.$$"
        jq --arg p "$obfs_password" '.hysteria2.obfs_password = $p' \
            "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"
    fi

    # Путь к сертификатам
    local cert_path key_path
    cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
    key_path=$(jq -r '.key_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")

    # Базовый конфиг — самоподписанный TLS если нет сертификатов
    local tls_block
    if [[ -n "$cert_path" && -n "$key_path" && -f "$cert_path" && -f "$key_path" ]]; then
        tls_block="tls:
  cert: $cert_path
  key: $key_path"
    else
        # Генерируем самоподписанный сертификат
        local hy_cert_dir="$HYSTERIA_CONFIG_DIR/certs"
        mkdir -p "$hy_cert_dir"
        if [[ ! -f "$hy_cert_dir/cert.pem" ]]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                -keyout "$hy_cert_dir/key.pem" -out "$hy_cert_dir/cert.pem" \
                -days 3650 -nodes -subj "/CN=hysteria" 2>/dev/null
            log_info "Сгенерирован самоподписанный TLS-сертификат для Hysteria 2"
        fi
        tls_block="tls:
  cert: $hy_cert_dir/cert.pem
  key: $hy_cert_dir/key.pem"
    fi

    cat > "$HYSTERIA_CONFIG" <<EOF
listen: :${port}

${tls_block}

auth:
  type: userpass
  userpass: {}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}

obfs:
  type: ${obfs}
  ${obfs}:
    password: ${obfs_password}
EOF

    log_info "Сгенерирован конфиг Hysteria 2: $HYSTERIA_CONFIG (порт $port)"
}

# --- Управление сервисом ---

hysteria_start_stop() {
    if ! hysteria_is_installed; then
        ui_error "Hysteria 2 не установлен. Сначала выполните установку."
        return
    fi

    if hysteria_is_running; then
        if ui_confirm "Hysteria 2 запущен. Остановить?"; then
            systemctl stop "$HYSTERIA_SERVICE"
            log_info "Hysteria 2 остановлен"
            ui_success "Hysteria 2 остановлен."
        fi
    else
        if systemctl start "$HYSTERIA_SERVICE"; then
            log_info "Hysteria 2 запущен"
            ui_success "Hysteria 2 запущен."
        else
            ui_error "Не удалось запустить Hysteria 2.\n\nПроверьте журнал:\njournalctl -u $HYSTERIA_SERVICE -n 30"
        fi
    fi
}

hysteria_restart() {
    if ! hysteria_is_installed; then
        ui_error "Hysteria 2 не установлен."
        return
    fi

    if systemctl restart "$HYSTERIA_SERVICE"; then
        log_info "Hysteria 2 перезапущен"
        ui_success "Hysteria 2 перезапущен."
    else
        ui_error "Не удалось перезапустить Hysteria 2.\n\nПроверьте: journalctl -u $HYSTERIA_SERVICE -n 30"
    fi
}

# --- Конфигурация ---

hysteria_show_config() {
    if [[ ! -f "$HYSTERIA_CONFIG" ]]; then
        ui_error "Конфиг не найден: $HYSTERIA_CONFIG\n\nВыполните установку Hysteria 2."
        return
    fi
    local config
    config=$(cat "$HYSTERIA_CONFIG")
    ui_msgbox "$config" "Конфиг Hysteria 2 ($HYSTERIA_CONFIG)"
}

hysteria_change_port() {
    if [[ ! -f "$HYSTERIA_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите Hysteria 2."
        return
    fi

    local current_port
    current_port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON")

    local new_port
    new_port=$(ui_input "Введите новый порт для Hysteria 2 (текущий: $current_port):" \
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

    # Обновляем конфиг Hysteria — YAML, меняем строку listen
    local tmp="${HYSTERIA_CONFIG}.tmp.$$"
    sed "s/^listen: :.*/listen: :${new_port}/" "$HYSTERIA_CONFIG" > "$tmp" && mv "$tmp" "$HYSTERIA_CONFIG"

    # Обновляем protocols.json
    tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --argjson p "$new_port" '.hysteria2.port = $p' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "Порт Hysteria 2 изменён: $current_port → $new_port"

    if hysteria_is_running; then
        hysteria_restart
    fi

    ui_success "Порт Hysteria 2 изменён на $new_port."
}

# --- Port Hopping ---

hysteria_port_hopping() {
    if ! hysteria_is_installed; then
        ui_error "Hysteria 2 не установлен."
        return
    fi

    local current_state
    current_state=$(jq -r '.hysteria2.port_hopping // false' "$PROTOCOLS_JSON")
    local main_port
    main_port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON")
    local current_range
    current_range=$(jq -r '.hysteria2.port_hopping_range // "20000-40000"' "$PROTOCOLS_JSON")

    if [[ "$current_state" == "true" ]]; then
        if ui_confirm "Port hopping ВКЛЮЧЁН ($current_range → :$main_port).\n\nОтключить?"; then
            # Удаляем правила iptables
            iptables -t nat -D PREROUTING -p udp --dport "${current_range}" \
                -j REDIRECT --to-ports "$main_port" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "${current_range}" \
                -j REDIRECT --to-ports "$main_port" 2>/dev/null || true

            local tmp="${PROTOCOLS_JSON}.tmp.$$"
            jq '.hysteria2.port_hopping = false' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

            log_info "Port hopping отключён"
            ui_success "Port hopping отключён."
        fi
    else
        local range
        range=$(ui_input "Диапазон портов для port hopping (формат: START-END):" \
            "$current_range" "Port Hopping") || return
        [[ -z "$range" ]] && return

        # Валидация формата
        if ! [[ "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
            ui_error "Некорректный формат. Используйте: START-END (например 20000-40000)"
            return
        fi

        local range_start range_end
        range_start="${range%-*}"
        range_end="${range#*-}"

        if [[ "$range_start" -ge "$range_end" || "$range_start" -lt 1 || "$range_end" -gt 65535 ]]; then
            ui_error "Некорректный диапазон портов."
            return
        fi

        # Добавляем правила iptables
        iptables -t nat -A PREROUTING -p udp --dport "${range}" \
            -j REDIRECT --to-ports "$main_port" 2>/dev/null || {
            ui_error "Не удалось добавить правило iptables.\nУбедитесь что iptables установлен."
            return
        }
        ip6tables -t nat -A PREROUTING -p udp --dport "${range}" \
            -j REDIRECT --to-ports "$main_port" 2>/dev/null || true

        local tmp="${PROTOCOLS_JSON}.tmp.$$"
        jq --arg r "$range" '.hysteria2.port_hopping = true | .hysteria2.port_hopping_range = $r' \
            "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

        log_info "Port hopping включён: $range → :$main_port"
        ui_success "Port hopping включён!\n\nДиапазон: $range → порт $main_port\n\nПримечание: правила iptables не сохраняются после перезагрузки.\nУстановите iptables-persistent для сохранения."
    fi
}

# --- Masquerade ---

hysteria_masquerade() {
    if [[ ! -f "$HYSTERIA_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите Hysteria 2."
        return
    fi

    local current_url
    current_url=$(jq -r '.hysteria2.masquerade_url // "https://www.google.com"' "$PROTOCOLS_JSON")

    local new_url
    new_url=$(ui_input "Masquerade URL (текущий: $current_url):" \
        "$current_url" "Masquerade") || return
    [[ -z "$new_url" ]] && return

    # Валидация URL
    if ! [[ "$new_url" =~ ^https?:// ]]; then
        ui_error "URL должен начинаться с http:// или https://"
        return
    fi

    # Обновляем YAML конфиг — заменяем строку url:
    local tmp="${HYSTERIA_CONFIG}.tmp.$$"
    sed "s|    url: .*|    url: ${new_url}|" "$HYSTERIA_CONFIG" > "$tmp" && mv "$tmp" "$HYSTERIA_CONFIG"

    # Обновляем protocols.json
    tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --arg u "$new_url" '.hysteria2.masquerade_url = $u' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "Masquerade URL изменён: $new_url"

    if hysteria_is_running; then
        hysteria_restart
    fi

    ui_success "Masquerade URL изменён на:\n$new_url"
}

# --- Salamander Obfs ---

hysteria_salamander() {
    if [[ ! -f "$HYSTERIA_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите Hysteria 2."
        return
    fi

    local current_obfs
    current_obfs=$(jq -r '.hysteria2.obfs // "salamander"' "$PROTOCOLS_JSON")

    if [[ "$current_obfs" == "salamander" ]]; then
        if ui_confirm "Salamander обфускация ВКЛЮЧЕНА.\n\nОтключить? (снизит защиту от DPI)"; then
            # Удаляем блок obfs из конфига (от "obfs:" до конца файла или следующего блока верхнего уровня)
            local tmp="${HYSTERIA_CONFIG}.tmp.$$"
            awk '
                /^obfs:/ { skip=1; next }
                skip && /^[a-z]/ { skip=0 }
                skip && /^  / { next }
                skip && /^$/ { next }
                !skip { print }
            ' "$HYSTERIA_CONFIG" > "$tmp"

            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$HYSTERIA_CONFIG"
            else
                rm -f "$tmp"
                ui_error "Ошибка обновления конфига."
                return
            fi

            tmp="${PROTOCOLS_JSON}.tmp.$$"
            jq '.hysteria2.obfs = ""' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

            log_info "Salamander обфускация отключена"

            if hysteria_is_running; then
                hysteria_restart
            fi

            ui_success "Salamander обфускация отключена."
        fi
    else
        local obfs_pass
        obfs_pass=$(jq -r '.hysteria2.obfs_password // ""' "$PROTOCOLS_JSON")
        if [[ -z "$obfs_pass" ]]; then
            obfs_pass=$(gen_password)
        fi

        obfs_pass=$(ui_input "Пароль обфускации Salamander:" \
            "$obfs_pass" "Salamander") || return
        [[ -z "$obfs_pass" ]] && return

        # Удаляем старый блок obfs если есть, затем добавляем новый
        local tmp="${HYSTERIA_CONFIG}.tmp.$$"
        awk '
            /^obfs:/ { skip=1; next }
            skip && /^[a-z]/ { skip=0 }
            skip && /^  / { next }
            skip && /^$/ { next }
            !skip { print }
        ' "$HYSTERIA_CONFIG" > "$tmp"

        # Добавляем новый блок
        cat >> "$tmp" <<EOF

obfs:
  type: salamander
  salamander:
    password: ${obfs_pass}
EOF
        mv "$tmp" "$HYSTERIA_CONFIG"

        tmp="${PROTOCOLS_JSON}.tmp.$$"
        jq --arg p "$obfs_pass" '.hysteria2.obfs = "salamander" | .hysteria2.obfs_password = $p' \
            "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

        log_info "Salamander обфускация включена"

        if hysteria_is_running; then
            hysteria_restart
        fi

        ui_success "Salamander обфускация включена.\n\nПароль: $obfs_pass"
    fi
}

# --- Удаление ---

hysteria_uninstall() {
    if ! ui_confirm "Удалить Hysteria 2?\n\nСервис будет остановлен,\nбинарный файл и конфиг — удалены."; then
        return
    fi

    # Убираем port hopping если был
    local ph_enabled
    ph_enabled=$(jq -r '.hysteria2.port_hopping // false' "$PROTOCOLS_JSON")
    if [[ "$ph_enabled" == "true" ]]; then
        local main_port ph_range
        main_port=$(jq -r '.hysteria2.port // 8443' "$PROTOCOLS_JSON")
        ph_range=$(jq -r '.hysteria2.port_hopping_range // ""' "$PROTOCOLS_JSON")
        if [[ -n "$ph_range" ]]; then
            iptables -t nat -D PREROUTING -p udp --dport "$ph_range" \
                -j REDIRECT --to-ports "$main_port" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$ph_range" \
                -j REDIRECT --to-ports "$main_port" 2>/dev/null || true
        fi
    fi

    systemctl stop    "$HYSTERIA_SERVICE" 2>/dev/null || true
    systemctl disable "$HYSTERIA_SERVICE" 2>/dev/null || true
    rm -f "$HYSTERIA_BIN" "$HYSTERIA_SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload

    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq '.hysteria2.enabled = false | .hysteria2.port_hopping = false' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "Hysteria 2 удалён"
    ui_success "Hysteria 2 удалён."
}

# --- Главное меню Hysteria 2 ---

hysteria_manage() {
    while true; do
        local status_line="не установлен"
        if hysteria_is_installed; then
            if hysteria_is_running; then
                status_line="запущен [●]"
            else
                status_line="остановлен [⏹]"
            fi
        fi

        local choice
        choice=$(ui_menu "Управление Hysteria 2 — $status_line" \
            "a" "Установить / обновить" \
            "b" "Запустить / Остановить" \
            "c" "Перезапустить" \
            "d" "Port hopping ON/OFF" \
            "e" "Изменить masquerade URL" \
            "f" "Salamander obfs ON/OFF" \
            "g" "Изменить порт" \
            "h" "Просмотреть конфиг" \
            "i" "Удалить" \
            "0" "Назад") || break

        case "$choice" in
            a) hysteria_install      || true ;;
            b) hysteria_start_stop   || true ;;
            c) hysteria_restart      || true ;;
            d) hysteria_port_hopping || true ;;
            e) hysteria_masquerade   || true ;;
            f) hysteria_salamander   || true ;;
            g) hysteria_change_port  || true ;;
            h) hysteria_show_config  || true ;;
            i) hysteria_uninstall    || true ;;
            0) return                ;;
        esac
    done
}
