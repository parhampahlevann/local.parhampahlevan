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
        apt-get install -y iproute2 net-tools sed grep iputils-ping
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools sed grep iputils
    fi
}

# Configure firewall for IPv6 tunnel
function configure_firewall() {
    colored_msg blue "Configuring firewall for IPv6 tunnel..."
    
    # Allow protocol 41 (IPv6 over IPv4)
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p 41 -j ACCEPT
        iptables -I FORWARD -p 41 -j ACCEPT
    fi
    
    # Allow IPv6 ICMP (for ping6)
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I INPUT -p icmpv6 -j ACCEPT
        ip6tables -I FORWARD -p icmpv6 -j ACCEPT
    fi
    
    # For systems with firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-protocol=41
        firewall-cmd --permanent --add-protocol=ipv6-icmp
        firewall-cmd --reload
    fi
    
    # For systems with ufw
    if command -v ufw >/dev/null 2>&1; then
        ufw allow proto 41
        ufw allow ipv6
        ufw reload
    fi
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
    
    # Remove any existing tunnel
    ip link del ipv6tun 2>/dev/null
    
    # Create tunnel interface
    ip tunnel add ipv6tun mode sit remote $remote_ipv4 local $local_ipv4 ttl 255
    
    # Set MTU to 1480 (standard for IPv6 in IPv4 tunnel)
    ip link set ipv6tun mtu 1480 up
    
    # Assign IPv6 addresses with point-to-point configuration
    ip addr add $local_ipv6 dev ipv6tun
    
    # Add route for remote IPv6 through the tunnel
    ip -6 route add $remote_ipv6 dev ipv6tun
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 > /dev/null
    sysctl -w net.ipv6.conf.ipv6tun.forwarding=1 > /dev/null
    
    # Enable neighbor discovery
    sysctl -w net.ipv6.conf.all.accept_ra=2 > /dev/null
    sysctl -w net.ipv6.conf.default.accept_ra=2 > /dev/null
    
    # Configure firewall
    configure_firewall
    
    # Save config for uninstall
    echo "$location $iran_ipv4 $foreign_ipv4" > /etc/ipv6tun.conf
    
    colored_msg green "IPv6 tunnel created successfully!"
    echo ""
    colored_msg yellow "Tunnel Information:"
    echo "Local IPv6: $local_ipv6"
    echo "Remote IPv6: $remote_ipv6"
    echo ""
    colored_msg yellow "To test connection, run this command on the remote server:"
    colored_msg blue "ping6 $remote_ipv6"
    echo ""
    colored_msg yellow "To test from this server:"
    colored_msg blue "ping6 -I ipv6tun $remote_ipv6"
}

# Remove tunnel and revert changes
function remove_tunnel() {
    if [ -f /etc/ipv6tun.conf ]; then
        colored_msg blue "Removing IPv6 tunnel..."
        
        # Remove tunnel interface
        ip link del ipv6tun 2>/dev/null
        
        # Disable IPv6 forwarding
        sysctl -w net.ipv6.conf.all.forwarding=0 > /dev/null
        sysctl -w net.ipv6.conf.default.forwarding=0 > /dev/null
        
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
    options=("Create IPv6 Tunnel" "Remove IPv6 Tunnel" "Exit")
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
