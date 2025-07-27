#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080
ALTERNATE_PORT=8081
CONFIG_FILE="/etc/iranv6tun.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${NC}"
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
    echo "║ 6. Exit                           ║"
    echo "╚════════════════════════════════════╝"
    echo -e "${NC}"
}

# Cleanup function
cleanup() {
    echo -e "${BLUE}Cleaning up existing tunnel...${NC}"
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    ip link delete $TUNNEL_IFACE 2>/dev/null
    sleep 2
}

# Verify tunnel interface
verify_interface() {
    local timeout=10
    while ((timeout > 0)); do
        if ip link show $TUNNEL_IFACE >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((timeout--))
    done
    return 1
}

# Install dependencies
install_deps() {
    echo -e "${BLUE}Installing required packages...${NC}"
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools socat kmod
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools socat kmod
    fi
    
    # Load required kernel modules
    echo -e "${BLUE}Loading kernel modules...${NC}"
    modprobe ip_gre 2>/dev/null
    modprobe ip6_gre 2>/dev/null
    modprobe sit 2>/dev/null
    
    echo -e "${GREEN}Dependencies installed successfully!${NC}"
}

# Method 1: Create tunnel using socat with GRE
create_tunnel_socat_gre() {
    echo -e "${BLUE}Creating tunnel using socat with GRE...${NC}"
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Method 2: Create tunnel using iproute2 (SIT)
create_tunnel_iproute() {
    echo -e "${BLUE}Creating tunnel using iproute2 (SIT)...${NC}"
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255
    ip link set $TUNNEL_IFACE up
    sleep 2
}

# Method 3: Create tunnel using socat with raw IP
create_tunnel_socat_raw() {
    echo -e "${BLUE}Creating tunnel using socat with raw IP...${NC}"
    nohup socat TCP-LISTEN:$ALTERNATE_PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=ip,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Configure tunnel
configure_tunnel() {
    echo -e "${BLUE}Configuring tunnel interface...${NC}"
    
    # Set MTU
    ip link set $TUNNEL_IFACE mtu 1400
    
    # Add IPv6 address
    ip addr add $LOCAL_IPV6 dev $TUNNEL_IFACE
    
    # Add IPv6 route
    ip route add ::/0 dev $TUNNEL_IFACE metric 100
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null
    
    # Configure firewall
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -A INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    # Save configuration
    echo "LOCATION=$location" > $CONFIG_FILE
    echo "IRAN_IPV4=$IRAN_IPV4" >> $CONFIG_FILE
    echo "FOREIGN_IPV4=$FOREIGN_IPV4" >> $CONFIG_FILE
    echo "PORT=$PORT" >> $CONFIG_FILE
    echo "ALTERNATE_PORT=$ALTERNATE_PORT" >> $CONFIG_FILE
    echo "LOCAL_IPV6=$LOCAL_IPV6" >> $CONFIG_FILE
    echo "REMOTE_IPV6=$REMOTE_IPV6" >> $CONFIG_FILE
}

# Create tunnel
create_tunnel() {
    # Get server information
    read -p "Enter Iran server IPv4: " IRAN_IPV4
    read -p "Enter Foreign server IPv4: " FOREIGN_IPV4
    
    echo -e "${YELLOW}Select your server location:${NC}"
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

    # Cleanup existing tunnel
    cleanup
    
    # Try methods in order
    create_tunnel_socat_gre || create_tunnel_iproute || create_tunnel_socat_raw
    
    if ! verify_interface; then
        echo -e "${RED}Error: Could not create tunnel interface '$TUNNEL_IFACE' after multiple attempts${NC}"
        echo -e "${YELLOW}Troubleshooting steps:"
        echo "1. Check kernel modules: 'lsmod | grep -E \"gre|sit\"'"
        echo "2. Verify socat installation: 'socat -h'"
        echo "3. Check port availability: 'netstat -tulnp | grep -E \"$PORT|$ALTERNATE_PORT\"'"
        echo "4. Check system logs: 'dmesg | tail -20'"
        echo "5. Try manual creation: 'ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255'"
        return 1
    fi

    # Configure the tunnel
    configure_tunnel
    
    echo -e "${GREEN}Tunnel created successfully!${NC}"
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}"
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}"
    
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On the Iran server, run:${NC}"
        echo "nohup socat TCP:$FOREIGN_IPV4:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &"
    fi
    
    read -p "Press [Enter] to return to main menu"
}

# Remove tunnel
remove_tunnel() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}"
        read -p "Press [Enter] to return to main menu"
        return
    fi
    
    echo -e "${BLUE}Removing tunnel...${NC}"
    cleanup
    
    # Remove firewall rules
    iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    # Remove config file
    rm -f $CONFIG_FILE
    
    echo -e "${GREEN}Tunnel removed successfully!${NC}"
    read -p "Press [Enter] to return to main menu"
}

# Check connection
check_connection() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}"
        read -p "Press [Enter] to return to main menu"
        return
    fi
    
    source $CONFIG_FILE
    
    if [ "$LOCATION" == "Iran" ]; then
        ping_target="${TUNNEL_PREFIX}::2"
    else
        ping_target="${TUNNEL_PREFIX}::1"
    fi
    
    echo -e "${BLUE}Testing connection to remote server...${NC}"
    ping6 -c 4 $ping_target
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Connection failed.${NC}"
        echo -e "${YELLOW}Troubleshooting info:"
        echo "Tunnel interface: $(ip link show $TUNNEL_IFACE 2>/dev/null)"
        echo "IPv6 address: $(ip -6 addr show $TUNNEL_IFACE 2>/dev/null)"
        echo "Routing table: $(ip -6 route show dev $TUNNEL_IFACE 2>/dev/null)"
    fi
    
    read -p "Press [Enter] to return to main menu"
}

# Show tunnel info
show_info() {
    if [ ! -f $CONFIG_FILE ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}"
        read -p "Press [Enter] to return to main menu"
        return
    fi
    
    source $CONFIG_FILE
    
    echo -e "${BLUE}Current Tunnel Configuration:${NC}"
    echo -e "${YELLOW}Location: $LOCATION"
    echo "Iran IPv4: $IRAN_IPV4"
    echo "Foreign IPv4: $FOREIGN_IPV4"
    echo "Main Port: $PORT"
    echo "Alternate Port: $ALTERNATE_PORT"
    echo "Local IPv6: $LOCAL_IPV6"
    echo "Remote IPv6: $REMOTE_IPV6${NC}"
    
    echo -e "\n${BLUE}Interface Status:${NC}"
    ip link show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}Interface $TUNNEL_IFACE not found${NC}"
    
    echo -e "\n${BLUE}IPv6 Address:${NC}"
    ip -6 addr show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 address assigned${NC}"
    
    echo -e "\n${BLUE}IPv6 Route:${NC}"
    ip -6 route show dev $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 routes found${NC}"
    
    read -p "Press [Enter] to return to main menu"
}

# Main loop
while true; do
    show_menu
    read -p "Enter your choice: " choice
    
    case $choice in
        1)
            create_tunnel
            ;;
        2)
            remove_tunnel
            ;;
        3)
            check_connection
            ;;
        4)
            show_info
            ;;
        5)
            install_deps
            read -p "Press [Enter] to return to main menu"
            ;;
        6)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            sleep 1
            ;;
    esac
done
