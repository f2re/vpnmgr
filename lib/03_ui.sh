#!/usr/bin/env bash

# Обёртки над whiptail

ui_msgbox() {
    local title="${2:-Инфо}"
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" --msgbox "$1" 10 60
}

ui_error() {
    whiptail --title "ОШИБКА" --backtitle "$WT_BACKTITLE" --msgbox "$1" 12 60
}

ui_warn() {
    whiptail --title "ПРЕДУПРЕЖДЕНИЕ" --backtitle "$WT_BACKTITLE" --msgbox "$1" 10 60
}

ui_confirm() {
    local title="${2:-Подтверждение}"
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" --yesno "$1" 10 60
}

ui_input() {
    local prompt="$1"
    local default="$2"
    local title="${3:-Ввод}"
    whiptail --title "$title" --backtitle "$WT_BACKTITLE" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
}

ui_menu() {
    local prompt="$1"
    shift
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" --menu "$prompt" 20 70 12 "$@" 3>&1 1>&2 2>&3
}

ui_checklist() {
    local prompt="$1"
    shift
    whiptail --title "$WT_TITLE" --backtitle "$WT_BACKTITLE" --checklist "$prompt" 20 70 10 "$@" 3>&1 1>&2 2>&3
}
