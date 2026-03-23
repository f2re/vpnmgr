#!/usr/bin/env bash

# lib/14_singbox.sh - sing-box: универсальный прокси-сервер нового поколения
# Поддержка: SOCKS5, VLESS, Shadowsocks, Hysteria2
# Конфигурация: JSON

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_CONFIG_DIR/config.json"
SINGBOX_SERVICE="sing-box"
SINGBOX_LOG="/var/log/sing-box/sing-box.log"
SINGBOX_USERS_JSON="$DATA_DIR/singbox_users.json"

# Порты по умолчанию (не пересекаются с другими сервисами)
SINGBOX_SOCKS_PORT=10808
SINGBOX_VLESS_PORT=10443
SINGBOX_SS_PORT=8388
SINGBOX_HY2_PORT=18443

# ─── Вспомогательные ────────────────────────────────────────────────────────

_singbox_users_init() {
    if [[ ! -f "$SINGBOX_USERS_JSON" ]]; then
        mkdir -p "$DATA_DIR"
        cat > "$SINGBOX_USERS_JSON" <<'EOF'
{"users":[]}
EOF
    fi
}

singbox_is_installed() {
    [[ -x "$SINGBOX_BIN" ]]
}

singbox_is_running() {
    systemctl is-active --quiet "$SINGBOX_SERVICE" 2>/dev/null
}

# Читает настройки sing-box из protocols.json
_singbox_get_settings() {
    local key="$1"
    jq -r ".singbox.${key} // \"\"" "$PROTOCOLS_JSON" 2>/dev/null
}

# Детект архитектуры
_singbox_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo "$arch" ;;
    esac
}

# ─── Установка / Удаление ───────────────────────────────────────────────────

singbox_install() {
    if singbox_is_installed; then
        ui_msgbox "sing-box уже установлен."
        return
    fi

    log_info "SINGBOX: начало установки"

    local install_log
    install_log=$(mktemp)
    local arch
    arch=$(_singbox_detect_arch)

    {
        echo "10"
        echo "XXX"
        echo "Определение последней версии..."
        echo "XXX"

        local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        local release_json
        release_json=$(curl -s --max-time 15 "$api_url" 2>/dev/null)
        local version
        version=$(echo "$release_json" | jq -r '.tag_name // ""' 2>/dev/null)
        version="${version#v}"

        if [[ -z "$version" ]]; then
            log_error "SINGBOX: не удалось определить версию"
            echo "100"
            exit 1
        fi

        log_info "SINGBOX: последняя версия: $version"

        echo "30"
        echo "XXX"
        echo "Скачивание sing-box v$version..."
        echo "XXX"

        local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
        local tmp_dir
        tmp_dir=$(mktemp -d)

        if ! curl -L --silent --show-error "$download_url" -o "$tmp_dir/sing-box.tar.gz" 2>>"$install_log"; then
            log_error "SINGBOX: ошибка скачивания: $download_url"
            rm -rf "$tmp_dir"
            echo "100"
            exit 1
        fi

        echo "60"
        echo "XXX"
        echo "Распаковка и установка..."
        echo "XXX"

        tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir/" 2>>"$install_log"
        local extracted
        extracted=$(find "$tmp_dir" -name "sing-box" -type f -executable 2>/dev/null | head -1)

        if [[ -z "$extracted" ]]; then
            # Ищем в подкаталогах
            extracted=$(find "$tmp_dir" -name "sing-box" -type f 2>/dev/null | head -1)
        fi

        if [[ -z "$extracted" || ! -f "$extracted" ]]; then
            log_error "SINGBOX: бинарник не найден в архиве"
            rm -rf "$tmp_dir"
            echo "100"
            exit 1
        fi

        cp "$extracted" "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
        rm -rf "$tmp_dir"
        log_info "SINGBOX: бинарник установлен в $SINGBOX_BIN"

        echo "70"
        echo "XXX"
        echo "Настройка конфигурации..."
        echo "XXX"

        mkdir -p "$SINGBOX_CONFIG_DIR" /var/log/sing-box
        _singbox_users_init

        # Сохраняем настройки в protocols.json
        local tmp_proto="${PROTOCOLS_JSON}.tmp.$$"
        jq '.singbox = {
            "enabled": false,
            "version": "",
            "socks_port": 10808,
            "socks_enabled": true,
            "vless_port": 10443,
            "vless_enabled": false,
            "ss_port": 8388,
            "ss_enabled": false,
            "ss_method": "2022-blake3-aes-128-gcm",
            "hy2_port": 18443,
            "hy2_enabled": false
        }' "$PROTOCOLS_JSON" > "$tmp_proto" && mv "$tmp_proto" "$PROTOCOLS_JSON"

        singbox_generate_config
        log_info "SINGBOX: конфигурация записана"

        echo "85"
        echo "XXX"
        echo "Создание systemd-сервиса..."
        echo "XXX"

        _singbox_create_systemd_service

        echo "95"
        echo "XXX"
        echo "Запуск сервиса..."
        echo "XXX"

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable "$SINGBOX_SERVICE" >> "$install_log" 2>&1 || true
        systemctl restart "$SINGBOX_SERVICE" >> "$install_log" 2>&1 || true

        echo "100"
    } | ui_progress "Установка sing-box"

    if ! singbox_is_installed; then
        local err_tail
        err_tail=$(tail -20 "$install_log" 2>/dev/null)
        log_error "SINGBOX: установка провалилась"
        rm -f "$install_log"
        ui_error "Ошибка установки sing-box.\n\n${err_tail}\n\nЛог: $MAIN_LOG"
        return
    fi

    local ver_str
    ver_str=$("$SINGBOX_BIN" version 2>/dev/null | head -1 || echo "")

    rm -f "$install_log"
    log_info "SINGBOX: установка завершена ($ver_str)"
    ui_success "sing-box установлен!\n\n$ver_str\n\nПо умолчанию включён SOCKS5 на порту $SINGBOX_SOCKS_PORT.\nНастройте протоколы через меню управления."
}

