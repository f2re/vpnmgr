#!/usr/bin/env bash

# lib/12_amnezia.sh - Управление AmneziaWG

AMNEZIA_CONFIG_DIR="/etc/amneziawg"
AMNEZIA_INTERFACE="awg0"
AMNEZIA_CONFIG="$AMNEZIA_CONFIG_DIR/$AMNEZIA_INTERFACE.conf"

amnezia_is_installed() {
    command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1
}

amnezia_is_running() {
    ip link show "$AMNEZIA_INTERFACE" >/dev/null 2>&1
}

# --- Установка: Ubuntu (PPA) ---

_amnezia_install_ubuntu() {
    echo "5"
    echo "XXX"
    echo "Добавление репозитория AmneziaWG (Ubuntu PPA)..."
    echo "XXX"

    local ubuntu_codename="focal"
    if [[ -f /etc/os-release ]]; then
        local vc
        vc=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        [[ -n "$vc" ]] && ubuntu_codename="$vc"
    fi

    if ! curl -fsSL https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/KEY.gpg \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/amnezia-keyring.gpg; then
        log_error "AmneziaWG: не удалось добавить GPG ключ"
        exit 1
    fi

    echo "deb [signed-by=/usr/share/keyrings/amnezia-keyring.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu $ubuntu_codename main" \
        > /etc/apt/sources.list.d/amnezia.list

    echo "30"
    echo "XXX"
    echo "Обновление пакетов..."
    echo "XXX"

    if ! apt-get update -qq; then
        log_error "AmneziaWG: apt-get update завершился с ошибкой"
        exit 1
    fi

    echo "50"
    echo "XXX"
    echo "Установка amneziawg..."
    echo "XXX"

    if ! apt-get install -y -qq amneziawg amneziawg-tools; then
        log_error "AmneziaWG: не удалось установить пакеты amneziawg"
        exit 1
    fi
}

# --- Установка: Debian (сборка из исходников) ---

_amnezia_install_debian() {
    echo "5"
    echo "XXX"
    echo "Установка зависимостей для сборки..."
    echo "XXX"

    # Устанавливаем базовые зависимости без linux-headers
    if ! apt-get install -y -qq build-essential dkms git pkg-config; then
        log_error "AmneziaWG: не удалось установить базовые зависимости"
        exit 1
    fi

    # Пробуем установить linux-headers: сначала точную версию, потом метапакет
    local _kr
    _kr=$(uname -r)
    if ! apt-get install -y -qq "linux-headers-${_kr}" 2>/dev/null; then
        log_warn "Пакет linux-headers-${_kr} не найден, пробуем метапакет linux-headers-$(dpkg --print-architecture)"
        if ! apt-get install -y -qq "linux-headers-$(dpkg --print-architecture)" 2>/dev/null; then
            log_error "AmneziaWG: не удалось установить linux-headers (нужны для сборки модуля ядра)"
            exit 1
        fi
    fi

    echo "20"
    echo "XXX"
    echo "Скачивание amneziawg-linux-kernel-module..."
    echo "XXX"

    local src_dir="/usr/src/amneziawg"
    rm -rf "$src_dir"

    if ! git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git "$src_dir"; then
        log_error "AmneziaWG: не удалось скачать исходники kernel module"
        exit 1
    fi

    echo "40"
    echo "XXX"
    echo "Сборка и установка модуля ядра (DKMS)..."
    echo "XXX"

    # Определяем версию из dkms.conf если есть, иначе из тега git
    local mod_version="1.0.0"
    if [[ -f "$src_dir/src/dkms.conf" ]]; then
        mod_version=$(grep 'PACKAGE_VERSION' "$src_dir/src/dkms.conf" | head -1 | cut -d'"' -f2)
    fi

    # Регистрируем и собираем через DKMS
    cd "$src_dir/src"
    if [[ -f dkms.conf ]]; then
        local dkms_src="/usr/src/amneziawg-${mod_version}"
        rm -rf "$dkms_src"
        cp -r "$src_dir/src" "$dkms_src"
        dkms add -m amneziawg -v "$mod_version" 2>/dev/null || true
        if ! dkms build -m amneziawg -v "$mod_version"; then
            log_error "AmneziaWG: ошибка сборки DKMS модуля"
            exit 1
        fi
        if ! dkms install -m amneziawg -v "$mod_version"; then
            log_error "AmneziaWG: ошибка установки DKMS модуля"
            exit 1
        fi
    else
        # Fallback: ручная сборка через make
        if ! (make && make install); then
            log_error "AmneziaWG: ошибка сборки модуля"
            exit 1
        fi
        depmod -a
    fi
    cd /

    # Загружаем модуль
    modprobe amneziawg 2>/dev/null || true

    echo "60"
    echo "XXX"
    echo "Скачивание amneziawg-tools..."
    echo "XXX"

    local tools_dir="/tmp/amneziawg-tools"
    rm -rf "$tools_dir"

    if ! git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git "$tools_dir"; then
        log_error "AmneziaWG: не удалось скачать исходники tools"
        exit 1
    fi

    echo "75"
    echo "XXX"
    echo "Сборка и установка amneziawg-tools..."
    echo "XXX"

    cd "$tools_dir/src"
    if ! (make && make install); then
        log_error "AmneziaWG: ошибка сборки amneziawg-tools"
        cd /
        exit 1
    fi
    cd /
    rm -rf "$tools_dir"
}

