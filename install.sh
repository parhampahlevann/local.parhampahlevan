#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
PORT=8080
ALTERNATE_PORT=8081
CONFIG_FILE="/etc/iranv6tun.conf"
LOG_FILE="/var/log/iranv6tun.log"
MTU_SIZE=1420
BACKUP_FILE="/etc/iranv6tun_backup.conf"

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
    echo "║ 2. Remove Tunnel (Complete Uninstall) ║"
    echo "║ 3. Check Connection               ║"
    echo "║ 4. Show Tunnel Info               ║"
    echo "║ 5. Install Dependencies           ║"
    echo "║ 6. View Logs                      ║"
    echo "║ 7. Exit                           ║"
    echo "╚════════════════════════════════════╝"
    echo -e "${NC}"
}

# Backup current network config
backup_config() {
    echo -e "${BLUE}Backing up current network configuration...${NC}" >&3
    {
        echo "# Backup created at $(date)"
        echo "IPTABLES_BACKUP=$(iptables-save 2>/dev/null | base64 -w0)"
        echo "IP6TABLES_BACKUP=$(ip6tables-save 2>/dev/null | base64 -w0)"
        echo "SYSCTL_BACKUP=$(sysctl -a 2>/dev/null | grep 'net.ipv6.conf' | base64 -w0)"
        echo "INTERFACES_BACKUP=$(ip -6 addr show 2>/dev/null | base64 -w0)"
    } > "$BACKUP_FILE"
    echo -e "${GREEN}Backup saved to $BACKUP_FILE${NC}" >&3
}

# Restore network config
restore_config() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}No backup file found. Performing basic cleanup.${NC}" >&3
        basic_cleanup
        return
    fi

    echo -e "${BLUE}Restoring original network configuration...${NC}" >&3
    
    # Basic cleanup first
    basic_cleanup
    
    # Restore from backup
    source "$BACKUP_FILE"
    
    # Restore iptables
    if [ -n "$IPTABLES_BACKUP" ]; then
        echo "$IPTABLES_BACKUP" | base64 -d | iptables-restore
    fi
    
    # Restore ip6tables
    if [ -n "$IP6TABLES_BACKUP" ]; then
        echo "$IP6TABLES_BACKUP" | base64 -d | ip6tables-restore
    fi
    
    # Restore sysctl
    if [ -n "$SYSCTL_BACKUP" ]; then
        echo "$SYSCTL_BACKUP" | base64 -d | while read -r line; do
            sysctl -w "$line" >/dev/null
        done
    fi
    
    echo -e "${GREEN}Original network configuration restored successfully!${NC}" >&3
    rm -f "$BACKUP_FILE"
}

# Basic cleanup function
basic_cleanup() {
    echo -e "${BLUE}Performing basic cleanup...${NC}" >&3
    
    # Kill socat processes
    pkill -f "socat TCP.*$TUNNEL_IFACE" 2>/dev/null
    
    # Remove tunnel interface
    ip link delete $TUNNEL_IFACE 2>/dev/null
    
    # Remove IPv6 address and route
    ip -6 addr flush dev $TUNNEL_IFACE 2>/dev/null
    ip -6 route flush dev $TUNNEL_IFACE 2>/dev/null
    
    # Remove tunnel config file
    rm -f "$CONFIG_FILE"
    
    # Reset firewall rules
    ip6tables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
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

# Create tunnel using iproute2 (SIT)
create_tunnel_iproute() {
    echo -e "${BLUE}Creating tunnel using iproute2 (SIT)...${NC}" >&3
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255
    ip link set $TUNNEL_IFACE up mtu $MTU_SIZE
    sleep 2
}

# Configure tunnel with enhanced connectivity settings
configure_tunnel() {
    echo -e "${BLUE}Configuring tunnel interface...${NC}" >&3
    
    # Backup current config before making changes
    backup_config
    
    # Set MTU to 1420 as requested
    ip link set $TUNNEL_IFACE mtu $MTU_SIZE
    
    # Add IPv6 address
    ip addr add $LOCAL_IPV6/64 dev $TUNNEL_IFACE
    
    # Add IPv6 route
    ip route add ::/0 dev $TUNNEL_IFACE metric 100
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null
    
    # Configure firewall to allow ICMPv6 and forwarding
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -A INPUT -p tcp --dport $ALTERNATE_PORT -j ACCEPT 2>/dev/null
    
    # Essential IPv6 firewall rules
    ip6tables -P INPUT ACCEPT 2>/dev/null
    ip6tables -P FORWARD ACCEPT 2>/dev/null
    ip6tables -F 2>/dev/null
    ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT 2>/dev/null
    ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-reply -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    # Save configuration
    {
        echo "LOCATION=$location"
        echo "IRAN_IPV4=$IRAN_IPV4"
        echo "FOREIGN_IPV4=$FOREIGN_IPV4"
        echo "LOCAL_IPV6=$LOCAL_IPV6"
        echo "REMOTE_IPV6=$REMOTE_IPV6"
        echo "MTU_SIZE=$MTU_SIZE"
    } > $CONFIG_FILE
    
    echo -e "${GREEN}Tunnel configuration saved successfully!${NC}" >&3
}

# Create tunnel with enhanced connectivity
create_tunnel() {
    # Get server information
    echo -e "${YELLOW}Enter server information:${NC}" >&3
    read -p "Enter Iran server IPv4: " IRAN_IPV4
    read -p "Enter Foreign server IPv4: " FOREIGN_IPV4
    
    echo -e "${YELLOW}Select your server location:${NC}" >&3
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
    basic_cleanup
    
    # Create tunnel using iproute
    create_tunnel_iproute
    
    if ! verify_interface; then
        echo -e "${RED}Error: Could not create tunnel interface '$TUNNEL_IFACE'${NC}" >&3
        echo -e "${YELLOW}Troubleshooting steps:" >&3
        echo "1. Check kernel modules: 'lsmod | grep sit'" >&3
        echo "2. Check system logs: 'dmesg | tail -20'" >&3
        read -p "Press [Enter] to return to main menu" <&3
        return 1
    fi

    # Configure the tunnel with enhanced settings
    configure_tunnel
    
    echo -e "${GREEN}Tunnel created successfully!${NC}" >&3
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}" >&3
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}" >&3
    
    # Display connection instructions for the other server
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On the Iran server, run these commands:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $FOREIGN_IPV4 local $IRAN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip addr add ${TUNNEL_PREFIX}::1/64 dev $TUNNEL_IFACE" >&3
        echo "ip route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
    else
        echo -e "${BLUE}On the Foreign server, run these commands:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $IRAN_IPV4 local $FOREIGN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip addr add ${TUNNEL_PREFIX}::2/64 dev $TUNNEL_IFACE" >&3
        echo "ip route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
    fi
    
    # Advanced connectivity test
    echo -e "${BLUE}Performing advanced connectivity test...${NC}" >&3
    echo -e "${YELLOW}Testing ping6 to remote server...${NC}" >&3
    
    if ping6 -c 4 -M do -s $((MTU_SIZE-48)) $REMOTE_IPV6; then
        echo -e "${GREEN}Connectivity test successful with MTU $MTU_SIZE!${NC}" >&3
    else
        echo -e "${YELLOW}Standard ping failed, trying smaller packet size...${NC}" >&3
        
        if ping6 -c 4 $REMOTE_IPV6; then
            echo -e "${YELLOW}Connection works with default packet size but not with MTU $MTU_SIZE${NC}" >&3
            echo -e "${YELLOW}Try adjusting the MTU size on both servers.${NC}" >&3
        else
            echo -e "${RED}Connection failed completely. Troubleshooting needed.${NC}" >&3
            echo -e "${YELLOW}Please check:" >&3
            echo "1. Firewall rules on both servers" >&3
            echo "2. Physical network connectivity" >&3
            echo "3. Correct IP addresses configuration" >&3
        fi
    fi
    
    read -p "Press [Enter] to return to main menu" <&3
}

