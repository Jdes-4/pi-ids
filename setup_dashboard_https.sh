#!/bin/bash

set -e

APP_PORT="5005"
DOMAIN_NAME="ids.local"
SSL_DIR="/etc/nginx/ssl"
SITE_NAME="ids-dashboard"
NGINX_AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
NGINX_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"

echo "================================="
echo " IDS Dashboard HTTPS Setup"
echo "================================="

read -p "Enter dashboard name/IP for certificate [ids.local]: " INPUT_DOMAIN

if [ -n "$INPUT_DOMAIN" ]; then
    DOMAIN_NAME="$INPUT_DOMAIN"
fi

echo "[+] Installing Nginx and OpenSSL..."
sudo apt update
sudo apt install -y nginx openssl

echo "[+] Creating SSL directory..."
sudo mkdir -p "$SSL_DIR"

echo "[+] Generating self-signed TLS certificate..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_DIR/ids.key" \
    -out "$SSL_DIR/ids.crt" \
    -subj "/CN=$DOMAIN_NAME"

echo "[+] Creating Nginx reverse proxy config..."
sudo tee "$NGINX_AVAILABLE" > /dev/null <<EOF
server {
    listen 80;
    server_name _;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate $SSL_DIR/ids.crt;
    ssl_certificate_key $SSL_DIR/ids.key;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

echo "[+] Enabling Nginx site..."
sudo ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"

echo "[+] Removing default Nginx site if present..."
sudo rm -f /etc/nginx/sites-enabled/default

echo "[+] Testing Nginx configuration..."
sudo nginx -t

echo "[+] Restarting Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

echo
echo "================================="
echo " HTTPS setup complete"
echo "================================="
echo "Make sure Flask runs on:"
echo "  127.0.0.1:$APP_PORT"
echo
echo "Access dashboard at:"
echo "  https://<pi-ip-address>"
echo
echo "Browser warning is expected because this uses a self-signed certificate."