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

# =============================================
# MONITORING PARAMETERS (TUNABLE - MATCHING SCRIPT 1)
# =============================================

CHECK_INTERVAL=2          # Check every 2 seconds (like script 1)
PING_COUNT=3              # 3 pings per check (like script 1)
PING_TIMEOUT=1            # 1 second timeout per ping (like script 1)

# When is a server considered DOWN?
HARD_DOWN_LOSS=90         # >= 90% loss = DOWN (like script 1)

# When to switch to backup (degraded condition)
DEGRADED_LOSS=40          # >= 40% loss = degraded (like script 1)
DEGRADED_RTT=300          # >= 300ms RTT = degraded (like script 1)
BAD_STREAK_LIMIT=3        # 3 consecutive degraded checks before switching (like script 1)

# When to switch back to primary (recovery condition)
PRIMARY_OK_LOSS=50        # loss <= 50% (like script 1)
PRIMARY_OK_RTT=450        # RTT <= 450ms (like script 1)
PRIMARY_STABLE_ROUNDS=3   # 3 consecutive good checks (6 seconds total) (like script 1)

# Failure thresholds (calculated based on CHECK_INTERVAL)
FAILURE_THRESHOLD=2       # 2 failures before failover (4 seconds total)
RECOVERY_THRESHOLD=3      # 3 good checks before recovery (6 seconds total)

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
# HEALTH CHECK FUNCTIONS (LIKE SCRIPT 1)
# =============================================

check_ip_health_detailed() {
    local ip="$1"
    
    local ping_output
    local loss=100
    local rtt=1000
    
    ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>/dev/null)
    
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
    else
        # Ping failed
        loss=100
        rtt=1000
    fi
    
    echo "$loss $rtt"
}

compute_score() {
    local loss="$1"
    local rtt="$2"
    # Lower score = better (like script 1)
    echo $(( loss * 100 + rtt ))
}

