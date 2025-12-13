#!/bin/bash

# =============================================
# SMART FAILOVER - PING BASED
# =============================================

set -euo pipefail

# Configuration
CONFIG_DIR="$HOME/.smart-failover"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$STATE_FILE"
LOG_FILE="$CONFIG_DIR/failover.log"
PID_FILE="$CONFIG_DIR/monitor.pid"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Failover Settings
CHECK_INTERVAL=10           # هر 10 ثانیه چک کن (نه 2 ثانیه)
DOWN_TIMEOUT=60             # 1 دقیقه down بودن قبل از سوئیچ
STABLE_TIME=60              # 1 دقیقه stable بودن قبل از بازگشت
PING_COUNT=3                # 3 پینگ برای اطمینان
PING_TIMEOUT=2              # 2 ثانیه timeout

# State
CURRENT_IP=""
CNAME=""
CNAME_RECORD_ID=""
PRIMARY_HOST=""
BACKUP_HOST=""
PRIMARY_IP=""
BACKUP_IP=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================
# LOGGING
# =============================================

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "ERROR") echo -e "${RED}[$timestamp] $msg${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] $msg${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] $msg${NC}" ;;
        *) echo "[$timestamp] $msg" ;;
    esac
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# =============================================
# BASIC FUNCTIONS
# =============================================

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

check_prerequisites() {
    local missing=0
    
    if ! command -v curl &>/dev/null; then
        echo "Please install curl"
        missing=1
    fi
    
    if ! command -v jq &>/dev/null; then
        echo "Please install jq"
        missing=1
    fi
    
    if ! command -v ping &>/dev/null; then
        echo "Please install ping"
        missing=1
    fi
    
    [ $missing -eq 1 ] && exit 1
}

# =============================================
# CONFIGURATION
# =============================================

save_config() {
    cat > "$CONFIG_FILE" << EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_HOST="$BASE_HOST"
PRIMARY_IP="$PRIMARY_IP"
BACKUP_IP="$BACKUP_IP"
CNAME="$CNAME"
PRIMARY_HOST="$PRIMARY_HOST"
BACKUP_HOST="$BACKUP_HOST"
CNAME_RECORD_ID="$CNAME_RECORD_ID"
EOF
    log "Configuration saved" "SUCCESS"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        CURRENT_IP="$PRIMARY_IP"
        return 0
    fi
    return 1
}

# =============================================
# CLOUDFLARE API
# =============================================

cf_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            --data "$data" 2>/dev/null || echo '{"success":false}'
    else
        curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            2>/dev/null || echo '{"success":false}'
    fi
}

# =============================================
# PING CHECK (ساده و قابل اطمینان)
# =============================================

check_ping() {
    local ip="$1"
    
    # 3 پینگ با timeout 2 ثانیه
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" &>/dev/null; then
        echo "success"
    else
        echo "failed"
    fi
}

# =============================================
# FAILOVER FUNCTIONS
# =============================================

