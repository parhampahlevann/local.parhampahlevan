#!/bin/bash

# =============================================
# CLOUDFLARE SMART LOAD BALANCER v4.0
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
DNS_TTL=60  # 1 minute TTL for fast failover

# Health Check Settings
HEALTH_CHECK_INTERVAL=30  # Check every 30 seconds (not too frequent)
HEALTH_CHECK_TIMEOUT=5    # 5 second timeout per check
MAX_FAILURES=3            # 3 failures = 90 seconds downtime before failover
RECOVERY_THRESHOLD=5      # 5 successful checks = 150 seconds before recovery

# Performance Settings
ENABLE_PERFORMANCE_MONITOR=true
MIN_RESPONSE_TIME_MS=100
MAX_RESPONSE_TIME_MS=2000

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
        "DEBUG")
            echo -e "${PURPLE}[$timestamp] [DEBUG]${NC} $msg" >> "$LOG_FILE"
            ;;
        "PERF")
            echo -e "${ORANGE}[$timestamp] [PERF]${NC} $msg" >> "$LOG_FILE"
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
    
    # Check timeout
    if ! command -v timeout &>/dev/null; then
        log "timeout is not installed" "ERROR"
        echo "Install with: sudo apt-get install coreutils"
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
HEALTH_CHECK_INTERVAL="$HEALTH_CHECK_INTERVAL"
HEALTH_CHECK_TIMEOUT="$HEALTH_CHECK_TIMEOUT"
MAX_FAILURES="$MAX_FAILURES"
RECOVERY_THRESHOLD="$RECOVERY_THRESHOLD"
ENABLE_PERFORMANCE_MONITOR="$ENABLE_PERFORMANCE_MONITOR"
MIN_RESPONSE_TIME_MS="$MIN_RESPONSE_TIME_MS"
MAX_RESPONSE_TIME_MS="$MAX_RESPONSE_TIME_MS"
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
  "failure_count": 0,
  "recovery_count": 0,
  "last_health_check": "$(date '+%Y-%m-%d %H:%M:%S')",
  "total_failovers": 0,
  "last_failover": null
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

increment_counter() {
    local key="$1"
    
    if [ -f "$STATE_FILE" ]; then
        local current_value
        current_value=$(jq -r ".[\"$key\"] // 0" "$STATE_FILE")
        local new_value=$((current_value + 1))
        
        local temp_file
        temp_file=$(mktemp)
        jq --arg key "$key" --argjson new_value "$new_value" '.[$key] = $new_value' "$STATE_FILE" > "$temp_file"
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
# SMART HEALTH CHECK SYSTEM
# =============================================

perform_health_check() {
    local ip="$1"
    local check_type="${2:-basic}"
    
    local start_time
    start_time=$(date +%s%N)
    local result="unknown"
    local response_time=0
    
    # Try multiple ports and methods
    local ports=(80 443 22)
    local methods=("http" "https" "tcp")
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local method="${methods[$i]}"
        
        case $method in
            "http")
                if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f "http://$ip:$port" &>/dev/null; then
                    result="healthy"
                    break
                fi
                ;;
            "https")
                if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f -k "https://$ip:$port" &>/dev/null; then
                    result="healthy"
                    break
                fi
                ;;
            "tcp")
                if timeout "$HEALTH_CHECK_TIMEOUT" bash -c "echo > /dev/tcp/$ip/$port" &>/dev/null; then
                    result="healthy"
                    break
                fi
                ;;
        esac
    done
    
    # Calculate response time
    local end_time
    end_time=$(date +%s%N)
    response_time=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds
    
    # Performance monitoring
    if [ "$ENABLE_PERFORMANCE_MONITOR" = "true" ]; then
        if [ "$result" = "healthy" ]; then
            if [ "$response_time" -gt "$MAX_RESPONSE_TIME_MS" ]; then
                result="degraded"
                log "Performance degraded for $ip: ${response_time}ms" "PERF"
            elif [ "$response_time" -lt "$MIN_RESPONSE_TIME_MS" ]; then
                log "Excellent performance for $ip: ${response_time}ms" "PERF"
            fi
        fi
    fi
    
    echo "$result:$response_time"
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
    
    local response
    response=$(api_request "PUT" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Updated CNAME: $cname → $target_host" "SUCCESS"
        return 0
    else
        log "Failed to update CNAME" "ERROR"
        return 1
    fi
}

