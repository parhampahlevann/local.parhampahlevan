#!/bin/bash

# ----- Color Variables -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ----- Function: Print Header -----
print_header() {
    clear
    echo -e "${CYAN}"
    echo "==============================================="
    echo "         WARP-GO Installation Script"
    echo "    (Cloudflare WARP IPv4 Single Stack)"
    echo "==============================================="
    echo -e "${NC}"
}

# ----- Function: Check Root -----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root. Use 'sudo -i' or 'sudo su'.${NC}"
        exit 1
    fi
}

# ----- Function: Check OS & Install Dependencies -----
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}Could not detect OS. Exiting.${NC}"
        exit 1
    fi

    case $OS in
        debian|ubuntu)
            apt update -y
            apt install -y curl wget grep iproute2 sudo
            ;;
        centos|fedora|rhel)
            yum install -y curl wget grep iproute sudo
            ;;
        *)
            echo -e "${YELLOW}Unsupported OS. Trying to install common dependencies...${NC}"
            if command -v apt &> /dev/null; then
                apt update -y && apt install -y curl wget grep iproute2 sudo
            elif command -v yum &> /dev/null; then
                yum install -y curl wget grep iproute sudo
            else
                echo -e "${RED}Please manually install: curl, wget, grep, iproute2, sudo${NC}"
                exit 1
            fi
            ;;
    esac
}

# ----- Function: Install/Reinstall WARP-GO (IPv4 Single Stack) -----
install_warp_ipv4() {
    echo -e "${GREEN}>>> Installing/Reinstalling WARP-GO for IPv4 Single Stack...${NC}"
    echo -e "${YELLOW}This will configure a Cloudflare WARP IPv4 address.${NC}"
    echo

    # Download and run the official WARP-GO install script
    wget -N --no-check-certificate https://raw.githubusercontent.com/fscarmen/warp/main/warp-go.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to download warp-go.sh${NC}"
        exit 1
    fi

    chmod +x warp-go.sh
    # Key command: Option 1 for WARP-GO, then Option 1 for IPv4 Single Stack
    # We use 'echo -e' to simulate pressing '1' then Enter, then '1' then Enter.
    echo -e "1\n1\n" | ./warp-go.sh

    # Clean up
    rm -f warp-go.sh

    echo -e "${GREEN}>>> WARP-GO installation/switch completed.${NC}"
    echo -e "${YELLOW}To check your new IP, run:${NC} curl -4 ip.sb"
    echo
}

# ----- Function: Show WARP Status -----
show_status() {
    echo -e "${CYAN}>>> Current WARP Status:${NC}"
    if command -v warp-go &> /dev/null; then
        warp-go status
    else
        echo -e "${RED}WARP-GO is not installed.${NC}"
    fi
    echo
}

# ----- Function: Remove WARP-GO -----
remove_warp() {
    echo -e "${RED}>>> Removing WARP-GO...${NC}"
    if [[ -f /etc/warp-go/warp.conf ]]; then
        wget -N --no-check-certificate https://raw.githubusercontent.com/fscarmen/warp/main/warp-go.sh
        chmod +x warp-go.sh
        # Simulate choosing option 4 (remove) and confirming
        echo -e "4\n" | ./warp-go.sh
        rm -f warp-go.sh
    else
        echo -e "${YELLOW}WARP-GO does not seem to be installed.${NC}"
    fi
    echo
}

# ----- Main Menu -----
main_menu() {
    while true; do
        print_header
        echo -e "${BOLD}Select an option:${NC}"
        echo -e "  ${GREEN}1)${NC} Install / Switch to WARP-GO (IPv4 Single Stack)"
        echo -e "  ${BLUE}2)${NC} Show WARP Status"
        echo -e "  ${YELLOW}3)${NC} Remove / Uninstall WARP-GO"
        echo -e "  ${RED}4)${NC} Exit Script"
        echo
        read -p "Enter your choice [1-4]: " choice

        case $choice in
            1)
                install_warp_ipv4
                ;;
            2)
                show_status
                ;;
            3)
                remove_warp
                ;;
            4)
                echo -e "${CYAN}Exiting. Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please choose 1-4.${NC}"
                ;;
        esac

        echo -e "${PURPLE}Press Enter to return to the menu...${NC}"
        read -p ""
    done
}

# ----- Script Start -----
check_root
check_os
main_menu