switch_to_backup() {
    log "Switching to backup IP: $BACKUP_IP" "INFO"
    
    local data
    data=$(cat << EOF
{
  "content": "$BACKUP_HOST"
}
EOF
)
    
    local response
    response=$(cf_request "PATCH" "/zones/${CF_ZONE_ID}/dns_records/$CNAME_RECORD_ID" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        CURRENT_IP="$BACKUP_IP"
        save_config
        log "Switched to backup successfully" "SUCCESS"
        return 0
    else
        log "Failed to switch to backup" "ERROR"
        return 1
    fi
}

switch_to_primary() {
    log "Switching back to primary IP: $PRIMARY_IP" "INFO"
    
    local data
    data=$(cat << EOF
{
  "content": "$PRIMARY_HOST"
}
EOF
)
    
    local response
    response=$(cf_request "PATCH" "/zones/${CF_ZONE_ID}/dns_records/$CNAME_RECORD_ID" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        CURRENT_IP="$PRIMARY_IP"
        save_config
        log "Switched back to primary successfully" "SUCCESS"
        return 0
    else
        log "Failed to switch to primary" "ERROR"
        return 1
    fi
}

# =============================================
# MONITORING (هوشمند و ساده)
# =============================================

monitor() {
    log "Starting smart failover monitor" "INFO"
    log "Primary IP: $PRIMARY_IP" "INFO"
    log "Backup IP: $BACKUP_IP" "INFO"
    log "Check interval: ${CHECK_INTERVAL}s" "INFO"
    log "Down timeout: ${DOWN_TIMEOUT}s" "INFO"
    log "Stable time: ${STABLE_TIME}s" "INFO"
    
    local primary_down_counter=0
    local primary_stable_counter=0
    local is_on_backup=false
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    # Main loop
    while true; do
        # Check primary IP
        local ping_result
        ping_result=$(check_ping "$PRIMARY_IP")
        
        if [ "$ping_result" = "success" ]; then
            # Primary is up
            primary_down_counter=0
            
            if [ "$is_on_backup" = true ]; then
                # روی backup هستیم، primary دوباره up شده
                primary_stable_counter=$((primary_stable_counter + CHECK_INTERVAL))
                log "Primary is up. Stable for: ${primary_stable_counter}/${STABLE_TIME}s" "INFO"
                
                if [ $primary_stable_counter -ge $STABLE_TIME ]; then
                    # 1 دقیقه stable بوده، برگرد به primary
                    if switch_to_primary; then
                        is_on_backup=false
                        primary_stable_counter=0
                        log "Returned to primary after $STABLE_TIME seconds of stability" "SUCCESS"
                    fi
                fi
            else
                # روی primary هستیم، همه چیز خوبه
                primary_stable_counter=0
            fi
            
        else
            # Primary is down
            primary_stable_counter=0
            
            if [ "$is_on_backup" = false ]; then
                # روی primary هستیم ولی down شده
                primary_down_counter=$((primary_down_counter + CHECK_INTERVAL))
                log "Primary is down. Down time: ${primary_down_counter}/${DOWN_TIMEOUT}s" "WARNING"
                
                if [ $primary_down_counter -ge $DOWN_TIMEOUT ]; then
                    # 1 دقیته down بوده، برو به backup
                    if switch_to_backup; then
                        is_on_backup=true
                        primary_down_counter=0
                        log "Switched to backup after $DOWN_TIMEOUT seconds of downtime" "WARNING"
                    fi
                fi
            else
                # از قبل روی backup هستیم
                log "Primary still down, staying on backup" "INFO"
            fi
        fi
        
        # Sleep before next check
        sleep "$CHECK_INTERVAL"
    done
}

start_monitor() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            log "Monitor is already running (PID: $pid)" "INFO"
            return 0
        fi
    fi
    
    # Start in background
    monitor &
    
    log "Monitor started in background" "SUCCESS"
    log "To stop: $0 --stop" "INFO"
}

stop_monitor() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        
        if kill "$pid" 2>/dev/null; then
            log "Monitor stopped (PID: $pid)" "SUCCESS"
        else
            log "Monitor was not running" "INFO"
        fi
        
        rm -f "$PID_FILE"
    else
        log "Monitor is not running" "INFO"
    fi
}

# =============================================
# SETUP
# =============================================

