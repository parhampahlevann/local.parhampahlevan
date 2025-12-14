#!/bin/bash

# =============================================
# CLOUDFLARE SMART LOAD BALANCER v4.1
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-smart-lb"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
HEALTH_LOG="$CONFIG_DIR/health.log"
LOCK_FILE="/tmp/cf-lb.lock"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Smart Load Balancer Settings
PRIMARY_IP=""
BACKUP_IP=""
CNAME=""
DNS_TTL=60  # 1 minute TTL for fast propagation

# Health Check Settings - DISABLED
ENABLE_HEALTH_CHECKS=false  # Disabled as requested
HEALTH_CHECK_INTERVAL=30
HEALTH_CHECK_TIMEOUT=5
MAX_FAILURES=3
RECOVERY_THRESHOLD=5

# Protocol Settings
ENABLE_QUIC=false
ENABLE_HTTPS=true
PREFERRED_PORTS=(443 80 22)
CUSTOM_PORTS=()

# Performance Settings
ENABLE_PERFORMANCE_MONITOR=false  # Disabled as requested

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
NC='\033[0m'

# =============================================
# LOCK MANAGEMENT (Prevent Multiple Instances)
# =============================================

acquire_lock() {
    local max_retries=10
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
            trap 'release_lock' EXIT
            return 0
        fi
        
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
        fi
        
        sleep 1
        retry_count=$((retry_count + 1))
    done
    
    log "Could not acquire lock after $max_retries attempts" "ERROR"
    return 1
}

release_lock() {
    rm -f "$LOCK_FILE"
}

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
        "HEALTH")
            echo -e "${BLUE}[$timestamp] [HEALTH]${NC} $msg" >> "$HEALTH_LOG"
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
    touch "$HEALTH_LOG" 2>/dev/null || true
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
        
        # Load additional configs
        if [ -f "$STATE_FILE" ]; then
            PRIMARY_IP=$(jq -r '.primary_ip // empty' "$STATE_FILE")
            BACKUP_IP=$(jq -r '.backup_ip // empty' "$STATE_FILE")
            CNAME=$(jq -r '.cname // empty' "$STATE_FILE")
        fi
        
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
ENABLE_HEALTH_CHECKS="$ENABLE_HEALTH_CHECKS"
ENABLE_QUIC="$ENABLE_QUIC"
ENABLE_HTTPS="$ENABLE_HTTPS"
PREFERRED_PORTS=(${PREFERRED_PORTS[@]})
CUSTOM_PORTS=(${CUSTOM_PORTS[@]})
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local cname="$1"
    local primary_ip="$2"
    local backup_ip="$3"
    local primary_record_id="$4"
    local backup_record_id="$5"
    local cname_record_id="$6"
    
    cat > "$STATE_FILE" << EOF
{
  "cname": "$cname",
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "primary_record_id": "$primary_record_id",
  "backup_record_id": "$backup_record_id",
  "cname_record_id": "$cname_record_id",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "active_ip": "$primary_ip",
  "health_status": {
    "primary": "unknown",
    "backup": "unknown"
  },
  "total_failovers": 0,
  "last_failover": null,
  "health_checks_enabled": "$ENABLE_HEALTH_CHECKS"
}
EOF
}

update_state() {
    local key="$1"
    local value="$2"
    
    if [ -f "$STATE_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)
        jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$STATE_FILE" > "$temp_file"
        mv "$temp_file" "$STATE_FILE"
    fi
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
            --max-time 10 \
            --retry 2 \
            --retry-delay 1 \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"API Connection failed"}]}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            --retry 2 \
            --retry-delay 1 \
            2>/dev/null || echo '{"success":false,"errors":[{"message":"API Connection failed"}]}')
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
    local ttl="${4:-$DNS_TTL}"
    
    local data
    data=$(cat << EOF
{
  "type": "$type",
  "name": "$name",
  "content": "$content",
  "ttl": $ttl,
  "proxied": false
}
EOF
)
    
    local response
    response=$(api_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        log "Created $type record: $name → $content (ID: $record_id)" "DEBUG"
        echo "$record_id"
        return 0
    else
        log "Failed to create $type record: $name → $content" "ERROR"
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$response")
        log "API Error: $error_msg" "DEBUG"
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

update_cname_target() {
    local cname="$1"
    local target_host="$2"
    
    # Get existing CNAME record ID
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${cname}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result[0].id // empty')
        
        if [ -z "$record_id" ]; then
            log "CNAME record not found: $cname" "ERROR"
            return 1
        fi
        
        local data
        data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$cname",
  "content": "$target_host",
  "ttl": $DNS_TTL,
  "proxied": false
}
EOF
)
        
        local update_response
        update_response=$(api_request "PUT" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
        
        if echo "$update_response" | jq -e '.success == true' &>/dev/null; then
            log "Updated CNAME: $cname → $target_host" "SUCCESS"
            return 0
        else
            log "Failed to update CNAME" "ERROR"
            local error_msg
            error_msg=$(echo "$update_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$update_response")
            log "API Error: $error_msg" "DEBUG"
            return 1
        fi
    else
        log "Failed to fetch CNAME record: $cname" "ERROR"
        return 1
    fi
}

