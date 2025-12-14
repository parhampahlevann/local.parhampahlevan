#!/bin/bash

# ================================================
# Cloudflare CNAME Manager with Full Menu System
# Complete CLI Dashboard for DNS Management
# ================================================

set -euo pipefail

# Configuration
CONFIG_DIR="/etc/cloudflare-manager"
API_TOKEN_FILE="$CONFIG_DIR/api_token.conf"
ZONE_CONFIG_FILE="$CONFIG_DIR/zone_config.conf"
DNS_CONFIG_FILE="$CONFIG_DIR/dns_config.conf"
LOG_FILE="/var/log/cloudflare-manager.log"
API_BASE="https://api.cloudflare.com/client/v4"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# ================================================
# INITIALIZATION
# ================================================

init_system() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     CLOUDFLARE CNAME MANAGER - COMPLETE DASHBOARD       ║"
    echo "║                 Interactive Menu System                 ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
    
    # Load existing config
    load_config
}

load_config() {
    if [[ -f "$API_TOKEN_FILE" ]]; then
        API_TOKEN=$(grep 'API_TOKEN=' "$API_TOKEN_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    
    if [[ -f "$ZONE_CONFIG_FILE" ]]; then
        ZONE_ID=$(grep 'ZONE_ID=' "$ZONE_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        DOMAIN=$(grep 'DOMAIN=' "$ZONE_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    
    if [[ -f "$DNS_CONFIG_FILE" ]]; then
        IP1=$(grep 'IP1=' "$DNS_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        IP2=$(grep 'IP2=' "$DNS_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        CNAME_ID=$(grep 'CNAME_ID=' "$DNS_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        A1_ID=$(grep 'A1_ID=' "$DNS_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        A2_ID=$(grep 'A2_ID=' "$DNS_CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
}

# ================================================
# DISPLAY FUNCTIONS
# ================================================

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                 MAIN MENU - CNAME MANAGER               ║"
    echo "╠══════════════════════════════════════════════════════════╣${NC}"
    
    # Configuration status
    echo -e "${WHITE}  📋 CURRENT CONFIGURATION${NC}"
    echo -e "  ──────────────────────────"
    
    if [[ -n "$API_TOKEN" ]]; then
        echo -e "  ${GREEN}✓${NC} API Token: ${GREEN}Configured${NC}"
    else
        echo -e "  ${RED}✗${NC} API Token: ${RED}Not Configured${NC}"
    fi
    
    if [[ -n "$DOMAIN" && -n "$ZONE_ID" ]]; then
        echo -e "  ${GREEN}✓${NC} Domain: ${GREEN}$DOMAIN${NC}"
    else
        echo -e "  ${RED}✗${NC} Domain: ${RED}Not Configured${NC}"
    fi
    
    if [[ -n "$IP1" && -n "$IP2" ]]; then
        echo -e "  ${GREEN}✓${NC} IPs: ${GREEN}$IP1${NC} / ${GREEN}$IP2${NC}"
    else
        echo -e "  ${RED}✗${NC} IPs: ${RED}Not Configured${NC}"
    fi
    
    echo -e "${CYAN}  ──────────────────────────${NC}"
    echo ""
    
    # Menu options
    echo -e "${WHITE}  📊 DNS MANAGEMENT${NC}"
    echo -e "${CYAN}  ──────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}) 🚀 Setup CNAME with Two IPs"
    echo -e "  ${GREEN}2${NC}) 🔄 Switch CNAME Target"
    echo -e "  ${GREEN}3${NC}) 📊 Check DNS Status"
    echo -e "  ${GREEN}4${NC}) 🛠️ Update DNS Records"
    
    echo ""
    echo -e "${WHITE}  ⚙️ CONFIGURATION${NC}"
    echo -e "${CYAN}  ──────────────────────────${NC}"
    echo -e "  ${GREEN}5${NC}) 🔑 Configure API Token"
    echo -e "  ${GREEN}6${NC}) 🌐 Configure Domain"
    echo -e "  ${GREEN}7${NC}) 📍 Configure IP Addresses"
    echo -e "  ${GREEN}8${NC}) 📄 View Current Configuration"
    
    echo ""
    echo -e "${WHITE}  🔧 ADVANCED${NC}"
    echo -e "${CYAN}  ──────────────────────────${NC}"
    echo -e "  ${GREEN}9${NC}) 🤖 Auto-Failover Monitor"
    echo -e "  ${GREEN}10${NC}) 📝 Test DNS Resolution"
    echo -e "  ${GREEN}11${NC}) 🧹 Reset Configuration"
    
    echo ""
    echo -e "${CYAN}  ──────────────────────────${NC}"
    echo -e "  ${RED}0${NC}) ❌ Exit"
    
    echo -e "${CYAN}"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Select an option [0-11]: ${NC}\c"
}

# ================================================
# MENU OPTION FUNCTIONS
# ================================================

option1_setup_cname() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                SETUP CNAME WITH TWO IPs                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check prerequisites
    if [[ -z "$API_TOKEN" ]]; then
        echo -e "${RED}❌ API Token not configured!${NC}"
        echo -e "Please configure API Token first (Option 5)."
        read -p "Press Enter to continue..."
        return
    fi
    
    if [[ -z "$DOMAIN" || -z "$ZONE_ID" ]]; then
        echo -e "${RED}❌ Domain not configured!${NC}"
        echo -e "Please configure domain first (Option 6)."
        read -p "Press Enter to continue..."
        return
    fi
    
    if [[ -z "$IP1" || -z "$IP2" ]]; then
        echo -e "${RED}❌ IP addresses not configured!${NC}"
        echo -e "Please configure IP addresses first (Option 7)."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "${GREEN}✓ All prerequisites met${NC}"
    echo ""
    
    # Verify API token
    echo -e "${YELLOW}🔐 Verifying API token...${NC}"
    if ! verify_api_token; then
        echo -e "${RED}❌ API token verification failed${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    # Setup DNS
    echo ""
    echo -e "${YELLOW}🚀 Setting up DNS records...${NC}"
    
    # Create A records
    A1_NAME="server1-app.$DOMAIN"
    A2_NAME="server2-app.$DOMAIN"
    CNAME_NAME="app.$DOMAIN"
    
    echo -e "${BLUE}Creating A record for $IP1...${NC}"
    A1_ID=$(create_dns_record "$A1_NAME" "$IP1" "A" "Server 1 - Primary")
    
    echo -e "${BLUE}Creating A record for $IP2...${NC}"
    A2_ID=$(create_dns_record "$A2_NAME" "$IP2" "A" "Server 2 - Secondary")
    
    echo -e "${BLUE}Creating CNAME record...${NC}"
    CNAME_ID=$(create_dns_record "$CNAME_NAME" "$A1_NAME" "CNAME" "CNAME for .app domain")
    
    # Save IDs
    echo "CNAME_ID=\"$CNAME_ID\"" >> "$DNS_CONFIG_FILE"
    echo "A1_ID=\"$A1_ID\"" >> "$DNS_CONFIG_FILE"
    echo "A2_ID=\"$A2_ID\"" >> "$DNS_CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}✅ CNAME setup completed successfully!${NC}"
    echo ""
    echo -e "${CYAN}📋 Summary:${NC}"
    echo -e "  CNAME: ${GREEN}$CNAME_NAME${NC}"
    echo -e "  Points to: ${GREEN}$A1_NAME ($IP1)${NC}"
    echo -e "  Backup: ${GREEN}$A2_NAME ($IP2)${NC}"
    echo ""
    echo -e "Access your site at: ${YELLOW}https://$CNAME_NAME${NC}"
    
    read -p "Press Enter to return to menu..."
}

option2_switch_cname() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                SWITCH CNAME TARGET                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if [[ -z "$CNAME_ID" ]]; then
        echo -e "${RED}❌ CNAME not configured!${NC}"
        echo -e "Please run setup first (Option 1)."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "${WHITE}Current CNAME target:${NC}"
    echo -e "${CYAN}──────────────────────${NC}"
    
    # Get current CNAME target
    CURRENT_TARGET=$(get_cname_target)
    
    if [[ "$CURRENT_TARGET" == *"server1-app"* ]]; then
        echo -e "  Currently pointing to: ${GREEN}Server 1 ($IP1)${NC}"
    elif [[ "$CURRENT_TARGET" == *"server2-app"* ]]; then
        echo -e "  Currently pointing to: ${GREEN}Server 2 ($IP2)${NC}"
    else
        echo -e "  Current target: ${YELLOW}$CURRENT_TARGET${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}Switch to:${NC}"
    echo -e "${CYAN}──────────${NC}"
    echo -e "  ${GREEN}1${NC}) Server 1 ($IP1)"
    echo -e "  ${GREEN}2${NC}) Server 2 ($IP2)"
    echo -e "  ${RED}0${NC}) Cancel"
    echo ""
    
    read -p "Select target [1-2, 0 to cancel]: " choice
    
    case $choice in
        1)
            echo -e "${YELLOW}Switching to Server 1...${NC}"
            switch_cname_target "server1-app.$DOMAIN"
            echo -e "${GREEN}✅ Now pointing to Server 1${NC}"
            ;;
        2)
            echo -e "${YELLOW}Switching to Server 2...${NC}"
            switch_cname_target "server2-app.$DOMAIN"
            echo -e "${GREEN}✅ Now pointing to Server 2${NC}"
            ;;
        0)
            echo -e "${YELLOW}Cancelled${NC}"
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

