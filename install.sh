#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"
CONFIG_FILE="/etc/iranv6tun.conf"
LOG_FILE="/var/log/iranv6tun.log"
MTU_SIZE=1280  # Default MTU for IPv6 tunnels
BACKUP_FILE="/etc/iranv6tun_backup.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize logging (ساده‌تر شده برای دیباگ)
echo "Script started at $(date)" > "$LOG_FILE" 2>&1
exec 3>&1

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
    echo "║ 2. Remove Tunnel (Complete)       ║"
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
    } > "$BACKUP_FILE" 2>>"$LOG_FILE"
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
    
    basic_cleanup
    
    source "$BACKUP_FILE" 2>>"$LOG_FILE"
    
    if [ -n "$IPTABLES_BACKUP" ]; then
        echo "$IPTABLES_BACKUP" | base64 -d | iptables-restore 2>>"$LOG_FILE"
    fi
    
    if [ -n "$IP6TABLES_BACKUP" ]; then
        echo "$IP6TABLES_BACKUP" | base64 -d | ip6tables-restore 2>>"$LOG_FILE"
    fi
    
    if [ -n "$SYSCTL_BACKUP" ]; then
        echo "$SYSCTL_BACKUP" | base64 -d | while read -r line; do
            sysctl -w "$line" >/dev/null 2>>"$LOG_FILE"
        done
    fi
    
    echo -e "${GREEN}Original network configuration restored successfully!${NC}" >&3
    rm -f "$BACKUP_FILE" 2>>"$LOG_FILE"
}

# Basic cleanup function
basic_cleanup() {
    echo -e "${BLUE}Performing basic cleanup...${NC}" >&3
    
    ip link delete $TUNNEL_IFACE 2>/dev/null
    ip -6 addr flush dev $TUNNEL_IFACE 2>/dev/null
    ip -6 route flush dev $TUNNEL_IFACE 2>/dev/null
    rm -f "$CONFIG_FILE" 2>>"$LOG_FILE"
    
    iptables -D INPUT -p 41 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p 41 -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null
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
        apt-get install -y iproute2 net-tools kmod traceroute6 2>>"$LOG_FILE"
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools kmod traceroute 2>>"$LOG_FILE"
    fi
    
    # Check and enable IPv6
    if ! sysctl -n net.ipv6.conf.all.disable_ipv6 | grep -q 0; then
        echo -e "${YELLOW}IPv6 is disabled. Enabling IPv6...${NC}" >&3
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>>"$LOG_FILE"
    fi
    
    # Verify kernel modules
    if ! lsmod | grep -q sit; then
        echo -e "${RED}SIT module not loaded. Loading...${NC}" >&3
        modprobe sit 2>>"$LOG_FILE"
        if ! lsmod | grep -q sit; then
            echo -e "${RED}Failed to load SIT module. Please check kernel support.${NC}" >&3
            exit 1
        fi
    fi
    
    echo -e "${GREEN}Dependencies installed successfully!${NC}" >&3
    read -p "Press [Enter] to return to main menu" <&3
}

# Create tunnel using iproute2 (SIT)
create_tunnel_iproute() {
    echo -e "${BLUE}Creating tunnel using iproute2 (SIT)...${NC}" >&3
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255 2>>"$LOG_FILE"
    ip link set $TUNNEL_IFACE up mtu $MTU_SIZE 2>>"$LOG_FILE"
    sleep 2
}

# Test and adjust MTU
test_mtu() {
    echo -e "${YELLOW}Testing MTU compatibility...${NC}" >&3
    local test_mtu=$((MTU_SIZE-48))
    if ! ping6 -c 4 -M do -s $test_mtu $REMOTE_IPV6 >/dev/null 2>>"$LOG_FILE"; then
        echo -e "${YELLOW}MTU $MTU_SIZE failed, trying lower MTU (1200)...${NC}" >&3
        MTU_SIZE=1200
        ip link set $TUNNEL_IFACE mtu $MTU_SIZE 2>>"$LOG_FILE"
        if ! ping6 -c 4 -M do -s $((MTU_SIZE-48)) $REMOTE_IPV6 >/dev/null 2>>"$LOG_FILE"; then
            echo -e "${YELLOW}MTU 1200 failed, trying 1480...${NC}" >&3
            MTU_SIZE=1480
            ip link set $TUNNEL_IFACE mtu $MTU_SIZE 2>>"$LOG_FILE"
        fi
        if ! ping6 -c 4 -M do -s $((MTU_SIZE-48)) $REMOTE_IPV6 >/dev/null 2>>"$LOG_FILE"; then
            echo -e "${RED}MTU test failed. Please check network configuration.${NC}" >&3
        else
            echo -e "${GREEN}MTU adjusted to $MTU_SIZE successfully!${NC}" >&3
        fi
    else
        echo -e "${GREEN}MTU test passed with $MTU_SIZE!${NC}" >&3
    fi
}