# =============================================
# SMART LOAD BALANCER SETUP
# =============================================

setup_smart_load_balancer() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          SMART LOAD BALANCER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    echo "This creates an intelligent load balancer with:"
    echo "  • Primary IP priority (always used if healthy)"
    echo "  • Automatic failover to Backup IP"
    echo "  • Automatic recovery to Primary IP"
    echo "  • Performance monitoring"
    echo "  • No downtime during failover"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses:"
    echo "-------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server - ALWAYS used if healthy): " primary_ip
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
    local cname="lb-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating Smart Load Balancer..." "INFO"
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
    log "SMART LOAD BALANCER CREATED SUCCESSFULLY!" "SUCCESS"
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
    echo "Smart Failover Settings:"
    echo "  Health Check: Every ${HEALTH_CHECK_INTERVAL} seconds"
    echo "  Failover after: $((HEALTH_CHECK_INTERVAL * MAX_FAILURES)) seconds"
    echo "  Recovery after: $((HEALTH_CHECK_INTERVAL * RECOVERY_THRESHOLD)) seconds"
    echo "  DNS TTL: ${DNS_TTL} seconds (fast propagation)"
    echo
    echo "Traffic Flow:"
    echo "  1. Always uses Primary IP if healthy"
    echo "  2. Auto-switch to Backup if Primary fails"
    echo "  3. Auto-switch back to Primary when recovered"
    echo "  4. No manual intervention needed"
    echo
    echo "To start the load balancer monitor:"
    echo "  Run this script → Start Load Balancer Service"
    echo
}

# =============================================
# INTELLIGENT FAILOVER SYSTEM
# =============================================

perform_failover() {
    acquire_lock || return 1
    
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    local backup_host
    backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found for failover" "ERROR"
        release_lock
        return 1
    fi
    
    if [ "$active_ip" = "$backup_ip" ]; then
        log "Already using Backup IP ($backup_ip)" "INFO"
        release_lock
        return 0
    fi
    
    log "Primary IP ($primary_ip) is unhealthy! Initiating failover..." "WARNING"
    log "Switching CNAME to backup: $cname → $backup_host" "INFO"
    
    if update_cname_target "$cname" "$backup_host"; then
        update_state "active_ip" "$backup_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        increment_counter "total_failovers"
        update_state "last_failover" "$(date '+%Y-%m-%d %H:%M:%S')"
        log "Failover completed! Now using Backup IP ($backup_ip)" "SUCCESS"
        release_lock
        return 0
    else
        log "Failed to perform failover" "ERROR"
        release_lock
        return 1
    fi
}

perform_recovery() {
    acquire_lock || return 1
    
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_host
    primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found for recovery" "ERROR"
        release_lock
        return 1
    fi
    
    if [ "$active_ip" = "$primary_ip" ]; then
        log "Already using Primary IP ($primary_ip)" "INFO"
        release_lock
        return 0
    fi
    
    log "Primary IP ($primary_ip) is healthy again! Switching back..." "INFO"
    log "Switching CNAME to primary: $cname → $primary_host" "INFO"
    
    if update_cname_target "$cname" "$primary_host"; then
        update_state "active_ip" "$primary_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        log "Recovery completed! Now using Primary IP ($primary_ip)" "SUCCESS"
        release_lock
        return 0
    else
        log "Failed to perform recovery" "ERROR"
        release_lock
        return 1
    fi
}

# =============================================
# LOAD BALANCER MONITOR SERVICE
# =============================================

