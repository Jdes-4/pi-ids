#!/bin/bash

set -e

PROJECT_DIR="/home/ids/pi-ids"
SERVICE_NAME="pi-ids"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
ENV_DIR="/etc/pi-ids"
ENV_FILE="$ENV_DIR/pi-ids.env"
PYTHON_BIN="$PROJECT_DIR/venv/bin/python"

AP_IFACE="wlan0"
WAN_IFACE="eth0"
AP_IP="192.168.50.1"
AP_NETMASK="255.255.255.0"
DHCP_START="192.168.50.10"
DHCP_END="192.168.50.100"
SSID="IDS-Network"

APP_PORT="5005"
DOMAIN_NAME="ids.local"
SSL_DIR="/etc/nginx/ssl"
SITE_NAME="ids-dashboard"
NGINX_AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
NGINX_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"

run_quiet() {
    "$@" >/dev/null 2>&1
}

heading() {
    echo
    echo "================================="
    echo " $1"
    echo "================================="
}

setup_inputs() {
    heading "Pi IDS Installer"

    read -p "Enter AP SSID [IDS-Network]: " INPUT_SSID
    if [ -n "$INPUT_SSID" ]; then
        SSID="$INPUT_SSID"
    fi

    read -s -p "Enter AP WiFi password (minimum 8 characters): " PASSPHRASE
    echo

    if [ ${#PASSPHRASE} -lt 8 ]; then
        echo "Error: WPA2 password must be at least 8 characters."
        exit 1
    fi

    read -p "Enter dashboard certificate name/IP [ids.local]: " INPUT_DOMAIN
    if [ -n "$INPUT_DOMAIN" ]; then
        DOMAIN_NAME="$INPUT_DOMAIN"
    fi
}

install_packages() {
    echo "[+] Installing required packages...(This may take a few minutes!)"
    export DEBIAN_FRONTEND=noninteractive

    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    run_quiet apt update
    run_quiet apt install -y hostapd dnsmasq iptables-persistent nginx openssl python3-venv
    echo "[+] Package installation complete."
}

setup_python_env() {
    echo "[+] Setting up Python virtual environment..."

    cd "$PROJECT_DIR"

    if [ ! -d "$PROJECT_DIR/venv" ]; then
        run_quiet python3 -m venv venv
    fi

    run_quiet "$PYTHON_BIN" -m pip install --upgrade pip
    run_quiet "$PYTHON_BIN" -m pip install -r requirements.txt
}

setup_ap() {
    heading "Access Point Setup"

    echo "[+] Checking Ethernet link..."

    if [ "$(cat /sys/class/net/$WAN_IFACE/carrier 2>/dev/null)" != "1" ]; then
        echo "Error: No Ethernet link detected on $WAN_IFACE."
        echo "Connect the Pi to the router using Ethernet before running this installer."
        exit 1
    fi

    echo "[+] Checking internet connectivity..."

    if ! ping -I "$WAN_IFACE" -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Error: $WAN_IFACE does not have internet access."
        exit 1
    fi

    echo "[+] Stopping network services..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl stop wpa_supplicant 2>/dev/null || true
    systemctl disable wpa_supplicant 2>/dev/null || true

    echo "[+] Removing existing Wi-Fi client profiles..."

    nmcli -t -f NAME,TYPE connection show | while IFS=: read -r NAME TYPE; do
    if [ "$TYPE" = "wifi" ]; then
        nmcli connection delete "$NAME" >/dev/null 2>&1 || true
    fi
    done

    echo "[+] Preparing wireless interface..."

    systemctl disable wpa_supplicant 2>/dev/null || true
        systemctl stop wpa_supplicant 2>/dev/null || true

            nmcli dev disconnect "$AP_IFACE" >/dev/null 2>&1 || true
    nmcli dev set "$AP_IFACE" managed no >/dev/null 2>&1 || true

    rfkill unblock wifi 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip link set "$AP_IFACE" up 2>/dev/null || true

    echo "[+] Configuring static AP IP..."
    touch /etc/dhcpcd.conf
    sed -i '/# BEGIN PI IDS AP CONFIG/,/# END PI IDS AP CONFIG/d' /etc/dhcpcd.conf

    tee -a /etc/dhcpcd.conf > /dev/null <<EOF

    # BEGIN PI IDS AP CONFIG
    interface $AP_IFACE
    static ip_address=$AP_IP/24
    nohook wpa_supplicant
        # END PI IDS AP CONFIG
EOF

    ip addr flush dev "$AP_IFACE"
    ip addr add "$AP_IP/24" dev "$AP_IFACE"
    ip link set "$AP_IFACE" up

    echo "[+] Writing hostapd configuration..."
    tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
    interface=$AP_IFACE
    driver=nl80211
    ssid=$SSID
    hw_mode=g
    channel=6
    wmm_enabled=0
    macaddr_acl=0
    auth_algs=1
    ignore_broadcast_ssid=0

    wpa=2
    wpa_passphrase=$PASSPHRASE
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
EOF

    sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

    echo "[+] Writing dnsmasq configuration..."

    if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.backup ]; then
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
    fi

    tee /etc/dnsmasq.conf > /dev/null <<EOF
    interface=$AP_IFACE
    dhcp-range=$DHCP_START,$DHCP_END,$AP_NETMASK,24h
    domain-needed
    bogus-priv
EOF

    echo "[+] Enabling IPv4 forwarding..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-pi-ids.conf
    run_quiet sysctl --system

    echo "[+] Configuring NAT rules..."
    iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$WAN_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$AP_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true

    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$WAN_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$AP_IFACE" -o "$WAN_IFACE" -j ACCEPT

    run_quiet netfilter-persistent save

    echo "[+] Enabling AP services..."
    systemctl unmask hostapd >/dev/null 2>&1 || true
    run_quiet systemctl enable hostapd
    run_quiet systemctl enable dnsmasq
    run_quiet systemctl restart dnsmasq
    run_quiet systemctl restart hostapd

    sleep 3

    if ! iw dev | grep -q "type AP"; then
        echo "Warning: $AP_IFACE may not have entered AP mode yet."
        echo "A reboot may be required."
    fi
}

setup_https() {
    heading "HTTPS Dashboard Setup"

    echo "[+] Creating SSL directory..."
    mkdir -p "$SSL_DIR"

    if [ ! -f "$SSL_DIR/ids.crt" ] || [ ! -f "$SSL_DIR/ids.key" ]; then
        echo "[+] Generating self-signed TLS certificate..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_DIR/ids.key" \
            -out "$SSL_DIR/ids.crt" \
            -subj "/CN=$DOMAIN_NAME" >/dev/null 2>&1
    else
        echo "[+] Existing TLS certificate found, skipping generation."
    fi

    echo "[+] Writing Nginx reverse proxy configuration..."
    tee "$NGINX_AVAILABLE" > /dev/null <<EOF
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
    ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default

    echo "[+] Testing Nginx configuration..."
    nginx -t >/dev/null

    echo "[+] Restarting Nginx..."
    run_quiet systemctl enable nginx
    run_quiet systemctl restart nginx
}

setup_credentials() {
    REGENERATE_CREDS="y"

    if [ -f "$ENV_FILE" ]; then
        echo
        echo "[+] Existing dashboard credentials detected."
        read -p "Regenerate dashboard credentials? (y/N): " RESPONSE

        if [[ ! "$RESPONSE" =~ ^[Yy]$ ]]; then
            REGENERATE_CREDS="n"
        fi
    fi

    mkdir -p "$ENV_DIR"

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

        echo "[+] Writing secure environment file..."
        tee "$ENV_FILE" > /dev/null <<EOF
IDS_ADMIN_USER='$ADMIN_USER'
IDS_ADMIN_PASSWORD_HASH='$ADMIN_PASSWORD_HASH'
IDS_SECRET_KEY='$SECRET_KEY'
IDS_INTERFACE='$AP_IFACE'
EOF

        chmod 600 "$ENV_FILE"
    else
        echo "[+] Preserving existing dashboard credentials."
    fi
}

setup_service() {
    heading "Pi IDS Service Setup"

    setup_credentials

    echo "[+] Writing systemd service..."
    tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Pi IDS
After=network.target nginx.service hostapd.service dnsmasq.service
Wants=nginx.service hostapd.service dnsmasq.service

[Service]
WorkingDirectory=$PROJECT_DIR
ExecStart=$PYTHON_BIN $PROJECT_DIR/app.py
Restart=always
RestartSec=5
User=root
EnvironmentFile=$ENV_FILE

[Install]
WantedBy=multi-user.target
EOF

    echo "[+] Reloading systemd..."
    run_quiet systemctl daemon-reload

    echo "[+] Enabling IDS service..."
    run_quiet systemctl enable "$SERVICE_NAME"

    echo "[+] Restarting IDS service..."
    run_quiet systemctl restart "$SERVICE_NAME"
}

main() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run this installer with sudo:"
        echo "sudo ./setup_all.sh"
        exit 1
    fi

    setup_inputs
    install_packages
    setup_python_env
    setup_ap
    setup_https
    setup_service

    ETH_IP=$(ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
    echo
    echo "================================="
    echo " Installation Complete"
    echo "================================="
    echo "AP SSID: $SSID"
    echo "AP Gateway: $AP_IP"
    echo "Dashboard address:"
    if [ -n "$ETH_IP" ]; then
    echo "  https://$ETH_IP"
    fi
    echo
    echo "Browser warning is expected because the dashboard uses a self-signed certificate."
    echo
    echo
    echo "A reboot is recommended:"
    echo "  sudo reboot"
}

main