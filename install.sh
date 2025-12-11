#!/bin/bash

# =============================================
# CLOUDFLARE AUTO-FAILOVER MANAGER v3.0
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-auto-failover"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
MONITOR_PID_FILE="$CONFIG_DIR/monitor.pid"
LAST_CNAME_FILE="$CONFIG_DIR/last_cname.txt"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Monitor Settings
CHECK_INTERVAL=5        # Check every 5 seconds
FAILURE_THRESHOLD=2     # 2 failures = 10 seconds total
RECOVERY_THRESHOLD=3    # 3 successful checks = 15 seconds

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
    
    # Check ping
    if ! command -v ping &>/dev/null; then
        log "ping is not installed" "WARNING"
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
CHECK_INTERVAL="$CHECK_INTERVAL"
FAILURE_THRESHOLD="$FAILURE_THRESHOLD"
RECOVERY_THRESHOLD="$RECOVERY_THRESHOLD"
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local primary_ip="$1"
    local backup_ip="$2"
    local cname="$3"
    local primary_record="$4"
    local backup_record="$5"
    
    cat > "$STATE_FILE" << EOF
{
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "cname": "$cname",
  "primary_record": "$primary_record",
  "backup_record": "$backup_record",
  "primary_host": "primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').$BASE_HOST",
  "backup_host": "backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').$BASE_HOST",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "active_ip": "$primary_ip",
  "monitoring": true,
  "failure_count": 0,
  "recovery_count": 0
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
  "ttl": 60,
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
    local target_host="$2"
    
    # Get existing CNAME record ID
    local record_id
    record_id=$(get_cname_record_id "$cname")
    
    if [ -z "$record_id" ]; then
        log "CNAME record not found: $cname" "ERROR"
        return 1
    fi
    
    # Delete old record
    delete_dns_record "$record_id"
    
    # Create new record with new target
    local new_record_id
    new_record_id=$(create_dns_record "$cname" "CNAME" "$target_host")
    
    if [ -n "$new_record_id" ]; then
        log "Updated CNAME: $cname → $target_host" "SUCCESS"
        return 0
    else
        log "Failed to update CNAME" "ERROR"
        return 1
    fi
}

# =============================================
# SETUP DUAL-IP SYSTEM
# =============================================

setup_dual_ip() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          DUAL IP AUTO-FAILOVER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses for auto-failover:"
    echo "-------------------------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server): " primary_ip
        if validate_ip "$primary_ip"; then
            break
        fi
        log "Invalid IPv4 address format" "ERROR"
    done
    
    # Backup IP
    while true; do
        read -rp "Backup IP (failover server): " backup_ip
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
    local cname="app-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating DNS records..." "INFO"
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
    save_state "$primary_ip" "$backup_ip" "$cname" "$primary_record_id" "$backup_record_id"
    
    # Save CNAME to file
    echo "$cname" > "$LAST_CNAME_FILE"
    
    echo
    echo "════════════════════════════════════════════════"
    log "SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo "Your CNAME is:"
    echo -e "  ${GREEN}$cname${NC}"
    echo
    echo "DNS Configuration:"
    echo "  Primary: $primary_host → $primary_ip"
    echo "  Backup:  $backup_host → $backup_ip"
    echo "  CNAME:   $cname → $primary_host"
    echo
    echo "Auto-Failover Settings:"
    echo "  Check interval: ${CHECK_INTERVAL} seconds"
    echo "  Failover after: $((CHECK_INTERVAL * FAILURE_THRESHOLD)) seconds"
    echo "  Recovery after: $((CHECK_INTERVAL * RECOVERY_THRESHOLD)) seconds"
    echo
    echo "Current traffic is routed to: ${GREEN}PRIMARY IP ($primary_ip)${NC}"
    echo
    echo "To start auto-monitoring:"
    echo "  Run this script → Start Monitor Service"
    echo
}

# =============================================
# MONITORING FUNCTIONS
# =============================================