_singbox_create_systemd_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    log_info "SINGBOX: systemd-сервис создан"
}

singbox_uninstall() {
    if ! singbox_is_installed; then
        ui_msgbox "sing-box не установлен."
        return
    fi

    if ! ui_confirm "Удалить sing-box и все конфигурации?"; then
        return
    fi

    log_info "SINGBOX: начало удаления"

    systemctl stop "$SINGBOX_SERVICE" 2>/dev/null || true
    systemctl disable "$SINGBOX_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload 2>/dev/null || true

    rm -f "$SINGBOX_BIN"
    rm -rf "$SINGBOX_CONFIG_DIR"
    rm -f "$SINGBOX_USERS_JSON"
    rm -rf /var/log/sing-box

    # Удаляем из protocols.json
    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq 'del(.singbox)' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "SINGBOX: удалён"
    ui_success "sing-box удалён."
}

# ─── Генерация конфига ──────────────────────────────────────────────────────

singbox_generate_config() {
    _singbox_users_init
    mkdir -p "$SINGBOX_CONFIG_DIR" /var/log/sing-box

    local socks_port vless_port ss_port hy2_port
    local socks_enabled vless_enabled ss_enabled hy2_enabled ss_method

    socks_port=$(jq -r '.singbox.socks_port // 10808' "$PROTOCOLS_JSON" 2>/dev/null)
    socks_enabled=$(jq -r '.singbox.socks_enabled // true' "$PROTOCOLS_JSON" 2>/dev/null)
    vless_port=$(jq -r '.singbox.vless_port // 10443' "$PROTOCOLS_JSON" 2>/dev/null)
    vless_enabled=$(jq -r '.singbox.vless_enabled // false' "$PROTOCOLS_JSON" 2>/dev/null)
    ss_port=$(jq -r '.singbox.ss_port // 8388' "$PROTOCOLS_JSON" 2>/dev/null)
    ss_enabled=$(jq -r '.singbox.ss_enabled // false' "$PROTOCOLS_JSON" 2>/dev/null)
    ss_method=$(jq -r '.singbox.ss_method // "2022-blake3-aes-128-gcm"' "$PROTOCOLS_JSON" 2>/dev/null)
    hy2_port=$(jq -r '.singbox.hy2_port // 18443' "$PROTOCOLS_JSON" 2>/dev/null)
    hy2_enabled=$(jq -r '.singbox.hy2_enabled // false' "$PROTOCOLS_JSON" 2>/dev/null)

    # Собираем пользователей
    local users_json_data
    users_json_data=$(cat "$SINGBOX_USERS_JSON" 2>/dev/null)

    # Построение inbounds
    local inbounds="[]"

    # SOCKS5 inbound
    if [[ "$socks_enabled" == "true" ]]; then
        local socks_users="[]"
        socks_users=$(echo "$users_json_data" | jq -c '[.users[] | select(.enabled == true) | {"username": .username, "password": .password}]' 2>/dev/null || echo "[]")
        inbounds=$(echo "$inbounds" | jq --argjson port "$socks_port" --argjson users "$socks_users" \
            '. += [{
                "type": "socks",
                "tag": "socks-in",
                "listen": "0.0.0.0",
                "listen_port": $port,
                "users": $users
            }]')
    fi

    # VLESS inbound
    if [[ "$vless_enabled" == "true" ]]; then
        local vless_users="[]"
        vless_users=$(echo "$users_json_data" | jq -c '[.users[] | select(.enabled == true and .vless_uuid != null and .vless_uuid != "") | {"name": .username, "uuid": .vless_uuid}]' 2>/dev/null || echo "[]")

        # TLS-сертификаты
        local cert_path key_path
        cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
        key_path=$(jq -r '.key_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")

        local tls_block="{}"
        if [[ -n "$cert_path" && -f "$cert_path" && -n "$key_path" && -f "$key_path" ]]; then
            tls_block=$(jq -n --arg cert "$cert_path" --arg key "$key_path" \
                '{"enabled": true, "certificate_path": $cert, "key_path": $key}')
        else
            # Генерируем самоподписанный
            local sb_cert_dir="$SINGBOX_CONFIG_DIR/certs"
            mkdir -p "$sb_cert_dir"
            if [[ ! -f "$sb_cert_dir/cert.pem" ]]; then
                openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                    -keyout "$sb_cert_dir/key.pem" -out "$sb_cert_dir/cert.pem" \
                    -days 3650 -nodes -subj "/CN=sing-box" 2>/dev/null
            fi
            tls_block=$(jq -n \
                --arg cert "$sb_cert_dir/cert.pem" \
                --arg key "$sb_cert_dir/key.pem" \
                '{"enabled": true, "certificate_path": $cert, "key_path": $key}')
        fi

        inbounds=$(echo "$inbounds" | jq --argjson port "$vless_port" --argjson users "$vless_users" --argjson tls "$tls_block" \
            '. += [{
                "type": "vless",
                "tag": "vless-in",
                "listen": "0.0.0.0",
                "listen_port": $port,
                "users": $users,
                "tls": $tls
            }]')
    fi

    # Shadowsocks inbound
    if [[ "$ss_enabled" == "true" ]]; then
        local ss_users="[]"
        ss_users=$(echo "$users_json_data" | jq -c '[.users[] | select(.enabled == true and .ss_password != null and .ss_password != "") | {"name": .username, "password": .ss_password}]' 2>/dev/null || echo "[]")

        # Для shadowsocks 2022 нужен server key
        local ss_server_key
        ss_server_key=$(jq -r '.singbox.ss_server_key // ""' "$PROTOCOLS_JSON" 2>/dev/null)
        if [[ -z "$ss_server_key" ]]; then
            ss_server_key=$(openssl rand -base64 16)
            local tmp="${PROTOCOLS_JSON}.tmp.$$"
            jq --arg k "$ss_server_key" '.singbox.ss_server_key = $k' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"
        fi

        inbounds=$(echo "$inbounds" | jq --argjson port "$ss_port" --arg method "$ss_method" --arg key "$ss_server_key" --argjson users "$ss_users" \
            '. += [{
                "type": "shadowsocks",
                "tag": "ss-in",
                "listen": "0.0.0.0",
                "listen_port": $port,
                "method": $method,
                "password": $key,
                "users": $users
            }]')
    fi

    # Hysteria2 inbound
    if [[ "$hy2_enabled" == "true" ]]; then
        local hy2_users="[]"
        hy2_users=$(echo "$users_json_data" | jq -c '[.users[] | select(.enabled == true) | {"name": .username, "password": .password}]' 2>/dev/null || echo "[]")

        local cert_path key_path
        cert_path=$(jq -r '.cert_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")
        key_path=$(jq -r '.key_path // ""' "$SERVER_JSON" 2>/dev/null || echo "")

        local tls_block="{}"
        if [[ -n "$cert_path" && -f "$cert_path" && -n "$key_path" && -f "$key_path" ]]; then
            tls_block=$(jq -n --arg cert "$cert_path" --arg key "$key_path" \
                '{"enabled": true, "certificate_path": $cert, "key_path": $key}')
        else
            local sb_cert_dir="$SINGBOX_CONFIG_DIR/certs"
            mkdir -p "$sb_cert_dir"
            if [[ ! -f "$sb_cert_dir/cert.pem" ]]; then
                openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                    -keyout "$sb_cert_dir/key.pem" -out "$sb_cert_dir/cert.pem" \
                    -days 3650 -nodes -subj "/CN=sing-box" 2>/dev/null
            fi
            tls_block=$(jq -n \
                --arg cert "$sb_cert_dir/cert.pem" \
                --arg key "$sb_cert_dir/key.pem" \
                '{"enabled": true, "certificate_path": $cert, "key_path": $key}')
        fi

        inbounds=$(echo "$inbounds" | jq --argjson port "$hy2_port" --argjson users "$hy2_users" --argjson tls "$tls_block" \
            '. += [{
                "type": "hysteria2",
                "tag": "hy2-in",
                "listen": "0.0.0.0",
                "listen_port": $port,
                "users": $users,
                "tls": $tls
            }]')
    fi

    # Собираем финальный конфиг
    local config
    config=$(jq -n --argjson inbounds "$inbounds" '{
        "log": {
            "level": "info",
            "output": "/var/log/sing-box/sing-box.log",
            "timestamp": true
        },
        "inbounds": $inbounds,
        "outbounds": [
            {
                "type": "direct",
                "tag": "direct"
            },
            {
                "type": "block",
                "tag": "block"
            },
            {
                "type": "dns",
                "tag": "dns-out"
            }
        ],
        "route": {
            "rules": [
                {
                    "protocol": "dns",
                    "outbound": "dns-out"
                }
            ],
            "final": "direct"
        },
        "dns": {
            "servers": [
                {
                    "address": "https://1.1.1.1/dns-query",
                    "tag": "cloudflare"
                },
                {
                    "address": "local",
                    "tag": "local"
                }
            ]
        }
    }')

    echo "$config" | jq '.' > "$SINGBOX_CONFIG"
    log_info "SINGBOX: конфигурация записана"
}

