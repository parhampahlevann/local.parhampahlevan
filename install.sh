#!/usr/bin/env bash
# Cloudflare Load Balancer Manager with Auto-Failover
# Complete menu-driven interface

set -euo pipefail

TOOL_NAME="cf-lb-manager"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${CONFIG_DIR}/state.json"
LOG_FILE="${CONFIG_DIR}/activity.log"
LAST_LB_FILE="${CONFIG_DIR}/last_loadbalancer.txt"
MONITOR_LOG="${CONFIG_DIR}/monitor.log"

CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""
HEALTH_CHECK_INTERVAL=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $1" >> "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "[SUCCESS] $1" >> "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $1" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[INFO] $1" >> "$LOG_FILE"
}

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" "$MONITOR_LOG"
}

install_prereqs() {
    echo
    info "Checking prerequisites..."
    
    local missing=0
    
    if ! command -v curl >/dev/null 2>&1; then
        warning "curl not found. Installing curl..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y curl
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y curl
        else
            error "Cannot install curl automatically. Please install it manually."
            missing=1
        fi
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        warning "jq not found. Installing jq..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y jq
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y jq
        else
            error "Cannot install jq automatically. Please install it manually."
            missing=1
        fi
    fi
    
    if ! command -v ping >/dev/null 2>&1; then
        warning "ping not found. Installing iputils-ping..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y iputils-ping
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y iputils
        fi
    fi
    
    if [[ $missing -eq 0 ]]; then
        success "All prerequisites are installed."
    fi
    return $missing
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_HOST="$BASE_HOST"
EOF
    log "Configuration saved"
}

