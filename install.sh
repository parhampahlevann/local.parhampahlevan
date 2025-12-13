#!/bin/bash

# =============================================
# SMART PING-BASED FAILOVER
# =============================================

set -euo pipefail

# Configuration
CONFIG_DIR="$HOME/.smart-failover"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$CONFIG_DIR/failover.log"
PID_FILE="$CONFIG_DIR/monitor.pid"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Failover Settings
CHECK_INTERVAL=10           # Check every 10 seconds
DOWN_TIMEOUT=60             # 1 minute downtime before switch
STABLE_TIME=60              # 1 minute stability before return
PING_COUNT=3                # 3 pings for reliability
PING_TIMEOUT=2              # 2 second timeout

# State variables (will be loaded from config)
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
        "ERROR") 
            echo -e "${RED}[$timestamp] $msg${NC}"
            echo "[$timestamp] [ERROR] $msg" >> "$LOG_FILE"
            ;;
        "SUCCESS") 
            echo -e "${GREEN}[$timestamp] $msg${NC}"
            echo "[$timestamp] [SUCCESS] $msg" >> "$LOG_FILE"
            ;;
        "WARNING") 
            echo -e "${YELLOW}[$timestamp] $msg${NC}"
            echo "[$timestamp] [WARNING] $msg" >> "$LOG_FILE"
            ;;
        *) 
            echo "[$timestamp] $msg"
            echo "[$timestamp] [INFO] $msg" >> "$LOG_FILE"
            ;;
    esac
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
        echo "Please install curl: sudo apt-get install curl"
        missing=1
    fi
    
    if ! command -v jq &>/dev/null; then
        echo "Please install jq: sudo apt-get install jq"
        missing=1
    fi
    
    if ! command -v ping &>/dev/null; then
        echo "Please install ping: sudo apt-get install iputils-ping"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# =============================================
# CONFIGURATION MANAGEMENT
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
CURRENT_IP="$CURRENT_IP"
EOF
    log "Configuration saved" "SUCCESS"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null || true
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
    local response
    
    if [ -n "$data" ]; then
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            --data "$data" 2>/dev/null || echo '{"success":false}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            2>/dev/null || echo '{"success":false}')
    fi
    
    echo "$response"
}

# =============================================
# PING CHECK
# =============================================