# =============================================
# SIMPLE LOAD BALANCER SETUP (NO HEALTH CHECKS)
# =============================================

setup_load_balancer() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          CLOUDFLARE LOAD BALANCER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    echo "This creates a simple load balancer with:"
    echo "  • Primary IP (default active)"
    echo "  • Backup IP (manual failover only)"
    echo "  • Fast DNS propagation (60s TTL)"
    echo "  • Manual control only"
    echo "  • NO automatic health checks"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses:"
    echo "-------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (default active server): " primary_ip
        if validate_ip "$primary_ip"; then
            break
        fi
        log "Invalid IPv4 address format" "ERROR"
    done
    
    # Backup IP
    while true; do
        read -rp "Backup IP (for manual failover): " backup_ip
        if validate_ip "$backup_ip"; then
            if [ "$primary_ip" = "$backup_ip" ]; then
                log "Warning: Primary and Backup IPs are the same!" "WARNING"
                read -rp "Continue anyway? (y/n): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            log "Invalid IPv4 address format" "ERROR"
        fi
    done
    
    # Generate unique names
    local random_id
    random_id=$(date +%s%N | md5sum | cut -c1-8)
    local cname="lb-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating Load Balancer..." "INFO"
    echo
    
    # Create Primary A record
    log "Creating Primary A record: $primary_host → $primary_ip" "INFO"
    local primary_record_id
    primary_record_id=$(create_dns_record "$primary_host" "A" "$primary_ip")
    if [ -z "$primary_record_id" ]; then
        log "Failed to create primary A record" "ERROR"
        return 1
    fi
    
    # Create Backup A record
    log "Creating Backup A record: $backup_host → $backup_ip" "INFO"
    local backup_record_id
    backup_record_id=$(create_dns_record "$backup_host" "A" "$backup_ip")
    if [ -z "$backup_record_id" ]; then
        log "Failed to create backup A record" "ERROR"
        delete_dns_record "$primary_record_id"
        return 1
    fi
    
    # Create CNAME record pointing to primary
    log "Creating CNAME: $cname → $primary_host" "INFO"
    local cname_record_id
    cname_record_id=$(create_dns_record "$cname" "CNAME" "$primary_host")
    if [ -z "$cname_record_id" ]; then
        log "Failed to create CNAME record" "ERROR"
        delete_dns_record "$primary_record_id"
        delete_dns_record "$backup_record_id"
        return 1
    fi
    
    # Save state
    save_state "$cname" "$primary_ip" "$backup_ip" "$primary_record_id" "$backup_record_id" "$cname_record_id"
    
    echo
    echo "════════════════════════════════════════════════"
    log "LOAD BALANCER CREATED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo "Your Load Balancer CNAME:"
    echo -e "  ${GREEN}$cname${NC}"
    echo
    echo "Configuration:"
    echo "  Primary: $primary_host → $primary_ip"
    echo "  Backup:  $backup_host → $backup_ip"
    echo "  CNAME:   $cname → $primary_host"
    echo
    echo "Important Notes:"
    echo "  • Automatic health checks are DISABLED"
    echo "  • Failover must be performed MANUALLY"
    echo "  • DNS TTL: ${DNS_TTL} seconds (fast propagation)"
    echo "  • Monitor your servers externally if needed"
    echo
    echo "Manual Control Options:"
    echo "  1. Use 'Manual Control' in this script"
    echo "  2. Switch between Primary/Backup IPs"
    echo "  3. No background monitoring service"
    echo
}

# =============================================
# MANUAL CONTROL (NO AUTO HEALTH CHECKS)
# =============================================

