#!/usr/bin/env bash

# Версия и метаданные
VPNMGR_VERSION="1.0.0"
VPNMGR_REPO="https://github.com/meteo/vpnmgr"

# Пути (используем относительные для разработки, но в проде это будет /opt/vpnmgr)
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

# Цвета (ANSI)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Whiptail настройки
WT_TITLE="vpnmgr v$VPNMGR_VERSION"
WT_BACKTITLE="VPN Manager - Управление VLESS, Hysteria2, AmneziaWG"
