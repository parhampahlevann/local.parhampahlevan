#!/bin/bash

# Script for managing Warp-GO (IPv4 with Cloudflare IP)
# Based on analysis of CFwarp.sh, focused on Warp-GO IPv4 installation
# Translated to English, with added uninstall option

# Function to check root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "Error: This script must be run as root."
        exit 1
    fi
}

# Function to detect architecture
get_arch() {
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
    esac
    echo $arch
}

# Function to install Warp-GO IPv4
install_warp_go_ipv4() {
    echo "Installing/Switching to Warp-GO Single-Stack IPv4..."

    # Download Warp-GO binary
    warp_bin_url="https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-go/warp-go_latest_linux_$(get_arch)"
    wget -O /usr/local/bin/warp-go "$warp_bin_url" || { echo "Download failed."; exit 1; }
    chmod +x /usr/local/bin/warp-go

    # Set up config
    mkdir -p /root/.config/warp-go
    cat <<EOF > /root/.config/warp-go/config.toml
[wireguard]
private_key = "your_private_key_here"  # Generate or use from Warp account
peer_public_key = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
endpoint = "engage.cloudflareclient.com:2408"  # Cloudflare IPv4 endpoint for clean IP
reserved = [0, 0, 0]
mtu = 1280

[ipv4]
address = "172.16.0.2/32"
route = "0.0.0.0/0"
EOF

    # Set up systemd service
    cat <<EOF > /etc/systemd/system/warp-go.service
[Unit]
Description=Warp-GO Service
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-go --config=/root/.config/warp-go/config.toml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-go
    systemctl start warp-go

    # Check IP (using Cloudflare trace for verification)
    curl https://www.cloudflare.com/cdn-cgi/trace | grep warp=on && echo "Warp IPv4 is active with Cloudflare IP." || echo "Warp activation failed."
}

# Function to uninstall Warp
uninstall_warp() {
    echo "Uninstalling Warp..."

    systemctl stop warp-go
    systemctl disable warp-go
    rm -f /etc/systemd/system/warp-go.service
    systemctl daemon-reload

    rm -f /usr/local/bin/warp-go
    rm -rf /root/.config/warp-go

    echo "Warp uninstalled successfully."
}

# Main menu
main_menu() {
    echo "Warp Management Menu:"
    echo "1. Install/Switch to Warp-GO"
    echo "2. Uninstall Warp"
    echo "0. Exit"

    read -p "Enter your choice: " choice
    case $choice in
        1)
            read -p "1. Install/Switch to Warp Single-Stack IPv4 (default, press Enter): " subchoice
            if [ -z "$subchoice" ] || [ "$subchoice" = "1" ]; then
                install_warp_go_ipv4
            else
                echo "Invalid subchoice."
            fi
            ;;
        2)
            uninstall_warp
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# Run script
check_root
main_menu
