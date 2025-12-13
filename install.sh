#!/bin/bash

# =============================================
# CLOUDFLARE LOAD BALANCER MANAGER v3.1
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-load-balancer"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
MONITOR_PID_FILE="$CONFIG_DIR/monitor.pid"
CNAME_FILE="$CONFIG_DIR/cname.txt"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
CF_ACCOUNT_ID=""
BASE_HOST=""

# Load Balancer Settings
CHECK_INTERVAL=10        # Health check every 10 seconds
MONITOR_INTERVAL=30      # Monitor status every 30 seconds

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
    
    # Check md5sum
    if ! command -v md5sum &>/dev/null && ! command -v md5 &>/dev/null; then
        log "md5sum/md5 is not installed" "WARNING"
    fi
    
    if [ $missing -eq 1 ]; then
        log "Please install missing prerequisites first" "ERROR"
        exit 1
    fi
    
    log "All prerequisites are installed" "SUCCESS"
}

generate_random_id() {
    if command -v md5sum &>/dev/null; then
        date +%s%N | md5sum | cut -c1-8
    elif command -v md5 &>/dev/null; then
        date +%s%N | md5 | cut -c1-8
    else
        date +%s%N | sha256sum | cut -c1-8
    fi
}

# =============================================
# CONFIGURATION MANAGEMENT
# =============================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" 2>/dev/null || true
        
        # Validate required configs
        if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$BASE_HOST" ]]; then
            log "Configuration incomplete. Please run setup again." "WARNING"
            return 1
        fi
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
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
    local cname="$8"
    
    cat > "$STATE_FILE" << EOF
{
  "load_balancer_name": "$lb_name",
  "load_balancer_id": "$lb_id",
  "pool_id": "$pool_id",
  "monitor_id": "$monitor_id",
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "fqdn": "$fqdn",
  "cname": "$cname",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "status": "active"
}
EOF
    
    # Save CNAME to separate file
    echo "$cname" > "$CNAME_FILE"
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
    
    # Set timeout
    local timeout=30
    
    if [ -n "$data" ]; then
        response=$(curl -s --max-time "$timeout" -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    else
        response=$(curl -s --max-time "$timeout" -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false,"errors":[{"message":"Connection failed"}]}')
    fi
    
    # Log errors for debugging
    if ! echo "$response" | jq -e '.success == true' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Invalid JSON response")
        log "API request failed: $error_msg" "ERROR" >&2
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
        CF_ACCOUNT_ID=$(echo "$response" | jq -r '.result.id // ""')
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
        CF_ACCOUNT_ID=$(echo "$response" | jq -r '.result.account.id // ""')
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
    echo "  - Zone.DNS (Edit)"
    echo "  - Account Load Balancers (Edit)"
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
    echo "Enter your base domain (without subdomain)"
    echo "Example: example.com"
    echo
    
    while true; do
        read -rp "Enter base domain: " BASE_HOST
        if [ -z "$BASE_HOST" ]; then
            log "Domain cannot be empty" "ERROR"
        elif [[ "$BASE_HOST" == *"//"* ]] || [[ "$BASE_HOST" == *"www."* ]]; then
            log "Please enter just the domain name (e.g., example.com)" "ERROR"
        else
            break
        fi
    done
    
    save_config
    echo
    log "Configuration completed successfully!" "SUCCESS"
    log "Account ID: $CF_ACCOUNT_ID" "INFO"
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
    
    # Reserved IP check
    if [ "$o1" -eq 0 ] || 
       [ "$o1" -eq 10 ] || 
       [ "$o1" -eq 127 ] ||
       ([ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]) ||
       ([ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]) ||
       ([ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]); then
        log "Warning: IP $ip appears to be a private/reserved IP" "WARNING"
        read -rp "Continue anyway? (y/n): " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            return 1
        fi
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
  "monitor": "",
  "check_regions": ["WNAM"]
}
EOF
)
    
    local response
    response=$(api_request "POST" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools" "$data")
    
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
  "expected_codes": "200,301,302",
  "follow_redirects": true,
  "allow_insecure": false,
  "header": {},
  "consecutive_up": 1,
  "consecutive_down": 1
}
EOF
)
    
    local response
    response=$(api_request "POST" "/accounts/${CF_ACCOUNT_ID}/load_balancers/monitors" "$data")
    
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
    "failover_across_pools": false
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

