#!/bin/bash

# =============================================
# CLOUDFLARE DNS MANAGER v3.0 - STABLE EDITION
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-dns-manager"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Stable DNS Settings - No auto-failover
DNS_TTL=300  # 5 minutes TTL for stable DNS

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================
# LOGGING FUNCTIONS
# =============================================

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "ERROR")
            echo -e "${RED}[$timestamp] [ERROR]${NC} $msg"
            echo "[$timestamp] [ERROR] $msg" >> "$LOG_FILE"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] [SUCCESS]${NC} $msg"
            echo "[$timestamp] [SUCCESS] $msg" >> "$LOG_FILE"
            ;;
        "WARNING")
            echo -e "${YELLOW}[$timestamp] [WARNING]${NC} $msg"
            echo "[$timestamp] [WARNING] $msg" >> "$LOG_FILE"
            ;;
        "INFO")
            echo -e "${CYAN}[$timestamp] [INFO]${NC} $msg"
            echo "[$timestamp] [INFO] $msg" >> "$LOG_FILE"
            ;;
        *)
            echo "[$timestamp] [$level] $msg"
            echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
            ;;
    esac
}

# =============================================
# UTILITY FUNCTIONS
# =============================================

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

check_prerequisites() {
    log "Checking prerequisites..." "INFO"
    
    local missing=0
    
    # Check curl
    if ! command -v curl &>/dev/null; then
        log "curl is not installed" "ERROR"
        echo "Install with: sudo apt-get install curl"
        missing=1
    fi
    
    # Check jq
    if ! command -v jq &>/dev/null; then
        log "jq is not installed" "ERROR"
        echo "Install with: sudo apt-get install jq"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        log "Please install missing prerequisites first" "ERROR"
        exit 1
    fi
    
    log "All prerequisites are installed" "SUCCESS"
}

# =============================================
# CONFIGURATION MANAGEMENT
# =============================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" 2>/dev/null || true
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_HOST="$BASE_HOST"
DNS_TTL="$DNS_TTL"
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local cname="$1"
    local ip="$2"
    local record_id="$3"
    
    cat > "$STATE_FILE" << EOF
{
  "cname": "$cname",
  "ip": "$ip",
  "record_id": "$record_id",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "type": "CNAME"
}
EOF
}

# =============================================
# API FUNCTIONS
# =============================================

api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    local response
    
    if [ -n "$data" ]; then
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    fi
    
    echo "$response"
}

test_api() {
    log "Testing API token..." "INFO"
    local response
    response=$(api_request "GET" "/user/tokens/verify")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local email
        email=$(echo "$response" | jq -r '.result.email // "Unknown"')
        log "API token is valid (User: $email)" "SUCCESS"
        return 0
    else
        log "Invalid API token" "ERROR"
        return 1
    fi
}

test_zone() {
    log "Testing zone access..." "INFO"
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local zone_name
        zone_name=$(echo "$response" | jq -r '.result.name // "Unknown"')
        log "Zone access confirmed: $zone_name" "SUCCESS"
        return 0
    else
        log "Invalid zone ID" "ERROR"
        return 1
    fi
}

# =============================================
# CONFIGURATION WIZARD
# =============================================

configure_api() {
    echo
    echo "════════════════════════════════════════════════"
    echo "        CLOUDFLARE API CONFIGURATION"
    echo "════════════════════════════════════════════════"
    echo
    
    echo "Step 1: API Token"
    echo "-----------------"
    echo "Get your API token from:"
    echo "https://dash.cloudflare.com/profile/api-tokens"
    echo "Required permission: Zone.DNS (Edit)"
    echo
    
    while true; do
        read -rp "Enter API Token: " CF_API_TOKEN
        if [ -z "$CF_API_TOKEN" ]; then
            log "API token cannot be empty" "ERROR"
            continue
        fi
        
        if test_api; then
            break
        fi
        
        echo
        log "Please check your API token and try again" "WARNING"
    done
    
    echo
    echo "Step 2: Zone ID"
    echo "---------------"
    echo "Get your Zone ID from Cloudflare Dashboard:"
    echo "Your Site → Overview → API Section"
    echo
    
    while true; do
        read -rp "Enter Zone ID: " CF_ZONE_ID
        if [ -z "$CF_ZONE_ID" ]; then
            log "Zone ID cannot be empty" "ERROR"
            continue
        fi
        
        if test_zone; then
            break
        fi
        
        echo
        log "Please check your Zone ID and try again" "WARNING"
    done
    
    echo
    echo "Step 3: Base Domain"
    echo "-------------------"
    echo "Enter your base domain"
    echo "Example: example.com or api.example.com"
    echo
    
    while true; do
        read -rp "Enter base domain: " BASE_HOST
        if [ -z "$BASE_HOST" ]; then
            log "Domain cannot be empty" "ERROR"
        else
            break
        fi
    done
    
    save_config
    echo
    log "Configuration completed successfully!" "SUCCESS"
}