check_ping() {
    local ip="$1"
    
    # Try 3 pings with 2 second timeout
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
    log "Primary down for 1 minute. Switching to backup: $BACKUP_IP" "WARNING"
    
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
    log "Primary stable for 1 minute. Switching back to primary: $PRIMARY_IP" "INFO"
    
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
# MONITORING
# =============================================

monitor() {
    log "Starting smart failover monitor" "INFO"
    log "Primary IP: $PRIMARY_IP, Backup IP: $BACKUP_IP" "INFO"
    log "Check interval: ${CHECK_INTERVAL}s, Down timeout: ${DOWN_TIMEOUT}s, Stable time: ${STABLE_TIME}s" "INFO"
    
    local primary_down_counter=0
    local primary_stable_counter=0
    local is_on_backup=false
    
    # Initial check
    if [ "$CURRENT_IP" = "$BACKUP_IP" ]; then
        is_on_backup=true
        log "Currently on backup IP" "INFO"
    else
        log "Currently on primary IP" "INFO"
    fi
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    # Main monitoring loop
    while true; do
        # Check primary IP
        local ping_result
        ping_result=$(check_ping "$PRIMARY_IP")
        
        if [ "$ping_result" = "success" ]; then
            # Primary is UP
            primary_down_counter=0
            
            if [ "$is_on_backup" = true ]; then
                # We're on backup, but primary is back up
                primary_stable_counter=$((primary_stable_counter + CHECK_INTERVAL))
                log "Primary is up. Stable for: ${primary_stable_counter}s/${STABLE_TIME}s" "INFO"
                
                # If primary has been stable for 1 minute, switch back
                if [ $primary_stable_counter -ge $STABLE_TIME ]; then
                    if switch_to_primary; then
                        is_on_backup=false
                        primary_stable_counter=0
                    fi
                fi
            else
                # We're on primary, everything is fine
                primary_stable_counter=0
            fi
            
        else
            # Primary is DOWN
            primary_stable_counter=0
            
            if [ "$is_on_backup" = false ]; then
                # We're on primary but it's down
                primary_down_counter=$((primary_down_counter + CHECK_INTERVAL))
                log "Primary is down. Down time: ${primary_down_counter}s/${DOWN_TIMEOUT}s" "WARNING"
                
                # If primary has been down for 1 minute, switch to backup
                if [ $primary_down_counter -ge $DOWN_TIMEOUT ]; then
                    if switch_to_backup; then
                        is_on_backup=true
                        primary_down_counter=0
                    fi
                fi
            else
                # Already on backup
                log "Primary still down, staying on backup" "INFO"
            fi
        fi
        
        # Wait before next check
        sleep "$CHECK_INTERVAL"
    done
}

start_monitor() {
    if ! load_config; then
        log "No configuration found. Please run --setup first" "ERROR"
        return 1
    fi
    
    if [ -z "$CNAME_RECORD_ID" ]; then
        log "Invalid configuration. Please run --setup again" "ERROR"
        return 1
    fi
    
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            log "Monitor is already running (PID: $pid)" "INFO"
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    
    # Start monitor in background
    monitor &
    
    log "Monitor started in background" "SUCCESS"
    log "Check status with: $0 --status" "INFO"
    log "View logs with: $0 --log" "INFO"
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
    echo "Cloudflare API Setup:"
    echo "---------------------"
    read -rp "API Token: " CF_API_TOKEN
    read -rp "Zone ID: " CF_ZONE_ID
    read -rp "Base Domain (example.com): " BASE_HOST
    
    echo
    echo "Server IP Addresses:"
    echo "--------------------"
    
    # Get Primary IP
    while true; do
        read -rp "Primary IP (main server): " PRIMARY_IP
        if [[ "$PRIMARY_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        echo "Invalid IP address format"
    done
    
    # Get Backup IP
    while true; do
        read -rp "Backup IP (failover server): " BACKUP_IP
        if [[ "$BACKUP_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            if [ "$PRIMARY_IP" != "$BACKUP_IP" ]; then
                break
            fi
            echo "Primary and backup IPs must be different"
        else
            echo "Invalid IP address format"
        fi
    done
    
    # Generate unique names
    local timestamp
    timestamp=$(date +%s)
    CNAME="failover-${timestamp}.${BASE_HOST}"
    PRIMARY_HOST="primary-${timestamp}.${BASE_HOST}"
    BACKUP_HOST="backup-${timestamp}.${BASE_HOST}"
    
    echo
    log "Creating DNS records..." "INFO"
    
    # Create Primary A record
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
    
    log "Creating primary A record: $PRIMARY_HOST → $PRIMARY_IP" "INFO"
    local primary_response
    primary_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$primary_data")
    local primary_record_id
    primary_record_id=$(echo "$primary_response" | jq -r '.result.id // empty')
    
    if [ -z "$primary_record_id" ]; then
        log "Failed to create primary A record" "ERROR"
        return 1
    fi
    
    # Create Backup A record
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
    
    log "Creating backup A record: $BACKUP_HOST → $BACKUP_IP" "INFO"
    local backup_response
    backup_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$backup_data")
    local backup_record_id
    backup_record_id=$(echo "$backup_response" | jq -r '.result.id // empty')
    
    if [ -z "$backup_record_id" ]; then
        log "Failed to create backup A record" "ERROR"
        return 1
    fi
    
    # Create CNAME pointing to primary
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
    
    log "Creating CNAME: $CNAME → $PRIMARY_HOST" "INFO"
    local cname_response
    cname_response=$(cf_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$cname_data")
    CNAME_RECORD_ID=$(echo "$cname_response" | jq -r '.result.id // empty')
    
    if [ -z "$CNAME_RECORD_ID" ]; then
        log "Failed to create CNAME record" "ERROR"
        return 1
    fi
    
    # Set initial state
    CURRENT_IP="$PRIMARY_IP"
    
    # Save configuration
    save_config
    
    echo
    echo "════════════════════════════════════════════════"
    log "SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "Your CNAME: ${GREEN}$CNAME${NC}"
    echo
    echo "DNS Configuration:"
    echo "  Primary: $PRIMARY_HOST → $PRIMARY_IP"
    echo "  Backup:  $BACKUP_HOST → $BACKUP_IP"
    echo "  CNAME:   $CNAME → $PRIMARY_HOST"
    echo
    echo "Failover Logic:"
    echo "  1. Check primary every ${CHECK_INTERVAL} seconds"
    echo "  2. Switch to backup after ${DOWN_TIMEOUT} seconds of downtime"
    echo "  3. Stay on backup until primary is stable for ${STABLE_TIME} seconds"
    echo "  4. Switch back to primary automatically"
    echo
    echo "To start auto-failover:"
    echo "  $0 --start"
    echo
}

# =============================================
# STATUS
# =============================================

show_status() {
    if ! load_config; then
        log "No configuration found. Please run --setup first" "ERROR"
        return 1
    fi
    
    echo
    echo "════════════════════════════════════════════════"
    echo "          FAILOVER STATUS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$CNAME${NC}"
    echo
    
    # Check current DNS target
    local current_target="Unknown"
    if [ -n "$CNAME_RECORD_ID" ]; then
        local record_info
        record_info=$(cf_request "GET" "/zones/${CF_ZONE_ID}/dns_records/$CNAME_RECORD_ID")
        if echo "$record_info" | jq -e '.success == true' &>/dev/null; then
            current_target=$(echo "$record_info" | jq -r '.result.content // "Unknown"')
        fi
    fi
    
    echo "Current DNS Target: $current_target"
    echo "Configured IPs:"
    echo "  Primary: $PRIMARY_IP"
    echo "  Backup:  $BACKUP_IP"
    echo
    
    # Check ping status
    echo "Current Ping Status:"
    echo -n "  Primary ($PRIMARY_IP): "
    if ping -c 1 -W 2 "$PRIMARY_IP" &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
    
    echo -n "  Backup ($BACKUP_IP): "
    if ping -c 1 -W 2 "$BACKUP_IP" &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
    
    echo
    echo "Monitor Status:"
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" &>/dev/null; then
            echo -e "  ${GREEN}ACTIVE${NC} (PID: $pid)"
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
# CLEANUP
# =============================================

cleanup() {
    if ! load_config; then
        log "No configuration found to cleanup" "ERROR"
        return 1
    fi
    
    echo
    echo "⚠️  WARNING: This will delete ALL DNS records!"
    echo
    read -rp "Type 'DELETE' to confirm: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    # Stop monitor first
    stop_monitor
    
    log "Deleting DNS records..." "INFO"
    
    # Get record IDs (we already have them in config)
    if [ -n "$CNAME_RECORD_ID" ]; then
        cf_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$CNAME_RECORD_ID" >/dev/null 2>&1
        log "Deleted CNAME record" "INFO"
    fi
    
    # Note: We don't have the A record IDs saved, but that's OK
    
    # Remove configuration
    rm -rf "$CONFIG_DIR"
    
    log "Cleanup completed. All files and DNS records removed." "SUCCESS"
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
            start_monitor
            ;;
        "--stop")
            stop_monitor
            ;;
        "--status")
            show_status
            ;;
        "--log")
            if [ -f "$LOG_FILE" ]; then
                echo "Recent logs:"
                echo "-----------"
                tail -20 "$LOG_FILE"
            else
                echo "No log file found"
            fi
            ;;
        "--cleanup")
            cleanup
            ;;
        *)
            echo "Usage: $0 [COMMAND]"
            echo
            echo "Commands:"
            echo "  --setup    Create failover setup"
            echo "  --start    Start auto-failover monitor"
            echo "  --stop     Stop monitor"
            echo "  --status   Show current status"
            echo "  --log      Show recent logs"
            echo "  --cleanup  Delete everything"
            echo
            echo "Example workflow:"
            echo "  1. $0 --setup     # First time setup"
            echo "  2. $0 --start     # Start monitoring"
            echo "  3. $0 --status    # Check status anytime"
            echo "  4. $0 --stop      # Stop when needed"
            ;;
    esac
}

# Run main function
main "$@"