create_cname_record() {
    local cname="$1"
    local target="$2"
    
    local data
    data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$cname",
  "content": "$target",
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
        log "Failed to create CNAME record" "ERROR"
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
    echo
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server): " primary_ip
        if validate_ip "$primary_ip"; then
            break
        fi
        log "Invalid IPv4 address format" "ERROR"
    done
    
    echo
    
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
    random_id=$(generate_random_id)
    local lb_name="lb-${random_id}"
    local pool_name="pool-${random_id}"
    local monitor_name="monitor-${random_id}"
    local fqdn="${lb_name}.${BASE_HOST}"
    local cname="app-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating load balancer components..." "INFO"
    echo "======================================"
    
    # Step 1: Create health monitor
    log "1. Creating health monitor..." "INFO"
    local monitor_id
    monitor_id=$(create_health_monitor "$monitor_name")
    if [ -z "$monitor_id" ]; then
        log "Failed to create health monitor" "ERROR"
        return 1
    fi
    log "✓ Health monitor created: $monitor_id" "SUCCESS"
    sleep 1
    
    # Step 2: Create origin pool
    log "2. Creating origin pool..." "INFO"
    local pool_id
    pool_id=$(create_origin_pool "$pool_name" "$primary_ip" "$backup_ip")
    if [ -z "$pool_id" ]; then
        log "Failed to create origin pool" "ERROR"
        # Cleanup monitor
        api_request "DELETE" "/accounts/${CF_ACCOUNT_ID}/load_balancers/monitors/$monitor_id" > /dev/null 2>&1
        return 1
    fi
    log "✓ Origin pool created: $pool_id" "SUCCESS"
    sleep 1
    
    # Step 3: Create load balancer
    log "3. Creating load balancer..." "INFO"
    local lb_id
    lb_id=$(create_load_balancer "$lb_name" "$fqdn" "$pool_id" "$monitor_id")
    if [ -z "$lb_id" ]; then
        log "Failed to create load balancer" "ERROR"
        # Cleanup
        api_request "DELETE" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools/$pool_id" > /dev/null 2>&1
        api_request "DELETE" "/accounts/${CF_ACCOUNT_ID}/load_balancers/monitors/$monitor_id" > /dev/null 2>&1
        return 1
    fi
    log "✓ Load balancer created: $lb_id" "SUCCESS"
    sleep 2
    
    # Step 4: Create CNAME record pointing to load balancer
    log "4. Creating CNAME record..." "INFO"
    local cname_record_id
    cname_record_id=$(create_cname_record "$cname" "$fqdn")
    if [ -z "$cname_record_id" ]; then
        log "Warning: Failed to create CNAME record, but load balancer is working" "WARNING"
    else
        log "✓ CNAME record created" "SUCCESS"
    fi
    
    # Wait for propagation
    log "5. Waiting for DNS propagation..." "INFO"
    sleep 3
    
    # Save state
    save_state "$lb_name" "$lb_id" "$pool_id" "$monitor_id" "$primary_ip" "$backup_ip" "$fqdn" "$cname"
    
    echo
    echo "════════════════════════════════════════════════"
    log "🎉 LOAD BALANCER SETUP COMPLETED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo "📋 YOUR LOAD BALANCER DETAILS:"
    echo "──────────────────────────────"
    echo
    echo -e "🌐 ${CYAN}Your CNAME (Use this in your applications):${NC}"
    echo -e "   ${GREEN}$cname${NC}"
    echo
    echo -e "🔗 ${CYAN}Load Balancer FQDN:${NC}"
    echo -e "   $fqdn"
    echo
    echo "🖥️  SERVER IP ADDRESSES:"
    echo "   Primary: $primary_ip"
    echo "   Backup:  $backup_ip"
    echo
    echo "⚙️  COMPONENTS CREATED:"
    echo "   • Load Balancer: $lb_name"
    echo "   • Origin Pool: $pool_name"
    echo "   • Health Monitor: $monitor_name"
    echo
    echo "✅ FEATURES:"
    echo "   ✓ Zero-downtime failover"
    echo "   ✓ Automatic health checks"
    echo "   ✓ Real-time monitoring"
    echo "   ✓ No DNS propagation delays"
    echo
    echo "📊 HEALTH CHECK SETTINGS:"
    echo "   • Interval: ${CHECK_INTERVAL} seconds"
    echo "   • Timeout: 5 seconds"
    echo "   • Retries: 2"
    echo
    echo "🔧 HOW IT WORKS:"
    echo "   1. Health monitor checks both servers every ${CHECK_INTERVAL}s"
    echo "   2. If Primary fails, traffic automatically routes to Backup"
    echo "   3. When Primary recovers, traffic automatically shifts back"
    echo "   4. All traffic flows through: ${CYAN}$cname → $fqdn → Active Server${NC}"
    echo
    echo "🚀 NEXT STEPS:"
    echo "   1. Use ${GREEN}$cname${NC} in your applications"
    echo "   2. DNS propagation may take 1-2 minutes"
    echo "   3. Start monitor service from main menu"
    echo
    echo "⚠️  IMPORTANT: Save your CNAME: ${GREEN}$cname${NC}"
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