check_ip_health() {
    local ip="$1"
    
    # Try ping first
    if command -v ping &>/dev/null; then
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            return 0  # Success
        fi
    fi
    
    # Fallback: try curl on port 80
    if command -v curl &>/dev/null; then
        if curl -s --max-time 2 "http://$ip" &>/dev/null; then
            return 0  # Success
        fi
    fi
    
    # Try netcat on port 80
    if command -v nc &>/dev/null; then
        if nc -z -w 1 "$ip" 80 &>/dev/null; then
            return 0  # Success
        fi
    fi
    
    return 1  # All checks failed
}

perform_failover() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    local backup_host
    backup_host=$(echo "$state" | jq -r '.backup_host // empty')
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found for failover" "ERROR"
        return 1
    fi
    
    log "Primary IP ($primary_ip) is down! Initiating failover..." "WARNING"
    log "Switching CNAME to backup: $cname → $backup_host" "INFO"
    
    if update_cname_target "$cname" "$backup_host"; then
        update_state "active_ip" "$backup_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        log "Failover completed! Now using Backup IP ($backup_ip)" "SUCCESS"
        return 0
    else
        log "Failed to perform failover" "ERROR"
        return 1
    fi
}

perform_recovery() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_host
    primary_host=$(echo "$state" | jq -r '.primary_host // empty')
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found for recovery" "ERROR"
        return 1
    fi
    
    log "Primary IP ($primary_ip) is healthy again! Switching back..." "INFO"
    log "Switching CNAME to primary: $cname → $primary_host" "INFO"
    
    if update_cname_target "$cname" "$primary_host"; then
        update_state "active_ip" "$primary_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        log "Recovery completed! Now using Primary IP ($primary_ip)" "SUCCESS"
        return 0
    else
        log "Failed to perform recovery" "ERROR"
        return 1
    fi
}

monitor_service() {
    log "Starting auto-monitor service..." "INFO"
    log "Monitoring interval: ${CHECK_INTERVAL} seconds" "INFO"
    
    # Load initial state
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Auto-monitor service started (PID: $$)" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    
    # Trap signals
    trap 'log "Monitor service stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    # Main monitoring loop
    while true; do
        state=$(load_state)
        
        local primary_ip
        primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
        local backup_ip
        backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
        local active_ip
        active_ip=$(echo "$state" | jq -r '.active_ip // empty')
        local failure_count
        failure_count=$(echo "$state" | jq -r '.failure_count // 0')
        local recovery_count
        recovery_count=$(echo "$state" | jq -r '.recovery_count // 0')
        
        # Check primary IP health
        if check_ip_health "$primary_ip"; then
            # Primary is healthy
            update_state "failure_count" "0"
            
            # If currently on backup and primary is healthy, start recovery count
            if [ "$active_ip" = "$backup_ip" ]; then
                local new_recovery_count=$((recovery_count + 1))
                update_state "recovery_count" "$new_recovery_count"
                
                log "Primary IP ($primary_ip) is healthy. Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "INFO"
                
                # Check if we should switch back to primary
                if [ "$new_recovery_count" -ge "$RECOVERY_THRESHOLD" ]; then
                    perform_recovery
                fi
            else
                # Reset recovery count if already on primary
                update_state "recovery_count" "0"
            fi
        else
            # Primary is down
            local new_failure_count=$((failure_count + 1))
            update_state "failure_count" "$new_failure_count"
            
            log "Primary IP ($primary_ip) is down. Failure count: $new_failure_count/$FAILURE_THRESHOLD" "WARNING"
            
            # Check if we should switch to backup
            if [ "$new_failure_count" -ge "$FAILURE_THRESHOLD" ] && [ "$active_ip" = "$primary_ip" ]; then
                perform_failover
            fi
            
            # Reset recovery count when primary is down
            update_state "recovery_count" "0"
        fi
        
        # Sleep before next check
        sleep "$CHECK_INTERVAL"
    done
}

start_monitor() {
    # Check if monitor is already running
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            log "Monitor service is already running (PID: $pid)" "INFO"
            return 0
        else
            rm -f "$MONITOR_PID_FILE"
        fi
    fi
    
    # Start monitor in background
    monitor_service &
    
    log "Monitor service started in background" "SUCCESS"
    log "Check logs at: $LOG_FILE" "INFO"
}

