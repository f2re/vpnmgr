#!/usr/bin/env bash

# lib/51_updater.sh - Обновление компонентов

# --- Проверка версий ---

_updater_get_local_version() {
    local component="$1"
    case "$component" in
        xray)
            if [[ -x "$XRAY_BIN" ]]; then
                "$XRAY_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "неизвестно"
            else
                echo "не установлен"
            fi
            ;;
        hysteria)
            if [[ -x "$HYSTERIA_BIN" ]]; then
                "$HYSTERIA_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "неизвестно"
            else
                echo "не установлен"
            fi
            ;;
        vpnmgr)
            echo "$VPNMGR_VERSION"
            ;;
    esac
}

_updater_get_remote_version() {
    local component="$1"
    local api_url
    case "$component" in
        xray)     api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest" ;;
        hysteria) api_url="https://api.github.com/repos/apernet/hysteria/releases/latest" ;;
        vpnmgr)   api_url="https://api.github.com/repos/f2re/vpnmgr/releases/latest" ;;
        *)        echo "неизвестно"; return ;;
    esac

    curl -s --max-time 10 "$api_url" 2>/dev/null | jq -r '.tag_name // "неизвестно"'
}

updater_check_versions() {
    local msg=""

    # Собираем версии с прогресс-баром
    local xray_local xray_remote hy_local hy_remote vpnmgr_local vpnmgr_remote

    {
        echo "10"
        echo "XXX"
        echo "Проверка Xray..."
        echo "XXX"

        xray_local=$(_updater_get_local_version xray)
        xray_remote=$(_updater_get_remote_version xray)

        echo "40"
        echo "XXX"
        echo "Проверка Hysteria 2..."
        echo "XXX"

        hy_local=$(_updater_get_local_version hysteria)
        hy_remote=$(_updater_get_remote_version hysteria)

        echo "70"
        echo "XXX"
        echo "Проверка vpnmgr..."
        echo "XXX"

        vpnmgr_local=$(_updater_get_local_version vpnmgr)
        vpnmgr_remote=$(_updater_get_remote_version vpnmgr)

        echo "100"
        echo "XXX"
        echo "Готово!"
        echo "XXX"
    } | ui_progress "Проверка версий..." "Обновления"

    # Повторно получаем (после pipe subshell переменные теряются)
    xray_local=$(_updater_get_local_version xray)
    xray_remote=$(_updater_get_remote_version xray)
    hy_local=$(_updater_get_local_version hysteria)
    hy_remote=$(_updater_get_remote_version hysteria)
    vpnmgr_local="$VPNMGR_VERSION"
    vpnmgr_remote=$(_updater_get_remote_version vpnmgr)

    msg+="=== Версии компонентов ===\n\n"
    msg+="Xray-core:\n"
    msg+="  Установлена: $xray_local\n"
    msg+="  Доступна:    $xray_remote\n\n"
    msg+="Hysteria 2:\n"
    msg+="  Установлена: $hy_local\n"
    msg+="  Доступна:    $hy_remote\n\n"
    msg+="vpnmgr:\n"
    msg+="  Установлена: $vpnmgr_local\n"
    msg+="  Доступна:    $vpnmgr_remote"

    ui_msgbox "$msg" "Проверка версий"
}

# --- Обновление Xray ---

updater_update_xray() {
    if ! xray_is_installed; then
        ui_error "Xray не установлен.\nИспользуйте раздел Протоколы для установки."
        return
    fi

    local current_ver
    current_ver=$(_updater_get_local_version xray)
    local remote_ver
    remote_ver=$(_updater_get_remote_version xray)

    if [[ "$remote_ver" == "неизвестно" ]]; then
        ui_error "Не удалось проверить новую версию.\nПроверьте интернет-соединение."
        return
    fi

    if ! ui_confirm "Обновить Xray?\n\nТекущая: $current_ver\nДоступна: $remote_ver\n\nСервис будет перезапущен."; then
        return
    fi

    # Бэкап текущего бинарника
    cp "$XRAY_BIN" "${XRAY_BIN}.bak.$(date +%s)" 2>/dev/null || true

    # Используем ту же функцию установки — она обновит бинарник
    xray_install
}

