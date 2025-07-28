#!/bin/bash

# Configuration
TUNNEL_IFACE="iranv6tun"
TUNNEL_PREFIX="fdbd:1b5d:0aa8"  # پیشوند IPv6 لوکال
CONFIG_FILE="/etc/iranv6tun.conf"
LOG_FILE="/var/log/iranv6tun.log"
MTU_SIZE=1280  # MTU پیش‌فرض برای تانل‌های IPv6
BACKUP_FILE="/etc/iranv6tun_backup.conf"
TIMEOUT=10  # زمان انتظار برای بررسی اینترفیس

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Initialize logging
exec 3>&1
echo "Script started at $(date)" > "$LOG_FILE" 2>&1

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
    echo "║    Iran-Foreign IPv6 TCP Tunnel    ║"
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

# Backup current config
backup_config() {
    echo -e "${BLUE}Backing up current configuration...${NC}" >&3
    {
        echo "# Backup created at $(date)"
        echo "IPTABLES_BACKUP=$(iptables-save 2>/dev/null | base64 -w0)"
        echo "IP6TABLES_BACKUP=$(ip6tables-save 2>/dev/null | base64 -w0)"
        echo "SYSCTL_BACKUP=$(sysctl -a 2>/dev/null | grep -E 'net.ipv6.conf|net.ipv4.ip_forward' | base64 -w0)"
        echo "INTERFACES_BACKUP=$(ip -6 addr show 2>/dev/null | base64 -w0)"
    } > "$BACKUP_FILE" 2>>"$LOG_FILE"
    echo -e "${GREEN}Backup saved to $BACKUP_FILE${NC}" >&3
}

# Restore config
restore_config() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}No backup found. Performing basic cleanup.${NC}" >&3
        basic_cleanup
        return
    fi

    echo -e "${BLUE}Restoring original configuration...${NC}" >&3
    
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
    
    echo -e "${GREEN}Configuration restored successfully!${NC}" >&3
    rm -f "$BACKUP_FILE" 2>>"$LOG_FILE"
}

# Basic cleanup
basic_cleanup() {
    echo -e "${BLUE}Cleaning up existing tunnel...${NC}" >&3
    
    ip link delete $TUNNEL_IFACE 2>/dev/null
    ip -6 addr flush dev $TUNNEL_IFACE 2>/dev/null
    ip -6 route flush dev $TUNNEL_IFACE 2>/dev/null
    
    iptables -D INPUT -p 41 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p 41 -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>/dev/null
    
    rm -f "$CONFIG_FILE" 2>>"$LOG_FILE"
    sleep 2
}

# Verify interface
verify_interface() {
    local timeout=$TIMEOUT
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
    
    if ! sysctl -n net.ipv6.conf.all.disable_ipv6 | grep -q 0; then
        echo -e "${YELLOW}Enabling IPv6...${NC}" >&3
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>>"$LOG_FILE"
    fi
    
    if ! lsmod | grep -q sit; then
        echo -e "${YELLOW}Loading SIT module...${NC}" >&3
        modprobe sit 2>>"$LOG_FILE"
        if ! lsmod | grep -q sit; then
            echo -e "${RED}Failed to load SIT module. Kernel support missing.${NC}" >&3
            exit 1
        fi
    fi
    
    echo -e "${GREEN}Dependencies installed successfully!${NC}" >&3
    read -p "Press [Enter] to return to main menu" <&3
}

# Create tunnel
create_tunnel_iproute() {
    echo -e "${BLUE}Creating SIT tunnel...${NC}" >&3
    
    ip tunnel add $TUNNEL_IFACE mode sit remote $REMOTE_IPV4 local $LOCAL_IPV4 ttl 255 2>>"$LOG_FILE" || {
        echo -e "${RED}Failed to create tunnel interface.${NC}" >&3
        return 1
    }
    
    ip link set $TUNNEL_IFACE up mtu $MTU_SIZE 2>>"$LOG_FILE" || {
        echo -e "${RED}Failed to bring up tunnel interface.${NC}" >&3
        return 1
    }
    
    sleep 2
}

# Test MTU
test_mtu() {
    echo -e "${YELLOW}Testing optimal MTU...${NC}" >&3
    local test_sizes=(1200 1280 1400 1472)
    local success=false
    
    for size in "${test_sizes[@]}"; do
        echo -e "${YELLOW}Trying MTU $size...${NC}" >&3
        if ping6 -c 2 -M do -s $size $REMOTE_IPV6 >/dev/null 2>&1; then
            MTU_SIZE=$((size + 48))
            ip link set $TUNNEL_IFACE mtu $MTU_SIZE
            echo -e "${GREEN}Optimal MTU found: $MTU_SIZE${NC}" >&3
            success=true
            break
        fi
    done
    
    if ! $success; then
        echo -e "${YELLOW}Using default MTU 1280${NC}" >&3
        ip link set $TUNNEL_IFACE mtu 1280
    fi
}