stop_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        
        if kill "$pid" 2>/dev/null; then
            log "Stopped monitor service (PID: $pid)" "SUCCESS"
        else
            log "Monitor service was not running" "INFO"
        fi
        
        rm -f "$MONITOR_PID_FILE"
    else
        log "Monitor service is not running" "INFO"
    fi
}

# =============================================
# STATUS AND INFO FUNCTIONS
# =============================================

show_status() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No dual-IP setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    local failure_count
    failure_count=$(echo "$state" | jq -r '.failure_count // 0')
    local recovery_count
    recovery_count=$(echo "$state" | jq -r '.recovery_count // 0')
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           CURRENT STATUS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$cname${NC}"
    echo
    echo "IP Addresses:"
    
    if [ "$active_ip" = "$primary_ip" ]; then
        echo -e "  Primary: $primary_ip ${GREEN}[ACTIVE]${NC}"
        echo -e "  Backup:  $backup_ip"
        echo -e "  Status: ${GREEN}Normal operation${NC}"
    else
        echo -e "  Primary: $primary_ip ${RED}[DOWN]${NC}"
        echo -e "  Backup:  $backup_ip ${GREEN}[ACTIVE - FAILOVER]${NC}"
        echo -e "  Status: ${YELLOW}Failover active${NC}"
    fi
    
    echo
    echo "Monitor Counters:"
    echo "  Failures: $failure_count/$FAILURE_THRESHOLD"
    echo "  Recovery: $recovery_count/$RECOVERY_THRESHOLD"
    echo
    
    # Check monitor status
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if ps -p "$pid" &>/dev/null; then
            echo -e "Monitor: ${GREEN}RUNNING${NC} (PID: $pid)"
        else
            echo -e "Monitor: ${RED}STOPPED${NC}"
            rm -f "$MONITOR_PID_FILE"
        fi
    else
        echo -e "Monitor: ${YELLOW}NOT RUNNING${NC}"
    fi
    
    echo
    echo "Health Check:"
    
    # Check primary
    echo -n "  Primary ($primary_ip): "
    if check_ip_health "$primary_ip"; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    # Check backup
    echo -n "  Backup ($backup_ip): "
    if check_ip_health "$backup_ip"; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

show_cname() {
    if [ -f "$LAST_CNAME_FILE" ]; then
        local cname
        cname=$(cat "$LAST_CNAME_FILE")
        
        echo
        echo "════════════════════════════════════════════════"
        echo "           YOUR CNAME"
        echo "════════════════════════════════════════════════"
        echo
        echo -e "  ${GREEN}$cname${NC}"
        echo
        echo "Use this CNAME in your applications."
        echo "DNS propagation may take 1-2 minutes."
        echo
        echo "Auto-failover will:"
        echo "  1. Monitor Primary IP every ${CHECK_INTERVAL}s"
        echo "  2. Switch to Backup after $((CHECK_INTERVAL * FAILURE_THRESHOLD))s of downtime"
        echo "  3. Switch back to Primary after $((CHECK_INTERVAL * RECOVERY_THRESHOLD))s of stability"
        echo
    else
        log "No CNAME found. Please run setup first." "ERROR"
    fi
}

# =============================================
# CLEANUP FUNCTION
# =============================================