# Синхронизация пользователей с конфигом (вызывается после изменения пользователей)
singbox_sync_users() {
    [[ ! -f "$SINGBOX_CONFIG" ]] && return 0
    singbox_generate_config

    if singbox_is_running; then
        systemctl restart "$SINGBOX_SERVICE" 2>/dev/null || true
    fi
}

# ─── Управление сервисом ────────────────────────────────────────────────────

singbox_start_stop() {
    if ! singbox_is_installed; then
        ui_msgbox "sing-box не установлен."
        return
    fi

    if singbox_is_running; then
        if ui_confirm "Остановить sing-box?"; then
            if systemctl stop "$SINGBOX_SERVICE" 2>/dev/null; then
                ui_success "sing-box остановлен."
            else
                ui_error "Не удалось остановить sing-box.\n\nСм. journalctl -u sing-box -n 30"
            fi
        fi
    else
        systemctl start "$SINGBOX_SERVICE" 2>/dev/null
        if singbox_is_running; then
            ui_success "sing-box запущен."
        else
            local journal_tail
            journal_tail=$(journalctl -u "$SINGBOX_SERVICE" -n 20 --no-pager 2>/dev/null || true)
            ui_error "Не удалось запустить sing-box.\n\nПроверьте логи:\n  journalctl -u sing-box -n 30"
        fi
    fi
}