option3_check_status() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  DNS STATUS CHECK                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}🔍 Checking DNS records...${NC}"
    echo ""
    
    # Check CNAME
    if [[ -n "$CNAME_ID" ]]; then
        echo -e "${WHITE}CNAME Record:${NC}"
        echo -e "  Name: ${GREEN}app.$DOMAIN${NC}"
        CURRENT_TARGET=$(get_cname_target)
        echo -e "  Target: ${CYAN}$CURRENT_TARGET${NC}"
        
        if [[ "$CURRENT_TARGET" == *"server1-app"* ]]; then
            echo -e "  Status: ${GREEN}✓ Pointing to Server 1${NC}"
        elif [[ "$CURRENT_TARGET" == *"server2-app"* ]]; then
            echo -e "  Status: ${GREEN}✓ Pointing to Server 2${NC}"
        fi
    else
        echo -e "${RED}✗ CNAME not configured${NC}"
    fi
    
    echo ""
    
    # Check A records
    echo -e "${WHITE}A Records:${NC}"
    if [[ -n "$IP1" ]]; then
        echo -e "  ${GREEN}✓${NC} server1-app.$DOMAIN → $IP1"
    fi
    
    if [[ -n "$IP2" ]]; then
        echo -e "  ${GREEN}✓${NC} server2-app.$DOMAIN → $IP2"
    fi
    
    echo ""
    
    # Test DNS resolution
    echo -e "${YELLOW}🌐 Testing DNS resolution...${NC}"
    if command -v dig &> /dev/null; then
        RESULT=$(dig +short "app.$DOMAIN" CNAME 2>/dev/null)
        if [[ -n "$RESULT" ]]; then
            echo -e "  ${GREEN}✓${NC} DNS resolving: $RESULT"
        else
            echo -e "  ${YELLOW}⚠${NC} DNS not resolving yet (may need propagation)"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} dig command not available"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