# =============================================
# IP VALIDATION
# =============================================

validate_ip() {
    local ip="$1"
    
    # Basic format check
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    # Check each octet
    local IFS="."
    read -r o1 o2 o3 o4 <<< "$ip"
    
    if [ "$o1" -gt 255 ] || [ "$o1" -lt 0 ] ||
       [ "$o2" -gt 255 ] || [ "$o2" -lt 0 ] ||
       [ "$o3" -gt 255 ] || [ "$o3" -lt 0 ] ||
       [ "$o4" -gt 255 ] || [ "$o4" -lt 0 ]; then
        return 1
    fi
    
    return 0
}

# =============================================
# DNS MANAGEMENT
# =============================================

create_dns_record() {
    local name="$1"
    local type="$2"
    local content="$3"
    
    local data
    data=$(cat << EOF
{
  "type": "$type",
  "name": "$name",
  "content": "$content",
  "ttl": $DNS_TTL,
  "proxied": false
}
EOF
)
    
    local response
    response=$(api_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result.id'
        return 0
    else
        log "Failed to create $type record: $name" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

delete_dns_record() {
    local record_id="$1"
    
    if [ -z "$record_id" ]; then
        return 0
    fi
    
    local response
    response=$(api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$record_id")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Deleted DNS record: $record_id" "INFO"
        return 0
    else
        log "Failed to delete DNS record: $record_id" "ERROR"
        return 1
    fi
}

get_cname_record_id() {
    local cname="$1"
    
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${cname}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result[0].id // empty'
    else
        echo ""
    fi
}

update_cname_target() {
    local cname="$1"
    local target="$2"
    
    # Get existing CNAME record ID
    local record_id
    record_id=$(get_cname_record_id "$cname")
    
    if [ -z "$record_id" ]; then
        log "CNAME record not found: $cname" "ERROR"
        return 1
    fi
    
    local data
    data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$cname",
  "content": "$target",
  "ttl": $DNS_TTL,
  "proxied": false
}
EOF
)
    
    local response
    response=$(api_request "PUT" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Updated CNAME: $cname → $target" "SUCCESS"
        return 0
    else
        log "Failed to update CNAME" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

# =============================================
# SIMPLE CNAME SETUP (NO AUTO-FAILOVER)
# =============================================

setup_simple_cname() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          SIMPLE CNAME SETUP"
    echo "════════════════════════════════════════════════"
    echo
    
    echo "Choose setup type:"
    echo "1. CNAME to existing hostname (recommended)"
    echo "2. CNAME to IP address (A record)"
    echo
    
    read -rp "Select option: " setup_type
    
    case $setup_type in
        1)
            setup_cname_to_hostname
            ;;
        2)
            setup_cname_to_ip
            ;;
        *)
            log "Invalid option" "ERROR"
            return 1
            ;;
    esac
}

setup_cname_to_hostname() {
    local cname_target
    
    echo
    echo "Enter target hostname (where CNAME should point to):"
    echo "Example: server1.example.com or app.server.com"
    echo
    
    while true; do
        read -rp "Target hostname: " cname_target
        if [ -z "$cname_target" ]; then
            log "Target hostname cannot be empty" "ERROR"
        else
            break
        fi
    done
    
    echo
    echo "Enter CNAME prefix (optional):"
    echo "Leave empty for random prefix"
    echo
    
    local cname_prefix
    read -rp "CNAME prefix: " cname_prefix
    
    if [ -z "$cname_prefix" ]; then
        local random_id
        random_id=$(date +%s%N | md5sum | cut -c1-8)
        cname_prefix="app-${random_id}"
    fi
    
    local cname="${cname_prefix}.${BASE_HOST}"
    
    echo
    log "Creating CNAME: $cname → $cname_target" "INFO"
    
    local record_id
    record_id=$(create_dns_record "$cname" "CNAME" "$cname_target")
    
    if [ -n "$record_id" ]; then
        save_state "$cname" "$cname_target" "$record_id"
        
        echo
        echo "════════════════════════════════════════════════"
        log "SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
        echo "════════════════════════════════════════════════"
        echo
        echo "Your CNAME is:"
        echo -e "  ${GREEN}$cname${NC}"
        echo
        echo "DNS Configuration:"
        echo "  CNAME: $cname → $cname_target"
        echo "  TTL: $DNS_TTL seconds"
        echo
        echo "DNS propagation may take a few minutes."
        echo
    fi
}

