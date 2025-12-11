#!/usr/bin/env bash

set -euo pipefail

# Configuration
TOOL_NAME="cf-ip-failover"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${CONFIG_DIR}/state.json"
LOG_FILE="${CONFIG_DIR}/activity.log"
LAST_CNAME_FILE="${CONFIG_DIR}/last_cname.txt"

CF_API_BASE="https://api.cloudflare.com/client/v4"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Initialize variables
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Logging functions
log_msg() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}✗ ERROR:${NC} $1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✓ SUCCESS:${NC} $1"
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}→ INFO:${NC} $1"
}

# Utility functions
pause() {
    echo
    read -rp "Press Enter to continue..." _
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

# Prerequisites check
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=0
    
    # Check curl
    if ! command -v curl &>/dev/null; then
        log_error "curl is not installed"
        echo "Install curl with:"
        echo "  Ubuntu/Debian: sudo apt-get install curl"
        echo "  CentOS/RHEL: sudo yum install curl"
        missing=1
    else
        log_info "curl is installed"
    fi
    
    # Check jq
    if ! command -v jq &>/dev/null; then
        log_error "jq is not installed"
        echo "Install jq with:"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  CentOS/RHEL: sudo yum install jq"
        missing=1
    else
        log_info "jq is installed"
    fi
    
    if [ $missing -eq 1 ]; then
        log_error "Please install missing prerequisites first"
        exit 1
    fi
    
    log_success "All prerequisites are installed"
}

# Configuration management
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
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
EOF
    log_success "Configuration saved"
}

save_state() {
    cat > "$STATE_FILE" << EOF
{
  "primary_ip": "$1",
  "backup_ip": "$2",
  "cname": "$3",
  "primary_record": "$4",
  "backup_record": "$5",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "active_ip": "$1"
}
EOF
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

# API functions
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    local curl_cmd="curl -s -X $method '$url' -H 'Authorization: Bearer $CF_API_TOKEN' -H 'Content-Type: application/json'"
    
    if [ -n "$data" ]; then
        curl_cmd="$curl_cmd --data '$data'"
    fi
    
    eval "$curl_cmd" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"API request failed"}]}'
}

test_api_token() {
    log_info "Testing API token..."
    local response
    response=$(api_request "GET" "/user/tokens/verify")
    
    local success
    success=$(echo "$response" | jq -r '.success // false')
    
    if [ "$success" = "true" ]; then
        local email
        email=$(echo "$response" | jq -r '.result.email // "Unknown"')
        log_success "API token is valid (User: $email)"
        return 0
    else
        log_error "Invalid API token"
        return 1
    fi
}

test_zone() {
    log_info "Testing zone access..."
    local response
    response=$(api_request "GET" "/zones/$CF_ZONE_ID")
    
    local success
    success=$(echo "$response" | jq -r '.success // false')
    
    if [ "$success" = "true" ]; then
        local zone_name
        zone_name=$(echo "$response" | jq -r '.result.name // "Unknown"')
        log_success "Zone access confirmed: $zone_name"
        return 0
    else
        log_error "Invalid zone ID"
        return 1
    fi
}

# Configuration wizard
configure_api() {
    echo
    echo "================================================"
    echo "        CLOUDFLARE API CONFIGURATION"
    echo "================================================"
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
            log_error "API token cannot be empty"
            continue
        fi
        
        if test_api_token; then
            break
        fi
        
        echo
        log_error "Please check your API token and try again"
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
            log_error "Zone ID cannot be empty"
            continue
        fi
        
        if test_zone; then
            break
        fi
        
        echo
        log_error "Please check your Zone ID and try again"
    done
    
    echo
    echo "Step 3: Base Domain"
    echo "-------------------"
    echo "Enter your base domain (e.g., example.com)"
    echo "or subdomain (e.g., api.example.com)"
    echo
    
    while true; do
        read -rp "Enter base domain: " BASE_HOST
        if [ -z "$BASE_HOST" ]; then
            log_error "Domain cannot be empty"
        else
            break
        fi
    done
    
    save_config
    echo
    log_success "Configuration completed successfully!"
}

