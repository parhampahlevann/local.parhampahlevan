#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080
ALTERNATE_PORT=8081

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

# Cleanup function
cleanup() {
    echo -e "${BLUE}Cleaning up existing tunnel...${NC}"
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    ip link delete $TUNNEL_IFACE 2>/dev/null
    rm -f /etc/iranv6tun.conf
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
    modprobe ip_gre
    modprobe ip6_gre
    lsmod | grep gre
}

# Method 1: Create tunnel using socat with GRE
create_tunnel_socat_gre() {
    echo -e "${BLUE}Attempting Method 1: socat with GRE...${NC}"
    nohup socat TCP-LISTEN:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Method 2: Create tunnel using iproute2
create_tunnel_iproute() {
    echo -e "${BLUE}Attempting Method 2: iproute2...${NC}"
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255
    ip link set $TUNNEL_IFACE up
    sleep 2
}

# Method 3: Create tunnel using socat with raw IP
create_tunnel_socat_raw() {
    echo -e "${BLUE}Attempting Method 3: socat with raw IP...${NC}"
    nohup socat TCP-LISTEN:$ALTERNATE_PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=ip,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &
    sleep 3
}

# Create tunnel with multiple fallback methods
create_tunnel() {
    # Try methods in order
    create_tunnel_socat_gre || create_tunnel_iproute || create_tunnel_socat_raw
    
    if ! verify_interface; then
        echo -e "${RED}Error: Could not create tunnel interface '$TUNNEL_IFACE' after multiple attempts${NC}"
        echo -e "${YELLOW}Troubleshooting steps:"
        echo "1. Check kernel modules: 'lsmod | grep gre'"
        echo "2. Verify socat installation: 'socat -h'"
        echo "3. Check port availability: 'netstat -tulnp | grep -E '$PORT|$ALTERNATE_PORT''"
        echo "4. Try manual creation: 'ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255'"
        exit 1
    fi

    # Configure the interface
    ip link set $TUNNEL_IFACE mtu 1400
    ip addr add $LOCAL_IPV6 dev $TUNNEL_IFACE
    ip route add ::/0 dev $TUNNEL_IFACE metric 100
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null
    
    # Configure firewall
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT
    
    # Save configuration
    echo "$location $IRAN_IPV4 $FOREIGN_IPV4 $PORT $ALTERNATE_PORT" > /etc/iranv6tun.conf
    
    echo -e "${GREEN}Tunnel created successfully!${NC}"
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}"
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}"
}

# Main function
main() {
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

    # Perform installation
    cleanup
    install_deps
    create_tunnel
    
    # Show connection instructions
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On the Iran server, run:${NC}"
        echo "nohup socat TCP:$FOREIGN_IPV4:$PORT,fork,reuseaddr TUN:$TUNNEL_IFACE,tun-type=gre,tun-name=$TUNNEL_IFACE >/dev/null 2>&1 &"
    fi
}

# Execute main function
main