setup_cname_to_ip() {
    local ip_address
    
    echo
    echo "Enter IP address for A record:"
    
    while true; do
        read -rp "IP Address: " ip_address
        if validate_ip "$ip_address"; then
            break
        fi
        log "Invalid IPv4 address format" "ERROR"
    done
    
    echo
    echo "Enter CNAME prefix (optional):"
    echo "Leave empty for random prefix"
    echo
    
    local cname_prefix
    read -rp "CNAME prefix: " cname_prefix
    
    if [ -z "$cname_prefix" ]; then
        local random_id
        random_id=$(date +%s%N | md5sum | cut -c1-8)
        cname_prefix="app-${random_id}"
    fi
    
    local cname="${cname_prefix}.${BASE_HOST}"
    
    echo
    log "Creating CNAME: $cname → $ip_address" "INFO"
    
    local record_id
    record_id=$(create_dns_record "$cname" "A" "$ip_address")
    
    if [ -n "$record_id" ]; then
        save_state "$cname" "$ip_address" "$record_id"
        
        echo
        echo "════════════════════════════════════════════════"
        log "SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
        echo "════════════════════════════════════════════════"
        echo
        echo "Your DNS record is:"
        echo -e "  ${GREEN}$cname${NC} → $ip_address (A record)"
        echo
        echo "DNS Configuration:"
        echo "  Type: A record"
        echo "  TTL: $DNS_TTL seconds"
        echo
        echo "DNS propagation may take a few minutes."
        echo
    fi
}

# =============================================
# MANUAL DNS MANAGEMENT
# =============================================

manual_dns_update() {
    echo
    echo "════════════════════════════════════════════════"
    echo "           MANUAL DNS UPDATE"
    echo "════════════════════════════════════════════════"
    echo
    
    echo "This feature allows you to manually update DNS records."
    echo "Useful for maintenance or planned changes."
    echo
    
    echo "1. Update CNAME target"
    echo "2. Create new DNS record"
    echo "3. Delete DNS record"
    echo "4. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            update_cname_manual
            ;;
        2)
            create_record_manual
            ;;
        3)
            delete_record_manual
            ;;
        4)
            return
            ;;
        *)
            log "Invalid option" "ERROR"
            ;;
    esac
}

update_cname_manual() {
    echo
    read -rp "Enter CNAME to update (e.g., app.example.com): " cname
    read -rp "Enter new target (e.g., new-server.example.com): " target
    
    if [ -z "$cname" ] || [ -z "$target" ]; then
        log "CNAME and target cannot be empty" "ERROR"
        return
    fi
    
    log "Updating CNAME: $cname → $target" "INFO"
    
    if update_cname_target "$cname" "$target"; then
        log "CNAME updated successfully" "SUCCESS"
    fi
}

create_record_manual() {
    echo
    echo "Select record type:"
    echo "1. A record"
    echo "2. CNAME record"
    echo "3. MX record"
    echo "4. TXT record"
    echo
    
    read -rp "Select type: " record_type_choice
    
    case $record_type_choice in
        1) record_type="A" ;;
        2) record_type="CNAME" ;;
        3) record_type="MX" ;;
        4) record_type="TXT" ;;
        *) log "Invalid type" "ERROR"; return ;;
    esac
    
    read -rp "Enter record name (e.g., subdomain.example.com): " name
    read -rp "Enter record content: " content
    
    if [ -z "$name" ] || [ -z "$content" ]; then
        log "Name and content cannot be empty" "ERROR"
        return
    fi
    
    log "Creating $record_type record: $name → $content" "INFO"
    
    local record_id
    record_id=$(create_dns_record "$name" "$record_type" "$content")
    
    if [ -n "$record_id" ]; then
        log "Record created successfully" "SUCCESS"
    fi
}

delete_record_manual() {
    echo
    echo "WARNING: This will permanently delete a DNS record!"
    echo
    
    read -rp "Enter record name to delete (e.g., subdomain.example.com): " name
    
    if [ -z "$name" ]; then
        log "Record name cannot be empty" "ERROR"
        return
    fi
    
    # Get record ID
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?name=${name}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result[0].id // empty')
        
        if [ -z "$record_id" ]; then
            log "Record not found: $name" "ERROR"
            return
        fi
        
        read -rp "Are you sure you want to delete $name? (type 'DELETE' to confirm): " confirm
        
        if [ "$confirm" = "DELETE" ]; then
            if delete_dns_record "$record_id"; then
                log "Record deleted successfully" "SUCCESS"
            fi
        else
            log "Deletion cancelled" "INFO"
        fi
    else
        log "Failed to find record" "ERROR"
    fi
}