# IP validation
validate_ip() {
    local ip="$1"
    
    # Check format
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

# Generate random string
generate_random() {
    date +%s%N | md5sum | head -c 8
}

# DNS record management
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
  "ttl": 120,
  "proxied": false
}
EOF
)
    
    local response
    response=$(api_request "POST" "/zones/$CF_ZONE_ID/dns_records" "$data")
    
    local success
    success=$(echo "$response" | jq -r '.success // false')
    
    if [ "$success" = "true" ]; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id // ""')
        echo "$record_id"
        return 0
    else
        log_error "Failed to create $type record: $name"
        echo "$response" | jq -r '.errors[].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

delete_dns_record() {
    local record_id="$1"
    
    if [ -z "$record_id" ]; then
        return 0
    fi
    
    local response
    response=$(api_request "DELETE" "/zones/$CF_ZONE_ID/dns_records/$record_id")
    
    local success
    success=$(echo "$response" | jq -r '.success // false')
    
    if [ "$success" = "true" ]; then
        log_info "Deleted DNS record: $record_id"
        return 0
    else
        log_error "Failed to delete DNS record: $record_id"
        return 1
    fi
}

# Main setup function
setup_dual_ip() {
    echo
    echo "================================================"
    echo "          DUAL IP FAILOVER SETUP"
    echo "================================================"
    echo
    
    # Get IP addresses
    local primary_ip
    local backup_ip
    
    echo "Enter IP addresses:"
    echo "-------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server): " primary_ip
        if validate_ip "$primary_ip"; then
            break
        fi
        log_error "Invalid IP address format. Please enter a valid IPv4 address."
    done
    
    # Backup IP
    while true; do
        read -rp "Backup IP (failover server): " backup_ip
        if validate_ip "$backup_ip"; then
            if [ "$primary_ip" = "$backup_ip" ]; then
                log_error "Primary and Backup IPs cannot be the same!"
                read -rp "Continue anyway? (y/n): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            log_error "Invalid IP address format. Please enter a valid IPv4 address."
        fi
    done
    
    # Generate unique names
    local random_id
    random_id=$(generate_random)
    local cname_host="app-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log_info "Creating DNS records..."
    echo
    
    # Create primary A record
    log_info "Creating Primary A record..."
    log_info "  $primary_host → $primary_ip"
    local primary_record_id
    primary_record_id=$(create_dns_record "$primary_host" "A" "$primary_ip")
    if [ -z "$primary_record_id" ]; then
        log_error "Failed to create primary A record"
        return 1
    fi
    log_success "Primary A record created"
    
    # Create backup A record
    log_info "Creating Backup A record..."
    log_info "  $backup_host → $backup_ip"
    local backup_record_id
    backup_record_id=$(create_dns_record "$backup_host" "A" "$backup_ip")
    if [ -z "$backup_record_id" ]; then
        log_error "Failed to create backup A record"
        # Clean up primary record
        delete_dns_record "$primary_record_id"
        return 1
    fi
    log_success "Backup A record created"
    
    # Create CNAME record
    log_info "Creating CNAME record..."
    log_info "  $cname_host → $primary_host"
    local cname_record_id
    cname_record_id=$(create_dns_record "$cname_host" "CNAME" "$primary_host")
    if [ -z "$cname_record_id" ]; then
        log_error "Failed to create CNAME record"
        # Clean up A records
        delete_dns_record "$primary_record_id"
        delete_dns_record "$backup_record_id"
        return 1
    fi
    log_success "CNAME record created"
    
    # Save state
    save_state "$primary_ip" "$backup_ip" "$cname_host" "$primary_record_id" "$backup_record_id"
    
    # Save CNAME to file
    echo "$cname_host" > "$LAST_CNAME_FILE"
    
    echo
    echo "================================================"
    log_success "SETUP COMPLETED SUCCESSFULLY!"
    echo "================================================"
    echo
    echo "Your CNAME is:"
    echo -e "  ${GREEN}$cname_host${NC}"
    echo
    echo "DNS Configuration:"
    echo "  Primary: $primary_host → $primary_ip"
    echo "  Backup:  $backup_host → $backup_ip"
    echo "  CNAME:   $cname_host → $primary_host"
    echo
    echo "Current traffic is routed to: ${GREEN}PRIMARY IP ($primary_ip)${NC}"
    echo
    echo "To switch to backup IP:"
    echo "  1. Run this script"
    echo "  2. Choose 'Manual Failover'"
    echo "  3. Select 'Switch to Backup'"
    echo
    echo "DNS changes may take 1-2 minutes to propagate."
    echo
}