get_pool_health() {
    local pool_id="$1"
    
    local response
    response=$(api_request "GET" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools/$pool_id/health")
    
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
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$lb_id" ]; then
        log "No load balancer setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    # Save PID
    echo $$ > "$MONITOR_PID_FILE"
    
    log "Load balancer monitor started (PID: $$)" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    log "Monitoring CNAME: $cname" "INFO"
    
    # Trap signals
    trap 'log "Monitor service stopped" "INFO"; rm -f "$MONITOR_PID_FILE"; exit 0' INT TERM
    
    local check_count=0
    
    # Main monitoring loop
    while true; do
        check_count=$((check_count + 1))
        
        echo
        log "=== Monitoring Check #$check_count ===" "INFO"
        log "Time: $(date '+%H:%M:%S')" "INFO"
        
        # Get load balancer status
        local lb_status
        lb_status=$(get_load_balancer_status "$lb_id")
        
        if echo "$lb_status" | jq -e '.success == true' &>/dev/null; then
            local lb_name
            lb_name=$(echo "$lb_status" | jq -r '.result.name // "Unknown"')
            local enabled
            enabled=$(echo "$lb_status" | jq -r '.result.enabled // false')
            
            if [ "$enabled" = "true" ]; then
                log "Load Balancer '$lb_name': ${GREEN}ACTIVE${NC}" "INFO"
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
            pool_health=$(get_pool_health "$pool_id")
            
            if echo "$pool_health" | jq -e '.success == true' &>/dev/null; then
                log "Origin Health Status:" "INFO"
                
                local origins
                origins=$(echo "$pool_health" | jq -c '.result.origins[]' 2>/dev/null)
                
                if [ -n "$origins" ]; then
                    while read -r origin; do
                        local origin_name
                        origin_name=$(echo "$origin" | jq -r '.name // "Unknown"')
                        local origin_address
                        origin_address=$(echo "$origin" | jq -r '.address // "Unknown"')
                        local origin_healthy
                        origin_healthy=$(echo "$origin" | jq -r '.healthy // false')
                        local origin_enabled
                        origin_enabled=$(echo "$origin" | jq -r '.enabled // false')
                        
                        if [ "$origin_healthy" = "true" ] && [ "$origin_enabled" = "true" ]; then
                            log "  $origin_name ($origin_address): ${GREEN}✓ HEALTHY${NC}" "INFO"
                        elif [ "$origin_enabled" = "false" ]; then
                            log "  $origin_name ($origin_address): ${YELLOW}○ DISABLED${NC}" "INFO"
                        else
                            log "  $origin_name ($origin_address): ${RED}✗ UNHEALTHY${NC}" "WARNING"
                        fi
                    done <<< "$origins"
                fi
            else
                log "Failed to get pool health status" "ERROR"
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
    
    # Check if setup exists
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    # Start monitor in background
    monitor_service &
    
    local pid=$!
    log "Monitor service started in background (PID: $pid)" "SUCCESS"
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
        log "No load balancer setup found. Please run setup first." "ERROR"
        return 1
    fi
    
    local fqdn
    fqdn=$(echo "$state" | jq -r '.fqdn // empty')
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
    echo -e "📌 ${CYAN}Your CNAME (for applications):${NC}"
    echo -e "   ${GREEN}$cname${NC}"
    echo
    echo -e "🔗 ${CYAN}Load Balancer FQDN:${NC}"
    echo -e "   $fqdn"
    echo
    echo -e "🏷️  ${CYAN}Load Balancer Name:${NC}"
    echo "   $lb_name ($lb_id)"
    echo
    echo "🖥️  SERVER IP ADDRESSES:"
    echo "   Primary: $primary_ip"
    echo "   Backup:  $backup_ip"
    echo
    
    # Get real-time status
    if [ -n "$lb_id" ]; then
        log "Fetching real-time status..." "INFO"
        echo
        
        # Get load balancer status
        local lb_status
        lb_status=$(get_load_balancer_status "$lb_id")
        
        if echo "$lb_status" | jq -e '.success == true' &>/dev/null; then
            local enabled
            enabled=$(echo "$lb_status" | jq -r '.result.enabled // false')
            
            if [ "$enabled" = "true" ]; then
                echo -e "📊 Load Balancer Status: ${GREEN}ACTIVE${NC}"
            else
                echo -e "📊 Load Balancer Status: ${RED}INACTIVE${NC}"
            fi
        fi
        
        # Get pool health
        local pool_id
        pool_id=$(echo "$state" | jq -r '.pool_id // empty')
        
        if [ -n "$pool_id" ]; then
            local pool_health
            pool_health=$(get_pool_health "$pool_id")
            
            if echo "$pool_health" | jq -e '.success == true' &>/dev/null; then
                echo
                echo "🩺 ORIGIN HEALTH STATUS:"
                
                local origins
                origins=$(echo "$pool_health" | jq -c '.result.origins[]' 2>/dev/null)
                
                if [ -n "$origins" ]; then
                    while read -r origin; do
                        local origin_name
                        origin_name=$(echo "$origin" | jq -r '.name // "Unknown"')
                        local origin_address
                        origin_address=$(echo "$origin" | jq -r '.address // "Unknown"')
                        local origin_healthy
                        origin_healthy=$(echo "$origin" | jq -r '.healthy // false')
                        local origin_enabled
                        origin_enabled=$(echo "$origin" | jq -r '.enabled // false')
                        
                        if [ "$origin_healthy" = "true" ] && [ "$origin_enabled" = "true" ]; then
                            echo -e "   $origin_name ($origin_address): ${GREEN}✓ HEALTHY${NC}"
                        elif [ "$origin_enabled" = "false" ]; then
                            echo -e "   $origin_name ($origin_address): ${YELLOW}○ DISABLED${NC}"
                        else
                            echo -e "   $origin_name ($origin_address): ${RED}✗ UNHEALTHY${NC}"
                        fi
                    done <<< "$origins"
                fi
            fi
        fi
    fi
    
    # Check monitor status
    echo
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if ps -p "$pid" &>/dev/null; then
            echo -e "👁️  Monitor Service: ${GREEN}RUNNING${NC} (PID: $pid)"
        else
            echo -e "👁️  Monitor Service: ${RED}STOPPED${NC}"
            rm -f "$MONITOR_PID_FILE"
        fi
    else
        echo -e "👁️  Monitor Service: ${YELLOW}NOT RUNNING${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

show_cname() {
    if [ -f "$CNAME_FILE" ]; then
        local cname
        cname=$(cat "$CNAME_FILE")
        
        local state
        state=$(load_state)
        local fqdn
        fqdn=$(echo "$state" | jq -r '.fqdn // empty')
        local primary_ip
        primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
        local backup_ip
        backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
        
        echo
        echo "════════════════════════════════════════════════"
        echo "           YOUR LOAD BALANCER CNAME"
        echo "════════════════════════════════════════════════"
        echo
        echo -e "🎯 ${CYAN}Use this CNAME in your applications:${NC}"
        echo
        echo -e "   ${GREEN}$cname${NC}"
        echo
        echo "🔗 DNS Configuration:"
        echo "   CNAME: $cname"
        echo "   Points to: $fqdn (Load Balancer)"
        echo "   Then to: Primary IP or Backup IP"
        echo
        echo "🖥️  Server IPs:"
        echo "   Primary: $primary_ip"
        echo "   Backup:  $backup_ip"
        echo
        echo "⚡ How it works:"
        echo "   1. Your application uses: $cname"
        echo "   2. DNS redirects to Load Balancer: $fqdn"
        echo "   3. Load Balancer routes to healthy server"
        echo "   4. Automatic failover if primary fails"
        echo
        echo "⏱️  Health Check Settings:"
        echo "   • Check every: ${CHECK_INTERVAL} seconds"
        echo "   • Failover: Instant (no DNS delay)"
        echo "   • Recovery: Automatic"
        echo
        echo "📝 Note: DNS propagation may take 1-2 minutes"
        echo
    else
        log "No CNAME found. Please run setup first." "ERROR"
    fi
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
    response=$(api_request "GET" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools/$pool_id")
    
    if ! echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Failed to get pool configuration" "ERROR"
        return 1
    fi
    
    # Update the specific origin
    local updated_origins
    updated_origins=$(echo "$response" | jq --arg name "$origin_name" --argjson enable "$enable" '
        .result.origins |= map(
            if .name == $name then
                .enabled = $enable
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
    update_response=$(api_request "PUT" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools/$pool_id" "$update_data")
    
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
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$pool_id" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    echo
    echo "════════════════════════════════════════════════"
    echo "           MANUAL ORIGIN CONTROL"
    echo "════════════════════════════════════════════════"
    echo
    echo "Current CNAME: $cname"
    echo
    echo "1. Enable Primary Origin ($primary_ip)"
    echo "2. Disable Primary Origin ($primary_ip)"
    echo "3. Enable Backup Origin ($backup_ip)"
    echo "4. Disable Backup Origin ($backup_ip)"
    echo "5. View Current Status"
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
            show_status
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
    
    log "Deleting load balancer components..." "INFO"
    
    # Get IDs from state
    local lb_id
    lb_id=$(echo "$state" | jq -r '.load_balancer_id // empty')
    local pool_id
    pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local monitor_id
    monitor_id=$(echo "$state" | jq -r '.monitor_id // empty')
    local fqdn
    fqdn=$(echo "$state" | jq -r '.fqdn // empty')
    
    # Delete Load Balancer
    if [ -n "$lb_id" ]; then
        log "Deleting load balancer..." "INFO"
        api_request "DELETE" "/zones/${CF_ZONE_ID}/load_balancers/$lb_id" > /dev/null 2>&1
        sleep 1
    fi
    
    # Delete Origin Pool
    if [ -n "$pool_id" ]; then
        log "Deleting origin pool..." "INFO"
        api_request "DELETE" "/accounts/${CF_ACCOUNT_ID}/load_balancers/pools/$pool_id" > /dev/null 2>&1
        sleep 1
    fi
    
    # Delete Health Monitor
    if [ -n "$monitor_id" ]; then
        log "Deleting health monitor..." "INFO"
        api_request "DELETE" "/accounts/${CF_ACCOUNT_ID}/load_balancers/monitors/$monitor_id" > /dev/null 2>&1
        sleep 1
    fi
    
    # Delete CNAME DNS record
    if [ -n "$cname" ]; then
        log "Deleting CNAME record..." "INFO"
        # Get DNS record ID
        local dns_response
        dns_response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=$cname")
        if echo "$dns_response" | jq -e '.success == true and .result | length > 0' &>/dev/null; then
            local dns_record_id
            dns_record_id=$(echo "$dns_response" | jq -r '.result[0].id')
            api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$dns_record_id" > /dev/null 2>&1
        fi
    fi
    
    # Delete Load Balancer DNS record
    if [ -n "$fqdn" ]; then
        log "Deleting load balancer DNS record..." "INFO"
        local lb_dns_response
        lb_dns_response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?name=$fqdn")
        if echo "$lb_dns_response" | jq -e '.success == true and .result | length > 0' &>/dev/null; then
            local lb_dns_record_id
            lb_dns_record_id=$(echo "$lb_dns_response" | jq -r '.result[0].id')
            api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$lb_dns_record_id" > /dev/null 2>&1
        fi
    fi
    
    # Delete state files
    rm -f "$STATE_FILE" "$CNAME_FILE" "$MONITOR_PID_FILE"
    
    log "Cleanup completed!" "SUCCESS"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE LOAD BALANCER MANAGER v3.1      ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Setup Load Balancer (Zero-Downtime)        ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                       ║"
    echo -e "║  ${GREEN}3.${NC} Start Monitor Service                     ║"
    echo -e "║  ${GREEN}4.${NC} Stop Monitor Service                      ║"
    echo -e "║  ${GREEN}5.${NC} Manual Origin Control                     ║"
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
            
            echo -e "║  ${CYAN}CNAME: $cname${NC}"
            echo -e "║  ${CYAN}Load Balancer: $lb_name ${monitor_status}${NC}"
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
        log "No configuration found. Please configure first." "INFO"
    fi
    
    # Main loop
    while true; do
        show_menu
        
        read -rp "Select option (1-9): " choice
        
        case $choice in
            1)
                if load_config; then
                    if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$BASE_HOST" ]]; then
                        log "Configuration incomplete. Please run option 8 first." "ERROR"
                    else
                        setup_load_balancer
                    fi
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
                pause
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
