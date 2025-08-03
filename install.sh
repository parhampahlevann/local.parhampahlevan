#!/bin/bash

# Color message functions
function colored_msg() {
    local color=$1
    local message=$2
    case $color in
        red) echo -e "\033[31m$message\033[0m" ;;
        green) echo -e "\033[32m$message\033[0m" ;;
        yellow) echo -e "\033[33m$message\033[0m" ;;
        blue) echo -e "\033[34m$message\033[0m" ;;
        *) echo "$message" ;;
    esac
}

# Check root access
function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        colored_msg red "This script must be run as root."
        exit 1
    fi
}

# Check OS compatibility
function check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VER=$(lsb_release -sr)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VER=$(uname -r)
    fi
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" && "$OS" != "centos" && "$OS" != "fedora" ]]; then
        colored_msg red "This script only supports Debian/Ubuntu and RHEL/CentOS/Fedora systems."
        exit 1
    fi
}

# Install required packages
function install_dependencies() {
    colored_msg blue "Installing required packages..."
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools sed grep iputils-ping curl netcat-openbsd
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools sed grep iputils curl nmap-ncat
    fi
}

# Load required kernel modules
function load_modules() {
    colored_msg blue "Loading required kernel modules..."
    modprobe sit
    modprobe tunnel4
    modprobe ip6_tunnel
    modprobe ip6_gre
    
    # Make modules load on boot
    echo "sit" > /etc/modules-load.d/sit.conf
    echo "tunnel4" > /etc/modules-load.d/tunnel4.conf
    echo "ip6_tunnel" > /etc/modules-load.d/ip6_tunnel.conf
    echo "ip6_gre" > /etc/modules-load.d/ip6_gre.conf
}

# Configure firewall for IPv6 tunnel
function configure_firewall() {
    colored_msg blue "Configuring firewall for IPv6 tunnel..."
    
    # Allow protocol 41 (IPv6 over IPv4)
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p 41 -j ACCEPT
        iptables -I FORWARD -p 41 -j ACCEPT
        iptables -I OUTPUT -p 41 -j ACCEPT
        
        # Save rules
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
    
    # Allow IPv6 ICMP (for ping6)
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p icmpv6 -j ACCEPT
        ip6tables -I FORWARD -p icmpv6 -j ACCEPT
        ip6tables -I OUTPUT -p icmpv6 -j ACCEPT
        
        # Save rules
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
    
    # For systems with firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-protocol=41 >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-protocol=ipv6-icmp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    
    # For systems with ufw
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow proto 41 >/dev/null 2>&1 || true
        ufw allow ipv6 >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    fi
}

# Configure sysctl parameters
function configure_sysctl() {
    colored_msg blue "Configuring sysctl parameters..."
    
    # Create sysctl configuration file
    cat > /etc/sysctl.d/99-ipv6-tunnel.conf <<EOF
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv4.ip_forward=1
EOF
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-ipv6-tunnel.conf
}

# Create IPv6 tunnel
function create_tunnel() {
    local location=$1
    local iran_ipv4=$2
    local foreign_ipv4=$3
    
    # Common IPv6 prefix
    local ipv6_prefix="fdbd:1b5d:0aa8"
    
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
    
    # Load kernel modules
    load_modules
    
    # Remove any existing tunnel
    ip link del ipv6tun 2>/dev/null
    
    # Create tunnel interface
    ip tunnel add ipv6tun mode sit remote $remote_ipv4 local $local_ipv4 ttl 255
    
    # Set MTU to 1480 (standard for IPv6 in IPv4 tunnel)
    ip link set ipv6tun mtu 1480 up
    
    # Assign IPv6 addresses
    ip addr add $local_ipv6 dev ipv6tun
    
    # Add route for remote IPv6 through the tunnel
    ip -6 route add $remote_ipv6 dev ipv6tun
    
    # Configure sysctl
    configure_sysctl
    
    # Configure firewall
    configure_firewall
    
    # Save config for uninstall
    echo "$location $iran_ipv4 $foreign_ipv4" > /etc/ipv6tun.conf
    
    # Create network configuration for persistence
    create_network_config "$location" "$iran_ipv4" "$foreign_ipv4"
    
    colored_msg green "IPv6 tunnel created successfully!"
    echo ""
    colored_msg yellow "Tunnel Information:"
    echo "Local IPv6: $local_ipv6"
    echo "Remote IPv6: $remote_ipv6"
    echo ""
    colored_msg yellow "To test connection, run this command on the remote server:"
    colored_msg blue "ping6 -I ipv6tun $remote_ipv6"
}

# Create network configuration for persistence
function create_network_config() {
    local location=$1
    local iran_ipv4=$2
    local foreign_ipv4=$3
    
    local ipv6_prefix="fdbd:1b5d:0aa8"
    
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
    
    # Create network configuration file
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
    
    # For systems using NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        nmcli con add type sit con-name ipv6tun ifname ipv6tun ip-tunnel.local $local_ipv4 ip-tunnel.remote $remote_ipv4
        nmcli con mod ipv6tun ipv6.addresses $local_ipv6
        nmcli con mod ipv6tun ipv6.method manual
        nmcli con up ipv6tun
    fi
}