# =============================================
# STATUS AND INFO FUNCTIONS
# =============================================

show_status() {
    echo
    echo "════════════════════════════════════════════════"
    echo "           CURRENT STATUS"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ -f "$STATE_FILE" ]; then
        local cname ip record_id created_at
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        ip=$(jq -r '.ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
        record_id=$(jq -r '.record_id // empty' "$STATE_FILE" 2>/dev/null || echo "")
        created_at=$(jq -r '.created_at // empty' "$STATE_FILE" 2>/dev/null || echo "")
        type=$(jq -r '.type // "CNAME"' "$STATE_FILE" 2>/dev/null || echo "CNAME")
        
        if [ -n "$cname" ]; then
            echo -e "${GREEN}Active DNS Record:${NC}"
            echo "  Name: $cname"
            echo "  Type: $type"
            echo "  Target: $ip"
            echo "  Created: $created_at"
            echo "  Record ID: $record_id"
            echo
        fi
    else
        echo -e "${YELLOW}No active DNS record found${NC}"
        echo
    fi
    
    # Test API connectivity
    echo -e "${CYAN}API Status:${NC}"
    if test_api; then
        echo -e "  Connection: ${GREEN}✓ OK${NC}"
    else
        echo -e "  Connection: ${RED}✗ FAILED${NC}"
    fi
    
    # Test Zone access
    if test_zone; then
        echo -e "  Zone Access: ${GREEN}✓ OK${NC}"
    else
        echo -e "  Zone Access: ${RED}✗ FAILED${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

show_cname() {
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$cname" ]; then
            echo
            echo "════════════════════════════════════════════════"
            echo "           YOUR DNS RECORD"
            echo "════════════════════════════════════════════════"
            echo
            echo -e "  ${GREEN}$cname${NC}"
            echo
            echo "Use this record in your applications."
            echo "DNS propagation may take a few minutes."
            echo
        else
            log "No DNS record found. Please run setup first." "ERROR"
        fi
    else
        log "No DNS record found. Please run setup first." "ERROR"
    fi
}

# =============================================
# CLEANUP FUNCTION
# =============================================

cleanup() {
    echo
    log "WARNING: This will delete the active DNS record!" "WARNING"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No active record found to cleanup" "ERROR"
        return 1
    fi
    
    local cname record_id
    cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
    record_id=$(jq -r '.record_id // empty' "$STATE_FILE" 2>/dev/null || echo "")
    
    if [ -z "$cname" ]; then
        log "No active record found" "ERROR"
        return 1
    fi
    
    echo "Record to delete:"
    echo "  CNAME: $cname"
    echo "  Record ID: $record_id"
    echo
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    log "Deleting DNS record..." "INFO"
    
    if [ -n "$record_id" ]; then
        delete_dns_record "$record_id"
    fi
    
    # Delete state file
    rm -f "$STATE_FILE"
    
    log "Cleanup completed!" "SUCCESS"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE DNS MANAGER v3.0 - STABLE      ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Create Simple DNS Record                 ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                      ║"
    echo -e "║  ${GREEN}3.${NC} Manual DNS Update                        ║"
    echo -e "║  ${GREEN}4.${NC} Show My DNS Record                       ║"
    echo -e "║  ${GREEN}5.${NC} Cleanup (Delete Record)                  ║"
    echo -e "║  ${GREEN}6.${NC} Configure API Settings                   ║"
    echo -e "║  ${GREEN}7.${NC} Exit                                     ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [ -n "$cname" ]; then
            local ip
            ip=$(jq -r '.ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
            echo -e "║  ${CYAN}Active: $cname → $ip${NC}"
        fi
    fi
    
    echo "╚════════════════════════════════════════════════╝"
    echo
}

# =============================================
# MAIN FUNCTION
# =============================================

main() {
    # Ensure directories exist
    ensure_dir
    
    # Check prerequisites
    check_prerequisites
    
    # Load config if exists
    if load_config; then
        log "Loaded existing configuration" "INFO"
    else
        log "No configuration found" "INFO"
    fi
    
    # Main loop
    while true; do
        show_menu
        
        read -rp "Select option (1-7): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_simple_cname
                else
                    log "Please configure API settings first (option 6)" "ERROR"
                fi
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                if load_config; then
                    manual_dns_update
                else
                    log "Please configure API settings first (option 6)" "ERROR"
                fi
                pause
                ;;
            4)
                show_cname
                pause
                ;;
            5)
                cleanup
                pause
                ;;
            6)
                configure_api
                ;;
            7)
                echo
                log "Goodbye!" "INFO"
                echo
                exit 0
                ;;
            *)
                log "Invalid option. Please select 1-7." "ERROR"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main
