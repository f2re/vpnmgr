#!/usr/bin/env bash

# lib/50_backup.sh - Бэкап, восстановление, обновления

CRON_FILE="/etc/cron.d/vpnmgr"

# --- Бэкап ---

backup_create() {
    local timestamp
    timestamp=$(date +%Y-%m-%d_%H-%M)
    local backup_file="$BACKUPS_DIR/${timestamp}.tar.gz"

    mkdir -p "$BACKUPS_DIR"

    local dirs_to_backup=("$DATA_DIR" "$TEMPLATES_DIR")
    [[ -d "$XRAY_CONFIG_DIR" ]]     && dirs_to_backup+=("$XRAY_CONFIG_DIR")
    [[ -d "$HYSTERIA_CONFIG_DIR" ]]  && dirs_to_backup+=("$HYSTERIA_CONFIG_DIR")
    [[ -d "/etc/amneziawg" ]]        && dirs_to_backup+=("/etc/amneziawg")
    [[ -d "/etc/3proxy" ]]           && dirs_to_backup+=("/etc/3proxy")
    [[ -d "/etc/sing-box" ]]         && dirs_to_backup+=("/etc/sing-box")

    {
        echo "10"
        echo "XXX"
        echo "Создание архива..."
        echo "XXX"

        if tar -czf "$backup_file" "${dirs_to_backup[@]}" 2>/dev/null; then
            echo "100"
            echo "XXX"
            echo "Готово!"
            echo "XXX"
        else
            exit 1
        fi
    } | ui_progress "Создание бэкапа..." "Бэкап"

    if [[ $? -ne 0 || ! -f "$backup_file" ]]; then
        ui_error "Ошибка создания бэкапа."
        return 1
    fi

    local size
    size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
    log_success "Создан бэкап: $backup_file ($size)"
    ui_success "Бэкап создан!\n\nФайл: $backup_file\nРазмер: $size"
}

# Тихий бэкап (для cron)
backup_create_silent() {
    local timestamp
    timestamp=$(date +%Y-%m-%d_%H-%M)
    local backup_file="$BACKUPS_DIR/${timestamp}.tar.gz"

    mkdir -p "$BACKUPS_DIR"

    local dirs_to_backup=("$DATA_DIR" "$TEMPLATES_DIR")
    [[ -d "$XRAY_CONFIG_DIR" ]]     && dirs_to_backup+=("$XRAY_CONFIG_DIR")
    [[ -d "$HYSTERIA_CONFIG_DIR" ]]  && dirs_to_backup+=("$HYSTERIA_CONFIG_DIR")
    [[ -d "/etc/amneziawg" ]]        && dirs_to_backup+=("/etc/amneziawg")
    [[ -d "/etc/3proxy" ]]           && dirs_to_backup+=("/etc/3proxy")
    [[ -d "/etc/sing-box" ]]         && dirs_to_backup+=("/etc/sing-box")

    if tar -czf "$backup_file" "${dirs_to_backup[@]}" 2>/dev/null; then
        log_info "Автобэкап создан: $backup_file"
        # Ротация: удаляем бэкапы старше 30 дней
        find "$BACKUPS_DIR" -name "*.tar.gz" -mtime +30 -delete 2>/dev/null || true
    else
        log_error "Ошибка автобэкапа"
    fi
}

