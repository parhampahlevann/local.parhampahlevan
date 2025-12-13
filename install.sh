#!/bin/bash

# =============================================
# CLOUDFLARE AUTO-FAILOVER MANAGER v3.2
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

# =============================================
# MONITORING PARAMETERS (TUNABLE - MATCHING SCRIPT 1)
# =============================================

CHECK_INTERVAL=5          # Check every 5 seconds (reduced from 2 to prevent rapid checks)
PING_COUNT=3              # 3 pings per check
PING_TIMEOUT=2            # 2 second timeout per ping (increased for reliability)

# When is a server considered DOWN?
HARD_DOWN_LOSS=90         # >= 90% loss = DOWN

# When to switch to backup (degraded condition)
DEGRADED_LOSS=40          # >= 40% loss = degraded
DEGRADED_RTT=300          # >= 300ms RTT = degraded
BAD_STREAK_LIMIT=3        # 3 consecutive degraded checks before switching

# When to switch back to primary (recovery condition)
PRIMARY_OK_LOSS=50        # loss <= 50%
PRIMARY_OK_RTT=450        # RTT <= 450ms
PRIMARY_STABLE_ROUNDS=5   # 5 consecutive good checks (25 seconds total)

# Hysteresis to prevent rapid switching
SWITCH_COOLDOWN=60        # 60 seconds cooldown after any switch
MIN_UPTIME_BEFORE_SWITCH=30  # Minimum 30 seconds uptime before allowing switch