singbox_restart() {
    if ! singbox_is_installed; then
        ui_msgbox "sing-box не установлен."
        return
    fi

    singbox_generate_config

    if systemctl restart "$SINGBOX_SERVICE" 2>/dev/null; then
        ui_success "sing-box перезапущен."
    else
        ui_error "Не удалось перезапустить sing-box.\n\nСм. journalctl -u sing-box -n 30"
    fi
}

# ─── Управление протоколами ─────────────────────────────────────────────────

singbox_protocols_manage() {
    while true; do
        local socks_st vless_st ss_st hy2_st
        socks_st=$(_singbox_get_settings "socks_enabled")
        vless_st=$(_singbox_get_settings "vless_enabled")
        ss_st=$(_singbox_get_settings "ss_enabled")
        hy2_st=$(_singbox_get_settings "hy2_enabled")

        local socks_mark="ВЫКЛ" vless_mark="ВЫКЛ" ss_mark="ВЫКЛ" hy2_mark="ВЫКЛ"
        [[ "$socks_st" == "true" ]] && socks_mark="ВКЛ"
        [[ "$vless_st" == "true" ]] && vless_mark="ВКЛ"
        [[ "$ss_st" == "true" ]] && ss_mark="ВКЛ"
        [[ "$hy2_st" == "true" ]] && hy2_mark="ВКЛ"

        local socks_port vless_port ss_port hy2_port
        socks_port=$(_singbox_get_settings "socks_port")
        vless_port=$(_singbox_get_settings "vless_port")
        ss_port=$(_singbox_get_settings "ss_port")
        hy2_port=$(_singbox_get_settings "hy2_port")

        local choice
        choice=$(ui_menu "Протоколы sing-box" \
            "1" "SOCKS5 [$socks_mark] :$socks_port — вкл/выкл" \
            "2" "VLESS [$vless_mark] :$vless_port — вкл/выкл" \
            "3" "Shadowsocks [$ss_mark] :$ss_port — вкл/выкл" \
            "4" "Hysteria2 [$hy2_mark] :$hy2_port — вкл/выкл" \
            "5" "Сменить порты" \
            "0" "Назад") || break

        case "$choice" in
            1) _singbox_toggle_protocol "socks" ;;
            2) _singbox_toggle_protocol "vless" ;;
            3) _singbox_toggle_protocol "ss" ;;
            4) _singbox_toggle_protocol "hy2" ;;
            5) _singbox_change_ports ;;
            0) return ;;
        esac
    done
}

