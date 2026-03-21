#!/usr/bin/env bash

# Вычисляет размеры окна whiptail на основе размера терминала
# Использование: read -r h w < <(_wt_dims h_pct w_pct min_h min_w)
_wt_dims() {
    local h_pct="${1:-60}" w_pct="${2:-80}" min_h="${3:-10}" min_w="${4:-60}"
    local rows cols h w
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    h=$(( rows * h_pct / 100 )); [[ $h -lt $min_h ]] && h=$min_h
    w=$(( cols * w_pct / 100 )); [[ $w -lt $min_w ]] && w=$min_w
    echo "$h $w"
}

ui_msgbox() {
    local title="${2:-Инфо}"
    local h w; read -r h w < <(_wt_dims 55 80 10 60)
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" --msgbox "$1" "$h" "$w"
}

ui_error() {
    local h w; read -r h w < <(_wt_dims 55 80 12 65)
    whiptail --title "ОШИБКА" --backtitle "$WT_BACKTITLE" --msgbox "$1" "$h" "$w"
}

ui_warn() {
    local h w; read -r h w < <(_wt_dims 55 80 10 60)
    whiptail --title "ПРЕДУПРЕЖДЕНИЕ" --backtitle "$WT_BACKTITLE" --msgbox "$1" "$h" "$w"
}

ui_success() {
    local h w; read -r h w < <(_wt_dims 55 80 10 60)
    whiptail --title "УСПЕХ" --backtitle "$WT_BACKTITLE" --msgbox "$1" "$h" "$w"
}

ui_confirm() {
    local title="${2:-Подтверждение}"
    local h w; read -r h w < <(_wt_dims 55 80 10 60)
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" --yesno "$1" "$h" "$w"
}

ui_input() {
    local prompt="$1"
    local default="${2:-}"
    local title="${3:-Ввод}"
    local h w; read -r h w < <(_wt_dims 40 70 10 60)
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" \
        --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3
}

ui_password() {
    local prompt="$1"
    local title="${2:-Пароль}"
    local h w; read -r h w < <(_wt_dims 40 70 10 60)
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" \
        --passwordbox "$prompt" "$h" "$w" 3>&1 1>&2 2>&3
}

ui_menu() {
    local prompt="$1"
    shift
    local rows cols h w list_h
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    h=$(( rows * 80 / 100 )); [[ $h -lt 15 ]] && h=15
    w=$(( cols * 80 / 100 )); [[ $w -lt 60 ]] && w=60
    list_h=$(( h - 8 ));      [[ $list_h -lt 5 ]] && list_h=5
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" \
        --menu "$prompt" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3
}

ui_checklist() {
    local prompt="$1"
    shift
    local rows cols h w list_h
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols  2>/dev/null || echo 80)
    h=$(( rows * 80 / 100 )); [[ $h -lt 15 ]] && h=15
    w=$(( cols * 80 / 100 )); [[ $w -lt 60 ]] && w=60
    list_h=$(( h - 8 ));      [[ $list_h -lt 5 ]] && list_h=5
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" \
        --checklist "$prompt" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3
}

# Прогресс-бар. Использование: echo "50" | ui_progress "Сообщение..."
ui_progress() {
    local message="${1:-Загрузка...}"
    local title="${2:-Прогресс}"
    local h w; read -r h w < <(_wt_dims 30 70 8 50)
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" \
        --gauge "$message" "$h" "$w" 0
}