monitor_service() {
    if ! acquire_lock; then
        log "Another monitor instance is already running" "ERROR"
        return 1
    fi
    
    log "Starting Smart Load Balancer Monitor..." "INFO"
    log "Health Check Interval: ${HEALTH_CHECK_INTERVAL} seconds" "INFO"
    
    # Load initial state
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found. Please run setup first." "ERROR"
        release_lock
        return 1
    fi
    
    log "Monitoring load balancer: $cname" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    
    # Trap signals
    trap 'cleanup_monitor' INT TERM EXIT
    
    # Main monitoring loop
    local monitoring=true
    while $monitoring; do
        # Check if config still exists
        if [ ! -f "$STATE_FILE" ]; then
            log "Load balancer configuration removed. Stopping monitor." "INFO"
            monitoring=false
            break
        fi
        
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
        
        # Update last check time
        update_state "last_health_check" "$(date '+%Y-%m-%d %H:%M:%S')"
        
        # Check primary IP health
        log "Checking Primary IP ($primary_ip) health..." "HEALTH"
        local health_result
        health_result=$(perform_health_check "$primary_ip")
        local primary_health="${health_result%:*}"
        local response_time="${health_result#*:}"
        
        # Update health status
        update_state "health_status.primary" "$primary_health"
        
        # Check backup IP health (less frequently)
        local backup_check_interval=$((HEALTH_CHECK_INTERVAL * 3))
        local current_time
        current_time=$(date +%s)
        local last_backup_check
        last_backup_check=$(echo "$state" | jq -r '.last_backup_check // 0')
        
        if [ $((current_time - last_backup_check)) -ge $backup_check_interval ]; then
            log "Checking Backup IP ($backup_ip) health..." "HEALTH"
            local backup_health_result
            backup_health_result=$(perform_health_check "$backup_ip")
            local backup_health="${backup_health_result%:*}"
            update_state "health_status.backup" "$backup_health"
            update_state "last_backup_check" "$current_time"
        fi
        
        # Handle primary IP health status
        if [ "$primary_health" = "healthy" ] || [ "$primary_health" = "degraded" ]; then
            # Primary is healthy or degraded but still functional
            update_state "failure_count" "0"
            
            # If currently on backup and primary is healthy, start recovery count
            if [ "$active_ip" = "$backup_ip" ]; then
                local new_recovery_count=$((recovery_count + 1))
                update_state "recovery_count" "$new_recovery_count"
                
                if [ "$primary_health" = "healthy" ]; then
                    log "Primary IP ($primary_ip) is healthy. Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "HEALTH"
                else
                    log "Primary IP ($primary_ip) is degraded (${response_time}ms). Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "HEALTH"
                fi
                
                # Check if we should switch back to primary
                if [ "$new_recovery_count" -ge "$RECOVERY_THRESHOLD" ]; then
                    perform_recovery
                fi
            else
                # Reset recovery count if already on primary
                update_state "recovery_count" "0"
                if [ "$primary_health" = "degraded" ]; then
                    log "Primary IP ($primary_ip) performance degraded: ${response_time}ms" "WARNING"
                fi
            fi
        else
            # Primary is unhealthy
            local new_failure_count=$((failure_count + 1))
            update_state "failure_count" "$new_failure_count"
            
            log "Primary IP ($primary_ip) is unhealthy. Failure count: $new_failure_count/$MAX_FAILURES" "HEALTH"
            
            # Check backup health before failover
            local backup_health
            backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
            
            # Check if we should switch to backup
            if [ "$new_failure_count" -ge "$MAX_FAILURES" ] && [ "$active_ip" = "$primary_ip" ]; then
                if [ "$backup_health" = "healthy" ] || [ "$backup_health" = "degraded" ]; then
                    perform_failover
                else
                    log "Backup IP ($backup_ip) is also unhealthy. Cannot failover!" "ERROR"
                    update_state "failure_count" "0"  # Reset to keep checking
                fi
            fi
            
            # Reset recovery count when primary is down
            update_state "recovery_count" "0"
        fi
        
        # Sleep before next check
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    
    cleanup_monitor
}

cleanup_monitor() {
    log "Stopping Load Balancer Monitor..." "INFO"
    release_lock
    exit 0
}

start_monitor() {
    # Check if monitor is already running
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "Load balancer monitor is already running (PID: $lock_pid)" "INFO"
            return 0
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Start monitor in background
    monitor_service &
    local monitor_pid=$!
    
    log "Load balancer monitor started in background (PID: $monitor_pid)" "SUCCESS"
    log "Health logs: $HEALTH_LOG" "INFO"
    log "Activity logs: $LOG_FILE" "INFO"
}