# DNS Settings for NO DOWNTIME
DNS_TTL=300               # 5 minutes TTL (standard for failover)
DNS_PROXIED=false         # Must be false for failover to work

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
        log "ping is not installed" "ERROR"
        echo "Install with: sudo apt-get install iputils-ping"
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
CHECK_INTERVAL="$CHECK_INTERVAL"
DNS_TTL="$DNS_TTL"
DNS_PROXIED="$DNS_PROXIED"
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local primary_ip="$1"
    local backup_ip="$2"
    local cname="$3"
    local primary_record="$4"
    local backup_record="$5"
    local cname_record="$6"
    
    cat > "$STATE_FILE" << EOF
{
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "cname": "$cname",
  "primary_record": "$primary_record",
  "backup_record": "$backup_record",
  "cname_record": "$cname_record",
  "primary_host": "primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').$BASE_HOST",
  "backup_host": "backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').$BASE_HOST",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "active_ip": "$primary_ip",
  "active_host": "primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').$BASE_HOST",
  "last_switch_time": 0,
  "setup_time": $(date +%s),
  "failure_count": 0,
  "recovery_count": 0,
  "consecutive_primary_down": 0,
  "consecutive_primary_good": 0,
  "current_state": "primary_active",
  "last_health_check": $(date +%s)
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
# API FUNCTIONS - OPTIMIZED FOR NO DOWNTIME
# =============================================

cf_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    local response
    local max_retries=2
    local retry_delay=1
    
    for ((retry=0; retry<=max_retries; retry++)); do
        if [ -n "$data" ]; then
            response=$(curl -s -X "$method" "$url" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --max-time 10 \
                --retry 2 \
                --retry-delay 1 \
                --retry-max-time 30 \
                --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
        else
            response=$(curl -s -X "$method" "$url" \
                -H "Authorization: Bearer $CF_API_TOKEN" \
                -H "Content-Type: application/json" \
                --max-time 10 \
                --retry 2 \
                --retry-delay 1 \
                --retry-max-time 30 \
                2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
        fi
        
        # Check if we got a valid JSON response
        if echo "$response" | jq -e . >/dev/null 2>&1; then
            if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
                echo "$response"
                return 0
            fi
        fi
        
        if [ $retry -lt $max_retries ]; then
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
    done
    
    log "API request failed after $max_retries retries: $endpoint" "ERROR"
    echo "$response"
    return 1
}

test_api() {
    log "Testing API token..." "INFO"
    local response
    response=$(cf_api_request "GET" "/user/tokens/verify")
    
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
    response=$(cf_api_request "GET" "/zones/${CF_ZONE_ID}")
    
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
# HEALTH CHECK FUNCTIONS - RELIABLE
# =============================================

check_ip_health_detailed() {
    local ip="$1"
    
    local ping_output
    local loss=100
    local rtt=1000
    
    # Try multiple ping attempts for reliability
    for attempt in {1..2}; do
        ping_output=$(timeout 5 ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            # Extract packet loss
            local loss_line
            loss_line=$(echo "$ping_output" | grep -m1 "packet loss")
            if [[ -n "$loss_line" ]]; then
                loss=$(echo "$loss_line" | awk -F',' '{print $3}' | sed 's/[^0-9]//g')
                [[ -z "$loss" ]] && loss=0
            else
                loss=0
            fi
            
            # Extract RTT
            local rtt_line
            rtt_line=$(echo "$ping_output" | grep -m1 "rtt" || true)
            if [[ -n "$rtt_line" ]]; then
                rtt=$(echo "$rtt_line" | awk -F'/' '{print $5}')
                rtt=${rtt%.*}
                [[ -z "$rtt" ]] && rtt=0
            else
                rtt=50
            fi
            
            # If we got a valid reading, break
            if [ $loss -lt 100 ] && [ $rtt -lt 1000 ]; then
                break
            fi
        fi
        
        if [ $attempt -lt 2 ]; then
            sleep 1
        fi
    done
    
    echo "$loss $rtt"
}

compute_score() {
    local loss="$1"
    local rtt="$2"
    # Lower score = better
    echo $(( loss * 100 + rtt ))
}

# =============================================
# DNS MANAGEMENT - ZERO DOWNTIME SOLUTION
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
  "proxied": $DNS_PROXIED,
  "comment": "Auto-failover $(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
)
    
    local response
    response=$(cf_api_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        log "Created $type record: $name → $content (ID: ${record_id:0:8}...)" "SUCCESS"
        echo "$record_id"
        return 0
    else
        log "Failed to create $type record: $name" "ERROR"
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$response")
        log "Error details: $error_msg" "ERROR"
        return 1
    fi
}

update_dns_record() {
    local record_id="$1"
    local name="$2"
    local content="$3"
    
    if [ -z "$record_id" ]; then
        log "No record ID provided for update" "ERROR"
        return 1
    fi
    
    # First check current value to avoid unnecessary updates
    local current_record
    current_record=$(cf_api_request "GET" "/zones/${CF_ZONE_ID}/dns_records/$record_id")
    
    if echo "$current_record" | jq -e '.success == true' &>/dev/null; then
        local current_content
        current_content=$(echo "$current_record" | jq -r '.result.content // empty')
        
        if [ "$current_content" = "$content" ]; then
            log "DNS record already points to $content, no update needed" "INFO"
            return 0
        fi
    fi
    
    # Use PATCH method for partial update (minimal changes)
    local data
    data=$(cat << EOF
{
  "content": "$content",
  "ttl": $DNS_TTL,
  "comment": "Updated by failover $(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
)
    
    log "Updating DNS record $name (ID: ${record_id:0:8}...) → $content" "INFO"
    
    local response
    response=$(cf_api_request "PATCH" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "DNS record updated successfully: $name → $content" "SUCCESS"
        return 0
    else
        log "Failed to update DNS record: $name" "ERROR"
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$response")
        log "Error details: $error_msg" "ERROR"
        return 1
    fi
}

get_record_id_by_name() {
    local name="$1"
    local type="${2:-}"
    
    local endpoint="/zones/${CF_ZONE_ID}/dns_records?name=${name}"
    if [ -n "$type" ]; then
        endpoint="${endpoint}&type=${type}"
    fi
    
    local response
    response=$(cf_api_request "GET" "$endpoint")
    
    if echo "$response" | jq -e '.success == true and .result | length > 0' &>/dev/null; then
        echo "$response" | jq -r '.result[0].id'
    else
        echo ""
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
            # Test connectivity
            log "Testing connectivity to $primary_ip..." "INFO"
            if ping -c 1 -W 2 "$primary_ip" &>/dev/null; then
                log "Primary IP is reachable" "SUCCESS"
                break
            else
                log "Warning: Primary IP is not responding to ping" "WARNING"
                read -rp "Continue anyway? (y/n): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        else
            log "Invalid IPv4 address format" "ERROR"
        fi
    done
    
    # Backup IP
    while true; do
        read -rp "Backup IP (failover server): " backup_ip
        if validate_ip "$backup_ip"; then
            if [ "$primary_ip" = "$backup_ip" ]; then
                log "Error: Primary and Backup IPs cannot be the same" "ERROR"
                continue
            fi
            
            # Test connectivity
            log "Testing connectivity to $backup_ip..." "INFO"
            if ping -c 1 -W 2 "$backup_ip" &>/dev/null; then
                log "Backup IP is reachable" "SUCCESS"
                break
            else
                log "Warning: Backup IP is not responding to ping" "WARNING"
                read -rp "Continue anyway? (y/n): " choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    break
                fi
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
    log "Creating DNS records (TTL: ${DNS_TTL}s, Proxied: ${DNS_PROXIED})..." "INFO"
    echo
    
    # Create Primary A record
    log "Creating Primary A record: $primary_host → $primary_ip" "INFO"
    local primary_record_id
    primary_record_id=$(create_dns_record "$primary_host" "A" "$primary_ip")
    if [ -z "$primary_record_id" ]; then
        log "Failed to create primary A record" "ERROR"
        return 1
    fi
    
    # Wait briefly between creations
    sleep 1
    
    # Create Backup A record
    log "Creating Backup A record: $backup_host → $backup_ip" "INFO"
    local backup_record_id
    backup_record_id=$(create_dns_record "$backup_host" "A" "$backup_ip")
    if [ -z "$backup_record_id" ]; then
        log "Failed to create backup A record" "ERROR"
        delete_dns_record "$primary_record_id"
        return 1
    fi
    
    # Wait briefly between creations
    sleep 1
    
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
    
    # Wait for DNS propagation (at least TTL/2)
    local wait_time=$((DNS_TTL / 2))
    if [ $wait_time -lt 30 ]; then
        wait_time=30
    fi
    
    log "Waiting $wait_time seconds for initial DNS propagation..." "INFO"
    for ((i=1; i<=wait_time; i+=5)); do
        echo -ne "  Waiting... $i/$wait_time seconds\r"
        sleep 5
    done
    echo
    
    # Save state
    save_state "$primary_ip" "$backup_ip" "$cname" "$primary_record_id" "$backup_record_id" "$cname_record_id"
    
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
    echo "  Primary: $primary_host → $primary_ip (Record ID: ${primary_record_id:0:8}...)"
    echo "  Backup:  $backup_host → $backup_ip (Record ID: ${backup_record_id:0:8}...)"
    echo "  CNAME:   $cname → $primary_host (Record ID: ${cname_record_id:0:8}...)"
    echo
    echo "DNS Settings:"
    echo "  TTL: ${DNS_TTL} seconds (5 minutes)"
    echo "  Cloudflare Proxy: ${DNS_PROXIED} (must be false for failover)"
    echo
    echo "Failover Settings:"
    echo "  Check interval: ${CHECK_INTERVAL} seconds"
    echo "  Switch cooldown: ${SWITCH_COOLDOWN} seconds"
    echo "  Minimum uptime before switch: ${MIN_UPTIME_BEFORE_SWITCH} seconds"
    echo
    echo "Current traffic is routed to: ${GREEN}PRIMARY IP ($primary_ip)${NC}"
    echo
    echo "To start auto-monitoring:"
    echo "  Run this script → Start Monitor Service"
    echo
    echo "Note: DNS changes may take up to ${DNS_TTL} seconds to propagate globally."
    echo
}

# =============================================
# MONITORING FUNCTIONS - STABLE VERSION
# =============================================

monitor_service_stable() {
    log "Starting stable auto-monitor service (zero downtime)..." "INFO"
    log "Settings: Check=${CHECK_INTERVAL}s, Cooldown=${SWITCH_COOLDOWN}s, TTL=${DNS_TTL}s" "INFO"
    
    # Load initial state
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local primary_host
    primary_host=$(echo "$state" | jq -r '.primary_host // empty')
    local backup_host
    backup_host=$(echo "$state" | jq -r '.backup_host // empty')
    local cname_record_id
    cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    if [ -z "$cname" ] || [ -z "$cname_record_id" ]; then
        log "No valid setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Monitor started (PID: $$)" "SUCCESS"
    log "CNAME: $cname, Record ID: ${cname_record_id:0:8}..." "INFO"
    log "Primary: $primary_ip, Backup: $backup_ip" "INFO"
    log "Press Ctrl+C to stop" "INFO"
    
    # Trap signals
    trap 'log "Monitor stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    # State tracking
    local current_state="primary_active"
    local consecutive_primary_down=0
    local consecutive_primary_good=0
    local consecutive_backup_down=0
    local last_switch_time=0
    local setup_time
    setup_time=$(echo "$state" | jq -r '.setup_time // 0')
    
    # Ensure minimum uptime has passed
    local current_time
    current_time=$(date +%s)
    local time_since_setup=$((current_time - setup_time))
    
    if [ $time_since_setup -lt $MIN_UPTIME_BEFORE_SWITCH ]; then
        local wait_time=$((MIN_UPTIME_BEFORE_SWITCH - time_since_setup))
        log "Waiting $wait_time seconds for initial stability period..." "INFO"
        sleep $wait_time
    fi
    
    # Main monitoring loop
    while true; do
        current_time=$(date +%s)
        
        # Check if cooldown period is active
        local time_since_last_switch=$((current_time - last_switch_time))
        local cooldown_active=0
        
        if [ $last_switch_time -gt 0 ] && [ $time_since_last_switch -lt $SWITCH_COOLDOWN ]; then
            cooldown_active=1
            local cooldown_remaining=$((SWITCH_COOLDOWN - time_since_last_switch))
        fi
        
        # Health checks with timeout
        local primary_health
        primary_health=$(timeout 10 bash -c "check_ip_health_detailed '$primary_ip'")
        local primary_loss
        primary_loss=$(echo "$primary_health" | awk '{print $1}')
        local primary_rtt
        primary_rtt=$(echo "$primary_health" | awk '{print $2}')
        
        local backup_health
        backup_health=$(timeout 10 bash -c "check_ip_health_detailed '$backup_ip'")
        local backup_loss
        backup_loss=$(echo "$backup_health" | awk '{print $1}')
        local backup_rtt
        backup_rtt=$(echo "$backup_health" | awk '{print $2}')
        
        # Update state tracking
        update_state "last_health_check" "$current_time"
        
        # Log only when there are issues or state changes
        if (( primary_loss >= DEGRADED_LOSS || primary_rtt >= DEGRADED_RTT )) || 
           (( backup_loss >= DEGRADED_LOSS || backup_rtt >= DEGRADED_RTT )) ||
           [ $cooldown_active -eq 1 ]; then
            
            log "Health - Primary: ${primary_loss}% loss, ${primary_rtt}ms | Backup: ${backup_loss}% loss, ${backup_rtt}ms | State: $current_state" "INFO"
            
            if [ $cooldown_active -eq 1 ]; then
                log "Cooldown active: ${cooldown_remaining}s remaining" "INFO"
            fi
        fi
        
        # Update consecutive counters
        if (( primary_loss >= HARD_DOWN_LOSS )); then
            consecutive_primary_down=$((consecutive_primary_down + 1))
            consecutive_primary_good=0
            update_state "consecutive_primary_down" "$consecutive_primary_down"
        elif (( primary_loss <= PRIMARY_OK_LOSS && primary_rtt <= PRIMARY_OK_RTT )); then
            consecutive_primary_good=$((consecutive_primary_good + 1))
            consecutive_primary_down=0
            update_state "consecutive_primary_good" "$consecutive_primary_good"
        else
            consecutive_primary_down=0
            consecutive_primary_good=0
        fi
        
        if (( backup_loss >= HARD_DOWN_LOSS )); then
            consecutive_backup_down=$((consecutive_backup_down + 1))
        else
            consecutive_backup_down=0
        fi
        
        # Decision logic - only proceed if cooldown is not active
        if [ $cooldown_active -eq 0 ]; then
            # Case 1: Currently on primary
            if [ "$current_state" = "primary_active" ]; then
                # Check if primary is down
                if (( consecutive_primary_down >= 2 )); then
                    log "Primary down for ${consecutive_primary_down} checks" "WARNING"
                    
                    # Check if backup is healthy
                    if (( backup_loss < HARD_DOWN_LOSS )); then
                        log "Switching to backup (primary down, backup healthy)" "WARNING"
                        
                        if update_dns_record "$cname_record_id" "$cname" "$backup_host"; then
                            current_state="backup_active"
                            last_switch_time=$current_time
                            update_state "current_state" "$current_state"
                            update_state "active_ip" "$backup_ip"
                            update_state "active_host" "$backup_host"
                            update_state "last_switch_time" "$last_switch_time"
                            log "Switched to backup IP: $backup_ip" "SUCCESS"
                        else
                            log "Failed to switch to backup" "ERROR"
                        fi
                    else
                        log "Backup also unhealthy (${backup_loss}% loss), cannot switch" "ERROR"
                    fi
                # Check if primary is degraded
                elif (( primary_loss >= DEGRADED_LOSS || primary_rtt >= DEGRADED_RTT )); then
                    if (( consecutive_primary_down >= 1 )); then
                        log "Primary degraded: ${primary_loss}% loss, ${primary_rtt}ms" "WARNING"
                    fi
                fi
            
            # Case 2: Currently on backup
            elif [ "$current_state" = "backup_active" ]; then
                # Check if backup is down
                if (( backup_loss >= HARD_DOWN_LOSS )); then
                    log "Backup down while active" "ERROR"
                    
                    # Check if primary is healthy enough to switch back
                    if (( primary_loss < HARD_DOWN_LOSS )); then
                        log "Switching back to primary (backup down)" "WARNING"
                        
                        if update_dns_record "$cname_record_id" "$cname" "$primary_host"; then
                            current_state="primary_active"
                            last_switch_time=$current_time
                            update_state "current_state" "$current_state"
                            update_state "active_ip" "$primary_ip"
                            update_state "active_host" "$primary_host"
                            update_state "last_switch_time" "$last_switch_time"
                            log "Switched back to primary IP: $primary_ip" "SUCCESS"
                        else
                            log "Failed to switch back to primary" "ERROR"
                        fi
                    fi
                
                # Check if primary has been good for long enough
                elif (( consecutive_primary_good >= PRIMARY_STABLE_ROUNDS )); then
                    log "Primary stable for ${consecutive_primary_good} checks, switching back" "INFO"
                    
                    if update_dns_record "$cname_record_id" "$cname" "$primary_host"; then
                        current_state="primary_active"
                        last_switch_time=$current_time
                        consecutive_primary_good=0
                        update_state "current_state" "$current_state"
                        update_state "active_ip" "$primary_ip"
                        update_state "active_host" "$primary_host"
                        update_state "last_switch_time" "$last_switch_time"
                        update_state "consecutive_primary_good" "0"
                        log "Switched back to primary IP: $primary_ip" "SUCCESS"
                    else
                        log "Failed to switch back to primary" "ERROR"
                    fi
                fi
            fi
        else
            # Cooldown is active, reset counters to prevent rapid switching
            consecutive_primary_down=0
            consecutive_primary_good=0
            update_state "consecutive_primary_down" "0"
            update_state "consecutive_primary_good" "0"
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
    
    # Check if setup exists
    if [ ! -f "$STATE_FILE" ]; then
        log "No setup found. Please run setup first (option 1)" "ERROR"
        return 1
    fi
    
    local cname_record_id
    cname_record_id=$(jq -r '.cname_record_id // empty' "$STATE_FILE" 2>/dev/null)
    
    if [ -z "$cname_record_id" ]; then
        log "No CNAME record ID found. Please run setup again." "ERROR"
        return 1
    fi
    
    # Start monitor in background
    monitor_service_stable &
    
    log "Monitor service started in background" "SUCCESS"
    log "Check logs at: $LOG_FILE" "INFO"
}

stop_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
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
    local active_host
    active_host=$(echo "$state" | jq -r '.active_host // empty')
    local current_state
    current_state=$(echo "$state" | jq -r '.current_state // "primary_active"')
    local last_switch_time
    last_switch_time=$(echo "$state" | jq -r '.last_switch_time // 0')
    local cname_record_id
    cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           CURRENT STATUS (ZERO DOWNTIME)"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$cname${NC}"
    if [ -n "$cname_record_id" ]; then
        echo -e "Record ID: ${CYAN}${cname_record_id:0:8}...${NC}"
    fi
    echo
    
    # Get current CNAME target from Cloudflare
    local current_target=""
    if [ -n "$cname_record_id" ]; then
        local cname_info
        cname_info=$(cf_api_request "GET" "/zones/${CF_ZONE_ID}/dns_records/$cname_record_id")
        if echo "$cname_info" | jq -e '.success == true' &>/dev/null; then
            current_target=$(echo "$cname_info" | jq -r '.result.content // empty')
            local record_ttl
            record_ttl=$(echo "$cname_info" | jq -r '.result.ttl // 0')
            echo -e "Current DNS Target: ${CYAN}$current_target${NC}"
            echo -e "DNS TTL: ${CYAN}${record_ttl}s${NC}"
        fi
    fi
    
    echo
    echo "IP Addresses:"
    
    if [ "$current_state" = "primary_active" ]; then
        echo -e "  Primary: $primary_ip ${GREEN}[ACTIVE]${NC}"
        echo -e "  Backup:  $backup_ip [STANDBY]"
        echo -e "  Status: ${GREEN}Normal operation${NC}"
    else
        echo -e "  Primary: $primary_ip [RECOVERING]"
        echo -e "  Backup:  $backup_ip ${GREEN}[ACTIVE - FAILOVER]${NC}"
        echo -e "  Status: ${YELLOW}Failover active${NC}"
    fi
    
    echo
    echo "Health Status:"
    
    local primary_check
    primary_check=$(check_ip_health_detailed "$primary_ip")
    local primary_loss
    primary_loss=$(echo "$primary_check" | awk '{print $1}')
    local primary_rtt
    primary_rtt=$(echo "$primary_check" | awk '{print $2}')
    
    local backup_check
    backup_check=$(check_ip_health_detailed "$backup_ip")
    local backup_loss
    backup_loss=$(echo "$backup_check" | awk '{print $1}')
    local backup_rtt
    backup_rtt=$(echo "$backup_check" | awk '{print $2}')
    
    echo -n "  Primary ($primary_ip): "
    if (( primary_loss >= HARD_DOWN_LOSS )); then
        echo -e "${RED}DOWN (${primary_loss}% loss, ${primary_rtt}ms)${NC}"
    elif (( primary_loss >= DEGRADED_LOSS || primary_rtt >= DEGRADED_RTT )); then
        echo -e "${YELLOW}DEGRADED (${primary_loss}% loss, ${primary_rtt}ms)${NC}"
    else
        echo -e "${GREEN}HEALTHY (${primary_loss}% loss, ${primary_rtt}ms)${NC}"
    fi
    
    echo -n "  Backup ($backup_ip): "
    if (( backup_loss >= HARD_DOWN_LOSS )); then
        echo -e "${RED}DOWN (${backup_loss}% loss, ${backup_rtt}ms)${NC}"
    elif (( backup_loss >= DEGRADED_LOSS || backup_rtt >= DEGRADED_RTT )); then
        echo -e "${YELLOW}DEGRADED (${backup_loss}% loss, ${backup_rtt}ms)${NC}"
    else
        echo -e "${GREEN}HEALTHY (${backup_loss}% loss, ${backup_rtt}ms)${NC}"
    fi
    
    echo
    echo "Switch Protection:"
    local current_time
    current_time=$(date +%s)
    if [ $last_switch_time -gt 0 ]; then
        local time_since_switch=$((current_time - last_switch_time))
        if [ $time_since_switch -lt $SWITCH_COOLDOWN ]; then
            local remaining=$((SWITCH_COOLDOWN - time_since_switch))
            echo -e "  Cooldown: ${YELLOW}${remaining}s remaining${NC}"
        else
            echo -e "  Cooldown: ${GREEN}Ready${NC}"
        fi
    else
        echo -e "  Cooldown: ${GREEN}Ready (never switched)${NC}"
    fi
    
    echo
    echo "Monitor Status:"
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if ps -p "$pid" &>/dev/null; then
            echo -e "  Service: ${GREEN}RUNNING${NC} (PID: $pid)"
            echo -e "  Interval: ${CYAN}${CHECK_INTERVAL}s${NC}"
            echo -e "  Mode: ${CYAN}Zero-downtime updates${NC}"
        else
            echo -e "  Service: ${RED}STOPPED${NC}"
            rm -f "$MONITOR_PID_FILE"
        fi
    else
        echo -e "  Service: ${YELLOW}NOT RUNNING${NC}"
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
        echo "Zero-Downtime Failover Features:"
        echo "  • DNS TTL: ${DNS_TTL} seconds (optimized for failover)"
        echo "  • Cloudflare Proxy: Disabled (required for IP failover)"
        echo "  • Update Method: PATCH API (no record deletion)"
        echo "  • Switch Cooldown: ${SWITCH_COOLDOWN} seconds"
        echo "  • Health Checks: ${CHECK_INTERVAL} second intervals"
        echo
        echo "Note: DNS changes are near-instant with Cloudflare."
        echo "No downtime during failover operations."
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
    local cname_record_id
    cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    # Delete records if they exist
    if [ -n "$cname_record_id" ]; then
        log "Deleting CNAME record: ${cname_record_id:0:8}..." "INFO"
        cf_api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$cname_record_id" >/dev/null 2>&1 || true
    fi
    
    if [ -n "$primary_record" ]; then
        log "Deleting Primary A record: ${primary_record:0:8}..." "INFO"
        cf_api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$primary_record" >/dev/null 2>&1 || true
    fi
    
    if [ -n "$backup_record" ]; then
        log "Deleting Backup A record: ${backup_record:0:8}..." "INFO"
        cf_api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$backup_record" >/dev/null 2>&1 || true
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
    echo "║    CLOUDFLARE AUTO-FAILOVER MANAGER v3.2      ║"
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
    local cname_record_id
    cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    if [ -z "$cname" ] || [ -z "$cname_record_id" ]; then
        log "No setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    local primary_host
    primary_host=$(echo "$state" | jq -r '.primary_host // empty')
    local backup_host
    backup_host=$(echo "$state" | jq -r '.backup_host // empty')
    
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
    echo "3. Test both IPs (detailed)"
    echo "4. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log "Manually switching to Primary IP..." "INFO"
            if update_dns_record "$cname_record_id" "$cname" "$primary_host"; then
                update_state "active_ip" "$primary_ip"
                update_state "active_host" "$primary_host"
                update_state "current_state" "primary_active"
                update_state "last_switch_time" "$(date +%s)"
                log "Manually switched to Primary IP ($primary_ip)" "SUCCESS"
            fi
            ;;
        2)
            log "Manually switching to Backup IP..." "INFO"
            if update_dns_record "$cname_record_id" "$cname" "$backup_host"; then
                update_state "active_ip" "$backup_ip"
                update_state "active_host" "$backup_host"
                update_state "current_state" "backup_active"
                update_state "last_switch_time" "$(date +%s)"
                log "Manually switched to Backup IP ($backup_ip)" "SUCCESS"
            fi
            ;;
        3)
            echo
            echo "Testing IP connectivity:"
            echo "------------------------"
            
            # Test primary
            echo -n "Primary IP ($primary_ip): "
            local primary_check
            primary_check=$(check_ip_health_detailed "$primary_ip")
            local primary_loss
            primary_loss=$(echo "$primary_check" | awk '{print $1}')
            local primary_rtt
            primary_rtt=$(echo "$primary_check" | awk '{print $2}')
            
            if (( primary_loss >= HARD_DOWN_LOSS )); then
                echo -e "${RED}✗ DOWN (loss=${primary_loss}%, rtt=${primary_rtt}ms)${NC}"
            elif (( primary_loss >= DEGRADED_LOSS || primary_rtt >= DEGRADED_RTT )); then
                echo -e "${YELLOW}⚠ DEGRADED (loss=${primary_loss}%, rtt=${primary_rtt}ms)${NC}"
            else
                echo -e "${GREEN}✓ HEALTHY (loss=${primary_loss}%, rtt=${primary_rtt}ms)${NC}"
            fi
            
            # Test backup
            echo -n "Backup IP ($backup_ip): "
            local backup_check
            backup_check=$(check_ip_health_detailed "$backup_ip")
            local backup_loss
            backup_loss=$(echo "$backup_check" | awk '{print $1}')
            local backup_rtt
            backup_rtt=$(echo "$backup_check" | awk '{print $2}')
            
            if (( backup_loss >= HARD_DOWN_LOSS )); then
                echo -e "${RED}✗ DOWN (loss=${backup_loss}%, rtt=${backup_rtt}ms)${NC}"
            elif (( backup_loss >= DEGRADED_LOSS || backup_rtt >= DEGRADED_RTT )); then
                echo -e "${YELLOW}⚠ DEGRADED (loss=${backup_loss}%, rtt=${backup_rtt}ms)${NC}"
            else
                echo -e "${GREEN}✓ HEALTHY (loss=${backup_loss}%, rtt=${backup_rtt}ms)${NC}"
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
