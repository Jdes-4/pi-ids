#!/bin/bash

set -e

PROJECT_DIR="/home/ids/pi-ids"
SERVICE_NAME="pi-ids"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
PYTHON_BIN="$PROJECT_DIR/venv/bin/python"

echo "================================="
echo " Pi IDS Service Setup"
echo "================================="

REGENERATE_CREDS="y"

if [ -f "$SERVICE_FILE" ]; then
echo
echo "[+] Existing Pi IDS service detected."

read -p "Regenerate dashboard credentials? (y/N): " RESPONSE

if [[ ! "$RESPONSE" =~ ^[Yy]$ ]]; then
    REGENERATE_CREDS="n"
fi

fi

if [ "$REGENERATE_CREDS" = "y" ]; then

echo
echo "[+] Creating dashboard credentials..."

read -p "Enter dashboard username: " ADMIN_USER

read -s -p "Enter dashboard password: " ADMIN_PASSWORD
echo

read -s -p "Confirm dashboard password: " ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo "Error: Passwords do not match."
    exit 1
fi

ADMIN_PASSWORD_HASH=$(
    "$PYTHON_BIN" -c "

from werkzeug.security import generate_password_hash
import sys
print(generate_password_hash(sys.argv[1]))
" "$ADMIN_PASSWORD"
)

SECRET_KEY=$(openssl rand -hex 32)

else

echo
echo "[+] Preserving existing credentials..."

EXISTING_USER=$(grep "^Environment=IDS_ADMIN_USER=" "$SERVICE_FILE" | cut -d= -f3-)
EXISTING_HASH=$(grep "^Environment=IDS_ADMIN_PASSWORD_HASH=" "$SERVICE_FILE" | cut -d= -f3-)
EXISTING_SECRET=$(grep "^Environment=IDS_SECRET_KEY=" "$SERVICE_FILE" | cut -d= -f3-)

ADMIN_USER="$EXISTING_USER"
ADMIN_PASSWORD_HASH="$EXISTING_HASH"
SECRET_KEY="$EXISTING_SECRET"

fi

echo
echo "[+] Writing systemd service..."

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Pi IDS
After=network.target

[Service]
WorkingDirectory=$PROJECT_DIR
ExecStart=$PYTHON_BIN $PROJECT_DIR/app.py

Restart=always
RestartSec=5

User=root

Environment=IDS_ADMIN_USER=$ADMIN_USER
Environment=IDS_ADMIN_PASSWORD_HASH=$ADMIN_PASSWORD_HASH
Environment=IDS_SECRET_KEY=$SECRET_KEY
Environment=IDS_INTERFACE=wlan0

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Reloading systemd..."
sudo systemctl daemon-reload

echo "[+] Enabling service..."
sudo systemctl enable $SERVICE_NAME

echo "[+] Restarting service..."
sudo systemctl restart $SERVICE_NAME

echo
echo "================================="
echo " Setup Complete"
echo "================================="
echo

sudo systemctl status $SERVICE_NAME --no-pager