#!/bin/bash
# IPv6 Tunnel Script between Iran and Foreign Servers
# Version: 2.0 - Fixed Version

# Color message functions
function colored_msg() {
    local color=$1
    local message=$2
    case $color in
        red) printf "\033[31m%s\033[0m\n" "$message" ;;
        green) printf "\033[32m%s\033[0m\n" "$message" ;;
        yellow) printf "\033[33m%s\033[0m\n" "$message" ;;
        blue) printf "\033[34m%s\033[0m\n" "$message" ;;
        *) printf "%s\n" "$message" ;;
    esac
}

# Check root access
function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        colored_msg red "This script must be run as root. Use 'sudo $0'"
        exit 1
    fi
}

# Detect OS
function detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        VER=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print tolower($1)}')
        VER=$(cat /etc/redhat-release | sed 's/.*release \([0-9\.]\+\).*/\1/')
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VER=$(uname -r)
    fi

    if [[ "$OS" != "ubuntu" && "$OS" != "debian" && "$OS" != "centos" && "$OS" != "fedora" ]]; then
        colored_msg red "Unsupported OS: $OS. Only Ubuntu, Debian, CentOS and Fedora are supported."
        exit 1
    fi
}

# Install required packages
function install_packages() {
    colored_msg blue "Installing required packages..."
    
    # Update package lists
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get update -qq
        apt-get install -y -qq iproute2 net-tools sed grep iputils-ping curl netcat-openbsd
    elif [ "$OS" = "centos" ] || [ "$OS" = "fedora" ]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y -q iproute net-tools sed grep iputils curl nmap-ncat
        else
            yum install -y -q iproute net-tools sed grep iputils curl nmap-ncat
        fi
    fi
    
    if [ $? -eq 0 ]; then
        colored_msg green "Packages installed successfully."
    else
        colored_msg red "Failed to install packages."
        exit 1
    fi
}

# Load kernel modules
function load_kernel_modules() {
    colored_msg blue "Loading kernel modules..."
    
    modules=("sit" "tunnel4" "ip6_tunnel" "ip6_gre")
    
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "$module"; then
            modprobe "$module" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "$module" > "/etc/modules-load.d/${module}.conf"
                colored_msg green "Module $module loaded."
            else
                colored_msg yellow "Warning: Failed to load module $module"
            fi
        fi
    done
}

# Configure firewall
function setup_firewall() {
    colored_msg blue "Configuring firewall..."
    
    # Allow protocol 41 (IPv6 over IPv4)
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p 41 -j ACCEPT 2>/dev/null
        iptables -I FORWARD -p 41 -j ACCEPT 2>/dev/null
        iptables -I OUTPUT -p 41 -j ACCEPT 2>/dev/null
        
        # Save rules
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
    
    # Allow IPv6 ICMP
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p icmpv6 -j ACCEPT 2>/dev/null
        ip6tables -I FORWARD -p icmpv6 -j ACCEPT 2>/dev/null
        ip6tables -I OUTPUT -p icmpv6 -j ACCEPT 2>/dev/null
        
        # Save rules
        if command -v ip6tables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
    
    # For firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-protocol=41 >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-protocol=ipv6-icmp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    
    # For UFW
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow proto 41 >/dev/null 2>&1 || true
        ufw allow ipv6 >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    fi
    
    colored_msg green "Firewall configured."
}

# Configure sysctl
function setup_sysctl() {
    colored_msg blue "Configuring sysctl parameters..."
    
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-ipv6-tunnel.conf <<EOF
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv4.ip_forward=1
EOF
    
    sysctl -p /etc/sysctl.d/99-ipv6-tunnel.conf >/dev/null 2>&1
    colored_msg green "Sysctl configured."
}

