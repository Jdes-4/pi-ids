#!/bin/bash

set -e

echo "================================="
echo " Raspberry Pi IDS AP Setup"
echo "================================="

AP_IFACE="wlan0"
WAN_IFACE="eth0"
AP_IP="192.168.50.1"
AP_NETMASK="255.255.255.0"
DHCP_START="192.168.50.10"
DHCP_END="192.168.50.100"
SSID="IDS-Network"

read -p "Enter SSID: " INPUT_SSID

if [ -n "$INPUT_SSID" ]; then
    SSID="$INPUT_SSID"
fi

read -s -p "Enter WiFi password (minimum 8 characters): " PASSPHRASE
echo

if [ ${#PASSPHRASE} -lt 8 ]; then
    echo "Error: WPA2 password must be at least 8 characters."
    exit 1
fi

echo "[+] Updating packages..."
sudo apt update

echo "[+] Installing hostapd, dnsmasq and iptables-persistent..."
sudo apt install -y hostapd dnsmasq iptables-persistent

echo "[+] Stopping services..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true

echo "[+] Releasing wlan0 from Wi-Fi client mode..."
sudo rfkill unblock wifi || true
sudo ip link set wlan0 down || true
sudo systemctl stop wpa_supplicant || true
sudo systemctl stop NetworkManager || true
sudo ip addr flush dev wlan0 || true
sudo ip link set wlan0 up || true

sudo nmcli dev set $AP_IFACE managed no 2>/dev/null || true

echo "[+] Configuring static IP..."
sudo touch /etc/dhcpcd.conf
sudo sed -i '/# BEGIN PI IDS AP CONFIG/,/# END PI IDS AP CONFIG/d' /etc/dhcpcd.conf

sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF

# BEGIN PI IDS AP CONFIG
interface $AP_IFACE
static ip_address=$AP_IP/24
nohook wpa_supplicant
# END PI IDS AP CONFIG
EOF

sudo ip addr flush dev $AP_IFACE
sudo ip addr add $AP_IP/24 dev $AP_IFACE
sudo ip link set $AP_IFACE up

echo "[+] Configuring hostapd..."

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
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

sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "[+] Configuring dnsmasq..."

if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.backup ]; then
    sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
fi

sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=$AP_IFACE
dhcp-range=$DHCP_START,$DHCP_END,$AP_NETMASK,24h
domain-needed
bogus-priv
EOF

echo "[+] Enabling IPv4 forwarding..."

echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-pi-ids.conf > /dev/null

sudo sysctl --system

echo "[+] Checking Ethernet link..."

if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" != "1" ]; then
    echo "Error: No Ethernet link detected on eth0."
    echo "Please connect the Pi to the router before running this script."
    exit 1
fi

echo "[+] Checking internet connectivity..."

if ! ping -I eth0 -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Error: eth0 does not have internet access."
    echo "Check the Ethernet cable and router connection."
    exit 1
fi

echo "[+] Configuring NAT..."

sudo iptables -t nat -D POSTROUTING -o $WAN_IFACE -j MASQUERADE 2>/dev/null || true

sudo iptables -D FORWARD \
    -i $WAN_IFACE \
    -o $AP_IFACE \
    -m state \
    --state RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || true

sudo iptables -D FORWARD \
    -i $AP_IFACE \
    -o $WAN_IFACE \
    -j ACCEPT 2>/dev/null || true

sudo iptables -t nat -A POSTROUTING -o $WAN_IFACE -j MASQUERADE

sudo iptables -A FORWARD \
    -i $WAN_IFACE \
    -o $AP_IFACE \
    -m state \
    --state RELATED,ESTABLISHED \
    -j ACCEPT

sudo iptables -A FORWARD \
    -i $AP_IFACE \
    -o $WAN_IFACE \
    -j ACCEPT

sudo netfilter-persistent save

echo "[+] Enabling services..."

sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

sudo systemctl restart dnsmasq
sudo systemctl restart hostapd

if ! sudo iw dev | grep -q "type AP"; then
    echo "ERROR: wlan0 failed to enter AP mode."
    exit 1
fi

echo
echo "================================="
echo " Setup Complete"
echo "================================="
echo "SSID: $SSID"
echo "Gateway: $AP_IP"
echo
echo "The access point should now be active!!"
echo "If it does not apear, reboot with:"
echo
echo "sudo reboot"