# Show current status
show_status() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log_error "No dual-IP setup found. Please run setup first."
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    echo
    echo "================================================"
    echo "           CURRENT STATUS"
    echo "================================================"
    echo
    echo -e "CNAME: ${GREEN}$cname${NC}"
    echo
    echo "IP Addresses:"
    if [ "$active_ip" = "$primary_ip" ]; then
        echo -e "  Primary: $primary_ip ${GREEN}[ACTIVE]${NC}"
        echo -e "  Backup:  $backup_ip"
    else
        echo -e "  Primary: $primary_ip"
        echo -e "  Backup:  $backup_ip ${GREEN}[ACTIVE]${NC}"
    fi
    echo
    
    # Test connectivity
    log_info "Testing connectivity..."
    echo
    
    # Test primary IP
    echo -e "Primary IP ($primary_ip):"
    if ping -c 2 -W 1 "$primary_ip" &>/dev/null; then
        echo -e "  ${GREEN}✓ Reachable${NC}"
    else
        echo -e "  ${RED}✗ Unreachable${NC}"
    fi
    
    # Test backup IP
    echo -e "Backup IP ($backup_ip):"
    if ping -c 2 -W 1 "$backup_ip" &>/dev/null; then
        echo -e "  ${GREEN}✓ Reachable${NC}"
    else
        echo -e "  ${RED}✗ Unreachable${NC}"
    fi
    
    echo
    echo "================================================"
}

# Manual failover control
manual_failover() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log_error "No setup found. Please run setup first."
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    # Extract random ID from cname
    local random_id
    random_id=$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//')
    
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    echo "================================================"
    echo "           MANUAL FAILOVER CONTROL"
    echo "================================================"
    echo
    echo "Current CNAME: $cname"
    echo
    echo "1. Switch to Primary IP ($primary_ip)"
    echo "2. Switch to Backup IP ($backup_ip)"
    echo "3. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log_info "Switching to Primary IP..."
            
            # Delete existing CNAME
            local cname_record_id
            cname_record_id=$(echo "$state" | jq -r '.cname_record // empty')
            if [ -n "$cname_record_id" ]; then
                delete_dns_record "$cname_record_id"
            fi
            
            # Create new CNAME pointing to primary
            local new_record_id
            new_record_id=$(create_dns_record "$cname" "CNAME" "$primary_host")
            
            if [ -n "$new_record_id" ]; then
                # Update state
                local new_state
                new_state=$(echo "$state" | jq --arg ip "$primary_ip" --arg id "$new_record_id" \
                    '.active_ip = $ip | .cname_record = $id')
                echo "$new_state" > "$STATE_FILE"
                
                log_success "Switched to Primary IP!"
                echo "CNAME $cname now points to $primary_host → $primary_ip"
            else
                log_error "Failed to switch to Primary IP"
            fi
            ;;
        2)
            log_info "Switching to Backup IP..."
            
            # Delete existing CNAME
            local cname_record_id
            cname_record_id=$(echo "$state" | jq -r '.cname_record // empty')
            if [ -n "$cname_record_id" ]; then
                delete_dns_record "$cname_record_id"
            fi
            
            # Create new CNAME pointing to backup
            local new_record_id
            new_record_id=$(create_dns_record "$cname" "CNAME" "$backup_host")
            
            if [ -n "$new_record_id" ]; then
                # Update state
                local new_state
                new_state=$(echo "$state" | jq --arg ip "$backup_ip" --arg id "$new_record_id" \
                    '.active_ip = $ip | .cname_record = $id')
                echo "$new_state" > "$STATE_FILE"
                
                log_success "Switched to Backup IP!"
                echo "CNAME $cname now points to $backup_host → $backup_ip"
            else
                log_error "Failed to switch to Backup IP"
            fi
            ;;
        3)
            return
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
}

