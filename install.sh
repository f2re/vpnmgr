#!/usr/bin/env bash

# install.sh - Скрипт установки vpnmgr

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Запустите от имени root: sudo bash install.sh" && exit 1

INSTALL_DIR="/opt/vpnmgr"
BIN_LINK="/usr/local/bin/vpnmgr"

echo "=== Установка vpnmgr ==="
echo ""

# Создание директории
mkdir -p "$INSTALL_DIR"

# Копирование файлов
echo "[1/5] Копирование файлов в $INSTALL_DIR..."
cp -r . "$INSTALL_DIR/"
rm -rf "$INSTALL_DIR/.git" 2>/dev/null || true

# Права
chmod +x "$INSTALL_DIR/vpnmgr.sh"
chmod +x "$INSTALL_DIR/watchdog.sh"

# Создание симлинка
echo "[2/5] Создание команды vpnmgr..."
ln -sf "$INSTALL_DIR/vpnmgr.sh" "$BIN_LINK"

# Установка зависимостей
echo "[3/5] Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq jq whiptail curl qrencode openssl

# Создание директорий данных
echo "[4/5] Инициализация..."
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/logs" "$INSTALL_DIR/backups"

# Инициализация data-файлов если не существуют
if [[ ! -f "$INSTALL_DIR/data/users.json" ]]; then
    echo '{"version":"1","users":[]}' > "$INSTALL_DIR/data/users.json"
fi

if [[ ! -f "$INSTALL_DIR/data/server.json" ]]; then
    # Определяем IP сервера
    local_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    cat > "$INSTALL_DIR/data/server.json" <<EOF
{
  "hostname": "",
  "ip": "$local_ip",
  "cert_path": "",
  "key_path": "",
  "email": "admin@example.com"
}
EOF
fi

# Настройка cron
echo "[5/5] Настройка cron..."
cat > /etc/cron.d/vpnmgr <<EOF
# vpnmgr - watchdog каждые 5 минут
*/5 * * * * root $INSTALL_DIR/watchdog.sh >> $INSTALL_DIR/logs/watchdog.log 2>&1

# Ночной бэкап (03:00)
0 3 * * * root $INSTALL_DIR/vpnmgr.sh --backup-silent >> $INSTALL_DIR/logs/vpnmgr.log 2>&1

# Проверка TLS сертификата (09:00)
0 9 * * * root $INSTALL_DIR/vpnmgr.sh --check-cert >> $INSTALL_DIR/logs/vpnmgr.log 2>&1
EOF
chmod 644 /etc/cron.d/vpnmgr

# Logrotate
cat > /etc/logrotate.d/vpnmgr <<EOF
$INSTALL_DIR/logs/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF

echo ""
echo "=== Установка завершена! ==="
echo ""
echo "  Запустите: vpnmgr"
echo ""