# --- Установка ---

amnezia_install() {
    log_info "Начало установки AmneziaWG"

    set +eo pipefail
    {
        set -e
        trap 'log_error "AmneziaWG: ошибка на шаге: $BASH_COMMAND (код $?)"' ERR

        # Определяем дистрибутив
        local distro_id=""
        if [[ -f /etc/os-release ]]; then
            distro_id=$(. /etc/os-release && echo "${ID:-}")
        fi

        if [[ "$distro_id" == "ubuntu" ]]; then
            _amnezia_install_ubuntu
        else
            _amnezia_install_debian
        fi

        echo "80"
        echo "XXX"
        echo "Генерация ключей и конфигурации..."
        echo "XXX"

        mkdir -p "$AMNEZIA_CONFIG_DIR"

        if [[ ! -f "$AMNEZIA_CONFIG" ]]; then
            amnezia_generate_config
        fi

        echo "85"
        echo "XXX"
        echo "Включение IP forwarding..."
        echo "XXX"

        # Включаем IP forwarding
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi

        echo "90"
        echo "XXX"
        echo "Запуск интерфейса..."
        echo "XXX"

        awg-quick up "$AMNEZIA_INTERFACE" 2>/dev/null || true
        # Включаем автозапуск
        systemctl enable "awg-quick@${AMNEZIA_INTERFACE}" 2>/dev/null || true

        echo "100"
        echo "XXX"
        echo "Готово!"
        echo "XXX"

    } 2>>"$MAIN_LOG" | ui_progress "Установка AmneziaWG..." "Установка AmneziaWG"

    local install_ok=${PIPESTATUS[0]}
    set -eo pipefail

    if [[ $install_ok -ne 0 ]]; then
        ui_error "Ошибка установки AmneziaWG.\nПодробности: $MAIN_LOG"
        return 1
    fi

    # Обновляем protocols.json
    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq '.amneziawg.enabled = true' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_success "AmneziaWG установлен"
    ui_success "AmneziaWG установлен и запущен!\n\nИнтерфейс: $AMNEZIA_INTERFACE\nКонфиг: $AMNEZIA_CONFIG"
}

# --- Генерация серверного конфига ---

amnezia_generate_config() {
    mkdir -p "$AMNEZIA_CONFIG_DIR"

    # Генерация ключей
    local privkey pubkey
    privkey=$(awg genkey 2>/dev/null || wg genkey 2>/dev/null)
    pubkey=$(echo "$privkey" | awg pubkey 2>/dev/null || echo "$privkey" | wg pubkey 2>/dev/null)

    # Сохраняем публичный ключ для пиров
    echo "$pubkey" > "$AMNEZIA_CONFIG_DIR/server_pubkey"
    echo "$privkey" > "$AMNEZIA_CONFIG_DIR/server_privkey"
    chmod 600 "$AMNEZIA_CONFIG_DIR/server_privkey"

    local port
    port=$(jq -r '.amneziawg.port // 51820' "$PROTOCOLS_JSON" 2>/dev/null || echo "51820")

    # Jitter-параметры (уникальные для AmneziaWG)
    local jc=4 jmin=50 jmax=1000
    local s1=59 s2=52
    local h1=1734590615 h2=868815740 h3=2997771783 h4=3436498498

    # Определяем внешний интерфейс
    local ext_iface
    ext_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$ext_iface" ]] && ext_iface="eth0"

    cat > "$AMNEZIA_CONFIG" <<EOF
[Interface]
PrivateKey = $privkey
Address = 10.0.0.1/24
ListenPort = $port
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $ext_iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $ext_iface -j MASQUERADE
EOF

    chmod 600 "$AMNEZIA_CONFIG"
    log_info "Сгенерирован конфиг AmneziaWG: $AMNEZIA_CONFIG (порт $port)"
}

