#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080
ALTERNATE_PORT=8081
CONFIG_FILE="/etc/iranv6tun.conf"
LOG_FILE="/var/log/iranv6tun.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize logging
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${NC}" >&3
    exit 1
fi

# Function to display main menu
show_menu() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════╗"
    echo "║    Iran-Foreign IPv6 Tunnel        ║"
    echo "╠════════════════════════════════════╣"
    echo "║ 1. Create Tunnel                  ║"
    echo "║ 2. Remove Tunnel                  ║"
    echo "║ 3. Check Connection               ║"
    echo "║ 4. Show Tunnel Info               ║"
    echo "║ 5. Install Dependencies           ║"
    echo "║ 6. View Logs                      ║"
    echo "║ 7. Exit                           ║"
    echo "╚════════════════════════════════════╝"
    echo -e "${NC}"
}

# Cleanup function
cleanup() {
    echo -e "${BLUE}Cleaning up existing tunnel...${NC}" >&3
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    ip link delete $TUNNEL_IFACE 2>/dev/null
    sleep 2
}

# Verify tunnel interface
verify_interface() {
    local timeout=10
    while [ $timeout -gt 0 ]; do
        if ip link show $TUNNEL_IFACE >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        timeout=$((timeout-1))
    done
    return 1
}

# Install dependencies
install_deps() {
    echo -e "${BLUE}Installing required packages...${NC}" >&3
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools socat kmod
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools socat kmod
    fi
    
    # Load required kernel modules
    echo -e "${BLUE}Loading kernel modules...${NC}" >&3
    modprobe ip_gre 2>/dev/null
    modprobe ip6_gre 2>/dev/null
    modprobe sit 2>/dev/null
    
    echo -e "${GREEN}Dependencies installed successfully!${NC}" >&3
    read -p "Press [Enter] to return to main menu" <&3
}

# Create tunnel methods
create_tunnel_socat_gre() {
    echo -e "${BLUE}Creating tunnel using socat with GRE...${NC}" >&3
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

create_tunnel_iproute() {
    echo -e "${BLUE}Creating tunnel using iproute2 (SIT)...${NC}" >&3
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255
    ip link set $TUNNEL_IFACE up
    sleep 2
}

create_tunnel_socat_raw() {
    echo -e "${BLUE}Creating tunnel using socat with raw IP...${NC}" >&3
    nohup socat TCP-LISTEN:$ALTERNATE_PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=ip,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Configure tunnel
configure_tunnel() {
    echo -e "${BLUE}Configuring tunnel interface...${NC}" >&3
    
    ip link set $TUNNEL_IFACE mtu 1400
    ip addr add $LOCAL_IPV6 dev $TUNNEL_IFACE
    ip route add ::/0 dev $TUNNEL_IFACE metric 100
    
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null
    
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -A INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    {
        echo "LOCATION=$location"
        echo "IRAN_IPV4=$IRAN_IPV4"
        echo "FOREIGN_IPV4=$FOREIGN_IPV4"
        echo "PORT=$PORT"
        echo "ALTERNATE_PORT=$ALTERNATE_PORT"
        echo "LOCAL_IPV6=$LOCAL_IPV6"
        echo "REMOTE_IPV6=$REMOTE_IPV6"
    } > $CONFIG_FILE
    
    echo -e "${GREEN}Tunnel configuration saved!${NC}" >&3
}

# Create tunnel
create_tunnel() {
    read -p "Enter Iran server IPv4: " IRAN_IPV4
    read -p "Enter Foreign server IPv4: " FOREIGN_IPV4
    
    echo -e "${YELLOW}Select server location:${NC}" >&3
    select location in Iran Foreign; do
        case $location in
            Iran)
                LOCAL_IPV6="${TUNNEL_PREFIX}::1/64"
                REMOTE_IPV6="${TUNNEL_PREFIX}::2"
                LOCAL_IPV4=$IRAN_IPV4
                REMOTE_IPV4=$FOREIGN_IPV4
                break
                ;;
            Foreign)
                LOCAL_IPV6="${TUNNEL_PREFIX}::2/64"
                REMOTE_IPV6="${TUNNEL_PREFIX}::1"
                LOCAL_IPV4=$FOREIGN_IPV4
                REMOTE_IPV4=$IRAN_IPV4
                break
                ;;
        esac
    done

    cleanup
    
    echo -e "${BLUE}Attempting to create tunnel...${NC}" >&3
    
    # Try methods sequentially
    create_tunnel_socat_gre
    if ! verify_interface; then
        echo -e "${YELLOW}Method 1 failed, trying Method 2...${NC}" >&3
        create_tunnel_iproute
        if ! verify_interface; then
            echo -e "${YELLOW}Method 2 failed, trying Method 3...${NC}" >&3
            create_tunnel_socat_raw
            if ! verify_interface; then
                echo -e "${RED}Failed to create tunnel after all methods!${NC}" >&3
                echo -e "${YELLOW}Troubleshooting steps:" >&3
                echo "1. Check kernel modules: lsmod | grep gre" >&3
                echo "2. Verify socat is installed: socat -h" >&3
                echo "3. Check ports: netstat -tulnp | grep -E '$PORT|$ALTERNATE_PORT'" >&3
                read -p "Press [Enter] to continue" <&3
                return 1
            fi
        fi
    fi

    configure_tunnel
    
    echo -e "${GREEN}Tunnel created successfully!${NC}" >&3
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}" >&3
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}" >&3
    
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On Iran server run:${NC}" >&3
        echo "nohup socat TCP:$FOREIGN_IPV4:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &" >&3
    fi
    
    read -p "Press [Enter] to continue" <&3
}