_singbox_toggle_protocol() {
    local proto="$1"
    local key="${proto}_enabled"
    local current
    current=$(_singbox_get_settings "$key")

    local new_val="true"
    [[ "$current" == "true" ]] && new_val="false"

    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --arg k "$key" --argjson v "$new_val" '.singbox[$k] = $v' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    singbox_generate_config
    if singbox_is_running; then
        systemctl restart "$SINGBOX_SERVICE" 2>/dev/null || true
    fi

    local label
    case "$proto" in
        socks) label="SOCKS5" ;;
        vless) label="VLESS" ;;
        ss)    label="Shadowsocks" ;;
        hy2)   label="Hysteria2" ;;
    esac

    if [[ "$new_val" == "true" ]]; then
        ui_success "$label включён в sing-box."
    else
        ui_success "$label выключен в sing-box."
    fi
}

_singbox_change_ports() {
    local socks_port vless_port ss_port hy2_port

    socks_port=$(_singbox_get_settings "socks_port")
    socks_port=$(ui_input "Порт SOCKS5:" "${socks_port:-$SINGBOX_SOCKS_PORT}" "sing-box порты") || return

    vless_port=$(_singbox_get_settings "vless_port")
    vless_port=$(ui_input "Порт VLESS:" "${vless_port:-$SINGBOX_VLESS_PORT}" "sing-box порты") || return

    ss_port=$(_singbox_get_settings "ss_port")
    ss_port=$(ui_input "Порт Shadowsocks:" "${ss_port:-$SINGBOX_SS_PORT}" "sing-box порты") || return

    hy2_port=$(_singbox_get_settings "hy2_port")
    hy2_port=$(ui_input "Порт Hysteria2:" "${hy2_port:-$SINGBOX_HY2_PORT}" "sing-box порты") || return

    # Проверяем что порты — числа
    for p in "$socks_port" "$vless_port" "$ss_port" "$hy2_port"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            ui_error "Некорректный порт: $p"
            return
        fi
    done

    # Проверяем что порты не повторяются
    local all_ports=("$socks_port" "$vless_port" "$ss_port" "$hy2_port")
    local unique_ports
    unique_ports=$(printf '%s\n' "${all_ports[@]}" | sort -u | wc -l)
    if [[ "$unique_ports" -ne 4 ]]; then
        ui_error "Порты не должны повторяться!"
        return
    fi

    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq --argjson sp "$socks_port" --argjson vp "$vless_port" --argjson ssp "$ss_port" --argjson hp "$hy2_port" \
        '.singbox.socks_port = $sp | .singbox.vless_port = $vp | .singbox.ss_port = $ssp | .singbox.hy2_port = $hp' \
        "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    singbox_generate_config
    if singbox_is_running; then
        systemctl restart "$SINGBOX_SERVICE" 2>/dev/null || true
    fi

    ui_success "Порты обновлены:\n\nSOCKS5: $socks_port\nVLESS: $vless_port\nShadowsocks: $ss_port\nHysteria2: $hy2_port"
}

# ─── Пользователи ───────────────────────────────────────────────────────────

