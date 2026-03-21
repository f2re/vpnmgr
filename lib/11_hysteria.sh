#!/usr/bin/env bash

# lib/11_hysteria.sh - Управление Hysteria 2

hysteria_manage() {
    local choice
    choice=$(ui_menu "Управление Hysteria 2" \
        "a" "Установить" \
        "b" "Запустить/Остановить" \
        "c" "Port hopping ON/OFF" \
        "d" "Изменить masquerade URL" \
        "e" "Salamander obfs ON/OFF" \
        "f" "Просмотреть конфиг" \
        "0" "Назад")

    case "$choice" in
        0) return ;;
        *) ui_msgbox "Функция в разработке" ;;
    esac
}