stop_monitor() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE")
        
        if [ -n "$lock_pid" ]; then
            if kill "$lock_pid" 2>/dev/null; then
                log "Stopped load balancer monitor (PID: $lock_pid)" "SUCCESS"
            else
                log "Monitor was not running" "INFO"
            fi
        fi
        
        rm -f "$LOCK_FILE"
    else
        log "Load balancer monitor is not running" "INFO"
    fi
}

# =============================================
# MANUAL CONTROL
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
    
    local state
    state=$(load_state)
    
    local cname primary_ip backup_ip active_ip primary_health backup_health
    cname=$(echo "$state" | jq -r '.cname // empty')
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    primary_health=$(echo "$state" | jq -r '.health_status.primary // "unknown"')
    backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
    
    echo "Current Status:"
    echo "  CNAME: $cname"
    echo "  Active IP: $active_ip"
    echo "  Primary IP ($primary_ip): $primary_health"
    echo "  Backup IP ($backup_ip): $backup_health"
    echo
    
    echo "Manual Control Options:"
    echo "1. Force switch to Primary IP"
    echo "2. Force switch to Backup IP"
    echo "3. Run immediate health check"
    echo "4. View detailed status"
    echo "5. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log "Forcing switch to Primary IP ($primary_ip)..." "INFO"
            local primary_host
            primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$primary_host"; then
                update_state "active_ip" "$primary_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Primary IP ($primary_ip)" "SUCCESS"
            fi
            ;;
        2)
            log "Forcing switch to Backup IP ($backup_ip)..." "INFO"
            local backup_host
            backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$backup_host"; then
                update_state "active_ip" "$backup_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Backup IP ($backup_ip)" "SUCCESS"
            fi
            ;;
        3)
            echo
            echo "Running immediate health checks..."
            echo "---------------------------------"
            
            echo -n "Primary IP ($primary_ip): "
            local health_result
            health_result=$(perform_health_check "$primary_ip")
            local health="${health_result%:*}"
            local response_time="${health_result#*:}"
            
            if [ "$health" = "healthy" ]; then
                echo -e "${GREEN}✓ HEALTHY${NC} (${response_time}ms)"
            elif [ "$health" = "degraded" ]; then
                echo -e "${YELLOW}⚠ DEGRADED${NC} (${response_time}ms)"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            
            echo -n "Backup IP ($backup_ip): "
            health_result=$(perform_health_check "$backup_ip")
            health="${health_result%:*}"
            response_time="${health_result#*:}"
            
            if [ "$health" = "healthy" ]; then
                echo -e "${GREEN}✓ HEALTHY${NC} (${response_time}ms)"
            elif [ "$health" = "degraded" ]; then
                echo -e "${YELLOW}⚠ DEGRADED${NC} (${response_time}ms)"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            
            # Update state
            update_state "health_status.primary" "$(echo "$health_result" | cut -d: -f1)"
            update_state "health_status.backup" "$(echo "$health_result" | cut -d: -f1)"
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