singbox_user_add() {
    _singbox_users_init

    local username
    username=$(ui_input "Имя пользователя:" "" "sing-box — новый пользователь") || return
    [[ -z "$username" ]] && return

    if ! validate_username "$username"; then
        ui_error "Некорректное имя пользователя.\n\nДопустимо: a-z, 0-9, _, дефис. От 2 до 32 символов."
        return
    fi

    if jq -e --arg u "$username" '.users[] | select(.username == $u)' "$SINGBOX_USERS_JSON" >/dev/null 2>&1; then
        ui_error "Пользователь '$username' уже существует."
        return
    fi

    local password
    password=$(ui_password "Пароль для '$username':\n(оставьте пустым — сгенерировать)" "Пароль sing-box")
    [[ -z "$password" ]] && password=$(gen_password 16)

    local vless_uuid
    vless_uuid=$(gen_uuid)

    # Shadowsocks 2022 пароль (base64)
    local ss_password
    ss_password=$(openssl rand -base64 16)

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp="${SINGBOX_USERS_JSON}.tmp.$$"
    jq --arg u "$username" --arg p "$password" --arg t "$created_at" \
        --arg vuuid "$vless_uuid" --arg ssp "$ss_password" \
        '.users += [{"username": $u, "password": $p, "created_at": $t, "enabled": true, "vless_uuid": $vuuid, "ss_password": $ssp}]' \
        "$SINGBOX_USERS_JSON" > "$tmp" && mv "$tmp" "$SINGBOX_USERS_JSON"

    singbox_sync_users

    log_info "SINGBOX: пользователь '$username' добавлен"
    ui_success "Пользователь добавлен!\n\nЛогин:     $username\nПароль:    $password\nVLESS UUID: $vless_uuid\nSS пароль: $ss_password"
}

singbox_user_delete() {
    _singbox_users_init

    local count
    count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SINGBOX_USERS_JSON")

    local username
    username=$(ui_menu "Выберите пользователя для удаления:" "${menu_args[@]}") || return
    [[ -z "$username" ]] && return

    if ! ui_confirm "Удалить пользователя '$username'?"; then
        return
    fi

    local tmp="${SINGBOX_USERS_JSON}.tmp.$$"
    jq --arg u "$username" 'del(.users[] | select(.username == $u))' \
        "$SINGBOX_USERS_JSON" > "$tmp" && mv "$tmp" "$SINGBOX_USERS_JSON"

    singbox_sync_users

    log_info "SINGBOX: пользователь '$username' удалён"
    ui_success "Пользователь '$username' удалён."
}

singbox_user_toggle() {
    _singbox_users_init

    local count
    count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SINGBOX_USERS_JSON")

    local username
    username=$(ui_menu "Выберите пользователя:" "${menu_args[@]}") || return
    [[ -z "$username" ]] && return

    local current_enabled
    current_enabled=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .enabled' "$SINGBOX_USERS_JSON")

    local tmp="${SINGBOX_USERS_JSON}.tmp.$$"
    if [[ "$current_enabled" == "true" ]]; then
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = false' \
            "$SINGBOX_USERS_JSON" > "$tmp" && mv "$tmp" "$SINGBOX_USERS_JSON"
        ui_success "Пользователь '$username' отключён."
    else
        jq --arg u "$username" '(.users[] | select(.username == $u)).enabled = true' \
            "$SINGBOX_USERS_JSON" > "$tmp" && mv "$tmp" "$SINGBOX_USERS_JSON"
        ui_success "Пользователь '$username' включён."
    fi

    singbox_sync_users
    log_info "SINGBOX: пользователь '$username' — статус изменён"
}

singbox_users_list() {
    _singbox_users_init

    local count
    count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Пользователей нет.\n\nДобавьте первого пользователя через меню."
        return
    fi

    local info="Пользователи sing-box ($count):\n\n"
    while IFS=$'\t' read -r username password enabled vless_uuid ss_password; do
        local status="вкл"
        [[ "$enabled" == "false" ]] && status="ВЫКЛ"
        info+="  ● $username [$status]\n"
        info+="    Пароль:      $password\n"
        info+="    VLESS UUID:  ${vless_uuid:0:8}...\n"
        info+="    SS пароль:   $ss_password\n\n"
    done < <(jq -r '.users[] | [.username, .password, (.enabled | tostring), .vless_uuid, .ss_password] | @tsv' "$SINGBOX_USERS_JSON")

    ui_msgbox "$info" "Пользователи sing-box"
}