option4_update_records() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  UPDATE DNS RECORDS                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Select record to update:${NC}"
    echo -e "${CYAN}─────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}) Update Server 1 IP (Currently: $IP1)"
    echo -e "  ${GREEN}2${NC}) Update Server 2 IP (Currently: $IP2)"
    echo -e "  ${GREEN}3${NC}) Update CNAME target"
    echo -e "  ${RED}0${NC}) Cancel"
    echo ""
    
    read -p "Select option [0-3]: " choice
    
    case $choice in
        1)
            update_server_ip 1
            ;;
        2)
            update_server_ip 2
            ;;
        3)
            option2_switch_cname
            ;;
        0)
            echo -e "${YELLOW}Cancelled${NC}"
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

option5_configure_token() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               CONFIGURE API TOKEN                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Enter Cloudflare API Token:${NC}"
    echo -e "${CYAN}(Token must have Zone.DNS Edit permissions)${NC}"
    echo ""
    
    read -p "API Token: " NEW_TOKEN
    
    if [[ -z "$NEW_TOKEN" ]]; then
        echo -e "${RED}❌ Token cannot be empty${NC}"
    else
        # Test token
        echo -e "${YELLOW}Testing token...${NC}"
        TEST_RESPONSE=$(curl -s -X GET "$API_BASE/user/tokens/verify" \
            -H "Authorization: Bearer $NEW_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null)
        
        if echo "$TEST_RESPONSE" | grep -q '"success":true'; then
            API_TOKEN="$NEW_TOKEN"
            echo "API_TOKEN=\"$API_TOKEN\"" > "$API_TOKEN_FILE"
            chmod 600 "$API_TOKEN_FILE"
            echo -e "${GREEN}✅ API token configured and verified${NC}"
        else
            echo -e "${RED}❌ Token verification failed${NC}"
        fi
    fi
    
    read -p "Press Enter to continue..."
}