# =============================================
# STATUS FUNCTIONS
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
    
    local state
    state=$(load_state)
    
    local cname primary_ip backup_ip active_ip created_at
    local failure_count recovery_count total_failovers last_failover
    local primary_health backup_health last_health_check
    
    cname=$(echo "$state" | jq -r '.cname // empty')
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    created_at=$(echo "$state" | jq -r '.created_at // empty')
    failure_count=$(echo "$state" | jq -r '.failure_count // 0')
    recovery_count=$(echo "$state" | jq -r '.recovery_count // 0')
    total_failovers=$(echo "$state" | jq -r '.total_failovers // 0')
    last_failover=$(echo "$state" | jq -r '.last_failover // "Never"')
    primary_health=$(echo "$state" | jq -r '.health_status.primary // "unknown"')
    backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
    last_health_check=$(echo "$state" | jq -r '.last_health_check // "Never"')
    
    echo -e "${GREEN}Load Balancer Configuration:${NC}"
    echo "  CNAME: $cname"
    echo "  Created: $created_at"
    echo
    
    echo -e "${CYAN}IP Status:${NC}"
    echo -n "  Primary ($primary_ip): "
    if [ "$primary_health" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    elif [ "$primary_health" = "degraded" ]; then
        echo -e "${YELLOW}⚠ DEGRADED${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    echo -n "  Backup ($backup_ip): "
    if [ "$backup_health" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    elif [ "$backup_health" = "degraded" ]; then
        echo -e "${YELLOW}⚠ DEGRADED${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    echo -n "  Active IP: "
    if [ "$active_ip" = "$primary_ip" ]; then
        echo -e "${GREEN}$active_ip (PRIMARY)${NC}"
    else
        echo -e "${YELLOW}$active_ip (BACKUP - FAILOVER)${NC}"
    fi
    echo
    
    echo -e "${PURPLE}Failover Status:${NC}"
    echo "  Failure Count: $failure_count/$MAX_FAILURES"
    echo "  Recovery Count: $recovery_count/$RECOVERY_THRESHOLD"
    echo "  Total Failovers: $total_failovers"
    echo "  Last Failover: $last_failover"
    echo "  Last Health Check: $last_health_check"
    echo
    
    # Check monitor status
    echo -e "${ORANGE}Monitor Status:${NC}"
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo -e "  Status: ${GREEN}RUNNING${NC} (PID: $lock_pid)"
        else
            echo -e "  Status: ${RED}STOPPED${NC}"
            rm -f "$LOCK_FILE"
        fi
    else
        echo -e "  Status: ${YELLOW}NOT RUNNING${NC}"
    fi
    
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
            echo "Smart Load Balancer Features:"
            echo "  • Always uses Primary IP if healthy"
            echo "  • Auto-failover to Backup if Primary fails"
            echo "  • Auto-recovery when Primary is healthy again"
            echo "  • Performance monitoring"
            echo "  • Health checks every ${HEALTH_CHECK_INTERVAL}s"
            echo "  • DNS TTL: ${DNS_TTL}s (fast propagation)"
            echo
            echo "Use this CNAME in your applications."
            echo "The load balancer will handle everything automatically."
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
    
    local state
    state=$(load_state)
    
    local cname primary_ip backup_ip primary_record_id backup_record_id cname_record_id
    cname=$(echo "$state" | jq -r '.cname // empty')
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    primary_record_id=$(echo "$state" | jq -r '.primary_record_id // empty')
    backup_record_id=$(echo "$state" | jq -r '.backup_record_id // empty')
    cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
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
    
    # Stop monitor first
    stop_monitor
    
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
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE SMART LOAD BALANCER v4.0       ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Create Smart Load Balancer               ║"
    echo -e "║  ${GREEN}2.${NC} Show Detailed Status                     ║"
    echo -e "║  ${GREEN}3.${NC} Start Load Balancer Service              ║"
    echo -e "║  ${GREEN}4.${NC} Stop Load Balancer Service               ║"
    echo -e "║  ${GREEN}5.${NC} Manual Control                           ║"
    echo -e "║  ${GREEN}6.${NC} Show My CNAME                            ║"
    echo -e "║  ${GREEN}7.${NC} Cleanup (Delete All)                     ║"
    echo -e "║  ${GREEN}8.${NC} Configure API Settings                   ║"
    echo -e "║  ${GREEN}9.${NC} Exit                                     ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname active_ip primary_health
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
        primary_health=$(jq -r '.health_status.primary // "unknown"' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$cname" ]; then
            local monitor_status=""
            
            if [ -f "$LOCK_FILE" ]; then
                local lock_pid
                lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
                if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                    monitor_status="${GREEN}●${NC}"
                else
                    monitor_status="${RED}●${NC}"
                fi
            else
                monitor_status="${YELLOW}○${NC}"
            fi
            
            local health_status=""
            if [ "$primary_health" = "healthy" ]; then
                health_status="${GREEN}✓${NC}"
            elif [ "$primary_health" = "degraded" ]; then
                health_status="${YELLOW}⚠${NC}"
            else
                health_status="${RED}✗${NC}"
            fi
            
            echo -e "║  ${CYAN}LB: $cname${NC}"
            echo -e "║  ${CYAN}Active: $active_ip ${health_status} ${monitor_status}${NC}"
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
        
        read -rp "Select option (1-9): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_smart_load_balancer
                else
                    log "Please configure API settings first (option 8)" "ERROR"
                fi
                pause
                ;;
            2)
                show_detailed_status
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
                    manual_control
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