# Configure tunnel
configure_tunnel() {
    echo -e "${BLUE}Configuring tunnel parameters...${NC}" >&3
    
    backup_config
    
    ip -6 addr add $LOCAL_IPV6 dev $TUNNEL_IFACE 2>>"$LOG_FILE" || {
        echo -e "${RED}Failed to assign IPv6 address.${NC}" >&3
        return 1
    }
    
    ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100 2>>"$LOG_FILE" || {
        echo -e "${RED}Failed to add IPv6 route.${NC}" >&3
        return 1
    }
    
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    sysctl -w net.ipv6.conf.$TUNNEL_IFACE.forwarding=1 >/dev/null 2>>"$LOG_FILE"
    
    # Firewall rules for SIT (protocol 41)
    iptables -A INPUT -p 41 -s $REMOTE_IPV4 -d $LOCAL_IPV4 -j ACCEPT 2>>"$LOG_FILE"
    iptables -A OUTPUT -p 41 -s $LOCAL_IPV4 -d $REMOTE_IPV4 -j ACCEPT 2>>"$LOG_FILE"
    
    # IPv6 firewall rules
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT 2>>"$LOG_FILE"
    ip6tables -A FORWARD -i $TUNNEL_IFACE -j ACCEPT 2>>"$LOG_FILE"
    ip6tables -A FORWARD -o $TUNNEL_IFACE -j ACCEPT 2>>"$LOG_FILE"
    
    # Save config
    {
        echo "LOCATION=$location"
        echo "IRAN_IPV4=$IRAN_IPV4"
        echo "FOREIGN_IPV4=$FOREIGN_IPV4"
        echo "LOCAL_IPV6=$LOCAL_IPV6"
        echo "REMOTE_IPV6=$REMOTE_IPV6"
        echo "MTU_SIZE=$MTU_SIZE"
    } > "$CONFIG_FILE" 2>>"$LOG_FILE"
    
    echo -e "${GREEN}Tunnel configured successfully!${NC}" >&3
}