option6_configure_domain() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               CONFIGURE DOMAIN                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    read -p "Enter domain (e.g., example.com): " NEW_DOMAIN
    
    if [[ -z "$NEW_DOMAIN" ]]; then
        echo -e "${RED}❌ Domain cannot be empty${NC}"
    else
        if [[ -z "$API_TOKEN" ]]; then
            echo -e "${YELLOW}⚠ API token not configured. Please configure token first.${NC}"
        else
            # Try to get Zone ID
            echo -e "${YELLOW}Looking up Zone ID...${NC}"
            ZONE_RESPONSE=$(curl -s -X GET "$API_BASE/zones?name=$NEW_DOMAIN" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json")
            
            if echo "$ZONE_RESPONSE" | grep -q '"success":true'; then
                NEW_ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
                
                if [[ -n "$NEW_ZONE_ID" ]]; then
                    DOMAIN="$NEW_DOMAIN"
                    ZONE_ID="$NEW_ZONE_ID"
                    
                    echo "ZONE_ID=\"$ZONE_ID\"" > "$ZONE_CONFIG_FILE"
                    echo "DOMAIN=\"$DOMAIN\"" >> "$ZONE_CONFIG_FILE"
                    chmod 600 "$ZONE_CONFIG_FILE"
                    
                    echo -e "${GREEN}✅ Domain configured: $DOMAIN${NC}"
                    echo -e "${GREEN}✅ Zone ID: $ZONE_ID${NC}"
                else
                    echo -e "${RED}❌ Could not find Zone ID for domain${NC}"
                    read -p "Enter Zone ID manually: " NEW_ZONE_ID
                    if [[ -n "$NEW_ZONE_ID" ]]; then
                        ZONE_ID="$NEW_ZONE_ID"
                        DOMAIN="$NEW_DOMAIN"
                        echo "ZONE_ID=\"$ZONE_ID\"" > "$ZONE_CONFIG_FILE"
                        echo "DOMAIN=\"$DOMAIN\"" >> "$ZONE_CONFIG_FILE"
                        echo -e "${GREEN}✅ Domain configured manually${NC}"
                    fi
                fi
            else
                echo -e "${RED}❌ Could not access Cloudflare API${NC}"
            fi
        fi
    fi
    
    read -p "Press Enter to continue..."
}

option7_configure_ips() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               CONFIGURE IP ADDRESSES                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Enter Server IP Addresses:${NC}"
    echo ""
    
    while true; do
        read -p "Server 1 IP address: " NEW_IP1
        if validate_ip "$NEW_IP1"; then
            break
        fi
        echo -e "${RED}❌ Invalid IP address${NC}"
    done
    
    while true; do
        read -p "Server 2 IP address: " NEW_IP2
        if validate_ip "$NEW_IP2" && [[ "$NEW_IP2" != "$NEW_IP1" ]]; then
            break
        fi
        echo -e "${RED}❌ Invalid IP or same as Server 1${NC}"
    done
    
    IP1="$NEW_IP1"
    IP2="$NEW_IP2"
    
    echo "IP1=\"$IP1\"" > "$DNS_CONFIG_FILE"
    echo "IP2=\"$IP2\"" >> "$DNS_CONFIG_FILE"
    chmod 600 "$DNS_CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}✅ IP addresses configured:${NC}"
    echo -e "  Server 1: ${GREEN}$IP1${NC}"
    echo -e "  Server 2: ${GREEN}$IP2${NC}"
    
    read -p "Press Enter to continue..."
}

