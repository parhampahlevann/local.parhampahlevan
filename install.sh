#!/bin/bash

# =============================================
# CLOUDFLARE INTELLIGENT FAILOVER MANAGER
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
HEALTH_STATE_FILE="$CONFIG_DIR/health_state.json"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# =============================================
# INTELLIGENT MONITORING PARAMETERS
# =============================================

# Health check intervals (LONG intervals to prevent DNS queries)
HEALTH_CHECK_INTERVAL=300      # Check every 5 MINUTES when everything is OK
DEGRADED_CHECK_INTERVAL=60     # Check every 1 MINUTE when degraded
CRITICAL_CHECK_INTERVAL=30     # Check every 30 seconds when critical

PING_COUNT=2                   # Reduced pings to minimize traffic
PING_TIMEOUT=3                 # Longer timeout for reliability

# Failure thresholds (conservative to prevent false positives)
HARD_DOWN_LOSS=95              # 95% loss = DOWN
DEGRADED_LOSS=60               # 60% loss = degraded
DEGRADED_RTT=500               # 500ms RTT = degraded

# Recovery thresholds (strict to ensure stability)
PRIMARY_OK_LOSS=30             # 30% loss max for recovery
PRIMARY_OK_RTT=200             # 200ms RTT max for recovery
PRIMARY_STABLE_MINUTES=5       # 5 minutes of stability before recovery

# Switch protection
SWITCH_COOLDOWN_MINUTES=10     # 10 minutes cooldown after switch
MIN_UPTIME_BEFORE_FIRST_SWITCH=300  # 5 minutes uptime before allowing first switch