save_state() {
    cat > "$STATE_FILE" <<EOF
{
    "load_balancer": "${1:-}",
    "cname": "${2:-}",
    "pool_id": "${3:-}",
    "monitor_id": "${4:-}",
    "primary_ip": "${5:-}",
    "backup_ip": "${6:-}",
    "created_at": "$(date -Iseconds)"
}
EOF
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

api_request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    
    local response
    if [[ -n "$data" ]]; then
        response=$(curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data" 2>/dev/null)
    else
        response=$(curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null)
    fi
    
    echo "$response"
}

test_api_access() {
    info "Testing Cloudflare API access..."
    local resp
    resp=$(api_request "GET" "${CF_API_BASE}/user/tokens/verify")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        local email=$(echo "$resp" | jq -r '.result.email // ""')
        success "API Token is valid (User: $email)"
        return 0
    else
        error "API Token is invalid"
        return 1
    fi
}

test_zone_access() {
    info "Testing Zone access..."
    local resp
    resp=$(api_request "GET" "${CF_API_BASE}/zones/${CF_ZONE_ID}")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        local zone_name=$(echo "$resp" | jq -r '.result.name // ""')
        success "Zone access confirmed: $zone_name"
        return 0
    else
        error "Cannot access Zone ID"
        return 1
    fi
}

configure_api() {
    echo
    info "Cloudflare API Configuration"
    echo "=============================="
    echo
    echo "You need a Cloudflare API token with these permissions:"
    echo "  • Zone.DNS (Edit)"
    echo "  • Zone.Load Balancing (Edit)"
    echo "  • Account.Load Balancing (Read)"
    echo
    echo "Get your token from: https://dash.cloudflare.com/profile/api-tokens"
    echo
    
    while true; do
        read -rp "Enter Cloudflare API Token: " CF_API_TOKEN
        if [[ -z "$CF_API_TOKEN" ]]; then
            error "API Token cannot be empty"
            continue
        fi
        
        if test_api_access; then
            break
        fi
        
        echo
        warning "Invalid token. Please try again or press Ctrl+C to exit."
    done
    
    echo
    echo "Get your Zone ID from:"
    echo "  Cloudflare Dashboard → Your Site → Overview (right sidebar)"
    echo
    
    while true; do
        read -rp "Enter Cloudflare Zone ID: " CF_ZONE_ID
        if [[ -z "$CF_ZONE_ID" ]]; then
            error "Zone ID cannot be empty"
            continue
        fi
        
        if test_zone_access; then
            break
        fi
        
        echo
        warning "Invalid Zone ID. Please try again."
    done
    
    echo
    echo "Enter the base domain for your load balancer:"
    echo "  Example: example.com  or  lb.example.com"
    echo
    
    while true; do
        read -rp "Enter base hostname: " BASE_HOST
        if [[ -z "$BASE_HOST" ]]; then
            error "Hostname cannot be empty"
            continue
        fi
        
        # Validate hostname format
        if [[ "$BASE_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            break
        else
            error "Invalid hostname format"
        fi
    done
    
    save_config
    success "Configuration saved successfully!"
}

valid_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    local IFS=.
    read -r o1 o2 o3 o4 <<< "$ip"
    [[ $o1 -le 255 && $o2 -le 255 && $o3 -le 255 && $o4 -le 255 && \
       $o1 -ge 0 && $o2 -ge 0 && $o3 -ge 0 && $o4 -ge 0 ]]
}

generate_id() {
    tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || \
    echo "$(date +%s%N | md5sum | head -c 8)"
}

check_lb_license() {
    info "Checking Load Balancer license..."
    local resp
    resp=$(api_request "GET" "${CF_API_BASE}/zones/${CF_ZONE_ID}/load_balancers")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        local error_msg=$(echo "$resp" | jq -r '.errors[0].message // ""')
        if [[ "$error_msg" == *"requires an Enterprise plan"* ]] || \
           [[ "$error_msg" == *"not available"* ]]; then
            error "Load Balancer requires Enterprise plan or Load Balancer add-on"
            error "Please upgrade your Cloudflare plan"
            return 1
        fi
    fi
    return 0
}

create_monitor() {
    local monitor_name="monitor-$(generate_id)"
    info "Creating Health Check Monitor: $monitor_name"
    
    local monitor_data=$(cat <<EOF
{
    "type": "http",
    "description": "Auto-failover monitor - Created by cf-lb-manager",
    "method": "GET",
    "path": "/",
    "port": 80,
    "timeout": 5,
    "retries": 2,
    "interval": $HEALTH_CHECK_INTERVAL,
    "expected_codes": "2xx,3xx",
    "follow_redirects": true,
    "allow_insecure": false,
    "header": {},
    "probe_zone": "",
    "expected_body": ""
}
EOF
)
    
    local resp
    resp=$(api_request "POST" "${CF_API_BASE}/user/load_balancers/monitors" "$monitor_data")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        error "Failed to create monitor:"
        echo "$resp" | jq -r '.errors[].message' 2>/dev/null || echo "$resp"
        return 1
    fi
    
    local monitor_id=$(echo "$resp" | jq -r '.result.id')
    success "Monitor created: $monitor_id"
    echo "$monitor_id"
}

create_pool() {
    local pool_name="pool-$(generate_id)"
    local primary_ip="$1"
    local backup_ip="$2"
    local monitor_id="$3"
    
    info "Creating Load Balancer Pool: $pool_name"
    
    local pool_data=$(cat <<EOF
{
    "name": "$pool_name",
    "monitor": "$monitor_id",
    "origins": [
        {
            "name": "primary-server",
            "address": "$primary_ip",
            "enabled": true,
            "weight": 1,
            "header": {}
        },
        {
            "name": "backup-server",
            "address": "$backup_ip",
            "enabled": true,
            "weight": 1,
            "header": {}
        }
    ],
    "description": "Auto-failover pool - Primary: $primary_ip, Backup: $backup_ip",
    "enabled": true,
    "minimum_origins": 1,
    "notification_email": "",
    "check_regions": ["WEU", "EEU", "ENAM", "WNAM"],
    "origin_steering": {
        "policy": "random"
    }
}
EOF
)
    
    local resp
    resp=$(api_request "POST" "${CF_API_BASE}/user/load_balancers/pools" "$pool_data")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        error "Failed to create pool:"
        echo "$resp" | jq -r '.errors[].message' 2>/dev/null || echo "$resp"
        return 1
    fi
    
    local pool_id=$(echo "$resp" | jq -r '.result.id')
    success "Pool created: $pool_id"
    echo "$pool_id"
}

create_load_balancer() {
    local lb_name="$1"
    local pool_id="$2"
    
    info "Creating Load Balancer: $lb_name"
    
    local lb_data=$(cat <<EOF
{
    "name": "$lb_name",
    "description": "Auto-failover Load Balancer - Created by cf-lb-manager",
    "ttl": 60,
    "fallback_pool": "$pool_id",
    "default_pools": ["$pool_id"],
    "region_pools": {},
    "pop_pools": {},
    "country_pools": {},
    "proxied": false,
    "steering_policy": "dynamic_latency",
    "session_affinity": "none",
    "session_affinity_attributes": {
        "samesite": "Auto",
        "secure": "Auto",
        "zero_downtime_failover": "temporary"
    },
    "rules": []
}
EOF
)
    
    local resp
    resp=$(api_request "POST" "${CF_API_BASE}/zones/${CF_ZONE_ID}/load_balancers" "$lb_data")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        error "Failed to create load balancer:"
        echo "$resp" | jq -r '.errors[].message' 2>/dev/null || echo "$resp"
        return 1
    fi
    
    local lb_dns=$(echo "$resp" | jq -r '.result.name')
    local lb_id=$(echo "$resp" | jq -r '.result.id')
    success "Load Balancer created: $lb_dns (ID: $lb_id)"
    echo "$lb_dns"
}

create_cname_record() {
    local cname_host="$1"
    local lb_dns="$2"
    
    info "Creating CNAME record: $cname_host → $lb_dns"
    
    local cname_data=$(cat <<EOF
{
    "type": "CNAME",
    "name": "$cname_host",
    "content": "$lb_dns",
    "ttl": 1,
    "proxied": false,
    "comment": "Auto-created by cf-lb-manager"
}
EOF
)
    
    local resp
    resp=$(api_request "POST" "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records" "$cname_data")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        error "Failed to create CNAME record:"
        echo "$resp" | jq -r '.errors[].message' 2>/dev/null || echo "$resp"
        return 1
    fi
    
    success "CNAME record created successfully"
    echo "$cname_host"
}

get_pool_status() {
    local pool_id="$1"
    
    info "Fetching pool status..."
    local resp
    resp=$(api_request "GET" "${CF_API_BASE}/user/load_balancers/pools/$pool_id")
    
    local success=$(echo "$resp" | jq -r '.success // false')
    if [[ "$success" != "true" ]]; then
        error "Failed to get pool status"
        return 1
    fi
    
    echo "$resp"
}

ping_ip() {
    local ip="$1"
    local count="${2:-3}"
    
    if command -v ping >/dev/null 2>&1; then
        ping -c "$count" -W 2 "$ip" 2>/dev/null | \
            grep -E "packets transmitted|rtt min/avg/max" || \
            echo "Ping failed or timed out"
    else
        echo "Ping command not available"
    fi
}

check_current_traffic() {
    local pool_id="$1"
    local primary_ip="$2"
    local backup_ip="$3"
    
    info "Checking current traffic distribution..."
    
    local pool_status
    pool_status=$(get_pool_status "$pool_id")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo
    echo "╔══════════════════════════════════════════════╗"
    echo "║         CURRENT TRAFFIC DISTRIBUTION         ║"
    echo "╠══════════════════════════════════════════════╣"
    
    local origins=$(echo "$pool_status" | jq -r '.result.origins[] | "\(.name)|\(.address)|\(.enabled)|\(.healthy // false)"')
    
    while IFS='|' read -r name address enabled healthy; do
        local status_color=$RED
        local status="DOWN"
        
        if [[ "$healthy" == "true" ]]; then
            status_color=$GREEN
            status="HEALTHY"
        elif [[ "$enabled" == "true" ]]; then
            status_color=$YELLOW
            status="ENABLED (checking...)"
        fi
        
        echo -e "║  ${CYAN}${name}${NC}: ${address}"
        echo -e "║    Status: ${status_color}${status}${NC}"
        
        # Ping check
        echo -e "║    Ping: \c"
        ping_ip "$address" 1 | grep -E "time=|packets" | head -1
        
    done <<< "$origins"
    
    echo "╠══════════════════════════════════════════════╣"
    
    # Check which IP is currently active (primary if healthy)
    local primary_healthy=$(echo "$pool_status" | jq -r '.result.origins[] | select(.name=="primary-server") | .healthy // false')
    
    if [[ "$primary_healthy" == "true" ]]; then
        echo -e "║  ${GREEN}✓ TRAFFIC IS GOING TO: PRIMARY IP${NC}"
        echo -e "║     ${primary_ip}"
    else
        local backup_healthy=$(echo "$pool_status" | jq -r '.result.origins[] | select(.name=="backup-server") | .healthy // false')
        if [[ "$backup_healthy" == "true" ]]; then
            echo -e "║  ${YELLOW}⚠ TRAFFIC IS GOING TO: BACKUP IP${NC}"
            echo -e "║     ${backup_ip} (Primary is down)"
        else
            echo -e "║  ${RED}✗ ALL SERVERS ARE DOWN!${NC}"
        fi
    fi
    
    echo "╚══════════════════════════════════════════════╝"
    echo
}

monitor_status() {
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    if [[ -z "$cname" ]] || [[ -z "$pool_id" ]]; then
        error "No load balancer found. Please create one first."
        return 1
    fi
    
    echo
    info "Starting real-time monitoring..."
    info "Press Ctrl+C to stop monitoring"
    echo
    
    local count=0
    while true; do
        count=$((count + 1))
        echo "╔══════════════════════════════════════════════════════════╗"
        echo -e "║  ${CYAN}MONITORING CYCLE #${count} - $(date '+%H:%M:%S')${NC}"
        echo "╠══════════════════════════════════════════════════════════╣"
        
        # Get pool status
        local pool_status
        pool_status=$(get_pool_status "$pool_id")
        
        if [[ $? -eq 0 ]]; then
            local primary_healthy=$(echo "$pool_status" | jq -r '.result.origins[] | select(.name=="primary-server") | .healthy // false')
            local backup_healthy=$(echo "$pool_status" | jq -r '.result.origins[] | select(.name=="backup-server") | .healthy // false')
            
            # Display status
            if [[ "$primary_healthy" == "true" ]]; then
                echo -e "║  Status: ${GREEN}PRIMARY IP ACTIVE${NC}"
                echo -e "║  IP: ${primary_ip}"
                echo "║  ↳ Traffic is being served from primary server"
            elif [[ "$backup_healthy" == "true" ]]; then
                echo -e "║  Status: ${YELLOW}BACKUP IP ACTIVE${NC}"
                echo -e "║  IP: ${backup_ip}"
                echo "║  ↳ Failover activated! Primary is down"
            else
                echo -e "║  Status: ${RED}ALL SERVERS DOWN${NC}"
                echo "║  ↳ Both primary and backup are unavailable"
            fi
            
            # Live ping results
            echo "╠══════════════════════════════════════════════════════════╣"
            echo "║  Live Ping Results:"
            
            # Ping primary
            echo -e "║  ${CYAN}Primary (${primary_ip}):${NC}"
            ping_ip "$primary_ip" 1 | while read -r line; do
                echo "║    $line"
            done
            
            # Ping backup
            echo -e "║  ${CYAN}Backup (${backup_ip}):${NC}"
            ping_ip "$backup_ip" 1 | while read -r line; do
                echo "║    $line"
            done
            
            # Health check status
            echo "╠══════════════════════════════════════════════════════════╣"
            echo "║  Cloudflare Health Check:"
            echo -e "║    Primary: $( [[ "$primary_healthy" == "true" ]] && echo -e "${GREEN}✓ HEALTHY${NC}" || echo -e "${RED}✗ UNHEALTHY${NC}" )"
            echo -e "║    Backup:  $( [[ "$backup_healthy" == "true" ]] && echo -e "${GREEN}✓ HEALTHY${NC}" || echo -e "${RED}✗ UNHEALTHY${NC}" )"
            
            # Log to monitor file
            echo "$(date '+%Y-%m-%d %H:%M:%S') | Primary: $primary_healthy | Backup: $backup_healthy | Traffic: $( [[ "$primary_healthy" == "true" ]] && echo "PRIMARY" || echo "BACKUP" )" >> "$MONITOR_LOG"
            
        else
            echo -e "║  ${RED}Error fetching status from Cloudflare${NC}"
        fi
        
        echo "╚══════════════════════════════════════════════════════════╝"
        echo
        echo "Next update in 10 seconds... (Press Ctrl+C to stop)"
        echo
        
        sleep 10
        clear
    done
}

show_cname_info() {
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local lb_dns=$(echo "$state" | jq -r '.load_balancer // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local created_at=$(echo "$state" | jq -r '.created_at // empty')
    
    if [[ -z "$cname" ]]; then
        error "No CNAME found. Please create a load balancer first."
        return 1
    fi
    
    echo
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  YOUR LOAD BALANCER INFO                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${GREEN}Your CNAME (Use this in your applications):${NC}"
    echo -e "║  ${CYAN}    $cname${NC}"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${YELLOW}Load Balancer DNS:${NC}"
    echo "║      $lb_dns"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${YELLOW}IP Addresses:${NC}"
    echo -e "║  ${GREEN}Primary:${NC} $primary_ip (Priority)"
    echo -e "║  ${BLUE}Backup:${NC}  $backup_ip (Failover)"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${YELLOW}Created:${NC} $created_at"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${GREEN}How to use:${NC}"
    echo "║  1. Point your domain to: $cname"
    echo "║  2. Cloudflare will automatically:"
    echo "║     • Route traffic to $primary_ip"
    echo "║     • Check health every 15 seconds"
    echo "║     • Failover to $backup_ip if primary fails"
    echo "║     • Return to primary when it recovers"
    echo "║"
    echo "║  Health Check: HTTP GET :80/ every 15 seconds"
    echo "║  Expected: 2xx or 3xx status code"
    echo "║  Timeout: 5 seconds"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo
    
    # Save to file
    echo "$cname" > "$LAST_LB_FILE"
    info "CNAME saved to: $LAST_LB_FILE"
}

test_failover() {
    info "Testing failover functionality..."
    
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    
    if [[ -z "$cname" ]]; then
        error "No load balancer found"
        return 1
    fi
    
    echo
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                FAILOVER TEST PROCEDURE                   ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  This test will verify that:                            ║"
    echo "║  1. Traffic goes to Primary when both are healthy       ║"
    echo "║  2. Traffic fails over to Backup when Primary is down   ║"
    echo "║  3. Traffic returns to Primary when it recovers         ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  ${CYAN}Current Configuration:${NC}                           ║"
    echo -e "║  CNAME: $cname${NC}        ║"
    echo -e "║  Primary: $primary_ip${NC}               ║"
    echo -e "║  Backup:  $backup_ip${NC}               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo
    warning "IMPORTANT: Make sure your servers are properly configured"
    warning "Primary server should be running on port 80 for health checks"
    echo
    
    read -rp "Start failover test? (y/n): " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Step 1: Check initial status
    echo
    info "Step 1: Checking initial status..."
    check_current_traffic "$pool_id" "$primary_ip" "$backup_ip"
    
    echo
    info "Step 2: Testing DNS resolution..."
    if command -v dig >/dev/null 2>&1; then
        echo "Resolving $cname..."
        dig +short "$cname" | while read -r result; do
            echo "  → $result"
        done
    elif command -v nslookup >/dev/null 2>&1; then
        echo "Resolving $cname..."
        nslookup "$cname" | grep -A5 "Address:" | tail -n +2
    else
        warning "dig/nslookup not available, skipping DNS test"
    fi
    
    echo
    info "Step 3: Testing connectivity..."
    echo "Testing connection to $cname..."
    
    if command -v curl >/dev/null 2>&1; then
        local http_test
        http_test=$(curl -s -o /dev/null -w "%{http_code}" -I "http://$cname" --connect-timeout 5 2>/dev/null || echo "FAILED")
        
        if [[ "$http_test" =~ ^[0-9]+$ ]]; then
            success "HTTP Connection successful (Status: $http_test)"
        else
            warning "HTTP Connection failed or timed out"
        fi
    fi
    
    echo
    info "Step 4: Simulating Primary failure..."
    echo "To test failover, you need to temporarily disable your primary server."
    echo "Options:"
    echo "  1. Stop web service on $primary_ip"
    echo "  2. Block port 80 on $primary_ip"
    echo "  3. Shutdown primary server temporarily"
    echo
    warning "MANUAL ACTION REQUIRED: Make Primary server unavailable"
    echo "Cloudflare will detect failure in ~30 seconds and switch to Backup"
    echo
    read -rp "Press Enter when Primary is down, or 's' to skip..." -n1 action
    
    if [[ "$action" != "s" ]]; then
        echo
        info "Waiting 35 seconds for failover detection..."
        sleep 35
        
        info "Checking failover status..."
        check_current_traffic "$pool_id" "$primary_ip" "$backup_ip"
        
        echo
        info "Step 5: Testing recovery..."
        echo "Now restore your Primary server and wait for recovery"
        echo
        read -rp "Press Enter when Primary is restored..."
        
        info "Waiting 35 seconds for recovery detection..."
        sleep 35
        
        info "Checking recovery status..."
        check_current_traffic "$pool_id" "$primary_ip" "$backup_ip"
    fi
    
    echo
    success "Failover test completed!"
    info "Check $MONITOR_LOG for detailed history"
}

cleanup_resources() {
    info "Starting cleanup..."
    
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local lb_dns=$(echo "$state" | jq -r '.load_balancer // empty')
    local pool_id=$(echo "$state" | jq -r '.pool_id // empty')
    local monitor_id=$(echo "$state" | jq -r '.monitor_id // empty')
    
    if [[ -z "$cname" ]] && [[ -z "$pool_id" ]]; then
        warning "No resources found to cleanup"
        return 0
    fi
    
    echo
    warning "WARNING: This will permanently delete all created resources!"
    echo "The following will be deleted:"
    [[ -n "$cname" ]] && echo "  • CNAME: $cname"
    [[ -n "$lb_dns" ]] && echo "  • Load Balancer: $lb_dns"
    [[ -n "$pool_id" ]] && echo "  • Pool: $pool_id"
    [[ -n "$monitor_id" ]] && echo "  • Monitor: $monitor_id"
    echo
    
    read -rp "Are you sure you want to delete everything? (type 'DELETE' to confirm): " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        info "Cleanup cancelled"
        return 0
    fi
    
    # Delete CNAME record
    if [[ -n "$cname" ]]; then
        info "Deleting CNAME record: $cname"
        # First find the record ID
        local resp
        resp=$(api_request "GET" "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${cname}")
        local record_id=$(echo "$resp" | jq -r '.result[0].id // empty')
        
        if [[ -n "$record_id" ]]; then
            resp=$(api_request "DELETE" "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/$record_id")
            if echo "$resp" | jq -r '.success // false' | grep -q true; then
                success "CNAME record deleted"
            else
                error "Failed to delete CNAME record"
            fi
        fi
    fi
    
    # Delete Load Balancer
    if [[ -n "$lb_dns" ]]; then
        info "Deleting Load Balancer: $lb_dns"
        # Get LB ID first
        local resp
        resp=$(api_request "GET" "${CF_API_BASE}/zones/${CF_ZONE_ID}/load_balancers")
        local lb_id=$(echo "$resp" | jq -r ".result[] | select(.name==\"$lb_dns\") | .id // empty")
        
        if [[ -n "$lb_id" ]]; then
            resp=$(api_request "DELETE" "${CF_API_BASE}/zones/${CF_ZONE_ID}/load_balancers/$lb_id")
            if echo "$resp" | jq -r '.success // false' | grep -q true; then
                success "Load Balancer deleted"
            else
                error "Failed to delete Load Balancer"
            fi
        fi
    fi
    
    # Delete Pool
    if [[ -n "$pool_id" ]]; then
        info "Deleting Pool: $pool_id"
        local resp
        resp=$(api_request "DELETE" "${CF_API_BASE}/user/load_balancers/pools/$pool_id")
        if echo "$resp" | jq -r '.success // false' | grep -q true; then
            success "Pool deleted"
        else
            error "Failed to delete Pool"
        fi
    fi
    
    # Delete Monitor
    if [[ -n "$monitor_id" ]]; then
        info "Deleting Monitor: $monitor_id"
        local resp
        resp=$(api_request "DELETE" "${CF_API_BASE}/user/load_balancers/monitors/$monitor_id")
        if echo "$resp" | jq -r '.success // false' | grep -q true; then
            success "Monitor deleted"
        else
            error "Failed to delete Monitor"
        fi
    fi
    
    # Clear state
    rm -f "$STATE_FILE" "$LAST_LB_FILE"
    success "All resources cleaned up successfully!"
}

setup_complete() {
    echo
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               COMPLETE SETUP WIZARD                      ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    # Check if already configured
    if load_config >/dev/null 2>&1; then
        info "Loading existing configuration..."
    else
        info "Starting new configuration..."
        configure_api
    fi
    
    # Install prerequisites
    install_prereqs
    
    # Check Load Balancer license
    if ! check_lb_license; then
        error "Cannot continue without Load Balancer license"
        pause
        return 1
    fi
    
    # Get IP addresses
    echo
    info "Enter IP addresses for load balancer"
    echo "══════════════════════════════════════════════════════════"
    
    local primary_ip backup_ip
    
    while true; do
        read -rp "Enter PRIMARY IPv4 (main server): " primary_ip
        if valid_ipv4 "$primary_ip"; then
            break
        fi
        error "Invalid IPv4 address"
    done
    
    while true; do
        read -rp "Enter BACKUP IPv4 (failover server): " backup_ip
        if valid_ipv4 "$backup_ip"; then
            if [[ "$primary_ip" == "$backup_ip" ]]; then
                warning "Primary and Backup IPs are the same!"
                read -rp "Continue anyway? (y/n): " answer
                [[ "$answer" =~ ^[Yy]$ ]] && break
            else
                break
            fi
        else
            error "Invalid IPv4 address"
        fi
    done
    
    echo
    info "Creating resources..."
    echo "══════════════════════════════════════════════════════════"
    
    # Step 1: Create monitor
    local monitor_id
    monitor_id=$(create_monitor)
    if [[ -z "$monitor_id" ]]; then
        error "Failed to create monitor"
        return 1
    fi
    
    # Step 2: Create pool
    local pool_id
    pool_id=$(create_pool "$primary_ip" "$backup_ip" "$monitor_id")
    if [[ -z "$pool_id" ]]; then
        error "Failed to create pool"
        return 1
    fi
    
    # Step 3: Create load balancer
    local rand_id
    rand_id=$(generate_id)
    local lb_name="lb-${rand_id}.${BASE_HOST}"
    local lb_dns
    lb_dns=$(create_load_balancer "$lb_name" "$pool_id")
    if [[ -z "$lb_dns" ]]; then
        error "Failed to create load balancer"
        return 1
    fi
    
    # Step 4: Create CNAME
    local cname_host="app-${rand_id}.${BASE_HOST}"
    local final_cname
    final_cname=$(create_cname_record "$cname_host" "$lb_dns")
    if [[ -z "$final_cname" ]]; then
        error "Failed to create CNAME"
        return 1
    fi
    
    # Save state
    save_state "$lb_dns" "$final_cname" "$pool_id" "$monitor_id" "$primary_ip" "$backup_ip"
    
    echo
    success "╔══════════════════════════════════════════════════════════╗"
    success "║                    SETUP COMPLETE!                       ║"
    success "╠══════════════════════════════════════════════════════════╣"
    success "║  Your CNAME is ready:                                    ║"
    echo -e "║  ${GREEN}$final_cname${NC}"
    success "║                                                          ║"
    success "║  Use this CNAME in your applications.                    ║"
    success "║  Cloudflare will automatically:                          ║"
    success "║    • Route to $primary_ip (primary)                      ║"
    success "║    • Check health every 15 seconds                       ║"
    success "║    • Failover to $backup_ip if primary fails             ║"
    success "║    • Return to primary when healthy                      ║"
    success "╚══════════════════════════════════════════════════════════╝"
    echo
    
    # Save to file
    echo "$final_cname" > "$LAST_LB_FILE"
    info "CNAME saved to: $LAST_LB_FILE"
    
    # Test immediately
    echo
    read -rp "Would you like to test the setup now? (y/n): " test_now
    if [[ "$test_now" =~ ^[Yy]$ ]]; then
        show_cname_info
        echo
        check_current_traffic "$pool_id" "$primary_ip" "$backup_ip"
    fi
    
    pause
}

show_menu() {
    clear
    echo
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║      CLOUDFLARE LOAD BALANCER MANAGER v2.0              ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo -e "║  ${GREEN}1.${NC} Complete Setup (Create new Load Balancer)        ║"
    echo -e "║  ${GREEN}2.${NC} Cleanup (Delete all resources)                  ║"
    echo -e "║  ${GREEN}3.${NC} Monitor Status (Real-time monitoring)           ║"
    echo -e "║  ${GREEN}4.${NC} Show CNAME Information                         ║"
    echo -e "║  ${GREEN}5.${NC} Test Failover Functionality                    ║"
    echo -e "║  ${GREEN}6.${NC} Check Current Traffic Distribution             ║"
    echo -e "║  ${GREEN}7.${NC} Configure API Settings                         ║"
    echo -e "║  ${GREEN}8.${NC} View Activity Log                              ║"
    echo -e "║  ${GREEN}9.${NC} Exit                                          ║"
    echo "║                                                          ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    # Show current status if configured
    if load_config >/dev/null 2>&1; then
        local state
        state=$(load_state)
        local cname=$(echo "$state" | jq -r '.cname // empty')
        
        if [[ -n "$cname" ]]; then
            echo -e "║  ${CYAN}Current CNAME: $cname${NC}"
        else
            echo -e "║  ${YELLOW}Status: No active load balancer${NC}"
        fi
    else
        echo -e "║  ${YELLOW}Status: Not configured${NC}"
    fi
    
    echo "╚══════════════════════════════════════════════════════════╝"
    echo
}

view_log() {
    echo
    info "Activity Log (last 50 entries):"
    echo "══════════════════════════════════════════════════════════"
    tail -50 "$LOG_FILE" 2>/dev/null || echo "No log entries found"
    echo
    echo "Full log: $LOG_FILE"
    echo
    pause
}

main() {
    ensure_dir
    
    # Check if config exists, if not force configuration first
    if ! load_config; then
        warning "First-time setup required"
        configure_api
    fi
    
    while true; do
        show_menu
        
        local choice
        read -rp "Select option (1-9): " choice
        
        case $choice in
            1)
                setup_complete
                ;;
            2)
                cleanup_resources
                pause
                ;;
            3)
                monitor_status
                ;;
            4)
                show_cname_info
                pause
                ;;
            5)
                test_failover
                pause
                ;;
            6)
                local state
                state=$(load_state)
                local pool_id=$(echo "$state" | jq -r '.pool_id // empty')
                local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
                local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
                
                if [[ -n "$pool_id" ]]; then
                    check_current_traffic "$pool_id" "$primary_ip" "$backup_ip"
                else
                    error "No active load balancer found"
                fi
                pause
                ;;
            7)
                configure_api
                ;;
            8)
                view_log
                ;;
            9)
                echo
                info "Goodbye!"
                echo
                exit 0
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Handle Ctrl+C
trap 'echo; echo "Interrupted. Exiting..."; exit 1' INT

# Start main function
main