option8_view_config() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               CURRENT CONFIGURATION                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${WHITE}Cloudflare API:${NC}"
    echo -e "${CYAN}────────────────${NC}"
    if [[ -n "$API_TOKEN" ]]; then
        echo -e "  Status: ${GREEN}Configured${NC}"
        echo -e "  Token: ${YELLOW}${API_TOKEN:0:10}...${API_TOKEN: -10}${NC}"
    else
        echo -e "  Status: ${RED}Not Configured${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}Domain Settings:${NC}"
    echo -e "${CYAN}────────────────${NC}"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  Domain: ${GREEN}$DOMAIN${NC}"
        echo -e "  Zone ID: ${YELLOW}$ZONE_ID${NC}"
    else
        echo -e "  Status: ${RED}Not Configured${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}Server IPs:${NC}"
    echo -e "${CYAN}──────────${NC}"
    if [[ -n "$IP1" ]]; then
        echo -e "  Server 1: ${GREEN}$IP1${NC}"
    else
        echo -e "  Server 1: ${RED}Not Configured${NC}"
    fi
    
    if [[ -n "$IP2" ]]; then
        echo -e "  Server 2: ${GREEN}$IP2${NC}"
    else
        echo -e "  Server 2: ${RED}Not Configured${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}DNS Records:${NC}"
    echo -e "${CYAN}────────────${NC}"
    if [[ -n "$CNAME_ID" ]]; then
        echo -e "  CNAME: ${GREEN}Configured${NC}"
        echo -e "    app.$DOMAIN → $(get_cname_target 2>/dev/null || echo "Unknown")"
    else
        echo -e "  CNAME: ${YELLOW}Not Created${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}Configuration Files:${NC}"
    echo -e "${CYAN}────────────────────${NC}"
    echo -e "  Config Directory: ${YELLOW}$CONFIG_DIR${NC}"
    echo -e "  Log File: ${YELLOW}$LOG_FILE${NC}"
    
    echo ""
    read -p "Press Enter to continue..."
}

option9_auto_failover() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               AUTO-FAILOVER MONITOR                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if [[ -z "$IP1" || -z "$IP2" || -z "$CNAME_ID" ]]; then
        echo -e "${RED}❌ Configuration incomplete!${NC}"
        echo -e "Please complete setup first."
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "${YELLOW}Auto-Failover Monitor Options:${NC}"
    echo -e "${CYAN}───────────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}) Start Monitor in Background"
    echo -e "  ${GREEN}2${NC}) Stop Monitor"
    echo -e "  ${GREEN}3${NC}) Monitor Status"
    echo -e "  ${GREEN}4${NC}) Test Failover Now"
    echo -e "  ${RED}0${NC}) Back to Menu"
    echo ""
    
    read -p "Select option [0-4]: " choice
    
    case $choice in
        1)
            start_monitor
            ;;
        2)
            stop_monitor
            ;;
        3)
            check_monitor_status
            ;;
        4)
            test_failover
            ;;
        0)
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

option10_test_dns() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               TEST DNS RESOLUTION                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ Domain not configured${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo -e "${YELLOW}Testing DNS resolution for app.$DOMAIN...${NC}"
    echo ""
    
    if command -v dig &> /dev/null; then
        echo -e "${WHITE}dig results:${NC}"
        dig "app.$DOMAIN" CNAME +short
        
        echo ""
        echo -e "${WHITE}nslookup results:${NC}"
        nslookup -type=CNAME "app.$DOMAIN" 2>/dev/null || echo "nslookup not available"
    else
        echo -e "${YELLOW}Installing dig...${NC}"
        apt-get update >/dev/null 2>&1 && apt-get install -y dnsutils >/dev/null 2>&1
        
        if command -v dig &> /dev/null; then
            echo -e "${GREEN}✓ dig installed${NC}"
            echo ""
            dig "app.$DOMAIN" CNAME +short
        else
            echo -e "${RED}Failed to install dig${NC}"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}Testing connectivity...${NC}"
    CURRENT_TARGET=$(get_cname_target 2>/dev/null)
    
    if [[ "$CURRENT_TARGET" == *"server1-app"* ]]; then
        TARGET_IP="$IP1"
    elif [[ "$CURRENT_TARGET" == *"server2-app"* ]]; then
        TARGET_IP="$IP2"
    else
        TARGET_IP="$CURRENT_TARGET"
    fi
    
    echo -e "Current target resolves to: ${CYAN}$CURRENT_TARGET${NC}"
    
    if ping -c 2 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "Ping test: ${GREEN}✓ Success${NC}"
    else
        echo -e "Ping test: ${RED}✗ Failed${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

