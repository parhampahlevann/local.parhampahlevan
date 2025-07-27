#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080

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

# Cleanup existing tunnel
cleanup() {
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    ip link delete $TUNNEL_IFACE 2>/dev/null
    rm -f /etc/iranv6tun.conf
}

# Install dependencies
install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools socat
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools socat
    fi
}

# Create tunnel
create_tunnel() {
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

    # Cleanup any existing tunnel
    cleanup
    
    # Create TCP-encapsulated GRE tunnel
    echo -e "${BLUE}Creating TCP-encapsulated GRE tunnel...${NC}"
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    
    sleep 2
    
    # Configure tunnel
    ip link set $TUNNEL_IFACE up mtu 1400
    ip addr add $LOCAL_IPV6 dev $TUNNEL_IFACE
    ip route add ::/0 dev $TUNNEL_IFACE metric 100
    
    # Enable forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null
    
    # Add firewall rules
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT
    
    # Save config
    echo "$location $IRAN_IPV4 $FOREIGN_IPV4 $PORT" > /etc/iranv6tun.conf
    
    echo -e "${GREEN}Tunnel created successfully!${NC}"
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}"
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}"
    
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On the Iran server, run this command:${NC}"
        echo "nohup socat TCP:$FOREIGN_IPV4:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &"
    fi
}

# Check connection
check_connection() {
    if [ -f /etc/iranv6tun.conf ]; then
        source /etc/iranv6tun.conf
        if [ "$location" == "Iran" ]; then
            ping_target="${TUNNEL_PREFIX}::2"
        else
            ping_target="${TUNNEL_PREFIX}::1"
        fi
        
        echo -e "${BLUE}Testing connection to remote server...${NC}"
        ping6 -c 4 $ping_target
    else
        echo -e "${RED}No active tunnel configuration found.${NC}"
    fi
}

# Remove tunnel
remove_tunnel() {
    echo -e "${BLUE}Removing tunnel...${NC}"
    cleanup
    
    # Remove firewall rules
    iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    echo -e "${GREEN}Tunnel removed successfully!${NC}"
}

# Main menu
while true; do
    echo -e "${BLUE}\nIran-Foreign IPv6 Tunnel${NC}"
    echo "1. Create Tunnel"
    echo "2. Remove Tunnel"
    echo "3. Check Connection"
    echo "4. Exit"

    read -p "Select option: " choice

    case $choice in
        1) 
            install_deps
            create_tunnel
            ;;
        2) 
            remove_tunnel
            ;;
        3)
            check_connection
            ;;
        4) 
            exit 0
            ;;
        *) 
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
done