# --- Управление сервисом ---

amnezia_start_stop() {
    if ! amnezia_is_installed; then
        ui_error "AmneziaWG не установлен. Сначала выполните установку."
        return
    fi

    if amnezia_is_running; then
        if ui_confirm "AmneziaWG запущен. Остановить?"; then
            awg-quick down "$AMNEZIA_INTERFACE" 2>/dev/null
            log_info "AmneziaWG остановлен"
            ui_success "AmneziaWG остановлен."
        fi
    else
        if awg-quick up "$AMNEZIA_INTERFACE" 2>/dev/null; then
            log_info "AmneziaWG запущен"
            ui_success "AmneziaWG запущен."
        else
            ui_error "Не удалось запустить AmneziaWG.\n\nПроверьте конфиг: $AMNEZIA_CONFIG"
        fi
    fi
}

amnezia_restart() {
    if ! amnezia_is_installed; then
        ui_error "AmneziaWG не установлен."
        return
    fi

    awg-quick down "$AMNEZIA_INTERFACE" 2>/dev/null || true
    if awg-quick up "$AMNEZIA_INTERFACE" 2>/dev/null; then
        log_info "AmneziaWG перезапущен"
        ui_success "AmneziaWG перезапущен."
    else
        ui_error "Не удалось перезапустить AmneziaWG."
    fi
}

# --- Управление пирами ---