manual_control() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          MANUAL LOAD BALANCER CONTROL"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    local cname primary_ip backup_ip active_ip
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE")
    active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE")
    
    echo "Current Status:"
    echo "  CNAME: $cname"
    echo "  Active IP: $active_ip"
    echo "  Primary IP: $primary_ip"
    echo "  Backup IP: $backup_ip"
    echo
    echo "NOTE: Automatic health checks are DISABLED"
    echo "      You must monitor servers externally"
    echo
    
    echo "Manual Control Options:"
    echo "1. Switch to Primary IP"
    echo "2. Switch to Backup IP"
    echo "3. Quick health check (one-time)"
    echo "4. View detailed status"
    echo "5. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log "Switching to Primary IP ($primary_ip)..." "INFO"
            local primary_host
            primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$primary_host"; then
                update_state "active_ip" "$primary_ip"
                log "Switched to Primary IP ($primary_ip)" "SUCCESS"
            fi
            ;;
        2)
            log "Switching to Backup IP ($backup_ip)..." "INFO"
            local backup_host
            backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$backup_host"; then
                update_state "active_ip" "$backup_ip"
                log "Switched to Backup IP ($backup_ip)" "SUCCESS"
            fi
            ;;
        3)
            quick_health_check
            ;;
        4)
            show_detailed_status
            ;;
        5)
            return
            ;;
        *)
            log "Invalid option" "ERROR"
            ;;
    esac
}

quick_health_check() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          QUICK HEALTH CHECK (One-time)"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    local primary_ip backup_ip
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE")
    
    echo "This is a one-time manual check."
    echo "Results are NOT used for automatic failover."
    echo
    
    # Check Primary IP
    echo -n "Primary IP ($primary_ip): "
    if ping -c 1 -W 2 "$primary_ip" &>/dev/null; then
        echo -e "${GREEN}✓ REACHABLE${NC}"
        
        # Try HTTP/HTTPS
        if curl -s -f --max-time 5 "http://$primary_ip" &>/dev/null; then
            echo "  HTTP: ${GREEN}✓ OK${NC}"
        else
            echo "  HTTP: ${YELLOW}✗ Failed${NC}"
        fi
        
        if curl -s -f -k --max-time 5 "https://$primary_ip" &>/dev/null; then
            echo "  HTTPS: ${GREEN}✓ OK${NC}"
        else
            echo "  HTTPS: ${YELLOW}✗ Failed${NC}"
        fi
    else
        echo -e "${RED}✗ UNREACHABLE${NC}"
    fi
    
    echo
    
    # Check Backup IP
    echo -n "Backup IP ($backup_ip): "
    if ping -c 1 -W 2 "$backup_ip" &>/dev/null; then
        echo -e "${GREEN}✓ REACHABLE${NC}"
        
        # Try HTTP/HTTPS
        if curl -s -f --max-time 5 "http://$backup_ip" &>/dev/null; then
            echo "  HTTP: ${GREEN}✓ OK${NC}"
        else
            echo "  HTTP: ${YELLOW}✗ Failed${NC}"
        fi
        
        if curl -s -f -k --max-time 5 "https://$backup_ip" &>/dev/null; then
            echo "  HTTPS: ${GREEN}✓ OK${NC}"
        else
            echo "  HTTPS: ${YELLOW}✗ Failed${NC}"
        fi
    else
        echo -e "${RED}✗ UNREACHABLE${NC}"
    fi
    
    echo
    echo "Note: This check does not trigger any automatic actions."
    echo "      Use manual control to switch IPs if needed."
}

# =============================================
# SIMPLIFIED STATUS FUNCTIONS
# =============================================

show_detailed_status() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          LOAD BALANCER DETAILED STATUS"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    local cname primary_ip backup_ip active_ip created_at
    local total_failovers last_failover
    
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE")
    active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE")
    created_at=$(jq -r '.created_at // empty' "$STATE_FILE")
    total_failovers=$(jq -r '.total_failovers // 0' "$STATE_FILE")
    last_failover=$(jq -r '.last_failover // "Never"' "$STATE_FILE")
    
    echo -e "${GREEN}Load Balancer Configuration:${NC}"
    echo "  CNAME: $cname"
    echo "  Created: $created_at"
    echo
    
    echo -e "${CYAN}IP Status:${NC}"
    echo -n "  Primary: $primary_ip"
    if [ "$active_ip" = "$primary_ip" ]; then
        echo -e " ${GREEN}(ACTIVE)${NC}"
    else
        echo " (inactive)"
    fi
    
    echo -n "  Backup:  $backup_ip"
    if [ "$active_ip" = "$backup_ip" ]; then
        echo -e " ${GREEN}(ACTIVE)${NC}"
    else
        echo " (inactive)"
    fi
    echo
    
    echo -e "${YELLOW}Important Notice:${NC}"
    echo "  Automatic health checks: ${RED}DISABLED${NC}"
    echo "  Failover mode: ${YELLOW}MANUAL ONLY${NC}"
    echo "  DNS TTL: ${DNS_TTL} seconds"
    echo "  Total manual failovers: $total_failovers"
    echo "  Last failover: $last_failover"
    echo
    
    echo -e "${ORANGE}Actions Required:${NC}"
    echo "  1. Monitor your servers externally"
    echo "  2. Use 'Manual Control' to switch IPs"
    echo "  3. No background service is running"
    echo
    echo "════════════════════════════════════════════════"
}