option11_reset_config() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               RESET CONFIGURATION                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${RED}⚠ WARNING: This will delete all configuration files!${NC}"
    echo ""
    echo -e "Select what to reset:"
    echo -e "${CYAN}──────────────────${NC}"
    echo -e "  ${GREEN}1${NC}) Reset API Token only"
    echo -e "  ${GREEN}2${NC}) Reset Domain only"
    echo -e "  ${GREEN}3${NC}) Reset IPs only"
    echo -e "  ${GREEN}4${NC}) Reset All (Full Reset)"
    echo -e "  ${RED}0${NC}) Cancel"
    echo ""
    
    read -p "Select option [0-4]: " choice
    
    case $choice in
        1)
            rm -f "$API_TOKEN_FILE"
            API_TOKEN=""
            echo -e "${GREEN}✅ API Token reset${NC}"
            ;;
        2)
            rm -f "$ZONE_CONFIG_FILE"
            ZONE_ID=""
            DOMAIN=""
            echo -e "${GREEN}✅ Domain configuration reset${NC}"
            ;;
        3)
            rm -f "$DNS_CONFIG_FILE"
            IP1=""
            IP2=""
            CNAME_ID=""
            A1_ID=""
            A2_ID=""
            echo -e "${GREEN}✅ IP configuration reset${NC}"
            ;;
        4)
            rm -rf "$CONFIG_DIR"
            mkdir -p "$CONFIG_DIR"
            API_TOKEN=""
            ZONE_ID=""
            DOMAIN=""
            IP1=""
            IP2=""
            CNAME_ID=""
            A1_ID=""
            A2_ID=""
            echo -e "${GREEN}✅ All configuration reset${NC}"
            ;;
        0)
            echo -e "${YELLOW}Cancelled${NC}"
            ;;
        *)
            echo -e "${RED}❌ Invalid choice${NC}"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

# ================================================
# HELPER FUNCTIONS
# ================================================

validate_ip() {
    [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
}

verify_api_token() {
    TEST_RESPONSE=$(curl -s -X GET "$API_BASE/user/tokens/verify" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    echo "$TEST_RESPONSE" | grep -q '"success":true'
}

create_dns_record() {
    local name=$1
    local content=$2
    local type=$3
    local comment=$4
    
    RESPONSE=$(curl -s -X POST "$API_BASE/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"$type\",
            \"name\": \"$name\",
            \"content\": \"$content\",
            \"ttl\": 1,
            \"proxied\": false,
            \"comment\": \"$comment\"
        }" 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo "$RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
    else
        echo ""
    fi
}

get_cname_target() {
    curl -s -X GET "$API_BASE/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null | \
        grep -o '"content":"[^"]*' | cut -d'"' -f4
}

switch_cname_target() {
    local target=$1
    
    curl -s -X PUT "$API_BASE/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"CNAME\",
            \"name\": \"app.$DOMAIN\",
            \"content\": \"$target\",
            \"ttl\": 1,
            \"proxied\": false
        }" >/dev/null 2>&1
}

update_server_ip() {
    local server_num=$1
    
    if [[ $server_num -eq 1 ]]; then
        read -p "Enter new IP for Server 1: " NEW_IP
        if validate_ip "$NEW_IP"; then
            # Update DNS record
            curl -s -X PUT "$API_BASE/zones/$ZONE_ID/dns_records/$A1_ID" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                    \"type\": \"A\",
                    \"name\": \"server1-app.$DOMAIN\",
                    \"content\": \"$NEW_IP\",
                    \"ttl\": 1,
                    \"proxied\": false
                }" >/dev/null 2>&1
            
            # Update config
            sed -i "s/IP1=.*/IP1=\"$NEW_IP\"/" "$DNS_CONFIG_FILE"
            IP1="$NEW_IP"
            echo -e "${GREEN}✅ Server 1 IP updated to $NEW_IP${NC}"
        else
            echo -e "${RED}❌ Invalid IP address${NC}"
        fi
    elif [[ $server_num -eq 2 ]]; then
        read -p "Enter new IP for Server 2: " NEW_IP
        if validate_ip "$NEW_IP"; then
            # Update DNS record
            curl -s -X PUT "$API_BASE/zones/$ZONE_ID/dns_records/$A2_ID" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                    \"type\": \"A\",
                    \"name\": \"server2-app.$DOMAIN\",
                    \"content\": \"$NEW_IP\",
                    \"ttl\": 1,
                    \"proxied\": false
                }" >/dev/null 2>&1
            
            # Update config
            sed -i "s/IP2=.*/IP2=\"$NEW_IP\"/" "$DNS_CONFIG_FILE"
            IP2="$NEW_IP"
            echo -e "${GREEN}✅ Server 2 IP updated to $NEW_IP${NC}"
        else
            echo -e "${RED}❌ Invalid IP address${NC}"
        fi
    fi
}