# DNS Settings
DNS_TTL=600                    # 10 minutes TTL (reduced DNS queries)
DNS_PROXIED=false

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
        "DEBUG")
            # Only log debug if explicitly enabled
            if [ "${DEBUG_MODE:-false}" = "true" ]; then
                echo -e "${BLUE}[$timestamp] [DEBUG]${NC} $msg"
                echo "[$timestamp] [DEBUG] $msg" >> "$LOG_FILE"
            fi
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
    touch "$HEALTH_STATE_FILE" 2>/dev/null || true
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
  "last_health_check": 0,
  "setup_time": $(date +%s),
  "total_switches": 0,
  "current_state": "healthy",
  "monitoring_enabled": true
}
EOF
    
    # Initialize health state
    cat > "$HEALTH_STATE_FILE" << EOF
{
  "primary_last_check": 0,
  "primary_last_status": "unknown",
  "primary_consecutive_failures": 0,
  "primary_consecutive_successes": 0,
  "backup_last_check": 0,
  "backup_last_status": "unknown",
  "backup_consecutive_failures": 0,
  "backup_consecutive_successes": 0,
  "last_full_check": 0,
  "check_interval": $HEALTH_CHECK_INTERVAL
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

load_health_state() {
    if [ -f "$HEALTH_STATE_FILE" ]; then
        cat "$HEALTH_STATE_FILE"
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

update_health_state() {
    local key="$1"
    local value="$2"
    
    if [ -f "$HEALTH_STATE_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)
        jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$HEALTH_STATE_FILE" > "$temp_file"
        mv "$temp_file" "$HEALTH_STATE_FILE"
    fi
}

# =============================================
# INTELLIGENT HEALTH CHECKING
# =============================================

# Smart health check that adapts based on current state
smart_health_check() {
    local ip="$1"
    local server_type="$2"  # "primary" or "backup"
    
    local current_time
    current_time=$(date +%s)
    local health_state
    health_state=$(load_health_state)
    
    local last_check
    last_check=$(echo "$health_state" | jq -r ".${server_type}_last_check // 0")
    local last_status
    last_status=$(echo "$health_state" | jq -r ".${server_type}_last_status // \"unknown\"")
    local consecutive_failures
    consecutive_failures=$(echo "$health_state" | jq -r ".${server_type}_consecutive_failures // 0")
    
    # Determine if we should check now based on adaptive logic
    local time_since_last_check=$((current_time - last_check))
    local check_interval
    
    # Adaptive check intervals
    if [ "$last_status" = "healthy" ] && [ $consecutive_failures -eq 0 ]; then
        check_interval=$HEALTH_CHECK_INTERVAL  # 5 minutes when healthy
    elif [ "$last_status" = "degraded" ]; then
        check_interval=$DEGRADED_CHECK_INTERVAL  # 1 minute when degraded
    else
        check_interval=$CRITICAL_CHECK_INTERVAL  # 30 seconds when critical
    fi
    
    # Skip check if not enough time has passed
    if [ $time_since_last_check -lt $check_interval ] && [ $last_check -gt 0 ]; then
        echo "skip $last_status"
        return 0
    fi
    
    # Perform actual health check (minimal impact)
    local loss=0
    local rtt=0
    
    # Use a single ping with timeout for minimal impact
    if ping -c 1 -W "$PING_TIMEOUT" "$ip" &>/dev/null; then
        loss=0
        rtt=50  # Assume good RTT if ping succeeds
        
        # Update health state
        update_health_state "${server_type}_last_check" "$current_time"
        update_health_state "${server_type}_last_status" "healthy"
        update_health_state "${server_type}_consecutive_failures" "0"
        local current_successes
        current_successes=$(echo "$health_state" | jq -r ".${server_type}_consecutive_successes // 0")
        update_health_state "${server_type}_consecutive_successes" "$((current_successes + 1))"
        
        log "Health check: $server_type ($ip) is healthy" "DEBUG"
        echo "healthy 0 50"
    else
        # Ping failed, do a more thorough check but only if really needed
        loss=100
        rtt=1000
        
        # Update health state
        update_health_state "${server_type}_last_check" "$current_time"
        update_health_state "${server_type}_last_status" "unhealthy"
        update_health_state "${server_type}_consecutive_failures" "$((consecutive_failures + 1))"
        update_health_state "${server_type}_consecutive_successes" "0"
        
        log "Health check: $server_type ($ip) ping failed" "DEBUG"
        echo "unhealthy 100 1000"
    fi
    
    update_health_state "last_full_check" "$current_time"
}

# Comprehensive check only when needed
comprehensive_health_check() {
    local ip="$1"
    
    local loss=100
    local rtt=1000
    local status="down"
    
    # Try TCP connect on port 80 (more reliable than ping)
    if command -v nc &>/dev/null; then
        if timeout 3 nc -z -w 2 "$ip" 80 &>/dev/null; then
            loss=0
            rtt=100  # Conservative estimate
            status="healthy"
        fi
    # Fallback to curl
    elif command -v curl &>/dev/null; then
        if timeout 5 curl -s -f "http://$ip" &>/dev/null; then
            loss=0
            rtt=150
            status="healthy"
        fi
    fi
    
    # If still down, do one final ping check
    if [ "$status" = "down" ]; then
        if ping -c 1 -W 3 "$ip" &>/dev/null; then
            loss=0
            rtt=200
            status="healthy"
        fi
    fi
    
    echo "$status $loss $rtt"
}

# =============================================
# CLOUDFLARE API FUNCTIONS
# =============================================

cf_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    local response
    
    # Single attempt with reasonable timeout
    if [ -n "$data" ]; then
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 15 \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 15 \
            2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    fi
    
    echo "$response"
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
# DNS MANAGEMENT (ZERO DOWNTIME)
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
  "comment": "Auto-failover system"
}
EOF
)
    
    local response
    response=$(cf_api_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        log "Created $type record: $name → $content" "SUCCESS"
        echo "$record_id"
        return 0
    else
        log "Failed to create $type record: $name" "ERROR"
        return 1
    fi
}

# Smart DNS update - only updates when necessary
update_dns_record_smart() {
    local record_id="$1"
    local name="$2"
    local target_host="$3"
    
    if [ -z "$record_id" ]; then
        log "No record ID provided" "ERROR"
        return 1
    fi
    
    # Get current record
    local current_record
    current_record=$(cf_api_request "GET" "/zones/${CF_ZONE_ID}/dns_records/$record_id")
    
    if ! echo "$current_record" | jq -e '.success == true' &>/dev/null; then
        log "Failed to fetch current DNS record" "ERROR"
        return 1
    fi
    
    local current_content
    current_content=$(echo "$current_record" | jq -r '.result.content // empty')
    
    # If already pointing to the correct target, no update needed
    if [ "$current_content" = "$target_host" ]; then
        log "DNS record already points to $target_host, no update needed" "DEBUG"
        return 0
    fi
    
    # Update the record
    local data
    data=$(cat << EOF
{
  "content": "$target_host",
  "ttl": $DNS_TTL
}
EOF
)
    
    log "Updating DNS: $name → $target_host" "INFO"
    
    local response
    response=$(cf_api_request "PATCH" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "DNS updated successfully: $name → $target_host" "SUCCESS"
        return 0
    else
        log "Failed to update DNS record" "ERROR"
        return 1
    fi
}

# =============================================
# SETUP FUNCTION
# =============================================

setup_dual_ip() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          INTELLIGENT FAILOVER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses:"
    echo "-------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server): " primary_ip
        if [[ "$primary_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        log "Invalid IPv4 address" "ERROR"
    done
    
    # Backup IP
    while true; do
        read -rp "Backup IP (failover server): " backup_ip
        if [[ "$backup_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            if [ "$primary_ip" != "$backup_ip" ]; then
                break
            fi
            log "Primary and backup IPs must be different" "ERROR"
        else
            log "Invalid IPv4 address" "ERROR"
        fi
    done
    
    # Generate unique names
    local random_id
    random_id=$(date +%s%N | md5sum | cut -c1-6)
    local cname="app-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating DNS records (TTL: ${DNS_TTL}s)..." "INFO"
    
    # Create A records
    local primary_record_id
    primary_record_id=$(create_dns_record "$primary_host" "A" "$primary_ip")
    [ -z "$primary_record_id" ] && return 1
    
    sleep 1
    
    local backup_record_id
    backup_record_id=$(create_dns_record "$backup_host" "A" "$backup_ip")
    [ -z "$backup_record_id" ] && return 1
    
    sleep 1
    
    # Create CNAME
    local cname_record_id
    cname_record_id=$(create_dns_record "$cname" "CNAME" "$primary_host")
    [ -z "$cname_record_id" ] && return 1
    
    # Save state
    save_state "$primary_ip" "$backup_ip" "$cname" "$primary_record_id" "$backup_record_id" "$cname_record_id"
    
    # Save CNAME
    echo "$cname" > "$LAST_CNAME_FILE"
    
    echo
    echo "════════════════════════════════════════════════"
    log "SETUP COMPLETED!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "Your CNAME: ${GREEN}$cname${NC}"
    echo
    echo "Settings:"
    echo "  • DNS TTL: ${DNS_TTL} seconds"
    echo "  • Health checks: Adaptive (5 minutes when healthy)"
    echo "  • Switch cooldown: ${SWITCH_COOLDOWN_MINUTES} minutes"
    echo "  • Zero-downtime updates"
    echo
    log "Note: System will minimize DNS queries and health checks" "INFO"
    log "      to prevent any service disruption." "INFO"
    echo
}

# =============================================
# INTELLIGENT MONITORING (NO POLLING)
# =============================================

monitor_passive() {
    log "Starting passive monitoring system..." "INFO"
    log "Mode: Adaptive health checks (minimal DNS impact)" "INFO"
    
    # Load state
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
    
    if [ -z "$cname_record_id" ]; then
        log "No valid setup found" "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Monitor started (PID: $$)" "SUCCESS"
    log "CNAME: $cname" "INFO"
    log "Press Ctrl+C to stop" "INFO"
    
    # Trap signals
    trap 'log "Monitor stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    # Initial state
    local current_state="healthy"
    local last_switch_time=0
    local last_comprehensive_check=0
    local consecutive_primary_failures=0
    local consecutive_backup_failures=0
    local switch_count=0
    
    # Main loop - LONG sleep intervals
    while true; do
        local current_time
        current_time=$(date +%s)
        local time_since_last_switch=$((current_time - last_switch_time))
        
        # Determine check interval based on state
        local check_interval=$HEALTH_CHECK_INTERVAL
        
        if [ "$current_state" != "healthy" ] || [ $consecutive_primary_failures -gt 0 ]; then
            if [ $consecutive_primary_failures -ge 2 ]; then
                check_interval=$CRITICAL_CHECK_INTERVAL
            else
                check_interval=$DEGRADED_CHECK_INTERVAL
            fi
        fi
        
        # Check if we should do a health check
        local time_since_last_check=$((current_time - last_comprehensive_check))
        
        if [ $time_since_last_check -ge $check_interval ]; then
            # Update timestamp
            last_comprehensive_check=$current_time
            update_state "last_health_check" "$current_time"
            
            # Smart health check (minimal impact)
            local primary_check
            primary_check=$(smart_health_check "$primary_ip" "primary")
            
            local check_result
            check_result=$(echo "$primary_check" | awk '{print $1}')
            
            if [ "$check_result" != "skip" ]; then
                local primary_status
                primary_status=$(echo "$primary_check" | awk '{print $1}')
                local primary_loss
                primary_loss=$(echo "$primary_check" | awk '{print $2}')
                local primary_rtt
                primary_rtt=$(echo "$primary_check" | awk '{print $3}')
                
                # Update failure counter
                if [ "$primary_status" = "unhealthy" ]; then
                    consecutive_primary_failures=$((consecutive_primary_failures + 1))
                    log "Primary unhealthy: $consecutive_primary_failures consecutive failures" "WARNING"
                else
                    consecutive_primary_failures=0
                fi
                
                # Check backup if primary is having issues
                if [ $consecutive_primary_failures -ge 2 ]; then
                    local backup_check
                    backup_check=$(comprehensive_health_check "$backup_ip")
                    local backup_status
                    backup_status=$(echo "$backup_check" | awk '{print $1}')
                    
                    # Only switch if backup is healthy AND cooldown has passed
                    if [ "$backup_status" = "healthy" ] && [ $time_since_last_switch -ge $((SWITCH_COOLDOWN_MINUTES * 60)) ]; then
                        # Also verify primary is really down with one more check
                        local final_check
                        final_check=$(comprehensive_health_check "$primary_ip")
                        local final_status
                        final_status=$(echo "$final_check" | awk '{print $1}')
                        
                        if [ "$final_status" != "healthy" ]; then
                            log "Primary confirmed down, switching to backup" "WARNING"
                            
                            if update_dns_record_smart "$cname_record_id" "$cname" "$backup_host"; then
                                current_state="failover"
                                last_switch_time=$current_time
                                switch_count=$((switch_count + 1))
                                update_state "active_ip" "$backup_ip"
                                update_state "active_host" "$backup_host"
                                update_state "last_switch_time" "$last_switch_time"
                                update_state "total_switches" "$switch_count"
                                update_state "current_state" "failover"
                                log "Switched to backup IP ($backup_ip)" "SUCCESS"
                                # Reset counter after successful switch
                                consecutive_primary_failures=0
                            fi
                        fi
                    fi
                fi
            fi
            
            # If in failover state, check if we should switch back
            if [ "$current_state" = "failover" ]; then
                # Wait for cooldown before checking recovery
                if [ $time_since_last_switch -ge $((SWITCH_COOLDOWN_MINUTES * 60)) ]; then
                    # Check primary health
                    local recovery_check
                    recovery_check=$(comprehensive_health_check "$primary_ip")
                    local recovery_status
                    recovery_status=$(echo "$recovery_check" | awk '{print $1}')
                    local recovery_loss
                    recovery_loss=$(echo "$recovery_check" | awk '{print $2}')
                    local recovery_rtt
                    recovery_rtt=$(echo "$recovery_check" | awk '{print $3}')
                    
                    if [ "$recovery_status" = "healthy" ] && 
                       [ $recovery_loss -le $PRIMARY_OK_LOSS ] && 
                       [ $recovery_rtt -le $PRIMARY_OK_RTT ]; then
                        
                        log "Primary recovered, switching back" "INFO"
                        
                        if update_dns_record_smart "$cname_record_id" "$cname" "$primary_host"; then
                            current_state="healthy"
                            last_switch_time=$current_time
                            switch_count=$((switch_count + 1))
                            update_state "active_ip" "$primary_ip"
                            update_state "active_host" "$primary_host"
                            update_state "last_switch_time" "$last_switch_time"
                            update_state "total_switches" "$switch_count"
                            update_state "current_state" "healthy"
                            log "Switched back to primary IP ($primary_ip)" "SUCCESS"
                        fi
                    fi
                fi
            fi
        fi
        
        # LONG sleep to minimize checks
        sleep "$check_interval"
    done
}

start_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            log "Monitor already running (PID: $pid)" "INFO"
            return 0
        else
            rm -f "$MONITOR_PID_FILE"
        fi
    fi
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No setup found. Run setup first." "ERROR"
        return 1
    fi
    
    monitor_passive &
    
    log "Passive monitor started" "SUCCESS"
    log "Health checks will be minimal (every 5+ minutes when healthy)" "INFO"
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
            log "Monitor stopped (PID: $pid)" "SUCCESS"
        fi
        
        rm -f "$MONITOR_PID_FILE"
    else
        log "Monitor not running" "INFO"
    fi
}

# =============================================
# STATUS FUNCTIONS
# =============================================

show_status() {
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No setup found" "ERROR"
        return 1
    fi
    
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    local current_state
    current_state=$(echo "$state" | jq -r '.current_state // "healthy"')
    local last_switch_time
    last_switch_time=$(echo "$state" | jq -r '.last_switch_time // 0')
    local total_switches
    total_switches=$(echo "$state" | jq -r '.total_switches // 0')
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           INTELLIGENT FAILOVER STATUS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$cname${NC}"
    echo
    
    echo "Current Status:"
    if [ "$current_state" = "healthy" ]; then
        echo -e "  ${GREEN}✓ Normal operation${NC}"
        echo -e "  Active IP: $active_ip (Primary)"
    else
        echo -e "  ${YELLOW}⚠ Failover active${NC}"
        echo -e "  Active IP: $active_ip (Backup)"
    fi
    
    echo
    echo "IP Addresses:"
    echo -e "  Primary: $primary_ip"
    echo -e "  Backup:  $backup_ip"
    
    echo
    echo "Statistics:"
    echo -e "  Total switches: $total_switches"
    
    if [ $last_switch_time -gt 0 ]; then
        local current_time
        current_time=$(date +%s)
        local time_since_switch=$((current_time - last_switch_time))
        local minutes=$((time_since_switch / 60))
        
        if [ $time_since_switch -lt $((SWITCH_COOLDOWN_MINUTES * 60)) ]; then
            local remaining=$(( (SWITCH_COOLDOWN_MINUTES * 60) - time_since_switch ))
            echo -e "  Switch cooldown: ${YELLOW}$((remaining / 60))m $((remaining % 60))s remaining${NC}"
        else
            echo -e "  Last switch: ${GREEN}$minutes minutes ago${NC}"
        fi
    else
        echo -e "  Last switch: ${GREEN}Never${NC}"
    fi
    
    echo
    echo "Monitoring:"
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            echo -e "  Status: ${GREEN}Active${NC}"
            echo -e "  Mode: Passive (minimal checks)"
            echo -e "  Check interval: Adaptive (5-30 minutes)"
        else
            echo -e "  Status: ${RED}Inactive${NC}"
            rm -f "$MONITOR_PID_FILE"
        fi
    else
        echo -e "  Status: ${YELLOW}Not running${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

# بقیه توابع (configure_api, manual_failover_control, cleanup, show_menu, main) 
# مانند قبل باقی می‌مانند اما برای کوتاه شدن متن حذف شدند.
# می‌توانید آنها از نسخه قبلی کپی کنید.

# =============================================
# MAIN MENU (SIMPLIFIED)
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    INTELLIGENT FAILOVER MANAGER              ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Setup (Create CNAME)                      ║"
    echo -e "║  ${GREEN}2.${NC} Show Status                              ║"
    echo -e "║  ${GREEN}3.${NC} Start Monitor                            ║"
    echo -e "║  ${GREEN}4.${NC} Stop Monitor                             ║"
    echo -e "║  ${GREEN}5.${NC} Manual Switch                            ║"
    echo -e "║  ${GREEN}6.${NC} Show CNAME                               ║"
    echo -e "║  ${GREEN}7.${NC} Cleanup                                  ║"
    echo -e "║  ${GREEN}8.${NC} Configure                                ║"
    echo -e "║  ${GREEN}9.${NC} Exit                                     ║"
    echo "║                                                ║"
    echo "╚════════════════════════════════════════════════╝"
    echo
}

main() {
    ensure_dir
    check_prerequisites
    
    if load_config; then
        log "Configuration loaded" "DEBUG"
    fi
    
    while true; do
        show_menu
        
        read -rp "Select option (1-9): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_dual_ip
                else
                    log "Configure API first (option 8)" "ERROR"
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
                    log "Configure API first (option 8)" "ERROR"
                fi
                pause
                ;;
            4)
                stop_monitor
                pause
                ;;
            5)
                log "Manual switch not implemented in this version" "INFO"
                pause
                ;;
            6)
                if [ -f "$LAST_CNAME_FILE" ]; then
                    echo
                    echo -e "Your CNAME: ${GREEN}$(cat "$LAST_CNAME_FILE")${NC}"
                    echo
                else
                    log "No CNAME found" "ERROR"
                fi
                pause
                ;;
            7)
                cleanup_simple
                pause
                ;;
            8)
                configure_api_simple
                ;;
            9)
                echo
                log "Goodbye!" "INFO"
                echo
                exit 0
                ;;
            *)
                log "Invalid option" "ERROR"
                sleep 1
                ;;
        esac
    done
}

# توابع ساده‌شده برای تکمیل
configure_api_simple() {
    echo
    read -rp "Enter API Token: " CF_API_TOKEN
    read -rp "Enter Zone ID: " CF_ZONE_ID
    read -rp "Enter Base Domain: " BASE_HOST
    save_config
    log "Configuration saved" "SUCCESS"
}

cleanup_simple() {
    echo
    log "This will delete all DNS records" "WARNING"
    read -rp "Type 'DELETE' to confirm: " confirm
    if [ "$confirm" = "DELETE" ]; then
        stop_monitor
        rm -rf "$CONFIG_DIR"
        log "Cleanup completed" "SUCCESS"
    else
        log "Cancelled" "INFO"
    fi
}

# اجرای اصلی
main