# Test the tunnel connection
function test_tunnel() {
    if [ -f /etc/ipv6tun.conf ]; then
        colored_msg blue "Testing IPv6 tunnel connection..."
        
        # Read config
        local location=$(awk '{print $1}' /etc/ipv6tun.conf)
        local iran_ipv4=$(awk '{print $2}' /etc/ipv6tun.conf)
        local foreign_ipv4=$(awk '{print $3}' /etc/ipv6tun.conf)
        
        local ipv6_prefix="fdbd:1b5d:0aa8"
        if [ "$location" == "iran" ]; then
            local remote_ipv6="${ipv6_prefix}::2"
        else
            local remote_ipv6="${ipv6_prefix}::1"
        fi
        
        # Test ping
        colored_msg yellow "Pinging remote IPv6 address: $remote_ipv6"
        if ping6 -c 3 -I ipv6tun $remote_ipv6 >/dev/null 2>&1; then
            colored_msg green "Ping successful! Tunnel is working."
            
            # Test with nc (netcat)
            colored_msg yellow "Testing with netcat..."
            nc -6 -u -w 3 $remote_ipv6 50000 <<< "test" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                colored_msg green "Netcat test successful!"
            else
                colored_msg yellow "Netcat test failed, but ping worked. Firewall may be blocking UDP."
            fi
        else
            colored_msg red "Ping failed. Running diagnostics..."
            run_diagnostics "$remote_ipv6" "$remote_ipv4"
        fi
    else
        colored_msg yellow "No IPv6 tunnel configuration found. Cannot test."
    fi
}

# Run diagnostics
function run_diagnostics() {
    local remote_ipv6=$1
    local remote_ipv4=$2
    
    colored_msg yellow "=== DIAGNOSTICS ==="
    
    # Check if tunnel interface exists
    if ip link show ipv6tun >/dev/null 2>&1; then
        colored_msg green "Tunnel interface exists."
        ip link show ipv6tun
    else
        colored_msg red "Tunnel interface does not exist!"
    fi
    
    # Check IPv6 addresses
    colored_msg yellow "IPv6 addresses on tunnel:"
    ip -6 addr show dev ipv6tun 2>/dev/null || colored_msg red "No IPv6 addresses on tunnel!"
    
    # Check routes
    colored_msg yellow "IPv6 routes:"
    ip -6 route show | grep ipv6tun
    
    # Check IPv4 connectivity
    colored_msg yellow "Testing IPv4 connectivity to remote server:"
    if ping -c 3 $remote_ipv4 >/dev/null 2>&1; then
        colored_msg green "IPv4 connectivity to remote server is working."
    else
        colored_msg red "IPv4 connectivity to remote server is failing!"
    fi
    
    # Check protocol 41
    colored_msg yellow "Checking if protocol 41 is allowed:"
    if nc -4 -w 3 $remote_ipv4 41 <<< "test" >/dev/null 2>&1; then
        colored_msg green "Protocol 41 is allowed."
    else
        colored_msg red "Protocol 41 may be blocked by firewall!"
    fi
    
    # Check kernel modules
    colored_msg yellow "Checking kernel modules:"
    lsmod | grep -E "(sit|tunnel4|ip6_tunnel)"
    
    colored_msg yellow "=== END DIAGNOSTICS ==="
}

# Remove tunnel and revert changes
function remove_tunnel() {
    if [ -f /etc/ipv6tun.conf ]; then
        colored_msg blue "Removing IPv6 tunnel..."
        
        # Remove tunnel interface
        ip link del ipv6tun 2>/dev/null
        
        # Remove network configuration
        rm -f /etc/network/interfaces.d/ipv6tun
        
        # Remove NetworkManager connection
        if command -v nmcli >/dev/null 2>&1; then
            nmcli con delete ipv6tun 2>/dev/null || true
        fi
        
        # Remove sysctl configuration
        rm -f /etc/sysctl.d/99-ipv6-tunnel.conf
        
        # Remove module loading configuration
        rm -f /etc/modules-load.d/sit.conf
        rm -f /etc/modules-load.d/tunnel4.conf
        rm -f /etc/modules-load.d/ip6_tunnel.conf
        rm -f /etc/modules-load.d/ip6_gre.conf
        
        # Remove config file
        rm -f /etc/ipv6tun.conf
        
        colored_msg green "IPv6 tunnel removed successfully!"
    else
        colored_msg yellow "No IPv6 tunnel configuration found. Nothing to remove."
    fi
}

# Main menu
function main_menu() {
    clear
    colored_msg blue "===================================="
    colored_msg blue "IPv6 Tunnel between Iran and Foreign"
    colored_msg blue "===================================="
    echo ""
    
    PS3="Please select an option: "
    options=("Create IPv6 Tunnel" "Test Tunnel Connection" "Remove IPv6 Tunnel" "Exit")
    select opt in "${options[@]}"
    do
        case $opt in
            "Create IPv6 Tunnel")
                check_root
                check_os
                install_dependencies
                
                PS3="Select server location: "
                locations=("Iran" "Foreign")
                select loc in "${locations[@]}"
                do
                    case $loc in
                        "Iran")
                            location="iran"
                            break
                            ;;
                        "Foreign")
                            location="foreign"
                            break
                            ;;
                        *) echo "Invalid option";;
                    esac
                done
                
                echo ""
                colored_msg yellow "Please enter required information:"
                read -p "Iran server IPv4: " iran_ipv4
                read -p "Foreign server IPv4: " foreign_ipv4
                
                echo ""
                colored_msg blue "Creating IPv6 tunnel..."
                create_tunnel "$location" "$iran_ipv4" "$foreign_ipv4"
                break
                ;;
            "Test Tunnel Connection")
                check_root
                test_tunnel
                break
                ;;
            "Remove IPv6 Tunnel")
                check_root
                remove_tunnel
                break
                ;;
            "Exit")
                exit 0
                ;;
            *) echo "Invalid option";;
        esac
    done
}

# Execute main menu
main_menu