# Create tunnel
function create_ipv6_tunnel() {
    local location=$1
    local iran_ipv4=$2
    local foreign_ipv4=$3
    
    # Validate IPv4 addresses
    if [[ ! "$iran_ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        colored_msg red "Invalid Iran IPv4 address format!"
        exit 1
    fi
    
    if [[ ! "$foreign_ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        colored_msg red "Invalid Foreign IPv4 address format!"
        exit 1
    fi
    
    # IPv6 prefix
    local ipv6_prefix="fd00:1234:5678:9abc"
    
    if [ "$location" == "iran" ]; then
        local local_ipv6="${ipv6_prefix}::1/64"
        local remote_ipv6="${ipv6_prefix}::2"
        local local_ipv4=$iran_ipv4
        local remote_ipv4=$foreign_ipv4
    else
        local local_ipv6="${ipv6_prefix}::2/64"
        local remote_ipv6="${ipv6_prefix}::1"
        local local_ipv4=$foreign_ipv4
        local remote_ipv4=$iran_ipv4
    fi
    
    # Remove existing tunnel
    ip link del ipv6tun 2>/dev/null || true
    
    # Create tunnel
    ip tunnel add ipv6tun mode sit remote "$remote_ipv4" local "$local_ipv4" ttl 255
    if [ $? -ne 0 ]; then
        colored_msg red "Failed to create tunnel interface."
        exit 1
    fi
    
    # Configure tunnel
    ip link set ipv6tun mtu 1480 up
    ip addr add "$local_ipv6" dev ipv6tun
    ip -6 route add "$remote_ipv6" dev ipv6tun
    
    # Save configuration
    echo "$location $iran_ipv4 $foreign_ipv4" > /etc/ipv6tun.conf
    
    # Create persistent config
    create_persistent_config "$location" "$iran_ipv4" "$foreign_ipv4"
    
    colored_msg green "IPv6 tunnel created successfully!"
    echo ""
    colored_msg yellow "Tunnel Information:"
    echo "Local IPv6: $local_ipv6"
    echo "Remote IPv6: $remote_ipv6"
    echo ""
    colored_msg yellow "Test command for remote server:"
    colored_msg blue "ping6 -c 3 $remote_ipv6"
}

# Create persistent configuration
function create_persistent_config() {
    local location=$1
    local iran_ipv4=$2
    local foreign_ipv4=$3
    
    local ipv6_prefix="fd00:1234:5678:9abc"
    
    if [ "$location" == "iran" ]; then
        local local_ipv6="${ipv6_prefix}::1/64"
        local remote_ipv6="${ipv6_prefix}::2"
        local local_ipv4=$iran_ipv4
        local remote_ipv4=$foreign_ipv4
    else
        local local_ipv6="${ipv6_prefix}::2/64"
        local remote_ipv6="${ipv6_prefix}::1"
        local local_ipv4=$foreign_ipv4
        local remote_ipv4=$iran_ipv4
    fi
    
    # For Debian/Ubuntu
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        mkdir -p /etc/network/interfaces.d
        cat > /etc/network/interfaces.d/ipv6tun <<EOF
auto ipv6tun
iface ipv6tun inet6 static
    address $local_ipv6
    netmask 64
    tunnel-ipv4-local $local_ipv4
    tunnel-ipv4-remote $remote_ipv4
    tunnel-mode sit
    mtu 1480
EOF
    fi
    
    # For CentOS/RHEL/Fedora
    if [ "$OS" = "centos" ] || [ "$OS" = "fedora" ]; then
        mkdir -p /etc/sysconfig/network-scripts
        cat > /etc/sysconfig/network-scripts/ifcfg-ipv6tun <<EOF
DEVICE=ipv6tun
BOOTPROTO=none
ONBOOT=yes
IPV6INIT=yes
IPV6ADDR=$local_ipv6
TYPE=sit
PEER_OUTER_IPV4ADDR=$remote_ipv4
PEER_INNER_IPV4ADDR=$local_ipv4
MTU=1480
EOF
    fi
    
    # For NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection add type sit con-name ipv6tun ifname ipv6tun \
            ip-tunnel.local "$local_ipv4" ip-tunnel.remote "$remote_ipv4" \
            ipv6.addresses "$local_ipv6" ipv6.method manual >/dev/null 2>&1 || true
        nmcli connection up ipv6tun >/dev/null 2>&1 || true
    fi
}

# Test tunnel
function test_connection() {
    if [ ! -f /etc/ipv6tun.conf ]; then
        colored_msg yellow "No tunnel configuration found. Please create a tunnel first."
        return 1
    fi
    
    colored_msg blue "Testing IPv6 tunnel connection..."
    
    # Read config
    local location=$(awk '{print $1}' /etc/ipv6tun.conf)
    local iran_ipv4=$(awk '{print $2}' /etc/ipv6tun.conf)
    local foreign_ipv4=$(awk '{print $3}' /etc/ipv6tun.conf)
    
    local ipv6_prefix="fd00:1234:5678:9abc"
    if [ "$location" == "iran" ]; then
        local remote_ipv6="${ipv6_prefix}::2"
    else
        local remote_ipv6="${ipv6_prefix}::1"
    fi
    
    # Test with ping6
    colored_msg yellow "Pinging $remote_ipv6..."
    if ping6 -c 3 -W 2 "$remote_ipv6" >/dev/null 2>&1; then
        colored_msg green "Ping successful! Tunnel is working."
        return 0
    else
        colored_msg red "Ping failed. Running diagnostics..."
        run_diagnostics "$remote_ipv6" "$remote_ipv4"
        return 1
    fi
}

# Diagnostics
function run_diagnostics() {
    local remote_ipv6=$1
    local remote_ipv4=$2
    
    colored_msg yellow "=== DIAGNOSTICS ==="
    
    # Check tunnel interface
    if ip link show ipv6tun >/dev/null 2>&1; then
        colored_msg green "Tunnel interface exists:"
        ip link show ipv6tun
    else
        colored_msg red "Tunnel interface does not exist!"
    fi
    
    # Check IPv6 address
    colored_msg yellow "IPv6 address on tunnel:"
    ip -6 addr show dev ipv6tun 2>/dev/null || colored_msg red "No IPv6 address assigned!"
    
    # Check routes
    colored_msg yellow "IPv6 routes:"
    ip -6 route show | grep ipv6tun || colored_msg red "No route through tunnel!"
    
    # Check IPv4 connectivity
    colored_msg yellow "Testing IPv4 connectivity to $remote_ipv4..."
    if ping -c 3 -W 2 "$remote_ipv4" >/dev/null 2>&1; then
        colored_msg green "IPv4 connectivity is working."
    else
        colored_msg red "IPv4 connectivity failed!"
    fi
    
    # Check protocol 41
    colored_msg yellow "Testing protocol 41..."
    nc -4 -w 3 "$remote_ipv4" 41 <<< "test" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        colored_msg green "Protocol 41 is allowed."
    else
        colored_msg red "Protocol 41 may be blocked!"
    fi
    
    # Check kernel modules
    colored_msg yellow "Checking kernel modules:"
    lsmod | grep -E "(sit|tunnel4|ip6_tunnel)" || colored_msg red "Required modules not loaded!"
    
    colored_msg yellow "=== END DIAGNOSTICS ==="
}

# Remove tunnel
function remove_ipv6_tunnel() {
    if [ ! -f /etc/ipv6tun.conf ]; then
        colored_msg yellow "No tunnel configuration found. Nothing to remove."
        return 0
    fi
    
    colored_msg blue "Removing IPv6 tunnel..."
    
    # Remove tunnel interface
    ip link del ipv6tun 2>/dev/null || true
    
    # Remove configuration files
    rm -f /etc/network/interfaces.d/ipv6tun
    rm -f /etc/sysconfig/network-scripts/ifcfg-ipv6tun
    rm -f /etc/ipv6tun.conf
    
    # Remove NetworkManager connection
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection delete ipv6tun 2>/dev/null || true
    fi
    
    # Remove sysctl config
    rm -f /etc/sysctl.d/99-ipv6-tunnel.conf
    
    # Remove module configs
    rm -f /etc/modules-load.d/sit.conf
    rm -f /etc/modules-load.d/tunnel4.conf
    rm -f /etc/modules-load.d/ip6_tunnel.conf
    rm -f /etc/modules-load.d/ip6_gre.conf
    
    colored_msg green "IPv6 tunnel removed successfully!"
}

# Main menu
function show_menu() {
    while true; do
        clear
        colored_msg blue "===================================="
        colored_msg blue "  IPv6 Tunnel Setup Tool v2.0"
        colored_msg blue "===================================="
        echo ""
        echo "1) Create IPv6 Tunnel"
        echo "2) Test Tunnel Connection"
        echo "3) Remove IPv6 Tunnel"
        echo "4) Exit"
        echo ""
        read -p "Select an option [1-4]: " choice
        
        case $choice in
            1)
                check_root
                detect_os
                install_packages
                load_kernel_modules
                setup_firewall
                setup_sysctl
                
                echo ""
                colored_msg yellow "Server Location:"
                echo "1) Iran"
                echo "2) Foreign"
                read -p "Select location [1-2]: " loc_choice
                
                case $loc_choice in
                    1) location="iran" ;;
                    2) location="foreign" ;;
                    *) 
                        colored_msg red "Invalid selection!"
                        continue
                        ;;
                esac
                
                echo ""
                read -p "Enter Iran server IPv4: " iran_ipv4
                read -p "Enter Foreign server IPv4: " foreign_ipv4
                
                create_ipv6_tunnel "$location" "$iran_ipv4" "$foreign_ipv4"
                read -p "Press Enter to continue..."
                ;;
            2)
                check_root
                test_connection
                read -p "Press Enter to continue..."
                ;;
            3)
                check_root
                remove_ipv6_tunnel
                read -p "Press Enter to continue..."
                ;;
            4)
                colored_msg green "Exiting..."
                exit 0
                ;;
            *)
                colored_msg red "Invalid option!"
                sleep 2
                ;;
        esac
    done
}

# Start script
show_menu