# Show CNAME
show_cname() {
    if [ -f "$LAST_CNAME_FILE" ]; then
        local cname
        cname=$(cat "$LAST_CNAME_FILE")
        
        echo
        echo "================================================"
        echo "           YOUR CNAME"
        echo "================================================"
        echo
        echo -e "  ${GREEN}$cname${NC}"
        echo
        echo "Use this CNAME in your applications."
        echo
        echo "To change active IP:"
        echo "  Run this script → Manual Failover"
        echo
    else
        log_error "No CNAME found. Please run setup first."
    fi
}

# Cleanup function
cleanup() {
    echo
    log_error "WARNING: This will delete ALL created DNS records!"
    echo
    
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log_error "No setup found to cleanup"
        return 1
    fi
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log_info "Cleanup cancelled"
        return 0
    fi
    
    log_info "Deleting DNS records..."
    
    # Get record IDs from state
    local primary_record_id
    primary_record_id=$(echo "$state" | jq -r '.primary_record // empty')
    local backup_record_id
    backup_record_id=$(echo "$state" | jq -r '.backup_record // empty')
    local cname_record_id
    cname_record_id=$(echo "$state" | jq -r '.cname_record // empty')
    
    # Delete records
    if [ -n "$cname_record_id" ]; then
        delete_dns_record "$cname_record_id"
    fi
    
    if [ -n "$primary_record_id" ]; then
        delete_dns_record "$primary_record_id"
    fi
    
    if [ -n "$backup_record_id" ]; then
        delete_dns_record "$backup_record_id"
    fi
    
    # Delete state files
    rm -f "$STATE_FILE" "$LAST_CNAME_FILE"
    
    log_success "Cleanup completed!"
}

# Main menu
show_menu() {
    clear
    echo
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     CLOUDFLARE DUAL-IP FAILOVER MANAGER      ║"
    echo "╠═══════════════════════════════════════════════╣"
    echo "║                                               ║"
    echo -e "║  ${GREEN}1.${NC} Complete Setup (Create Dual-IP CNAME)     ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                      ║"
    echo -e "║  ${GREEN}3.${NC} Manual Failover Control                  ║"
    echo -e "║  ${GREEN}4.${NC} Show My CNAME                            ║"
    echo -e "║  ${GREEN}5.${NC} Cleanup (Delete All)                     ║"
    echo -e "║  ${GREEN}6.${NC} Configure API Settings                   ║"
    echo -e "║  ${GREEN}7.${NC} Exit                                     ║"
    echo "║                                               ║"
    echo "╠═══════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [ -n "$cname" ]; then
            echo -e "║  ${CYAN}Current: $cname${NC}"
            local active_ip
            active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
            echo -e "║  ${CYAN}Active IP: $active_ip${NC}"
        fi
    fi
    
    echo "╚═══════════════════════════════════════════════╝"
    echo
}

# Main function
main() {
    # Ensure directories exist
    ensure_dir
    
    # Check prerequisites
    check_prerequisites
    
    # Load config if exists
    if load_config; then
        log_info "Loaded existing configuration"
    else
        log_info "No configuration found. First-time setup required."
    fi
    
    # Main loop
    while true; do
        show_menu
        
        read -rp "Select option (1-7): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_dual_ip
                else
                    log_error "Please configure API settings first (option 6)"
                fi
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                if load_config; then
                    manual_failover
                else
                    log_error "Please configure API settings first (option 6)"
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
                log_info "Goodbye!"
                echo
                exit 0
                ;;
            *)
                log_error "Invalid option. Please select 1-7."
                sleep 1
                ;;
        esac
    done
}

# Run main function
main