# Configure tunnel with enhanced connectivity settings
configure_tunnel() {
    echo -e "${BLUE}Configuring tunnel interface...${NC}" >&3
    
    backup_config
    
    ip link set $TUNNEL_IFACE mtu $MTU_SIZE 2>>"$LOG_FILE"
    
    # Add IPv6 address with proper syntax
    ip -6 addr add $LOCAL_IPV6 dev $TUNNEL_IFACE 2>>"$LOG_FILE"
    ip -6 addr show dev $TUNNEL_IFACE | grep $LOCAL_IPV6 || {
        echo -e "${RED}Failed to set IPv6 address $LOCAL_IPV6. Check permissions or syntax.${NC}" >&3
        exit 1
    }
    
    # Add IPv6 route
    ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100 2>>"$LOG_FILE"
    ip -6 route show dev $TUNNEL_IFACE | grep "::/0" || {
        echo -e "${RED}Failed to add IPv6 default route. Check routing table.${NC}" >&3
        exit 1
    }
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    
    # Flush existing rules
    ip6tables -F 2>>"$LOG_FILE"
    ip6tables -X 2>>"$LOG_FILE"
    ip6tables -Z 2>>"$LOG_FILE"
    iptables -F 2>>"$LOG_FILE"
    iptables -X 2>>"$LOG_FILE"
    iptables -Z 2>>"$LOG_FILE"
    
    # Essential IPv6 and IPv4 firewall rules
    ip6tables -P INPUT ACCEPT 2>>"$LOG_FILE"
    ip6tables -P FORWARD ACCEPT 2>>"$LOG_FILE"
    ip6tables -P OUTPUT ACCEPT 2>>"$LOG_FILE"
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT 2>>"$LOG_FILE"
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>>"$LOG_FILE"
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>>"$LOG_FILE"
    
    # Allow SIT protocol (41) for IPv4
    iptables -A INPUT -p 41 -s $REMOTE_IPV4 -d $LOCAL_IPV4 -j ACCEPT 2>>"$LOG_FILE"
    iptables -A OUTPUT -p 41 -s $LOCAL_IPV4 -d $REMOTE_IPV4 -j ACCEPT 2>>"$LOG_FILE"
    
    # Save configuration
    {
        echo "LOCATION=$location"
        echo "IRAN_IPV4=$IRAN_IPV4"
        echo "FOREIGN_IPV4=$FOREIGN_IPV4"
        echo "LOCAL_IPV6=$LOCAL_IPV6"
        echo "REMOTE_IPV6=$REMOTE_IPV6"
        echo "MTU_SIZE=$MTU_SIZE"
    } > "$CONFIG_FILE" 2>>"$LOG_FILE"
    
    echo -e "${GREEN}Tunnel configuration saved successfully!${NC}" >&3
}