cleanup() {
    echo
    log "WARNING: This will delete ALL created DNS records!" "WARNING"
    echo
    
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found to cleanup" "ERROR"
        return 1
    fi
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    # Stop monitor first
    stop_monitor
    
    log "Deleting DNS records..." "INFO"
    
    # Get record IDs from state
    local primary_record
    primary_record=$(echo "$state" | jq -r '.primary_record // empty')
    local backup_record
    backup_record=$(echo "$state" | jq -r '.backup_record // empty')
    
    # Delete CNAME record
    local cname_record_id
    cname_record_id=$(get_cname_record_id "$cname")
    if [ -n "$cname_record_id" ]; then
        delete_dns_record "$cname_record_id"
    fi
    
    # Delete A records
    if [ -n "$primary_record" ]; then
        delete_dns_record "$primary_record"
    fi
    
    if [ -n "$backup_record" ]; then
        delete_dns_record "$backup_record"
    fi
    
    # Delete state files
    rm -f "$STATE_FILE" "$LAST_CNAME_FILE" "$MONITOR_PID_FILE"
    
    log "Cleanup completed!" "SUCCESS"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE AUTO-FAILOVER MANAGER v3.0      ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Complete Setup (Create Dual-IP CNAME)      ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                       ║"
    echo -e "║  ${GREEN}3.${NC} Start Auto-Monitor Service                ║"
    echo -e "║  ${GREEN}4.${NC} Stop Auto-Monitor Service                 ║"
    echo -e "║  ${GREEN}5.${NC} Manual Failover Control                   ║"
    echo -e "║  ${GREEN}6.${NC} Show My CNAME                             ║"
    echo -e "║  ${GREEN}7.${NC} Cleanup (Delete All)                      ║"
    echo -e "║  ${GREEN}8.${NC} Configure API Settings                    ║"
    echo -e "║  ${GREEN}9.${NC} Exit                                      ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [ -n "$cname" ]; then
            local active_ip
            active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
            local monitor_status=""
            
            if [ -f "$MONITOR_PID_FILE" ]; then
                local pid
                pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null || echo "")
                if ps -p "$pid" &>/dev/null; then
                    monitor_status="${GREEN}●${NC}"
                else
                    monitor_status="${RED}●${NC}"
                fi
            else
                monitor_status="${YELLOW}○${NC}"
            fi
            
            echo -e "║  ${CYAN}CNAME: $cname${NC}"
            echo -e "║  ${CYAN}Active IP: $active_ip ${monitor_status}${NC}"
        fi
    fi
    
    echo "╚════════════════════════════════════════════════╝"
    echo
}

manual_failover_control() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           MANUAL FAILOVER CONTROL"
    echo "════════════════════════════════════════════════"
    echo
    echo "Current CNAME: $cname"
    echo "Active IP: $active_ip"
    echo
    echo "1. Switch to Primary IP ($primary_ip)"
    echo "2. Switch to Backup IP ($backup_ip)"
    echo "3. Test both IPs"
    echo "4. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            local primary_host
            primary_host=$(echo "$state" | jq -r '.primary_host // empty')
            log "Switching to Primary IP..." "INFO"
            if update_cname_target "$cname" "$primary_host"; then
                update_state "active_ip" "$primary_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Primary IP ($primary_ip)" "SUCCESS"
            fi
            ;;
        2)
            local backup_host
            backup_host=$(echo "$state" | jq -r '.backup_host // empty')
            log "Switching to Backup IP..." "INFO"
            if update_cname_target "$cname" "$backup_host"; then
                update_state "active_ip" "$backup_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Backup IP ($backup_ip)" "SUCCESS"
            fi
            ;;
        3)
            echo
            echo "Testing IP connectivity:"
            echo "------------------------"
            echo -n "Primary IP ($primary_ip): "
            if check_ip_health "$primary_ip"; then
                echo -e "${GREEN}✓ HEALTHY${NC}"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            
            echo -n "Backup IP ($backup_ip): "
            if check_ip_health "$backup_ip"; then
                echo -e "${GREEN}✓ HEALTHY${NC}"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            ;;
        4)
            return
            ;;
    esac
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
        
        read -rp "Select option (1-9): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_dual_ip
                else
                    log "Please configure API settings first (option 8)" "ERROR"
                fi
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                if load_config; then
                    start_monitor
                else
                    log "Please configure API settings first (option 8)" "ERROR"
                fi
                pause
                ;;
            4)
                stop_monitor
                pause
                ;;
            5)
                if load_config; then
                    manual_failover_control
                else
                    log "Please configure API settings first (option 8)" "ERROR"
                fi
                pause
                ;;
            6)
                show_cname
                pause
                ;;
            7)
                cleanup
                pause
                ;;
            8)
                configure_api
                ;;
            9)
                echo
                log "Goodbye!" "INFO"
                echo
                exit 0
                ;;
            *)
                log "Invalid option. Please select 1-9." "ERROR"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main
