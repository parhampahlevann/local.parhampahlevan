#!/bin/bash

# =============================================
# CLOUDFLARE LOAD BALANCER MANAGER v3.0
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-load-balancer"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
MONITOR_PID_FILE="$CONFIG_DIR/monitor.pid"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Load Balancer Settings
CHECK_INTERVAL=10        # Health check every 10 seconds
MONITOR_INTERVAL=60      # Monitor status every 60 seconds

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
CHECK_INTERVAL="$CHECK_INTERVAL"
MONITOR_INTERVAL="$MONITOR_INTERVAL"
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local lb_name="$1"
    local lb_id="$2"
    local pool_id="$3"
    local monitor_id="$4"
    local primary_ip="$5"
    local backup_ip="$6"
    local fqdn="$7"
    
    cat > "$STATE_FILE" << EOF
{
  "load_balancer_name": "$lb_name",
  "load_balancer_id": "$lb_id",
  "pool_id": "$pool_id",
  "monitor_id": "$monitor_id",
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "fqdn": "$fqdn",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "status": "active"
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
    echo "Required permissions:"
    echo "  - Zone.Load Balancer (Edit)"
    echo "  - Zone.DNS (Edit)"
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
    echo "Example: example.com"
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
# LOAD BALANCER FUNCTIONS
# =============================================

create_origin_pool() {
    local pool_name="$1"
    local primary_ip="$2"
    local backup_ip="$3"
    
    local data
    data=$(cat << EOF
{
  "name": "$pool_name",
  "origins": [
    {
      "name": "primary-server",
      "address": "$primary_ip",
      "enabled": true,
      "weight": 1,
      "healthy": true
    },
    {
      "name": "backup-server",
      "address": "$backup_ip",
      "enabled": true,
      "weight": 1,
      "healthy": true
    }
  ],
  "notification_email": "",
  "enabled": true,
  "monitor": ""
}
EOF
)
    
    local response
    response=$(api_request "POST" "/accounts/${CF_ZONE_ID}/load_balancers/pools" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result.id'
        return 0
    else
        log "Failed to create origin pool" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

create_health_monitor() {
    local monitor_name="$1"
    
    local data
    data=$(cat << EOF
{
  "type": "http",
  "description": "Health monitor for $monitor_name",
  "method": "GET",
  "port": 80,
  "path": "/",
  "timeout": 5,
  "retries": 2,
  "interval": $CHECK_INTERVAL,
  "expected_body": "",
  "expected_codes": "200",
  "follow_redirects": true,
  "allow_insecure": false,
  "header": {},
  "consecutive_up": 2,
  "consecutive_down": 2
}
EOF
)
    
    local response
    response=$(api_request "POST" "/accounts/${CF_ZONE_ID}/load_balancers/monitors" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result.id'
        return 0
    else
        log "Failed to create health monitor" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

create_load_balancer() {
    local lb_name="$1"
    local fqdn="$2"
    local pool_id="$3"
    local monitor_id="$4"
    
    local data
    data=$(cat << EOF
{
  "name": "$lb_name",
  "description": "Load Balancer for $fqdn",
  "enabled": true,
  "ttl": 60,
  "fallback_pool": "$pool_id",
  "default_pools": ["$pool_id"],
  "proxied": false,
  "steering_policy": "off",
  "session_affinity": "none",
  "session_affinity_ttl": 82800,
  "region_pools": {},
  "country_pools": {},
  "pop_pools": {},
  "random_steering": {
    "default_weight": 1
  },
  "adaptive_routing": {
    "failover_across_pools": true
  },
  "location_strategy": {
    "prefer_ecs": "always",
    "mode": "resolver_ip"
  },
  "rules": [],
  "monitor": "$monitor_id"
}
EOF
)
    
    local response
    response=$(api_request "POST" "/zones/${CF_ZONE_ID}/load_balancers" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result.id'
        return 0
    else
        log "Failed to create load balancer" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

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
        log "Failed to create DNS record" "ERROR"
        return 1
    fi
}

# =============================================
# SETUP LOAD BALANCER
# =============================================

setup_load_balancer() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          LOAD BALANCER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses for load balancing:"
    echo "--------------------------------------"
    
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
    local lb_name="lb-${random_id}"
    local pool_name="pool-${random_id}"
    local monitor_name="monitor-${random_id}"
    local fqdn="${lb_name}.${BASE_HOST}"
    
    echo
    log "Creating load balancer components..." "INFO"
    echo
    
    # Step 1: Create health monitor
    log "Creating health monitor..." "INFO"
    local monitor_id
    monitor_id=$(create_health_monitor "$monitor_name")
    if [ -z "$monitor_id" ]; then
        log "Failed to create health monitor" "ERROR"
        return 1
    fi
    log "Health monitor created: $monitor_id" "SUCCESS"
    
    # Step 2: Create origin pool
    log "Creating origin pool..." "INFO"
    local pool_id
    pool_id=$(create_origin_pool "$pool_name" "$primary_ip" "$backup_ip")
    if [ -z "$pool_id" ]; then
        log "Failed to create origin pool" "ERROR"
        # Cleanup monitor
        api_request "DELETE" "/accounts/${CF_ZONE_ID}/load_balancers/monitors/$monitor_id" > /dev/null
        return 1
    fi
    log "Origin pool created: $pool_id" "SUCCESS"
    
    # Step 3: Create load balancer
    log "Creating load balancer..." "INFO"
    local lb_id
    lb_id=$(create_load_balancer "$lb_name" "$fqdn" "$pool_id" "$monitor_id")
    if [ -z "$lb_id" ]; then
        log "Failed to create load balancer" "ERROR"
        # Cleanup
        api_request "DELETE" "/accounts/${CF_ZONE_ID}/load_balancers/pools/$pool_id" > /dev/null
        api_request "DELETE" "/accounts/${CF_ZONE_ID}/load_balancers/monitors/$monitor_id" > /dev/null
        return 1
    fi
    log "Load balancer created: $lb_id" "SUCCESS"
    
    # Step 4: Create DNS record (optional - Load Balancer already creates this)
    log "Creating DNS record..." "INFO"
    local dns_record_id
    dns_record_id=$(create_dns_record "$fqdn" "A" "192.0.2.1")  # Dummy IP, LB will handle it
    if [ -n "$dns_record_id" ]; then
        log "DNS record created" "SUCCESS"
    fi
    
    # Save state
    save_state "$lb_name" "$lb_id" "$pool_id" "$monitor_id" "$primary_ip" "$backup_ip" "$fqdn"
    
    echo
    echo "════════════════════════════════════════════════"
    log "LOAD BALANCER SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo "Your Load Balancer FQDN is:"
    echo -e "  ${GREEN}$fqdn${NC}"
    echo
    echo "Components Created:"
    echo "  Load Balancer: $lb_name ($lb_id)"
    echo "  Origin Pool: $pool_name ($pool_id)"
    echo "  Health Monitor: $monitor_name ($monitor_id)"
    echo
    echo "IP Addresses:"
    echo "  Primary: $primary_ip"
    echo "  Backup:  $backup_ip"
    echo
    echo "Features:"
    echo "  ✓ Zero-downtime failover"
    echo "  ✓ Automatic health checks"
    echo "  ✓ Traffic distribution"
    echo "  ✓ Real-time monitoring"
    echo
    echo "Health Check Settings:"
    echo "  Interval: ${CHECK_INTERVAL} seconds"
    echo "  Timeout: 5 seconds"
    echo "  Retries: 2"
    echo
    echo "How it works:"
    echo "  1. Health monitor checks both servers every ${CHECK_INTERVAL}s"
    echo "  2. If Primary fails, traffic automatically routes to Backup"
    echo "  3. When Primary recovers, traffic automatically shifts back"
    echo "  4. No DNS propagation delays - instant failover"
    echo
    echo "Use $fqdn in your applications"
    echo
}

# =============================================
# MONITORING FUNCTIONS
# =============================================

get_load_balancer_status() {
    local lb_id="$1"
    
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/load_balancers/$lb_id")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response"
        return 0
    else
        echo "{}"
        return 1
    fi
}

get_pool_status() {
    local pool_id="$1"
    
    local response
    response=$(api_request "GET" "/accounts/${CF_ZONE_ID}/load_balancers/pools/$pool_id/health")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response"
        return 0
    else
        echo "{}"
        return 1
    fi
}

monitor_service() {
    log "Starting load balancer monitor..." "INFO"
    log "Monitoring interval: ${MONITOR_INTERVAL} seconds" "INFO"
    
    # Load state
    local state
    state=$(load_state)
    
    local lb_id
    lb_id=$(echo "$state" | jq -r '.load_balancer_id // empty')
    
    if [ -z "$lb_id" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Load balancer monitor started (PID: $$)" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    
    # Trap signals
    trap 'log "Monitor service stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    # Main monitoring loop
    while true; do
        echo
        log "=== Load Balancer Status Check ===" "INFO"
        
        # Get load balancer status
        local lb_status
        lb_status=$(get_load_balancer_status "$lb_id")
        
        if echo "$lb_status" | jq -e '.success == true' &>/dev/null; then
            local lb_name
            lb_name=$(echo "$lb_status" | jq -r '.result.name // "Unknown"')
            local enabled
            enabled=$(echo "$lb_status" | jq -r '.result.enabled // false')
            
            if [ "$enabled" = "true" ]; then
                log "Load Balancer '$lb_name': ${GREEN}ENABLED${NC}" "INFO"
            else
                log "Load Balancer '$lb_name': ${RED}DISABLED${NC}" "WARNING"
            fi
        else
            log "Failed to get load balancer status" "ERROR"
        fi
        
        # Get pool health status
        local pool_id
        pool_id=$(echo "$state" | jq -r '.pool_id // empty')
        
        if [ -n "$pool_id" ]; then
            local pool_health
            pool_health=$(get_pool_status "$pool_id")
            
            if echo "$pool_health" | jq -e '.success == true' &>/dev/null; then
                echo "$pool_health" | jq -c '.result.origins[]' | while read -r origin; do
                    local origin_name
                    origin_name=$(echo "$origin" | jq -r '.name // "Unknown"')
                    local origin_address
                    origin_address=$(echo "$origin" | jq -r '.address // "Unknown"')
                    local origin_healthy
                    origin_healthy=$(echo "$origin" | jq -r '.healthy // false')
                    local origin_enabled
                    origin_enabled=$(echo "$origin" | jq -r '.enabled // false')
                    
                    local status_color="${GREEN}"
                    local status_text="HEALTHY"
                    
                    if [ "$origin_healthy" = "false" ]; then
                        status_color="${RED}"
                        status_text="UNHEALTHY"
                    elif [ "$origin_enabled" = "false" ]; then
                        status_color="${YELLOW}"
                        status_text="DISABLED"
                    fi
                    
                    log "  Origin: $origin_name ($origin_address) - ${status_color}${status_text}${NC}" "INFO"
                done
            fi
        fi
        
        log "Next check in ${MONITOR_INTERVAL} seconds..." "INFO"
        sleep "$MONITOR_INTERVAL"
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
    
    local fqdn
    fqdn=$(echo "$state" | jq -r '.fqdn // empty')
    
    if [ -z "$fqdn" ]; then
        log "No load balancer setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    local lb_name
    lb_name=$(echo "$state" | jq -r '.load_balancer_name // empty')
    local lb_id
    lb_id=$(echo "$state" | jq -r '.load_balancer_id // empty')
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           LOAD BALANCER STATUS"
    echo "════════════════════════════════════════════════"
    echo
    echo -e "FQDN: ${GREEN}$fqdn${NC}"
    echo -e "Name: $lb_name ($lb_id)"
    echo
    echo "IP Addresses:"
    echo "  Primary: $primary_ip"
    echo "  Backup:  $backup_ip"
    echo
    
    # Get current status
    if [ -n "$lb_id" ]; then
        log "Fetching real-time status..." "INFO"
        
        # Get load balancer status
        local lb_status
        lb_status=$(get_load_balancer_status "$lb_id")
        
        if echo "$lb_status" | jq -e '.success == true' &>/dev/null; then
            local enabled
            enabled=$(echo "$lb_status" | jq -r '.result.enabled // false')
            
            if [ "$enabled" = "true" ]; then
                echo -e "Load Balancer Status: ${GREEN}ACTIVE${NC}"
            else
                echo -e "Load Balancer Status: ${RED}INACTIVE${NC}"
            fi
        fi
        
        # Get pool health
        local pool_id
        pool_id=$(echo "$state" | jq -r '.pool_id // empty')
        
        if [ -n "$pool_id" ]; then
            local pool_health
            pool_health=$(get_pool_status "$pool_id")
            
            if echo "$pool_health" | jq -e '.success == true' &>/dev/null; then
                echo
                echo "Origin Health Status:"
                
                echo "$pool_health" | jq -c '.result.origins[]' | while read -r origin; do
                    local origin_name
                    origin_name=$(echo "$origin" | jq -r '.name // "Unknown"')
                    local origin_address
                    origin_address=$(echo "$origin" | jq -r '.address // "Unknown"')
                    local origin_healthy
                    origin_healthy=$(echo "$origin" | jq -r '.healthy // false')
                    local origin_enabled
                    origin_enabled=$(echo "$origin" | jq -r '.enabled // false')
                    
                    if [ "$origin_healthy" = "true" ] && [ "$origin_enabled" = "true" ]; then
                        echo -e "  $origin_name ($origin_address): ${GREEN}✓ HEALTHY${NC}"
                    elif [ "$origin_enabled" = "false" ]; then
                        echo -e "  $origin_name ($origin_address): ${YELLOW}○ DISABLED${NC}"
                    else
                        echo -e "  $origin_name ($origin_address): ${RED}✗ UNHEALTHY${NC}"
                    fi
                done
            fi
        fi
    fi
    
    # Check monitor status
    echo
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
    echo "════════════════════════════════════════════════"
}

# =============================================
# MANUAL CONTROL FUNCTIONS
# =============================================

toggle_origin() {
    local pool_id="$1"
    local origin_name="$2"
    local enable="$3"
    
    # First get current pool configuration
    local response
    response=$(api_request "GET" "/accounts/${CF_ZONE_ID}/load_balancers/pools/$pool_id")
    
    if ! echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Failed to get pool configuration" "ERROR"
        return 1
    fi
    
    # Update the specific origin
    local updated_origins
    updated_origins=$(echo "$response" | jq --arg name "$origin_name" --arg enable "$enable" '
        .result.origins |= map(
            if .name == $name then
                .enabled = ($enable == "true")
            else
                .
            end
        ) | .result.origins
    ')
    
    # Update pool
    local update_data
    update_data=$(cat << EOF
{
  "origins": $updated_origins
}
EOF
)
    
    local update_response
    update_response=$(api_request "PUT" "/accounts/${CF_ZONE_ID}/load_balancers/pools/$pool_id" "$update_data")
    
    if echo "$update_response" | jq -e '.success == true' &>/dev/null; then
        log "Origin '$origin_name' $( [ "$enable" = "true" ] && echo "enabled" || echo "disabled" )" "SUCCESS"
        return 0
    else
        log "Failed to update origin" "ERROR"
        return 1
    fi
}

manual_control() {
    local state
    state=$(load_state)
    
    local pool_id
    pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local primary_ip
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    if [ -z "$pool_id" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           MANUAL ORIGIN CONTROL"
    echo "════════════════════════════════════════════════"
    echo
    echo "1. Enable Primary Origin ($primary_ip)"
    echo "2. Disable Primary Origin ($primary_ip)"
    echo "3. Enable Backup Origin ($backup_ip)"
    echo "4. Disable Backup Origin ($backup_ip)"
    echo "5. Test Origins Health"
    echo "6. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            toggle_origin "$pool_id" "primary-server" "true"
            ;;
        2)
            toggle_origin "$pool_id" "primary-server" "false"
            ;;
        3)
            toggle_origin "$pool_id" "backup-server" "true"
            ;;
        4)
            toggle_origin "$pool_id" "backup-server" "false"
            ;;
        5)
            echo
            echo "Testing origin connectivity:"
            echo "---------------------------"
            
            # Get current health status
            local pool_health
            pool_health=$(get_pool_status "$pool_id")
            
            if echo "$pool_health" | jq -e '.success == true' &>/dev/null; then
                echo "$pool_health" | jq -c '.result.origins[]' | while read -r origin; do
                    local origin_name
                    origin_name=$(echo "$origin" | jq -r '.name // "Unknown"')
                    local origin_address
                    origin_address=$(echo "$origin" | jq -r '.address // "Unknown"')
                    local origin_healthy
                    origin_healthy=$(echo "$origin" | jq -r '.healthy // false')
                    local origin_enabled
                    origin_enabled=$(echo "$origin" | jq -r '.enabled // false')
                    
                    echo -n "  $origin_name ($origin_address): "
                    if [ "$origin_healthy" = "true" ] && [ "$origin_enabled" = "true" ]; then
                        echo -e "${GREEN}✓ HEALTHY${NC}"
                    elif [ "$origin_enabled" = "false" ]; then
                        echo -e "${YELLOW}○ DISABLED${NC}"
                    else
                        echo -e "${RED}✗ UNHEALTHY${NC}"
                    fi
                done
            fi
            ;;
        6)
            return
            ;;
        *)
            log "Invalid option" "ERROR"
            ;;
    esac
}

# =============================================
# CLEANUP FUNCTION
# =============================================

cleanup() {
    echo
    log "WARNING: This will delete ALL load balancer components!" "WARNING"
    echo
    
    local state
    state=$(load_state)
    
    local fqdn
    fqdn=$(echo "$state" | jq -r '.fqdn // empty')
    
    if [ -z "$fqdn" ]; then
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
    
    log "Deleting load balancer components..." "INFO"
    
    # Get IDs from state
    local lb_id
    lb_id=$(echo "$state" | jq -r '.load_balancer_id // empty')
    local pool_id
    pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local monitor_id
    monitor_id=$(echo "$state" | jq -r '.monitor_id // empty')
    
    # Delete Load Balancer
    if [ -n "$lb_id" ]; then
        log "Deleting load balancer..." "INFO"
        api_request "DELETE" "/zones/${CF_ZONE_ID}/load_balancers/$lb_id" > /dev/null
    fi
    
    # Delete Origin Pool
    if [ -n "$pool_id" ]; then
        log "Deleting origin pool..." "INFO"
        api_request "DELETE" "/accounts/${CF_ZONE_ID}/load_balancers/pools/$pool_id" > /dev/null
    fi
    
    # Delete Health Monitor
    if [ -n "$monitor_id" ]; then
        log "Deleting health monitor..." "INFO"
        api_request "DELETE" "/accounts/${CF_ZONE_ID}/load_balancers/monitors/$monitor_id" > /dev/null
    fi
    
    # Delete DNS record (if exists)
    log "Cleaning up DNS records..." "INFO"
    local dns_response
    dns_response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?name=$fqdn")
    if echo "$dns_response" | jq -e '.success == true and .result | length > 0' &>/dev/null; then
        local dns_record_id
        dns_record_id=$(echo "$dns_response" | jq -r '.result[0].id')
        api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$dns_record_id" > /dev/null
    fi
    
    # Delete state files
    rm -f "$STATE_FILE" "$MONITOR_PID_FILE"
    
    log "Cleanup completed!" "SUCCESS"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE LOAD BALANCER MANAGER v3.0      ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Setup Load Balancer (Zero-Downtime)        ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                       ║"
    echo -e "║  ${GREEN}3.${NC} Start Monitor Service                     ║"
    echo -e "║  ${GREEN}4.${NC} Stop Monitor Service                      ║"
    echo -e "║  ${GREEN}5.${NC} Manual Origin Control                     ║"
    echo -e "║  ${GREEN}6.${NC} Cleanup (Delete All)                      ║"
    echo -e "║  ${GREEN}7.${NC} Configure API Settings                    ║"
    echo -e "║  ${GREEN}8.${NC} Exit                                      ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local fqdn
        fqdn=$(jq -r '.fqdn // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [ -n "$fqdn" ]; then
            local lb_name
            lb_name=$(jq -r '.load_balancer_name // empty' "$STATE_FILE" 2>/dev/null || echo "")
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
            
            echo -e "║  ${CYAN}FQDN: $fqdn${NC}"
            echo -e "║  ${CYAN}LB: $lb_name ${monitor_status}${NC}"
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
        
        read -rp "Select option (1-8): " choice
        
        case $choice in
            1)
                if load_config; then
                    setup_load_balancer
                else
                    log "Please configure API settings first (option 7)" "ERROR"
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
                    log "Please configure API settings first (option 7)" "ERROR"
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
                    log "Please configure API settings first (option 7)" "ERROR"
                fi
                pause
                ;;
            6)
                cleanup
                pause
                ;;
            7)
                configure_api
                ;;
            8)
                echo
                log "Goodbye!" "INFO"
                echo
                exit 0
                ;;
            *)
                log "Invalid option. Please select 1-8." "ERROR"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main