start_monitor() {
    # Create monitor script
    cat > /usr/local/bin/cname-monitor.sh << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/cloudflare-manager"
DNS_CONFIG_FILE="$CONFIG_DIR/dns_config.conf"

source "$DNS_CONFIG_FILE"

while true; do
    # Check Server 1
    if ping -c 2 -W 1 "$IP1" >/dev/null 2>&1; then
        # Server 1 is up
        CURRENT_TARGET=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
            -H "Authorization: Bearer $API_TOKEN" | grep -o '"content":"[^"]*' | cut -d'"' -f4)
        
        if [[ "$CURRENT_TARGET" != "server1-app.$DOMAIN" ]]; then
            # Switch back to Server 1
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{\"content\":\"server1-app.$DOMAIN\",\"ttl\":1}" >/dev/null
            echo "$(date): Switched to Server 1" >> /var/log/cname-monitor.log
        fi
    else
        # Server 1 is down, check Server 2
        if ping -c 2 -W 1 "$IP2" >/dev/null 2>&1; then
            # Switch to Server 2
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{\"content\":\"server2-app.$DOMAIN\",\"ttl\":1}" >/dev/null
            echo "$(date): Server 1 down, switched to Server 2" >> /var/log/cname-monitor.log
        fi
    fi
    
    sleep 30
done
EOF

    chmod +x /usr/local/bin/cname-monitor.sh
    
    # Start in background
    nohup /usr/local/bin/cname-monitor.sh > /dev/null 2>&1 &
    MONITOR_PID=$!
    
    echo "MONITOR_PID=\"$MONITOR_PID\"" >> "$DNS_CONFIG_FILE"
    echo -e "${GREEN}✅ Auto-failover monitor started (PID: $MONITOR_PID)${NC}"
}

stop_monitor() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null
        sed -i '/MONITOR_PID=/d' "$DNS_CONFIG_FILE"
        echo -e "${GREEN}✅ Monitor stopped${NC}"
    else
        echo -e "${YELLOW}⚠ Monitor not running${NC}"
    fi
}

check_monitor_status() {
    if [[ -n "$MONITOR_PID" ]] && ps -p "$MONITOR_PID" > /dev/null; then
        echo -e "${GREEN}✅ Monitor is running (PID: $MONITOR_PID)${NC}"
    else
        echo -e "${YELLOW}⚠ Monitor is not running${NC}"
    fi
}

test_failover() {
    echo -e "${YELLOW}Testing failover...${NC}"
    
    # Get current target
    CURRENT_TARGET=$(get_cname_target)
    
    if [[ "$CURRENT_TARGET" == *"server1-app"* ]]; then
        echo -e "Current: Server 1"
        echo -e "Testing failover to Server 2..."
        switch_cname_target "server2-app.$DOMAIN"
        echo -e "${GREEN}✅ Switched to Server 2${NC}"
        
        read -p "Switch back to Server 1? [Y/n]: " switch_back
        if [[ "$switch_back" != "n" ]]; then
            switch_cname_target "server1-app.$DOMAIN"
            echo -e "${GREEN}✅ Switched back to Server 1${NC}"
        fi
    else
        echo -e "Current: Server 2"
        echo -e "Testing failover to Server 1..."
        switch_cname_target "server1-app.$DOMAIN"
        echo -e "${GREEN}✅ Switched to Server 1${NC}"
    fi
}

# ================================================
# MAIN LOOP
# ================================================

main() {
    # Initialize variables
    API_TOKEN=""
    ZONE_ID=""
    DOMAIN=""
    IP1=""
    IP2=""
    CNAME_ID=""
    A1_ID=""
    A2_ID=""
    MONITOR_PID=""
    
    init_system
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1) option1_setup_cname ;;
            2) option2_switch_cname ;;
            3) option3_check_status ;;
            4) option4_update_records ;;
            5) option5_configure_token ;;
            6) option6_configure_domain ;;
            7) option7_configure_ips ;;
            8) option8_view_config ;;
            9) option9_auto_failover ;;
            10) option10_test_dns ;;
            11) option11_reset_config ;;
            0)
                clear
                echo -e "${GREEN}Goodbye! 👋${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option! Press Enter to continue...${NC}"
                read
                ;;
        esac
    done
}

# Run the main function
main