# Create tunnel with enhanced connectivity
create_tunnel() {
    echo -e "${YELLOW}Enter server information:${NC}" >&3
    while true; do
        read -p "Enter Iran server IPv4: " IRAN_IPV4
        if [[ $IRAN_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}Invalid IPv4 address format. Please try again.${NC}" >&3
        fi
    done
    
    while true; do
        read -p "Enter Foreign server IPv4: " FOREIGN_IPV4
        if [[ $FOREIGN_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}Invalid IPv4 address format. Please try again.${NC}" >&3
        fi
    done
    
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
            *) echo -e "${RED}Invalid selection. Please choose Iran or Foreign.${NC}" >&3 ;;
        esac
    done

    basic_cleanup
    
    create_tunnel_iproute
    
    if ! verify_interface; then
        echo -e "${RED}Error: Could not create tunnel interface '$TUNNEL_IFACE'${NC}" >&3
        echo -e "${YELLOW}Troubleshooting steps:" >&3
        echo "1. Check kernel modules: 'lsmod | grep sit'" >&3
        echo "2. Check system logs: 'dmesg | tail -20'" >&3
        echo "3. Check log file: 'cat $LOG_FILE'" >&3
        read -p "Press [Enter] to return to main menu" <&3
        return 1
    fi

    configure_tunnel
    test_mtu
    
    echo -e "${GREEN}Tunnel created successfully!${NC}" >&3
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}" >&3
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}" >&3
    
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On the Iran server ($IRAN_IPV4), run these commands immediately:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $FOREIGN_IPV4 local $IRAN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip -6 addr add ${TUNNEL_PREFIX}::1/64 dev $TUNNEL_IFACE" >&3
        echo "ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
        echo "sysctl -w net.ipv6.conf.all.forwarding=1" >&3
        echo "sysctl -w net.ipv6.conf.default.forwarding=1" >&3
        echo "iptables -A INPUT -p 41 -s $FOREIGN_IPV4 -d $IRAN_IPV4 -j ACCEPT" >&3
        echo "iptables -A OUTPUT -p 41 -s $IRAN_IPV4 -d $FOREIGN_IPV4 -j ACCEPT" >&3
        echo -e "${YELLOW}Please confirm execution on Iran server before proceeding.${NC}" >&3
        read -p "Press [Enter] after executing commands on Iran server" <&3
    elif [ "$location" == "Iran" ]; then
        echo -e "${BLUE}On the Foreign server ($FOREIGN_IPV4), run these commands immediately:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $IRAN_IPV4 local $FOREIGN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip -6 addr add ${TUNNEL_PREFIX}::2/64 dev $TUNNEL_IFACE" >&3
        echo "ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
        echo "sysctl -w net.ipv6.conf.all.forwarding=1" >&3
        echo "sysctl -w net.ipv6.conf.default.forwarding=1" >&3
        echo "iptables -A INPUT -p 41 -s $IRAN_IPV4 -d $FOREIGN_IPV4 -j ACCEPT" >&3
        echo "iptables -A OUTPUT -p 41 -s $FOREIGN_IPV4 -d $IRAN_IPV4 -j ACCEPT" >&3
        echo -e "${YELLOW}Please confirm execution on Foreign server before proceeding.${NC}" >&3
        read -p "Press [Enter] after executing commands on Foreign server" <&3
    fi
    
    # Advanced connectivity test
    echo -e "${BLUE}Testing connection...${NC}" >&3
    check_connection
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
    
    source "$CONFIG_FILE" 2>>"$LOG_FILE"
    
    if [ "$LOCATION" == "Iran" ]; then
        ping_target="${TUNNEL_PREFIX}::2"
    else
        ping_target="${TUNNEL_PREFIX}::1"
    fi
    
    echo -e "${BLUE}Testing connection to remote server ($ping_target)...${NC}" >&3
    
    # Check IPv4 connectivity first
    echo -e "${YELLOW}Step 1: Testing IPv4 connectivity to $REMOTE_IPV4...${NC}" >&3
    if ping -c 4 $REMOTE_IPV4 >/dev/null 2>>"$LOG_FILE"; then
        echo -e "${GREEN}IPv4 connectivity OK${NC}" >&3
    else
        echo -e "${RED}IPv4 connectivity failed. Please check network or firewall.${NC}" >&3
        read -p "Press [Enter] to return to main menu" <&3
        return
    fi
    
    echo -e "${YELLOW}Step 2: Basic IPv6 ping test...${NC}" >&3
    if ping6 -c 4 $ping_target >/dev/null 2>>"$LOG_FILE"; then
        echo -e "${GREEN}Basic ping test successful!${NC}" >&3
        
        echo -e "${YELLOW}Step 3: Testing with MTU $MTU_SIZE...${NC}" >&3
        if ping6 -c 4 -M do -s $((MTU_SIZE-48)) $ping_target >/dev/null 2>>"$LOG_FILE"; then
            echo -e "${GREEN}MTU test successful with packet size $((MTU_SIZE-48))!${NC}" >&3
        else
            echo -e "${YELLOW}MTU test failed, but basic connectivity works.${NC}" >&3
        fi
        
        echo -e "${YELLOW}Step 4: Traceroute test...${NC}" >&3
        traceroute6 -n $ping_target >&3 2>>"$LOG_FILE"
    else
        echo -e "${RED}IPv6 connection failed completely${NC}" >&3
        echo -e "${YELLOW}Interface status:" >&3
        ip link show $TUNNEL_IFACE >&3 2>>"$LOG_FILE"
        echo -e "${YELLOW}IPv6 address:" >&3
        ip -6 addr show $TUNNEL_IFACE >&3 2>>"$LOG_FILE"
        echo -e "${YELLOW}IPv6 route:" >&3
        ip -6 route show dev $TUNNEL_IFACE >&3 2>>"$LOG_FILE"
        echo -e "${YELLOW}Checking kernel logs for errors:" >&3
        dmesg | tail -n 20 >&3 2>>"$LOG_FILE"
        echo -e "${YELLOW}Troubleshooting steps:" >&3
        echo "1. Verify IPv6 address is set on both servers." >&3
        echo "2. Check firewall rules on both servers: 'iptables -L -v -n' and 'ip6tables -L -v -n'." >&3
        echo "3. Ensure both servers have matching MTU settings." >&3
    fi
    
    read -p "Press [Enter] to return to main menu" <&3
}

# Show tunnel info
show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No active tunnel configuration found.${NC}" >&3
    else
        source "$CONFIG_FILE" 2>>"$LOG_FILE"
        
        echo -e "${BLUE}Current Tunnel Configuration:${NC}" >&3
        echo -e "${YELLOW}Location: $LOCATION" >&3
        echo "Iran IPv4: $IRAN_IPV4" >&3
        echo "Foreign IPv4: $FOREIGN_IPV4" >&3
        echo "Local IPv6: $LOCAL_IPV6" >&3
        echo "Remote IPv6: $REMOTE_IPV6" >&3
        echo "MTU Size: $MTU_SIZE${NC}" >&3
        
        echo -e "\n${BLUE}Interface Status:${NC}" >&3
        ip link show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}Interface not found${NC}" >&3 2>>"$LOG_FILE"
        
        echo -e "\n${BLUE}IPv6 Address:${NC}" >&3
        ip -6 addr show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 address${NC}" >&3 2>>"$LOG_FILE"
        
        echo -e "\n${BLUE}IPv6 Route:${NC}" >&3
        ip -6 route show dev $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 routes${NC}" >&3 2>>"$LOG_FILE"
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