singbox_user_show_connection() {
    _singbox_users_init

    local count
    count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)
    if [[ "$count" -eq 0 ]]; then
        ui_msgbox "Нет пользователей."
        return
    fi

    local menu_args=()
    while IFS=$'\t' read -r username enabled; do
        local mark="[вкл]"
        [[ "$enabled" == "false" ]] && mark="[выкл]"
        menu_args+=("$username" "$mark")
    done < <(jq -r '.users[] | [.username, (.enabled | tostring)] | @tsv' "$SINGBOX_USERS_JSON")

    local username
    username=$(ui_menu "Показать данные подключения:" "${menu_args[@]}") || return

    local password vless_uuid ss_password
    password=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .password' "$SINGBOX_USERS_JSON")
    vless_uuid=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .vless_uuid' "$SINGBOX_USERS_JSON")
    ss_password=$(jq -r --arg u "$username" '.users[] | select(.username == $u) | .ss_password' "$SINGBOX_USERS_JSON")

    local server_ip
    server_ip=$(get_server_ip)

    local socks_port vless_port ss_port hy2_port
    socks_port=$(_singbox_get_settings "socks_port")
    vless_port=$(_singbox_get_settings "vless_port")
    ss_port=$(_singbox_get_settings "ss_port")
    hy2_port=$(_singbox_get_settings "hy2_port")

    local socks_en vless_en ss_en hy2_en
    socks_en=$(_singbox_get_settings "socks_enabled")
    vless_en=$(_singbox_get_settings "vless_enabled")
    ss_en=$(_singbox_get_settings "ss_enabled")
    hy2_en=$(_singbox_get_settings "hy2_enabled")

    local info="=== sing-box: $username ===\n\n"

    if [[ "$socks_en" == "true" ]]; then
        info+="─── SOCKS5 (:$socks_port) ───────────────\n"
        info+="socks5://$username:$password@$server_ip:$socks_port\n"
        info+="curl --socks5 $username:$password@$server_ip:$socks_port https://example.com\n\n"
    fi

    if [[ "$vless_en" == "true" ]]; then
        info+="─── VLESS (:$vless_port) ────────────────\n"
        info+="vless://${vless_uuid}@${server_ip}:${vless_port}?encryption=none&security=tls&type=tcp#sb-${username}\n\n"
    fi

    if [[ "$ss_en" == "true" ]]; then
        local ss_method ss_server_key
        ss_method=$(_singbox_get_settings "ss_method")
        ss_server_key=$(_singbox_get_settings "ss_server_key")
        info+="─── Shadowsocks (:$ss_port) ─────────────\n"
        info+="Метод:       $ss_method\n"
        info+="Server key:  $ss_server_key\n"
        info+="User key:    $ss_password\n"
        info+="ss://${ss_method}:${ss_server_key}:${ss_password}@${server_ip}:${ss_port}#sb-ss-${username}\n\n"
    fi

    if [[ "$hy2_en" == "true" ]]; then
        info+="─── Hysteria2 (:$hy2_port) ──────────────\n"
        info+="hysteria2://${username}:${password}@${server_ip}:${hy2_port}?insecure=1#sb-hy2-${username}\n\n"
    fi

    ui_msgbox "$info" "Подключение sing-box — $username"

    # QR
    if command -v qrencode >/dev/null 2>&1; then
        local qr_items=()
        [[ "$socks_en" == "true" ]] && qr_items+=("1" "QR SOCKS5")
        [[ "$vless_en" == "true" ]] && qr_items+=("2" "QR VLESS")
        [[ "$ss_en" == "true" ]]    && qr_items+=("3" "QR Shadowsocks")
        [[ "$hy2_en" == "true" ]]   && qr_items+=("4" "QR Hysteria2")
        qr_items+=("0" "Назад")

        local qr_choice
        qr_choice=$(ui_menu "Показать QR-код:" "${qr_items[@]}") || return

        local uri=""
        case "$qr_choice" in
            1) uri="socks5://$username:$password@$server_ip:$socks_port" ;;
            2) uri="vless://${vless_uuid}@${server_ip}:${vless_port}?encryption=none&security=tls&type=tcp#sb-${username}" ;;
            3) local ss_server_key; ss_server_key=$(_singbox_get_settings "ss_server_key"); local ss_method; ss_method=$(_singbox_get_settings "ss_method"); uri="ss://${ss_method}:${ss_server_key}:${ss_password}@${server_ip}:${ss_port}#sb-ss-${username}" ;;
            4) uri="hysteria2://${username}:${password}@${server_ip}:${hy2_port}?insecure=1#sb-hy2-${username}" ;;
            0) return ;;
        esac

        if [[ -n "$uri" ]]; then
            clear
            qrencode -t ANSIUTF8 -o - "$uri" 2>/dev/null || echo "(ошибка генерации QR)"
            echo ""
            echo "URI: $uri"
            echo ""
            echo "Нажмите Enter для возврата в меню..."
            read -r
        fi
    fi
}

# ─── Статус / Конфиг ────────────────────────────────────────────────────────