# Remove tunnel
remove_tunnel() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel found.${NC}" >&3
        read -p "Press [Enter] to continue" <&3
        return
    fi
    
    echo -e "${BLUE}Removing tunnel...${NC}" >&3
    cleanup
    
    iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    rm -f $CONFIG_FILE
    
    echo -e "${GREEN}Tunnel removed successfully!${NC}" >&3
    read -p "Press [Enter] to continue" <&3
}

# Check connection
check_connection() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel found.${NC}" >&3
        read -p "Press [Enter] to continue" <&3
        return
    fi
    
    source $CONFIG_FILE
    
    if [ "$LOCATION" == "Iran" ]; then
        ping_target="${TUNNEL_PREFIX}::2"
    else
        ping_target="${TUNNEL_PREFIX}::1"
    fi
    
    echo -e "${BLUE}Testing connection...${NC}" >&3
    if ping6 -c 4 $ping_target; then
        echo -e "${GREEN}Connection successful!${NC}" >&3
    else
        echo -e "${RED}Connection failed!${NC}" >&3
        echo -e "${YELLOW}Troubleshooting:" >&3
        echo "Interface: $(ip link show $TUNNEL_IFACE 2>/dev/null)" >&3
        echo "IP Address: $(ip -6 addr show $TUNNEL_IFACE 2>/dev/null)" >&3
    fi
    
    read -p "Press [Enter] to continue" <&3
}

# Show tunnel info
show_info() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel found.${NC}" >&3
        read -p "Press [Enter] to continue" <&3
        return
    fi
    
    source $CONFIG_FILE
    
    echo -e "${BLUE}Tunnel Configuration:${NC}" >&3
    echo -e "${YELLOW}Location: $LOCATION" >&3
    echo "Iran IPv4: $IRAN_IPV4" >&3
    echo "Foreign IPv4: $FOREIGN_IPV4" >&3
    echo "Ports: $PORT (main), $ALTERNATE_PORT (alt)" >&3
    echo "Local IPv6: $LOCAL_IPV6" >&3
    echo "Remote IPv6: $REMOTE_IPV6${NC}" >&3
    
    echo -e "\n${BLUE}Interface Status:${NC}" >&3
    ip link show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}Interface not found${NC}" >&3
    
    echo -e "\n${BLUE}IPv6 Address:${NC}" >&3
    ip -6 addr show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 address${NC}" >&3
    
    read -p "Press [Enter] to continue" <&3
}

# View logs
view_logs() {
    if [ ! -f $LOG_FILE ]; then
        echo -e "${RED}No log file found.${NC}" >&3
    else
        echo -e "${BLUE}Last 20 lines of log:${NC}" >&3
        tail -n 20 $LOG_FILE >&3
    fi
    read -p "Press [Enter] to continue" <&3
}

# Main loop
while true; do
    show_menu
    read -p "Enter choice [1-7]: " choice
    
    case $choice in
        1) create_tunnel ;;
        2) remove_tunnel ;;
        3) check_connection ;;
        4) show_info ;;
        5) install_deps ;;
        6) view_logs ;;
        7) 
            echo -e "${GREEN}Exiting...${NC}" >&3
            exit 0
            ;;
        *) 
            echo -e "${RED}Invalid choice!${NC}" >&3
            sleep 1
            ;;
    esac
done