show_cname() {
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE")
        
        if [ -n "$cname" ]; then
            echo
            echo "════════════════════════════════════════════════"
            echo "           YOUR LOAD BALANCER CNAME"
            echo "════════════════════════════════════════════════"
            echo
            echo -e "  ${GREEN}$cname${NC}"
            echo
            echo "Configuration:"
            echo "  • Primary IP: Default active server"
            echo "  • Backup IP: Manual failover only"
            echo "  • DNS TTL: ${DNS_TTL}s (fast propagation)"
            echo "  • Automatic health checks: ${RED}DISABLED${NC}"
            echo "  • Failover mode: ${YELLOW}MANUAL ONLY${NC}"
            echo
            echo "Important:"
            echo "  You must monitor your servers externally."
            echo "  Use the 'Manual Control' option to switch IPs."
            echo "  No background monitoring service is running."
            echo
        else
            log "No load balancer setup found" "ERROR"
        fi
    else
        log "No load balancer setup found" "ERROR"
    fi
}

# =============================================
# CLEANUP FUNCTION
# =============================================

cleanup() {
    echo
    log "WARNING: This will delete the load balancer configuration!" "WARNING"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found to cleanup" "ERROR"
        return 1
    fi
    
    local cname primary_ip backup_ip primary_record_id backup_record_id cname_record_id
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE")
    primary_record_id=$(jq -r '.primary_record_id // empty' "$STATE_FILE")
    backup_record_id=$(jq -r '.backup_record_id // empty' "$STATE_FILE")
    cname_record_id=$(jq -r '.cname_record_id // empty' "$STATE_FILE")
    
    if [ -z "$cname" ]; then
        log "No active load balancer found" "ERROR"
        return 1
    fi
    
    echo "Load Balancer to delete:"
    echo "  CNAME: $cname"
    echo "  Primary IP: $primary_ip"
    echo "  Backup IP: $backup_ip"
    echo
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    log "Deleting load balancer DNS records..." "INFO"
    
    # Delete DNS records
    delete_dns_record "$cname_record_id"
    delete_dns_record "$primary_record_id"
    delete_dns_record "$backup_record_id"
    
    # Delete state files
    rm -f "$STATE_FILE" "$LOCK_FILE"
    
    log "Load balancer cleanup completed!" "SUCCESS"
}

# =============================================
# SIMPLIFIED MAIN MENU (NO MONITORING OPTIONS)
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE LOAD BALANCER v4.1             ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Create Load Balancer                    ║"
    echo -e "║  ${GREEN}2.${NC} Show Detailed Status                    ║"
    echo -e "║  ${GREEN}3.${NC} Manual Control                          ║"
    echo -e "║  ${GREEN}4.${NC} Show My CNAME                           ║"
    echo -e "║  ${GREEN}5.${NC} Cleanup (Delete All)                    ║"
    echo -e "║  ${GREEN}6.${NC} Configure API Settings                  ║"
    echo -e "║  ${GREEN}7.${NC} Exit                                    ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname active_ip primary_ip
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
        primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$cname" ]; then
            echo -e "║  ${CYAN}LB: $cname${NC}"
            echo -n "║  ${CYAN}Active: $active_ip"
            
            if [ "$active_ip" = "$primary_ip" ]; then
                echo -e " ${GREEN}(PRIMARY)${NC}"
            else
                echo -e " ${YELLOW}(BACKUP)${NC}"
            fi
            
            echo -e "║  ${RED}Auto-health: DISABLED${NC}"
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
    
    # Display warning about disabled health checks
    if [ -f "$STATE_FILE" ]; then
        local health_enabled
        health_enabled=$(jq -r '.health_checks_enabled // "false"' "$STATE_FILE")
        if [ "$health_enabled" = "false" ]; then
            echo
            echo -e "${YELLOW}⚠  WARNING: Automatic health checks are DISABLED${NC}"
            echo -e "${YELLOW}   Failover must be performed MANUALLY${NC}"
            echo
        fi
    fi
    
    # Main loop
    while true; do
        show_menu
        
        read -rp "Select option (1-7): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_load_balancer
                else
                    log "Please configure API settings first (option 6)" "ERROR"
                fi
                pause
                ;;
            2)
                show_detailed_status
                pause
                ;;
            3)
                if load_config; then
                    manual_control
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