backup_list() {
    mkdir -p "$BACKUPS_DIR"

    local backups
    backups=$(ls -1 "$BACKUPS_DIR"/*.tar.gz 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        ui_msgbox "Нет доступных бэкапов.\n\nСоздайте первый через 'Создать бэкап'." "Бэкапы"
        return
    fi

    local list=""
    while IFS= read -r f; do
        local name size date_str
        name=$(basename "$f")
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        date_str="${name%.tar.gz}"
        list+="  $date_str  ($size)\n"
    done <<< "$backups"

    ui_msgbox "Доступные бэкапы:\n\n$list" "Список бэкапов"
}

backup_restore() {
    mkdir -p "$BACKUPS_DIR"

    local files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local name size
        name=$(basename "$f")
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        files+=("$name" "$size")
    done < <(ls -1t "$BACKUPS_DIR"/*.tar.gz 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        ui_msgbox "Нет доступных бэкапов." "Восстановление"
        return
    fi

    local selected
    selected=$(ui_menu "Выберите бэкап для восстановления:" "${files[@]}") || return

    local backup_file="$BACKUPS_DIR/$selected"
    if [[ ! -f "$backup_file" ]]; then
        ui_error "Файл не найден: $backup_file"
        return
    fi

    if ! ui_confirm "Восстановить из бэкапа?\n\n$selected\n\nТекущие конфиги будут перезаписаны!"; then
        return
    fi

    {
        echo "10"
        echo "XXX"
        echo "Распаковка архива..."
        echo "XXX"

        if tar -xzf "$backup_file" -C / 2>/dev/null; then
            echo "70"
            echo "XXX"
            echo "Перезапуск сервисов..."
            echo "XXX"

            systemctl restart "$XRAY_SERVICE" 2>/dev/null || true
            systemctl restart "$HYSTERIA_SERVICE" 2>/dev/null || true
            systemctl restart "3proxy" 2>/dev/null || true
            systemctl restart "sing-box" 2>/dev/null || true

            echo "100"
            echo "XXX"
            echo "Готово!"
            echo "XXX"
        else
            exit 1
        fi
    } | ui_progress "Восстановление..." "Восстановление из бэкапа"

    if [[ $? -ne 0 ]]; then
        ui_error "Ошибка восстановления из бэкапа."
        return 1
    fi

    log_success "Восстановлено из бэкапа: $selected"
    ui_success "Восстановление завершено!\n\nСервисы перезапущены."
}

backup_schedule() {
    local current="не настроено"
    if [[ -f "$CRON_FILE" ]] && grep -q "backup-silent" "$CRON_FILE" 2>/dev/null; then
        local cron_line
        cron_line=$(grep "backup-silent" "$CRON_FILE")
        if echo "$cron_line" | grep -q "^0 3 \* \* \*"; then
            current="ежедневно в 03:00"
        elif echo "$cron_line" | grep -q "^0 3 \* \* 0"; then
            current="еженедельно (вс) в 03:00"
        else
            current="настроено (пользовательское)"
        fi
    fi

    local choice
    choice=$(ui_menu "Расписание автобэкапа (сейчас: $current)" \
        "1" "Ежедневно в 03:00" \
        "2" "Еженедельно (вс) в 03:00" \
        "3" "Отключить" \
        "0" "Назад") || return

    case "$choice" in
        1)
            _backup_write_cron "0 3 * * *"
            ui_success "Автобэкап настроен: ежедневно в 03:00."
            ;;
        2)
            _backup_write_cron "0 3 * * 0"
            ui_success "Автобэкап настроен: каждое воскресенье в 03:00."
            ;;
        3)
            # Удаляем строку backup из cron, но оставляем файл если есть другие записи
            if [[ -f "$CRON_FILE" ]]; then
                local tmp="${CRON_FILE}.tmp.$$"
                grep -v "backup-silent" "$CRON_FILE" > "$tmp" 2>/dev/null || true
                if [[ -s "$tmp" ]]; then
                    mv "$tmp" "$CRON_FILE"
                else
                    rm -f "$tmp" "$CRON_FILE"
                fi
            fi
            log_info "Автобэкап отключён"
            ui_success "Автобэкап отключён."
            ;;
        0) return ;;
    esac
}

_backup_write_cron() {
    local schedule="$1"
    # Сохраняем существующие записи (не backup)
    local other_lines=""
    if [[ -f "$CRON_FILE" ]]; then
        other_lines=$(grep -v "backup-silent" "$CRON_FILE" 2>/dev/null || true)
    fi

    {
        [[ -n "$other_lines" ]] && echo "$other_lines"
        echo "$schedule root $BASE_DIR/vpnmgr.sh --backup-silent >> $MAIN_LOG 2>&1"
    } > "$CRON_FILE"

    chmod 644 "$CRON_FILE"
    log_info "Автобэкап настроен: $schedule"
}

backup_export_users() {
    if [[ ! -f "$USERS_JSON" ]]; then
        ui_error "Файл пользователей не найден."
        return
    fi

    local export_file="$BACKUPS_DIR/users_export_$(date +%Y-%m-%d_%H-%M).json"
    mkdir -p "$BACKUPS_DIR"
    cp "$USERS_JSON" "$export_file"

    local count
    count=$(jq '.users | length' "$export_file" 2>/dev/null || echo "0")

    log_info "Экспорт пользователей: $export_file ($count польз.)"
    ui_success "Пользователи экспортированы!\n\nФайл: $export_file\nПользователей: $count"
}

# --- Меню бэкапа ---

backup_manage() {
    while true; do
        local choice
        choice=$(ui_menu "Бэкап и восстановление" \
            "1" "Создать бэкап сейчас" \
            "2" "Список бэкапов" \
            "3" "Восстановить из бэкапа" \
            "4" "Настроить расписание (cron)" \
            "5" "Экспорт пользователей (JSON)" \
            "0" "Назад") || break

        case "$choice" in
            1) backup_create       || true ;;
            2) backup_list         || true ;;
            3) backup_restore      || true ;;
            4) backup_schedule     || true ;;
            5) backup_export_users || true ;;
            0) return              ;;
        esac
    done
}