singbox_show_status() {
    if ! singbox_is_installed; then
        ui_msgbox "sing-box: НЕ УСТАНОВЛЕН\n\nУстановите через меню ниже." "Статус sing-box"
        return
    fi

    local status_str="ОСТАНОВЛЕН"
    singbox_is_running && status_str="РАБОТАЕТ"

    local ver_str
    ver_str=$("$SINGBOX_BIN" version 2>/dev/null | head -1 || echo "неизвестно")

    local server_ip
    server_ip=$(get_server_ip)

    _singbox_users_init
    local user_count
    user_count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)

    local socks_en vless_en ss_en hy2_en
    socks_en=$(_singbox_get_settings "socks_enabled")
    vless_en=$(_singbox_get_settings "vless_enabled")
    ss_en=$(_singbox_get_settings "ss_enabled")
    hy2_en=$(_singbox_get_settings "hy2_enabled")

    local protos=""
    [[ "$socks_en" == "true" ]] && protos+="SOCKS5(:$(_singbox_get_settings socks_port)) "
    [[ "$vless_en" == "true" ]] && protos+="VLESS(:$(_singbox_get_settings vless_port)) "
    [[ "$ss_en" == "true" ]]    && protos+="SS(:$(_singbox_get_settings ss_port)) "
    [[ "$hy2_en" == "true" ]]   && protos+="HY2(:$(_singbox_get_settings hy2_port)) "
    [[ -z "$protos" ]] && protos="нет активных протоколов"

    local info
    info="sing-box: $status_str\n\n"
    info+="Версия:        $ver_str\n"
    info+="Сервер:        $server_ip\n"
    info+="Пользователей: $user_count\n\n"
    info+="Активные протоколы:\n  $protos\n\n"
    info+="─── Лог ────────────────────────────────\n"
    info+="journalctl -u sing-box -n 30 -f"

    ui_msgbox "$info" "Статус sing-box"
}

singbox_show_config() {
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        ui_msgbox "Конфиг не найден: $SINGBOX_CONFIG"
        return
    fi

    local content
    content=$(cat "$SINGBOX_CONFIG" 2>/dev/null)
    ui_msgbox "$content" "sing-box config.json"
}

# ─── Меню пользователей ─────────────────────────────────────────────────────

singbox_users_manage() {
    while true; do
        _singbox_users_init
        local count
        count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)

        local choice
        choice=$(ui_menu "Пользователи sing-box (всего: $count)" \
            "1" "Список пользователей" \
            "2" "Добавить пользователя" \
            "3" "Удалить пользователя" \
            "4" "Включить / Отключить" \
            "5" "Данные подключения" \
            "0" "Назад") || break

        case "$choice" in
            1) singbox_users_list            || true ;;
            2) singbox_user_add              || true ;;
            3) singbox_user_delete           || true ;;
            4) singbox_user_toggle           || true ;;
            5) singbox_user_show_connection  || true ;;
            0) return ;;
        esac
    done
}

# ─── Главное меню sing-box ──────────────────────────────────────────────────

singbox_manage() {
    while true; do
        local status_str="не установлен"
        if singbox_is_installed; then
            if singbox_is_running; then
                _singbox_users_init
                local count
                count=$(jq '.users | length' "$SINGBOX_USERS_JSON" 2>/dev/null)
                local active_protos=0
                [[ "$(_singbox_get_settings socks_enabled)" == "true" ]] && (( active_protos++ ))
                [[ "$(_singbox_get_settings vless_enabled)" == "true" ]] && (( active_protos++ ))
                [[ "$(_singbox_get_settings ss_enabled)" == "true" ]]   && (( active_protos++ ))
                [[ "$(_singbox_get_settings hy2_enabled)" == "true" ]]  && (( active_protos++ ))
                status_str="работает, протоколов: $active_protos, пользователей: $count"
            else
                status_str="установлен, остановлен"
            fi
        fi

        local choice
        choice=$(ui_menu "sing-box — $status_str" \
            "1" "Статус" \
            "2" "Установить" \
            "3" "Запустить / Остановить" \
            "4" "Перезапустить" \
            "5" "Протоколы (SOCKS5/VLESS/SS/HY2)" \
            "6" "Пользователи" \
            "7" "Показать конфиг" \
            "8" "Удалить" \
            "0" "Назад") || break

        case "$choice" in
            1) singbox_show_status      || true ;;
            2) singbox_install          || true ;;
            3) singbox_start_stop       || true ;;
            4) singbox_restart          || true ;;
            5) singbox_protocols_manage || true ;;
            6) singbox_users_manage     || true ;;
            7) singbox_show_config      || true ;;
            8) singbox_uninstall        || true ;;
            0) return ;;
        esac
    done
}
