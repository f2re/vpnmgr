#!/usr/bin/env bash

# Версия и метаданные
VPNMGR_VERSION="1.0.0"
VPNMGR_REPO="https://github.com/f2re/vpnmgr"

# Пути
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB_DIR="$BASE_DIR/lib"
DATA_DIR="$BASE_DIR/data"
LOGS_DIR="$BASE_DIR/logs"
BACKUPS_DIR="$BASE_DIR/backups"
TEMPLATES_DIR="$BASE_DIR/templates"

# Файлы БД
USERS_JSON="$DATA_DIR/users.json"
PROTOCOLS_JSON="$DATA_DIR/protocols.json"
SERVER_JSON="$DATA_DIR/server.json"

# Логи
MAIN_LOG="$LOGS_DIR/vpnmgr.log"

# Бинарные файлы протоколов
XRAY_BIN="/usr/local/bin/xray"
HYSTERIA_BIN="/usr/local/bin/hysteria"

# Конфигурационные файлы протоколов
XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
HYSTERIA_CONFIG_DIR="/etc/hysteria"
HYSTERIA_CONFIG="$HYSTERIA_CONFIG_DIR/config.yaml"

# Systemd сервисы
XRAY_SERVICE="xray"
HYSTERIA_SERVICE="hysteria"

# sing-box
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_CONFIG_DIR/config.json"
SINGBOX_SERVICE="sing-box"

# Whiptail настройки
WT_TITLE="vpnmgr v$VPNMGR_VERSION"
WT_BACKTITLE="VPN Manager - Управление VLESS, Hysteria2, AmneziaWG, sing-box"