check_ip_basic() {
    local ip="$1"
    
    # Simple check for basic connectivity
    if ping -c 1 -W 1 "$ip" &>/dev/null; then
        return 0
    fi
    
    # Fallback: try curl on port 80
    if curl -s --max-time 2 "http://$ip" &>/dev/null; then
        return 0
    fi
    
    # Try netcat on port 80
    if command -v nc &>/dev/null; then
        if nc -z -w 1 "$ip" 80 &>/dev/null; then
            return 0
        fi
    fi
    
    return 1
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
    echo "Auto-Failover Settings (like Script 1):"
    echo "  Check interval: ${CHECK_INTERVAL} seconds"
    echo "  Ping count: ${PING_COUNT} per check"
    echo "  Degraded threshold: ${DEGRADED_LOSS}% loss or ${DEGRADED_RTT}ms RTT"
    echo "  Hard down threshold: ${HARD_DOWN_LOSS}% loss"
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
# ENHANCED MONITORING FUNCTIONS (LIKE SCRIPT 1)
# =============================================

perform_failover() {
    local cname="$1"
    local backup_host="$2"
    local primary_ip="$3"
    local backup_ip="$4"
    
    log "Primary IP ($primary_ip) is down! Initiating failover..." "WARNING"
    log "Switching CNAME to backup: $cname → $backup_host" "INFO"
    
    if update_cname_target "$cname" "$backup_host"; then
        log "Failover completed! Now using Backup IP ($backup_ip)" "SUCCESS"
        return 0
    else
        log "Failed to perform failover" "ERROR"
        return 1
    fi
}

perform_recovery() {
    local cname="$1"
    local primary_host="$2"
    local primary_ip="$3"
    local backup_ip="$4"
    
    log "Primary IP ($primary_ip) is healthy again! Switching back..." "INFO"
    log "Switching CNAME to primary: $cname → $primary_host" "INFO"
    
    if update_cname_target "$cname" "$primary_host"; then
        log "Recovery completed! Now using Primary IP ($primary_ip)" "SUCCESS"
        return 0
    else
        log "Failed to perform recovery" "ERROR"
        return 1
    fi
}

monitor_service_enhanced() {
    log "Starting enhanced auto-monitor service (like Script 1)..." "INFO"
    log "Monitoring interval: ${CHECK_INTERVAL} seconds" "INFO"
    
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
    
    if [ -z "$cname" ]; then
        log "No setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Enhanced monitor service started (PID: $$)" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    
    # Trap signals
    trap 'log "Monitor service stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    # State variables (like script 1)
    local CURRENT_IP="$primary_ip"
    local CURRENT_BAD_STREAK=0
    local PRIMARY_GOOD_STREAK=0
    local FAILURE_COUNT=0
    local RECOVERY_COUNT=0
    
    # Main monitoring loop
    while true; do
        # Check primary IP health with detailed metrics (like script 1)
        local primary_check
        primary_check=$(check_ip_health_detailed "$primary_ip")
        local primary_loss
        primary_loss=$(echo "$primary_check" | awk '{print $1}')
        local primary_rtt
        primary_rtt=$(echo "$primary_check" | awk '{print $2}')
        local primary_score
        primary_score=$(compute_score "$primary_loss" "$primary_rtt")
        
        # Check backup IP health with detailed metrics (like script 1)
        local backup_check
        backup_check=$(check_ip_health_detailed "$backup_ip")
        local backup_loss
        backup_loss=$(echo "$backup_check" | awk '{print $1}')
        local backup_rtt
        backup_rtt=$(echo "$backup_check" | awk '{print $2}')
        local backup_score
        backup_score=$(compute_score "$backup_loss" "$backup_rtt")
        
        # Log health status
        log "Primary: loss=${primary_loss}% rtt=${primary_rtt}ms score=$primary_score | Backup: loss=${backup_loss}% rtt=${backup_rtt}ms score=$backup_score" "INFO"
        
        # Track primary stability (برای برگشت روی سرور اصلی - like script 1)
        if (( primary_loss <= PRIMARY_OK_LOSS && primary_rtt <= PRIMARY_OK_RTT )); then
            PRIMARY_GOOD_STREAK=$((PRIMARY_GOOD_STREAK + 1))
            log "Primary good streak: $PRIMARY_GOOD_STREAK/$PRIMARY_STABLE_ROUNDS" "INFO"
        else
            PRIMARY_GOOD_STREAK=0
        fi
        
        # Track current degradation (برای رفتن روی بکاپ - like script 1)
        if [[ "$CURRENT_IP" == "$primary_ip" ]]; then
            if (( primary_loss >= DEGRADED_LOSS || primary_rtt >= DEGRADED_RTT )); then
                CURRENT_BAD_STREAK=$((CURRENT_BAD_STREAK + 1))
                log "Primary degraded streak: $CURRENT_BAD_STREAK/$BAD_STREAK_LIMIT" "WARNING"
            else
                CURRENT_BAD_STREAK=0
            fi
        fi
        
        # تصمیم‌گیری (decision making) - منطق مشابه اسکریپت اول
        # Case 1: Currently on PRIMARY
        if [[ "$CURRENT_IP" == "$primary_ip" ]]; then
            
            # 1a) Primary is completely DOWN (like script 1: HARD_DOWN_LOSS=90)
            if (( primary_loss >= HARD_DOWN_LOSS )); then
                FAILURE_COUNT=$((FAILURE_COUNT + 1))
                log "Primary is DOWN! Failure count: $FAILURE_COUNT/$FAILURE_THRESHOLD" "WARNING"
                
                if (( FAILURE_COUNT >= FAILURE_THRESHOLD )); then
                    # Switch to backup (like script 1)
                    log "Primary is effectively DOWN (loss=${primary_loss}%). Switching to backup..." "WARNING"
                    if update_cname_target "$cname" "$backup_host"; then
                        CURRENT_IP="$backup_ip"
                        CURRENT_BAD_STREAK=0
                        FAILURE_COUNT=0
                        log "Switched to Backup IP ($backup_ip)" "SUCCESS"
                        update_state "active_ip" "$backup_ip"
                    fi
                fi
            
            # 1b) Primary is degraded but not completely DOWN (like script 1)
            elif (( CURRENT_BAD_STREAK >= BAD_STREAK_LIMIT )); then
                log "Primary degraded for $CURRENT_BAD_STREAK checks. Checking backup..." "WARNING"
                
                # Check if backup is healthy enough (like script 1)
                if (( backup_loss < HARD_DOWN_LOSS )); then
                    log "Backup is healthy. Switching from degraded primary to backup." "INFO"
                    if update_cname_target "$cname" "$backup_host"; then
                        CURRENT_IP="$backup_ip"
                        CURRENT_BAD_STREAK=0
                        log "Switched to Backup IP ($backup_ip)" "SUCCESS"
                        update_state "active_ip" "$backup_ip"
                    fi
                fi
            
            # 1c) Primary is healthy
            else
                FAILURE_COUNT=0
                CURRENT_BAD_STREAK=0
            fi
        
        # Case 2: Currently on BACKUP
        else
            # 2a) Check if we should switch back to primary (like script 1)
            if (( PRIMARY_GOOD_STREAK >= PRIMARY_STABLE_ROUNDS )); then
                log "Primary has been stable for ${PRIMARY_GOOD_STREAK} checks. Switching back to primary." "INFO"
                if update_cname_target "$cname" "$primary_host"; then
                    CURRENT_IP="$primary_ip"
                    PRIMARY_GOOD_STREAK=0
                    RECOVERY_COUNT=0
                    log "Switched back to Primary IP ($primary_ip)" "SUCCESS"
                    update_state "active_ip" "$primary_ip"
                fi
            
            # 2b) Primary is improving but not stable yet (like script 1)
            elif (( primary_loss < HARD_DOWN_LOSS )); then
                RECOVERY_COUNT=$((RECOVERY_COUNT + 1))
                log "Primary is recovering. Recovery count: $RECOVERY_COUNT/$RECOVERY_THRESHOLD" "INFO"
            else
                RECOVERY_COUNT=0
            fi
            
            # 2c) Check if backup itself is DOWN (like script 1)
            if (( backup_loss >= HARD_DOWN_LOSS )); then
                log "Backup is DOWN while active! Checking primary..." "ERROR"
                
                # If primary is somewhat reachable, switch back (like script 1)
                if (( primary_loss < HARD_DOWN_LOSS )); then
                    log "Primary is reachable. Switching back from failed backup." "WARNING"
                    if update_cname_target "$cname" "$primary_host"; then
                        CURRENT_IP="$primary_ip"
                        log "Switched back to Primary IP ($primary_ip)" "SUCCESS"
                        update_state "active_ip" "$primary_ip"
                    fi
                fi
            fi
        fi
        
        # Update state file
        update_state "failure_count" "$FAILURE_COUNT"
        update_state "recovery_count" "$RECOVERY_COUNT"
        
        # Sleep before next check (like script 1: SLEEP_INTERVAL=2)
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
    
    # Start enhanced monitor in background
    monitor_service_enhanced &
    
    log "Enhanced monitor service started in background" "SUCCESS"
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
    echo "           CURRENT STATUS (LIKE SCRIPT 1)"
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
    echo "Monitor Counters (like Script 1):"
    echo "  Failures: $failure_count/$FAILURE_THRESHOLD"
    echo "  Recovery: $recovery_count/$RECOVERY_THRESHOLD"
    echo
    
    # Check detailed health
    echo "Detailed Health Check (like Script 1):"
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
    
    echo "  Primary ($primary_ip):"
    echo -n "    Loss: "
    if (( primary_loss >= HARD_DOWN_LOSS )); then
        echo -e "${RED}${primary_loss}% (DOWN)${NC}"
    elif (( primary_loss >= DEGRADED_LOSS )); then
        echo -e "${YELLOW}${primary_loss}% (DEGRADED)${NC}"
    else
        echo -e "${GREEN}${primary_loss}%${NC}"
    fi
    
    echo -n "    RTT: "
    if (( primary_rtt >= DEGRADED_RTT )); then
        echo -e "${YELLOW}${primary_rtt}ms (DEGRADED)${NC}"
    else
        echo -e "${GREEN}${primary_rtt}ms${NC}"
    fi
    
    echo "  Backup ($backup_ip):"
    echo -n "    Loss: "
    if (( backup_loss >= HARD_DOWN_LOSS )); then
        echo -e "${RED}${backup_loss}% (DOWN)${NC}"
    elif (( backup_loss >= DEGRADED_LOSS )); then
        echo -e "${YELLOW}${backup_loss}% (DEGRADED)${NC}"
    else
        echo -e "${GREEN}${backup_loss}%${NC}"
    fi
    
    echo -n "    RTT: "
    if (( backup_rtt >= DEGRADED_RTT )); then
        echo -e "${YELLOW}${backup_rtt}ms (DEGRADED)${NC}"
    else
        echo -e "${GREEN}${backup_rtt}ms${NC}"
    fi
    
    echo
    echo "Monitor Status:"
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if ps -p "$pid" &>/dev/null; then
            echo -e "  Service: ${GREEN}RUNNING${NC} (PID: $pid)"
            echo -e "  Interval: ${CYAN}${CHECK_INTERVAL}s${NC}"
            echo -e "  Mode: ${CYAN}Enhanced (like Script 1)${NC}"
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
        echo "Auto-failover Settings (matching Script 1):"
        echo "  1. Check Primary IP every ${CHECK_INTERVAL} seconds"
        echo "  2. Use ${PING_COUNT} pings per check"
        echo "  3. Switch to Backup if:"
        echo "     - Loss ≥ ${HARD_DOWN_LOSS}% for ${FAILURE_THRESHOLD} checks ($((CHECK_INTERVAL * FAILURE_THRESHOLD))s)"
        echo "     OR"
        echo "     - Loss ≥ ${DEGRADED_LOSS}% or RTT ≥ ${DEGRADED_RTT}ms for ${BAD_STREAK_LIMIT} consecutive checks"
        echo "  4. Switch back to Primary if:"
        echo "     - Loss ≤ ${PRIMARY_OK_LOSS}% and RTT ≤ ${PRIMARY_OK_RTT}ms for ${PRIMARY_STABLE_ROUNDS} consecutive checks"
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
    echo "3. Test both IPs (detailed - like Script 1)"
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
            echo "Testing IP connectivity (like Script 1):"
            echo "----------------------------------------"
            
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