# Main tunnel creation
create_tunnel() {
    echo -e "${YELLOW}Enter server details:${NC}" >&3
    
    while true; do
        read -p "Iran server IPv4: " IRAN_IPV4
        [[ $IRAN_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo -e "${RED}Invalid IPv4 format. Try again.${NC}" >&3
    done
    
    while true; do
        read -p "Foreign server IPv4: " FOREIGN_IPV4
        [[ $FOREIGN_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo -e "${RED}Invalid IPv4 format. Try again.${NC}" >&3
    done
    
    echo -e "${YELLOW}Select your location:${NC}" >&3
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
            *) echo -e "${RED}Invalid choice. Select 1 or 2.${NC}" >&3 ;;
        esac
    done

    basic_cleanup
    
    create_tunnel_iproute || {
        read -p "Press [Enter] to return to main menu" <&3
        return 1
    }
    
    verify_interface || {
        echo -e "${RED}Tunnel interface not created. Check logs.${NC}" >&3
        echo -e "${YELLOW}Debug info:" >&3
        dmesg | tail -20 >&3
        ip link show >&3
        read -p "Press [Enter] to return to main menu" <&3
        return 1
    }
    
    configure_tunnel
    test_mtu
    
    echo -e "${GREEN}Tunnel created successfully!${NC}" >&3
    echo -e "${YELLOW}Local IPv6: $LOCAL_IPV6${NC}" >&3
    echo -e "${YELLOW}Remote IPv6: $REMOTE_IPV6${NC}" >&3
    
    if [ "$location" == "Foreign" ]; then
        echo -e "${BLUE}On Iran server ($IRAN_IPV4), run these commands:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $FOREIGN_IPV4 local $IRAN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip -6 addr add ${TUNNEL_PREFIX}::1/64 dev $TUNNEL_IFACE" >&3
        echo "ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
    else
        echo -e "${BLUE}On Foreign server ($FOREIGN_IPV4), run these commands:${NC}" >&3
        echo "ip tunnel add $TUNNEL_IFACE mode sit remote $IRAN_IPV4 local $FOREIGN_IPV4 ttl 255" >&3
        echo "ip link set $TUNNEL_IFACE up mtu $MTU_SIZE" >&3
        echo "ip -6 addr add ${TUNNEL_PREFIX}::2/64 dev $TUNNEL_IFACE" >&3
        echo "ip -6 route add ::/0 dev $TUNNEL_IFACE metric 100" >&3
    fi
    
    read -p "Press [Enter] after configuring the other server" <&3
    check_connection
}

# Remove tunnel
remove_tunnel() {
    echo -e "${RED}Warning: This will remove the tunnel completely${NC}" >&3
    read -p "Are you sure? [y/N] " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        restore_config
        echo -e "${GREEN}Tunnel removed successfully!${NC}" >&3
    else
        echo -e "${YELLOW}Operation canceled.${NC}" >&3
    fi
    
    read -p "Press [Enter] to continue" <&3
}

# Check connection
check_connection() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No active tunnel found.${NC}" >&3
        read -p "Press [Enter] to continue" <&3
        return
    fi
    
    source "$CONFIG_FILE" 2>>"$LOG_FILE"
    
    if [ "$LOCATION" == "Iran" ]; then
        ping_target="${TUNNEL_PREFIX}::2"
    else
        ping_target="${TUNNEL_PREFIX}::1"
    fi
    
    echo -e "${BLUE}Testing connection to $ping_target...${NC}" >&3
    
    # Basic ping test
    if ping6 -c 4 $ping_target >/dev/null 2>&1; then
        echo -e "${GREEN}Basic IPv6 connectivity OK${NC}" >&3
        
        # TCP test using netcat (if installed)
        if command -v nc &>/dev/null; then
            echo -e "${YELLOW}Testing TCP connectivity...${NC}" >&3
            if nc -6 -z -v -w 3 $ping_target 22 2>>"$LOG_FILE"; then
                echo -e "${GREEN}TCP connectivity OK${NC}" >&3
            else
                echo -e "${YELLOW}TCP test failed (may be firewall related)${NC}" >&3
            fi
        fi
        
        # MTU test
        if ping6 -c 2 -M do -s $((MTU_SIZE-48)) $ping_target >/dev/null 2>&1; then
            echo -e "${GREEN}MTU test successful with $MTU_SIZE${NC}" >&3
        else
            echo -e "${YELLOW}MTU test failed (actual MTU may be smaller)${NC}" >&3
        fi
        
        # Traceroute
        echo -e "${YELLOW}Traceroute results:${NC}" >&3
        traceroute6 -n $ping_target >&3 2>>"$LOG_FILE"
    else
        echo -e "${RED}IPv6 connectivity failed!${NC}" >&3
        echo -e "${YELLOW}Troubleshooting info:${NC}" >&3
        ip link show $TUNNEL_IFACE >&3
        ip -6 addr show $TUNNEL_IFACE >&3
        ip -6 route show >&3
        dmesg | tail -15 >&3
    fi
    
    read -p "Press [Enter] to continue" <&3
}

# Show tunnel info
show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}No active tunnel found.${NC}" >&3
    else
        source "$CONFIG_FILE" 2>>"$LOG_FILE"
        
        echo -e "${BLUE}Current Tunnel Configuration:${NC}" >&3
        echo -e "${YELLOW}Location: $LOCATION" >&3
        echo "Iran IPv4: $IRAN_IPV4" >&3
        echo "Foreign IPv4: $FOREIGN_IPV4" >&3
        echo "Local IPv6: $LOCAL_IPV6" >&3
        echo "Remote IPv6: $REMOTE_IPV6" >&3
        echo "MTU: $MTU_SIZE${NC}" >&3
        
        echo -e "\n${BLUE}Interface Status:${NC}" >&3
        ip link show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}Interface not found${NC}" >&3
        
        echo -e "\n${BLUE}IPv6 Address:${NC}" >&3
        ip -6 addr show $TUNNEL_IFACE 2>/dev/null || echo -e "${RED}No IPv6 address${NC}" >&3
        
        echo -e "\n${BLUE}IPv6 Routes:${NC}" >&3
        ip -6 route show 2>/dev/null | grep -v '^fe80' >&3
    fi
    
    read -p "Press [Enter] to continue" <&3
}

# View logs
view_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${RED}No log file found.${NC}" >&3
    else
        echo -e "${BLUE}Last 20 lines of log:${NC}" >&3
        tail -n 20 "$LOG_FILE" >&3
    fi
    read -p "Press [Enter] to continue" <&3
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
            echo -e "${RED}Invalid option. Try again.${NC}" >&3
            sleep 1
            ;;
    esac
done