setup() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          SMART FAILOVER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    
    # Get API credentials
    read -rp "Cloudflare API Token: " CF_API_TOKEN
    read -rp "Zone ID: " CF_ZONE_ID
    read -rp "Base Domain (example.com): " BASE_HOST
    
    # Get IPs
    while true; do
        read -rp "Primary IP (main server): " PRIMARY_IP
        if [[ "$PRIMARY_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        echo "Invalid IP address"
    done
    
    while true; do
        read -rp "Backup IP (failover server): " BACKUP_IP
        if [[ "$BACKUP_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            if [ "$PRIMARY_IP" != "$BACKUP_IP" ]; then
                break
            fi
            echo "Primary and backup IPs must be different"
        else
            echo "Invalid IP address"
        fi
    done
    
    # Generate unique names
    local timestamp
    timestamp=$(date +%s)
    CNAME="smart-${timestamp}.${BASE_HOST}"
    PRIMARY_HOST="p-${timestamp}.${BASE_HOST}"
    BACKUP_HOST="b-${timestamp}.${BASE_HOST}"
    
    log "Creating DNS records..." "INFO"
    
    # Create A records
    local primary_data
    primary_data=$(cat << EOF
{
  "type": "A",
  "name": "$PRIMARY_HOST",
  "content": "$PRIMARY_IP",
  "ttl": 300,
  "proxied": false
}
EOF
)
    
    local primary_response
    primary_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$primary_data")
    local primary_record_id
    primary_record_id=$(echo "$primary_response" | jq -r '.result.id // empty')
    
    if [ -z "$primary_record_id" ]; then
        log "Failed to create primary A record" "ERROR"
        return 1
    fi
    
    local backup_data
    backup_data=$(cat << EOF
{
  "type": "A",
  "name": "$BACKUP_HOST",
  "content": "$BACKUP_IP",
  "ttl": 300,
  "proxied": false
}
EOF
)
    
    local backup_response
    backup_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$backup_data")
    local backup_record_id
    backup_record_id=$(echo "$backup_response" | jq -r '.result.id // empty')
    
    if [ -z "$backup_record_id" ]; then
        log "Failed to create backup A record" "ERROR"
        return 1
    fi
    
    # Create CNAME
    local cname_data
    cname_data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$CNAME",
  "content": "$PRIMARY_HOST",
  "ttl": 300,
  "proxied": false
}
EOF
)
    
    local cname_response
    cname_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$cname_data")
    CNAME_RECORD_ID=$(echo "$cname_response" | jq -r '.result.id // empty')
    
    if [ -z "$CNAME_RECORD_ID" ]; then
        log "Failed to create CNAME record" "ERROR"
        return 1
    fi
    
    # Save config
    save_config
    
    echo
    echo "════════════════════════════════════════════════"
    log "SETUP COMPLETED!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "Your CNAME: ${GREEN}$CNAME${NC}"
    echo
    echo "Behavior:"
    echo "  1. هر ${CHECK_INTERVAL} ثانیه primary را چک می‌کند"
    echo "  2. اگر primary ${DOWN_TIMEOUT} ثانیه down بود، می‌رود روی backup"
    echo "  3. روی backup می‌ماند تا primary ${STABLE_TIME} ثانیه stable شود"
    echo "  4. سپس برمی‌گردد روی primary"
    echo
    echo "To start monitoring:"
    echo "  $0 --start"
    echo
}

# =============================================
# STATUS
# =============================================

show_status() {
    if ! load_config; then
        log "No configuration found" "ERROR"
        return 1
    fi
    
    echo
    echo "════════════════════════════════════════════════"
    echo "          SMART FAILOVER STATUS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$CNAME${NC}"
    echo
    echo "IP Addresses:"
    echo "  Primary: $PRIMARY_IP"
    echo "  Backup:  $BACKUP_IP"
    echo
    echo "Current Status:"
    
    # Check current IP
    local ping_result
    ping_result=$(check_ping "$PRIMARY_IP")
    
    if [ "$ping_result" = "success" ]; then
        echo -e "  Primary: ${GREEN}UP${NC}"
    else
        echo -e "  Primary: ${RED}DOWN${NC}"
    fi
    
    ping_result=$(check_ping "$BACKUP_IP")
    if [ "$ping_result" = "success" ]; then
        echo -e "  Backup:  ${GREEN}UP${NC}"
    else
        echo -e "  Backup:  ${RED}DOWN${NC}"
    fi
    
    echo
    echo "Monitor Status:"
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            echo -e "  ${GREEN}ACTIVE${NC}"
        else
            echo -e "  ${RED}INACTIVE${NC}"
            rm -f "$PID_FILE"
        fi
    else
        echo -e "  ${YELLOW}NOT RUNNING${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

# =============================================
# MAIN
# =============================================

main() {
    ensure_dir
    check_prerequisites
    
    case "${1:-}" in
        "--setup")
            setup
            ;;
        "--start")
            load_config
            start_monitor
            ;;
        "--stop")
            stop_monitor
            ;;
        "--status")
            load_config
            show_status
            ;;
        "--log")
            if [ -f "$LOG_FILE" ]; then
                tail -20 "$LOG_FILE"
            else
                echo "No log file found"
            fi
            ;;
        *)
            echo "Usage: $0 [COMMAND]"
            echo
            echo "Commands:"
            echo "  --setup    Create failover setup"
            echo "  --start    Start monitoring"
            echo "  --stop     Stop monitoring"
            echo "  --status   Show current status"
            echo "  --log      Show recent logs"
            echo
            echo "Example:"
            echo "  $0 --setup   # First time setup"
            echo "  $0 --start   # Start auto-failover"
            echo "  $0 --status  # Check status"
            ;;
    esac
}

main "$@"