# Remove tunnel (Complete Uninstall)
remove_tunnel() {
    echo -e "${RED}WARNING: This will completely remove the tunnel and restore original network settings${NC}" >&3
    read -p "Are you sure you want to continue? [y/N] " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        restore_config
        echo -e "${GREEN}All tunnel configurations have been completely removed and original settings restored.${NC}" >&3
    else
        echo -e "${YELLOW}Uninstall canceled.${NC}" >&3
    fi
    
    read -p "Press [Enter] to return to main menu" <&3
}

# Check connection
check_connection() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}" >&3
        read -p "Press [Enter] to return to main menu" <&3
        return
    fi
    
    source "$CONFIG_FILE"
    
    if [ "$LOCATION" == "Iran" ]; then
        ping_target="${TUNNEL_PREFIX}::2"
    else
        ping_target="${TUNNEL_PREFIX}::1"
    fi
    
    echo -e "${BLUE}Testing connection to remote server...${NC}" >&3
    if ping6 -c 4 -M do -s $((MTU_SIZE-48)) "$ping_target"; then
        echo -e "${GREEN}Connection successful with MTU $MTU_SIZE!${NC}" >&3
    else
        echo -e "${YELLOW}Trying with default packet size...${NC}" >&3
        if ping6 -c 4 "$ping_target"; then
            echo -e "${YELLOW}Connection works but MTU size may need adjustment${NC}" >&3
        else
            echo -e "${RED}Connection failed completely${NC}" >&3
        fi
    fi
    
    read -p "Press [Enter] to return to main menu" <&3
}

# Show tunnel info
show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}" >&3
    else
        source "$CONFIG_FILE"
        
        echo -e "${BLUE}Current Tunnel Configuration:${NC}" >&3
        echo -e "${YELLOW}Location: $LOCATION" >&3
        echo "Iran IPv4: $IRAN_IPV4" >&3
        echo "Foreign IPv4: $FOREIGN_IPV4" >&3
        echo "Local IPv6: $LOCAL_IPV6" >&3
        echo "Remote IPv6: $REMOTE_IPV6" >&3
        echo "MTU Size: $MTU_SIZE${NC}" >&3
        
        echo -e "\n${BLUE}Interface Status:${NC}" >&3
        ip link show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}Interface not found${NC}" >&3
        
        echo -e "\n${BLUE}IPv6 Address:${NC}" >&3
        ip -6 addr show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 address${NC}" >&3
        
        echo -e "\n${BLUE}IPv6 Route:${NC}" >&3
        ip -6 route show dev $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 routes${NC}" >&3
    fi
    
    read -p "Press [Enter] to return to main menu" <&3
}

# View logs
view_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${RED}No log file found.${NC}" >&3
    else
        echo -e "${BLUE}Last 50 lines of log:${NC}" >&3
        tail -n 50 "$LOG_FILE" >&3
    fi
    read -p "Press [Enter] to return to main menu" <&3
}

# Main loop
while true; do
    show_menu
    read -p "Enter your choice [1-7]: " choice
    
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
            echo -e "${RED}Invalid option. Please try again.${NC}" >&3
            sleep 1
            ;;
    esac
done
