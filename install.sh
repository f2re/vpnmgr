#!/usr/bin/env bash

# install.sh - Скрипт установки vpnmgr

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Запустите от имени root" && exit 1

INSTALL_DIR="/opt/vpnmgr"
BIN_LINK="/usr/local/bin/vpnmgr"

echo "Установка vpnmgr в $INSTALL_DIR..."

# Создание директории
mkdir -p "$INSTALL_DIR"

# Копирование файлов (предполагаем, что мы в корне репозитория)
cp -r . "$INSTALL_DIR/"

# Права
chmod +x "$INSTALL_DIR/vpnmgr.sh"

# Создание симлинка
ln -sf "$INSTALL_DIR/vpnmgr.sh" "$BIN_LINK"

# Установка зависимостей
echo "Установка зависимостей..."
apt-get update && apt-get install -y jq whiptail curl qrencode openssl

echo "Установка завершена! Запустите 'vpnmgr' для начала работы."