# --- Обновление Hysteria ---

updater_update_hysteria() {
    if ! hysteria_is_installed; then
        ui_error "Hysteria 2 не установлен.\nИспользуйте раздел Протоколы для установки."
        return
    fi

    local current_ver
    current_ver=$(_updater_get_local_version hysteria)
    local remote_ver
    remote_ver=$(_updater_get_remote_version hysteria)

    if [[ "$remote_ver" == "неизвестно" ]]; then
        ui_error "Не удалось проверить новую версию.\nПроверьте интернет-соединение."
        return
    fi

    if ! ui_confirm "Обновить Hysteria 2?\n\nТекущая: $current_ver\nДоступна: $remote_ver\n\nСервис будет перезапущен."; then
        return
    fi

    # Бэкап текущего бинарника
    cp "$HYSTERIA_BIN" "${HYSTERIA_BIN}.bak.$(date +%s)" 2>/dev/null || true

    # Используем ту же функцию установки — она обновит бинарник
    hysteria_install
}

# --- Обновление vpnmgr ---

updater_update_vpnmgr() {
    local remote_ver
    remote_ver=$(_updater_get_remote_version vpnmgr)

    if [[ "$remote_ver" == "неизвестно" ]]; then
        ui_error "Не удалось проверить новую версию vpnmgr.\nПроверьте интернет-соединение."
        return
    fi

    if ! ui_confirm "Обновить vpnmgr?\n\nТекущая: $VPNMGR_VERSION\nДоступна: $remote_ver\n\nФайлы data/ не будут затронуты."; then
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive_url="https://github.com/f2re/vpnmgr/archive/refs/heads/main.tar.gz"

    {
        echo "10"
        echo "XXX"
        echo "Скачивание обновления..."
        echo "XXX"

        if ! curl -L --silent --show-error "$archive_url" -o "$tmp_dir/vpnmgr.tar.gz" 2>"$tmp_dir/curl.err"; then
            rm -rf "$tmp_dir"
            exit 1
        fi

        echo "40"
        echo "XXX"
        echo "Распаковка..."
        echo "XXX"

        tar -xzf "$tmp_dir/vpnmgr.tar.gz" -C "$tmp_dir/"
        local extracted_dir
        extracted_dir=$(ls -d "$tmp_dir"/vpnmgr-* 2>/dev/null | head -1)

        if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
            rm -rf "$tmp_dir"
            exit 1
        fi

        echo "70"
        echo "XXX"
        echo "Обновление файлов..."
        echo "XXX"

        # Обновляем только скрипты, не трогаем data/ и backups/
        cp -f "$extracted_dir/vpnmgr.sh" "$BASE_DIR/vpnmgr.sh"
        cp -rf "$extracted_dir/lib/"* "$BASE_DIR/lib/" 2>/dev/null || true
        cp -rf "$extracted_dir/templates/"* "$BASE_DIR/templates/" 2>/dev/null || true
        [[ -f "$extracted_dir/install.sh" ]] && cp -f "$extracted_dir/install.sh" "$BASE_DIR/install.sh"

        chmod +x "$BASE_DIR/vpnmgr.sh"

        echo "100"
        echo "XXX"
        echo "Готово!"
        echo "XXX"

    } | ui_progress "Обновление vpnmgr..." "Обновление"

    local update_ok=$?
    rm -rf "$tmp_dir"

    if [[ $update_ok -ne 0 ]]; then
        ui_error "Ошибка обновления vpnmgr."
        return 1
    fi

    log_success "vpnmgr обновлён до $remote_ver"
    ui_success "vpnmgr обновлён!\n\nПерезапустите vpnmgr для применения изменений."
}

# --- Меню обновлений ---

updater_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Обновления" \
            "1" "Проверить версии" \
            "2" "Обновить Xray-core" \
            "3" "Обновить Hysteria 2" \
            "4" "Обновить vpnmgr" \
            "0" "Назад") || break

        case "$choice" in
            1) updater_check_versions   || true ;;
            2) updater_update_xray      || true ;;
            3) updater_update_hysteria  || true ;;
            4) updater_update_vpnmgr    || true ;;
            0) return                   ;;
        esac
    done
}