amnezia_add_peer() {
    if [[ ! -f "$AMNEZIA_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите AmneziaWG."
        return
    fi

    local peer_name
    peer_name=$(ui_input "Имя нового пира (клиента):" "" "Добавить пир") || return
    [[ -z "$peer_name" ]] && return

    if ! validate_username "$peer_name"; then
        ui_error "Недопустимое имя. Используйте буквы, цифры, дефис, подчёркивание."
        return
    fi

    local peer_dir="$AMNEZIA_CONFIG_DIR/peers/$peer_name"
    if [[ -d "$peer_dir" ]]; then
        ui_error "Пир '$peer_name' уже существует."
        return
    fi

    mkdir -p "$peer_dir"

    # Генерация ключей пира
    local peer_privkey peer_pubkey peer_psk
    peer_privkey=$(awg genkey 2>/dev/null || wg genkey 2>/dev/null)
    peer_pubkey=$(echo "$peer_privkey" | awg pubkey 2>/dev/null || echo "$peer_privkey" | wg pubkey 2>/dev/null)
    peer_psk=$(awg genpsk 2>/dev/null || wg genpsk 2>/dev/null)

    # Следующий свободный IP
    local next_ip
    next_ip=$(_amnezia_next_ip)

    # Сохраняем ключи
    echo "$peer_privkey" > "$peer_dir/privkey"
    echo "$peer_pubkey"  > "$peer_dir/pubkey"
    echo "$peer_psk"     > "$peer_dir/psk"
    echo "$next_ip"      > "$peer_dir/ip"
    chmod 600 "$peer_dir/privkey" "$peer_dir/psk"

    # Добавляем пир в серверный конфиг
    cat >> "$AMNEZIA_CONFIG" <<EOF

# Peer: $peer_name
[Peer]
PublicKey = $peer_pubkey
PresharedKey = $peer_psk
AllowedIPs = ${next_ip}/32
EOF

    # Генерируем клиентский конфиг
    local server_ip server_pubkey port
    server_ip=$(get_server_ip)
    server_pubkey=$(cat "$AMNEZIA_CONFIG_DIR/server_pubkey" 2>/dev/null)
    port=$(jq -r '.amneziawg.port // 51820' "$PROTOCOLS_JSON" 2>/dev/null || echo "51820")

    # Jitter-параметры из серверного конфига
    local jc jmin jmax s1 s2 h1 h2 h3 h4
    jc=$(grep "^Jc" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmin=$(grep "^Jmin" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmax=$(grep "^Jmax" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s1=$(grep "^S1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s2=$(grep "^S2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h1=$(grep "^H1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h2=$(grep "^H2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h3=$(grep "^H3" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h4=$(grep "^H4" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')

    cat > "$peer_dir/client.conf" <<EOF
[Interface]
PrivateKey = $peer_privkey
Address = ${next_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = $jc
Jmin = $jmin
Jmax = $jmax
S1 = $s1
S2 = $s2
H1 = $h1
H2 = $h2
H3 = $h3
H4 = $h4

[Peer]
PublicKey = $server_pubkey
PresharedKey = $peer_psk
Endpoint = ${server_ip}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Перезагружаем интерфейс если запущен
    if amnezia_is_running; then
        awg-quick down "$AMNEZIA_INTERFACE" 2>/dev/null || true
        awg-quick up "$AMNEZIA_INTERFACE" 2>/dev/null || true
    fi

    log_success "Добавлен пир AmneziaWG: $peer_name ($next_ip)"

    # Показываем QR и конфиг
    local client_conf
    client_conf=$(cat "$peer_dir/client.conf")
    ui_msgbox "Пир '$peer_name' добавлен!\n\nIP: $next_ip\n\nКлиентский конфиг:\n$client_conf" "AmneziaWG — Новый пир"

    # QR-код
    if is_installed "qrencode"; then
        if ui_confirm "Показать QR-код для клиента?"; then
            clear
            echo "=== AmneziaWG — $peer_name ==="
            qrencode -t ANSIUTF8 -o - < "$peer_dir/client.conf" 2>/dev/null || echo "(ошибка QR)"
            echo ""
            echo "Нажмите Enter для возврата..."
            read -r
        fi
    fi
}

_amnezia_next_ip() {
    # Находим следующий свободный IP в подсети 10.0.0.x
    local used_ips
    used_ips=$(grep "AllowedIPs" "$AMNEZIA_CONFIG" 2>/dev/null | grep -oE '10\.0\.0\.[0-9]+' || true)

    local i
    for i in $(seq 2 254); do
        if ! echo "$used_ips" | grep -q "10.0.0.${i}$"; then
            echo "10.0.0.${i}"
            return
        fi
    done
    echo "10.0.0.254"
}

amnezia_remove_peer() {
    if [[ ! -d "$AMNEZIA_CONFIG_DIR/peers" ]]; then
        ui_msgbox "Нет пиров для удаления."
        return
    fi

    local peers=()
    local peer_dir
    for peer_dir in "$AMNEZIA_CONFIG_DIR/peers"/*/; do
        [[ ! -d "$peer_dir" ]] && continue
        local name ip
        name=$(basename "$peer_dir")
        ip=$(cat "$peer_dir/ip" 2>/dev/null || echo "?")
        peers+=("$name" "IP: $ip")
    done

    if [[ ${#peers[@]} -eq 0 ]]; then
        ui_msgbox "Нет пиров для удаления."
        return
    fi

    local selected
    selected=$(ui_menu "Выберите пир для удаления:" "${peers[@]}") || return

    if ! ui_confirm "Удалить пир '$selected'?\n\nЭто действие необратимо."; then
        return
    fi

    # Удаляем блок пира из серверного конфига (от "# Peer: name" до следующего пира или конца файла)
    local tmp="${AMNEZIA_CONFIG}.tmp.$$"
    awk -v peer="# Peer: ${selected}" '
        $0 == peer { skip=1; next }
        skip && /^# Peer: / { skip=0 }
        skip && /^\[Peer\]/ { next }
        skip && /^[A-Za-z]/ { next }
        skip && /^$/ { next }
        !skip { print }
    ' "$AMNEZIA_CONFIG" > "$tmp"

    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$AMNEZIA_CONFIG"
    else
        rm -f "$tmp"
    fi

    rm -rf "$AMNEZIA_CONFIG_DIR/peers/$selected"

    if amnezia_is_running; then
        awg-quick down "$AMNEZIA_INTERFACE" 2>/dev/null || true
        awg-quick up "$AMNEZIA_INTERFACE" 2>/dev/null || true
    fi

    log_success "Удалён пир AmneziaWG: $selected"
    ui_success "Пир '$selected' удалён."
}

# --- Jitter настройки ---

amnezia_jitter_settings() {
    if [[ ! -f "$AMNEZIA_CONFIG" ]]; then
        ui_error "Конфиг не найден. Сначала установите AmneziaWG."
        return
    fi

    local jc jmin jmax s1 s2 h1 h2 h3 h4
    jc=$(grep "^Jc" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmin=$(grep "^Jmin" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmax=$(grep "^Jmax" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s1=$(grep "^S1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s2=$(grep "^S2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h1=$(grep "^H1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h2=$(grep "^H2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h3=$(grep "^H3" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h4=$(grep "^H4" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')

    local msg="Текущие Jitter-параметры:\n\n"
    msg+="  Jc   = $jc    (количество junk-пакетов)\n"
    msg+="  Jmin = $jmin  (мин. размер junk, байт)\n"
    msg+="  Jmax = $jmax  (макс. размер junk, байт)\n"
    msg+="  S1   = $s1    (init packet magic)\n"
    msg+="  S2   = $s2    (response packet magic)\n"
    msg+="  H1   = $h1\n  H2   = $h2\n  H3   = $h3\n  H4   = $h4\n"

    local choice
    choice=$(ui_menu "$msg" \
        "1" "Изменить Jc (junk count)" \
        "2" "Изменить Jmin/Jmax (junk size)" \
        "3" "Перегенерировать все параметры (случайные)" \
        "0" "Назад") || return

    case "$choice" in
        1)
            local new_jc
            new_jc=$(ui_input "Jc (junk count, 0-128):" "$jc" "Jitter") || return
            [[ -z "$new_jc" ]] && return
            sed -i "s/^Jc = .*/Jc = $new_jc/" "$AMNEZIA_CONFIG"
            _amnezia_update_peer_configs
            ui_success "Jc изменён на $new_jc.\nНе забудьте обновить клиентские конфиги!"
            ;;
        2)
            local new_jmin new_jmax
            new_jmin=$(ui_input "Jmin (мин. размер junk, байт):" "$jmin" "Jitter") || return
            new_jmax=$(ui_input "Jmax (макс. размер junk, байт):" "$jmax" "Jitter") || return
            [[ -z "$new_jmin" || -z "$new_jmax" ]] && return
            sed -i "s/^Jmin = .*/Jmin = $new_jmin/" "$AMNEZIA_CONFIG"
            sed -i "s/^Jmax = .*/Jmax = $new_jmax/" "$AMNEZIA_CONFIG"
            _amnezia_update_peer_configs
            ui_success "Jmin=$new_jmin, Jmax=$new_jmax.\nНе забудьте обновить клиентские конфиги!"
            ;;
        3)
            if ui_confirm "Перегенерировать ВСЕ jitter-параметры?\n\nВСЕ клиентские конфиги станут недействительными!"; then
                local new_s1 new_s2 new_h1 new_h2 new_h3 new_h4
                new_jc=$((RANDOM % 10 + 3))
                new_jmin=$((RANDOM % 50 + 40))
                new_jmax=$((RANDOM % 500 + 500))
                new_s1=$((RANDOM * RANDOM))
                new_s2=$((RANDOM * RANDOM))
                new_h1=$((RANDOM * RANDOM))
                new_h2=$((RANDOM * RANDOM))
                new_h3=$((RANDOM * RANDOM))
                new_h4=$((RANDOM * RANDOM))

                sed -i "s/^Jc = .*/Jc = $new_jc/" "$AMNEZIA_CONFIG"
                sed -i "s/^Jmin = .*/Jmin = $new_jmin/" "$AMNEZIA_CONFIG"
                sed -i "s/^Jmax = .*/Jmax = $new_jmax/" "$AMNEZIA_CONFIG"
                sed -i "s/^S1 = .*/S1 = $new_s1/" "$AMNEZIA_CONFIG"
                sed -i "s/^S2 = .*/S2 = $new_s2/" "$AMNEZIA_CONFIG"
                sed -i "s/^H1 = .*/H1 = $new_h1/" "$AMNEZIA_CONFIG"
                sed -i "s/^H2 = .*/H2 = $new_h2/" "$AMNEZIA_CONFIG"
                sed -i "s/^H3 = .*/H3 = $new_h3/" "$AMNEZIA_CONFIG"
                sed -i "s/^H4 = .*/H4 = $new_h4/" "$AMNEZIA_CONFIG"

                _amnezia_update_peer_configs

                if amnezia_is_running; then
                    amnezia_restart
                fi

                ui_success "Jitter-параметры перегенерированы.\n\nВсе клиентские конфиги обновлены.\nРаздайте клиентам новые конфиги/QR."
            fi
            ;;
        0) return ;;
    esac

    if amnezia_is_running; then
        amnezia_restart
    fi
}

# Обновляет jitter-параметры во всех клиентских конфигах
_amnezia_update_peer_configs() {
    [[ ! -d "$AMNEZIA_CONFIG_DIR/peers" ]] && return

    local jc jmin jmax s1 s2 h1 h2 h3 h4
    jc=$(grep "^Jc" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmin=$(grep "^Jmin" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    jmax=$(grep "^Jmax" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s1=$(grep "^S1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    s2=$(grep "^S2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h1=$(grep "^H1" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h2=$(grep "^H2" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h3=$(grep "^H3" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')
    h4=$(grep "^H4" "$AMNEZIA_CONFIG" | head -1 | awk '{print $3}')

    local conf
    for conf in "$AMNEZIA_CONFIG_DIR/peers"/*/client.conf; do
        [[ ! -f "$conf" ]] && continue
        sed -i "s/^Jc = .*/Jc = $jc/" "$conf"
        sed -i "s/^Jmin = .*/Jmin = $jmin/" "$conf"
        sed -i "s/^Jmax = .*/Jmax = $jmax/" "$conf"
        sed -i "s/^S1 = .*/S1 = $s1/" "$conf"
        sed -i "s/^S2 = .*/S2 = $s2/" "$conf"
        sed -i "s/^H1 = .*/H1 = $h1/" "$conf"
        sed -i "s/^H2 = .*/H2 = $h2/" "$conf"
        sed -i "s/^H3 = .*/H3 = $h3/" "$conf"
        sed -i "s/^H4 = .*/H4 = $h4/" "$conf"
    done
}

# --- Конфигурация ---

amnezia_show_config() {
    if [[ ! -f "$AMNEZIA_CONFIG" ]]; then
        ui_error "Конфиг не найден: $AMNEZIA_CONFIG"
        return
    fi
    local config
    config=$(cat "$AMNEZIA_CONFIG")
    ui_msgbox "$config" "Конфиг AmneziaWG ($AMNEZIA_CONFIG)"
}

# --- Удаление ---

amnezia_uninstall() {
    if ! ui_confirm "Удалить AmneziaWG?\n\nИнтерфейс будет остановлен,\nвсе пиры и конфиги — удалены."; then
        return
    fi

    awg-quick down "$AMNEZIA_INTERFACE" 2>/dev/null || true
    systemctl disable "awg-quick@${AMNEZIA_INTERFACE}" 2>/dev/null || true

    local tmp="${PROTOCOLS_JSON}.tmp.$$"
    jq '.amneziawg.enabled = false' "$PROTOCOLS_JSON" > "$tmp" && mv "$tmp" "$PROTOCOLS_JSON"

    log_info "AmneziaWG удалён"
    ui_success "AmneziaWG удалён.\n\nКонфиги сохранены в $AMNEZIA_CONFIG_DIR\n(удалите вручную при необходимости)."
}

# --- Главное меню ---

amnezia_manage() {
    while true; do
        local status_line="не установлен"
        if amnezia_is_installed; then
            if amnezia_is_running; then
                status_line="запущен [●]"
            else
                status_line="остановлен [⏹]"
            fi
        fi

        # Считаем пиров
        local peer_count=0
        if [[ -d "$AMNEZIA_CONFIG_DIR/peers" ]]; then
            peer_count=$(ls -d "$AMNEZIA_CONFIG_DIR/peers"/*/ 2>/dev/null | wc -l || echo "0")
        fi

        local choice
        choice=$(ui_menu "AmneziaWG — $status_line ($peer_count пиров)" \
            "a" "Установить" \
            "b" "Запустить / Остановить" \
            "c" "Перезапустить" \
            "d" "Добавить пир (клиента)" \
            "e" "Удалить пир" \
            "f" "Jitter настройки" \
            "g" "Просмотреть конфиг" \
            "h" "Удалить AmneziaWG" \
            "0" "Назад") || break

        case "$choice" in
            a) amnezia_install         ;;
            b) amnezia_start_stop      ;;
            c) amnezia_restart         ;;
            d) amnezia_add_peer        ;;
            e) amnezia_remove_peer     ;;
            f) amnezia_jitter_settings ;;
            g) amnezia_show_config     ;;
            h) amnezia_uninstall       ;;
            0) return                  ;;
        esac
    done
}
