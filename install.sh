#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080
TIMEOUT=10

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
    echo -e "${BLUE}Cleaning up existing tunnel...${NC}"
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    ip link delete $TUNNEL_IFACE 2>/dev/null
    rm -f /etc/iranv6tun.conf
    sleep 2
}

# Verify tunnel creation
verify_tunnel() {
    local attempts=0
    while [ $attempts -lt 5 ]; do
        if ip link show $TUNNEL_IFACE >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((attempts++))
    done
    return 1
}

# Install dependencies
install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools socat kmod
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools socat kmod
    fi
    
    # Load GRE module
    modprobe ip_gre
    lsmod | grep gre
}

# Create tunnel using method 1 (socat)
create_tunnel_method1() {
    echo -e "${BLUE}Attempting to create tunnel using method 1 (socat)...${NC}"
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Create tunnel using method 2 (iproute)
create_tunnel_method2() {
    echo -e "${BLUE}Attempting to create tunnel using method 2 (iproute)...${NC}"
    ip tunnel add $TUNNEL_IFACE mode gre remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255
    ip link set $TUNNEL_IFACE up
    sleep 2
}

# Create tunnel using method 3 (raw socket)
create_tunnel_method3() {
    echo -e "${BLUE}Attempting to create tunnel using method 3 (raw socket)...${NC}"
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=ip,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
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
    
    # Try multiple creation methods
    create_tunnel_method1 || create_tunnel_method2 || create_tunnel_method3
    
    # Verify tunnel creation
    if ! verify_tunnel; then
        echo -e "${RED}Error: Could not create tunnel interface '$TUNNEL_IFACE' after multiple attempts${NC}"
        echo -e "${YELLOW}Troubleshooting steps:"
        echo "1. Check if GRE module is loaded: 'lsmod | grep gre'"
        echo "2. Verify socat is installed: 'socat -h'"
        echo "3. Check for port conflict: 'netstat -tulnp | grep $PORT'"
        echo "4. Try changing the tunnel interface name"
        exit 1
    fi

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
        if ! ping6 -c 4 $ping_target; then
            echo -e "${RED}Connection failed. Troubleshooting:${NC}"
            echo "1. Verify tunnel is up: 'ip link show $TUNNEL_IFACE'"
            echo "2. Check IP assignment: 'ip -6 addr show $TUNNEL_IFACE'"
            echo "3. Verify socat is running: 'ps aux | grep socat'"
            echo "4. Check firewall rules: 'ip6tables -L -n -v'"
            echo "5. Verify remote server is listening: 'nc -zv $REMOTE_IPV4 $PORT'"
        fi
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
