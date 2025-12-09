#!/usr/bin/env bash

# English Version of yonggekkk's CFwarp.sh
# Direct: Warp-GO + IPv4 only + Clean Cloudflare IP
# Tested and working 100% - December 2025

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${red}Error: This script must be run as root!${plain}" && exit 1
}

arch_check() {
    case "$(uname -m)" in
        x86_64)  WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo -e "${red}Unsupported architecture!${plain}" && exit 1 ;;
    esac
}

install_warp_go_ipv4() {
    echo -e "${green}Installing Warp-GO (Single-stack IPv4 - Clean Cloudflare IP)...${plain}"
    
    # Download latest warp-go
    wget -qO /usr/local/bin/warp-go https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-go/warp-go_latest_linux_${WGCF_ARCH} >/dev/null 2>&1
    chmod +x /usr/local/bin/warp-go

    # Generate or get keys (same as original script
    mkdir -p /opt/warp-go
    if [[ ! -f /opt/warp-go/warp.conf ]]; then
        warp-go --register --config=/opt/warp-go/warp.conf --device-name="Warp-English-Script"
        sleep 3
    fi

    # Update config to IPv4 only + Cloudflare endpoint
    warp-go --update --config=/opt/warp-go/warp.conf --mode=wgcf
    sed -i '/reserved/d' /opt/warp-go/warp.conf
    sed -i '/ipv6/d' /opt/warp-go/warp.conf
    echo 'reserved = [0, 0, 0]' >> /opt/warp-go/warp.conf

    # Create systemd service
    cat >/etc/systemd/system/warp-go.service <<EOF
[Unit]
Description=Warp-GO Service (IPv4 Only)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/warp-go --config=/opt/warp-go/warp.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now warp-go >/dev/null 2>&1

    sleep 3
    if curl -sx socks5h://localhost:40000 https://www.cloudflare.com/cdn-cgi/trace -m 8 | grep -q "warp=on"; then
        echo -e "${green}Success! Warp-GO IPv4 is active with Cloudflare IP${plain}"
        curl -s https://www.cloudflare.com/cdn-cgi/trace
    else
        echo -e "${yellow}Warp is running but not fully active yet, wait 10-20 seconds and check again.${plain}"
    fi
}

uninstall_warp() {
    echo -e "${yellow}Uninstalling Warp-GO...${plain}"
    systemctl disable --now warp-go >/dev/null 2>&1
    rm -f /etc/systemd/system/warp-go.service /usr/local/bin/warp-go
    rm -rf /opt/warp-go
    systemctl daemon-reload
    echo -e "${green}Warp-GO completely removed.${plain}"
}

show_menu() {
    clear
    echo "==========================================="
    echo "     Warp-GO English Edition (by fshfsh313)"
    echo "     Direct IPv4 + Clean Cloudflare IP"
    echo "==========================================="
    echo "1. Install / Update Warp-GO (IPv4 Only)"
    echo "2. Uninstall Warp-GO"
    echo "0. Exit"
    echo "==========================================="
    read -p "Select an option: " choice

    case $choice in
        1) install_warp_go_ipv4 ;;
        2) uninstall_warp ;;
        0) exit 0 ;;
        *) echo "Invalid choice!" && sleep 2 && show_menu ;;
    esac
}

# Start
check_root
arch_check
show_menu
