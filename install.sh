#!/bin/bash

# =============================================
# CLOUDFLARE DUAL-IP DNS MANAGER v3.0
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-dualip-dns"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Stable DNS Settings
DNS_TTL=120  # 2 minutes TTL for better propagation

# Load Balancing Strategy
LB_STRATEGY="round-robin"  # Options: round-robin, weight-based

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
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
            echo -e "${BLUE}[$timestamp] [DEBUG]${NC} $msg" >> "$LOG_FILE"
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
DNS_TTL="$DNS_TTL"
LB_STRATEGY="$LB_STRATEGY"
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local cname="$1"
    local ip1="$2"
    local ip2="$3"
    local record_id1="$4"
    local record_id2="$5"
    
    cat > "$STATE_FILE" << EOF
{
  "cname": "$cname",
  "ip1": "$ip1",
  "ip2": "$ip2",
  "record_id1": "$record_id1",
  "record_id2": "$record_id2",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "strategy": "$LB_STRATEGY",
  "active_ips": ["$ip1", "$ip2"],
  "health_status": {
    "$ip1": "unknown",
    "$ip2": "unknown"
  }
}
EOF
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
    
    log "API Request: $method $endpoint" "DEBUG"
    
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
    
    log "API Response: $(echo "$response" | jq -c .)" "DEBUG"
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
    
    echo
    echo "Step 4: Load Balancing Strategy"
    echo "-------------------------------"
    echo "Choose how traffic is distributed:"
    echo "1. Round Robin (equal distribution)"
    echo "2. Weight Based (70% primary, 30% backup)"
    echo
    
    while true; do
        read -rp "Select strategy (1-2): " strategy_choice
        case $strategy_choice in
            1)
                LB_STRATEGY="round-robin"
                break
                ;;
            2)
                LB_STRATEGY="weight-based"
                break
                ;;
            *)
                log "Invalid choice. Select 1 or 2." "ERROR"
                ;;
        esac
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

get_record_id_by_name() {
    local name="$1"
    local type="$2"
    
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?name=${name}&type=${type}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        echo "$response" | jq -r '.result[0].id // empty'
    else
        echo ""
    fi
}

# =============================================
# DUAL-IP DNS SETUP
# =============================================

setup_dual_ip_dns() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          DUAL IP DNS SETUP"
    echo "════════════════════════════════════════════════"
    echo
    echo "This setup creates DNS records that distribute"
    echo "traffic between two IP addresses."
    echo
    echo "Features:"
    echo "  • Traffic distribution between 2 IPs"
    echo "  • No automatic failover (no downtime)"
    echo "  • Manual IP management"
    echo "  • Health checking (optional)"
    echo
    
    # Get two IP addresses
    local ip1 ip2
    
    echo "Enter the two IP addresses for DNS distribution:"
    echo "------------------------------------------------"
    
    # First IP
    while true; do
        read -rp "First IP Address: " ip1
        if validate_ip "$ip1"; then
            break
        fi
        log "Invalid IPv4 address format" "ERROR"
    done
    
    # Second IP
    while true; do
        read -rp "Second IP Address: " ip2
        if validate_ip "$ip2"; then
            if [ "$ip1" = "$ip2" ]; then
                log "Warning: Both IPs are the same!" "WARNING"
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
    
    # Get CNAME prefix
    echo
    echo "Enter DNS record name:"
    echo "----------------------"
    echo "This will be your CNAME (e.g., app.example.com)"
    echo
    
    local cname_prefix
    read -rp "Subdomain prefix (leave empty for random): " cname_prefix
    
    if [ -z "$cname_prefix" ]; then
        local random_id
        random_id=$(date +%s%N | md5sum | cut -c1-8)
        cname_prefix="app-${random_id}"
    fi
    
    local cname="${cname_prefix}.${BASE_HOST}"
    
    echo
    log "Creating Dual-IP DNS configuration..." "INFO"
    echo
    
    # Create A records with different hostnames
    local host1="${cname_prefix}-a1.${BASE_HOST}"
    local host2="${cname_prefix}-a2.${BASE_HOST}"
    
    # Create first A record
    log "Creating first A record: $host1 → $ip1" "INFO"
    local record_id1
    record_id1=$(create_dns_record "$host1" "A" "$ip1")
    if [ -z "$record_id1" ]; then
        log "Failed to create first A record" "ERROR"
        return 1
    fi
    
    # Create second A record
    log "Creating second A record: $host2 → $ip2" "INFO"
    local record_id2
    record_id2=$(create_dns_record "$host2" "A" "$ip2")
    if [ -z "$record_id2" ]; then
        log "Failed to create second A record" "ERROR"
        delete_dns_record "$record_id1"
        return 1
    fi
    
    # Create CNAME record
    log "Creating CNAME: $cname" "INFO"
    
    # Based on strategy, create appropriate DNS configuration
    if [ "$LB_STRATEGY" = "round-robin" ]; then
        # For round-robin, create both A records with same name
        log "Strategy: Round Robin (both IPs equally)" "INFO"
        
        # Create additional A record for second IP (same name)
        local record_id3
        record_id3=$(create_dns_record "$cname" "A" "$ip2")
        
        # Update first A record to use CNAME name
        delete_dns_record "$record_id1"
        record_id1=$(create_dns_record "$cname" "A" "$ip1")
        
        echo
        echo "════════════════════════════════════════════════"
        log "DUAL-IP DNS CREATED SUCCESSFULLY!" "SUCCESS"
        echo "════════════════════════════════════════════════"
        echo
        echo "Your DNS configuration:"
        echo -e "  ${GREEN}$cname${NC} (Round Robin)"
        echo "  ↳ IP: $ip1"
        echo "  ↳ IP: $ip2"
        echo
        echo "Traffic will be distributed equally between both IPs."
        
        # Update state with both record IDs
        save_state "$cname" "$ip1" "$ip2" "$record_id1" "$record_id3"
        
    else # weight-based
        log "Strategy: Weight Based (70% primary, 30% backup)" "INFO"
        
        # Create CNAME that points to primary
        local cname_record_id
        cname_record_id=$(create_dns_record "$cname" "CNAME" "$host1")
        
        if [ -z "$cname_record_id" ]; then
            log "Failed to create CNAME record" "ERROR"
            delete_dns_record "$record_id1"
            delete_dns_record "$record_id2"
            return 1
        fi
        
        echo
        echo "════════════════════════════════════════════════"
        log "DUAL-IP DNS CREATED SUCCESSFULLY!" "SUCCESS"
        echo "════════════════════════════════════════════════"
        echo
        echo "Your DNS configuration:"
        echo -e "  ${GREEN}$cname${NC} (Weight Based)"
        echo "  ↳ Primary: $host1 → $ip1 (70% traffic)"
        echo "  ↳ Backup:  $host2 → $ip2 (30% traffic)"
        echo
        echo "Note: Manual switching required for failover."
        
        # Save state
        save_state "$cname" "$ip1" "$ip2" "$record_id1" "$record_id2"
    fi
    
    echo
    echo "DNS Settings:"
    echo "  TTL: $DNS_TTL seconds"
    echo "  Propagation: Usually within 2-5 minutes"
    echo
    echo "You can now use ${GREEN}$cname${NC} in your applications."
    echo
}

# =============================================
# HEALTH CHECKING (OPTIONAL, MANUAL)
# =============================================

check_ip_health() {
    local ip="$1"
    
    log "Checking health of IP: $ip" "DEBUG"
    
    # Try multiple methods for reliability
    local healthy=false
    
    # Method 1: ping
    if command -v ping &>/dev/null; then
        if timeout 2 ping -c 1 -W 1 "$ip" &>/dev/null; then
            healthy=true
            log "Ping successful for $ip" "DEBUG"
        fi
    fi
    
    # Method 2: curl on port 80
    if [ "$healthy" = false ] && command -v curl &>/dev/null; then
        if timeout 2 curl -s -f "http://$ip" &>/dev/null; then
            healthy=true
            log "HTTP check successful for $ip" "DEBUG"
        fi
    fi
    
    # Method 3: nc on port 80
    if [ "$healthy" = false ] && command -v nc &>/dev/null; then
        if timeout 2 nc -z -w 1 "$ip" 80 &>/dev/null; then
            healthy=true
            log "Port 80 check successful for $ip" "DEBUG"
        fi
    fi
    
    if [ "$healthy" = true ]; then
        echo "healthy"
    else
        echo "unhealthy"
    fi
}

check_health_status() {
    echo
    echo "════════════════════════════════════════════════"
    echo "           MANUAL HEALTH CHECK"
    echo "════════════════════════════════════════════════"
    echo
    echo "This checks the health of both IPs without"
    echo "making any DNS changes."
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No dual-IP setup found" "ERROR"
        return 1
    fi
    
    local ip1 ip2 cname
    ip1=$(jq -r '.ip1 // empty' "$STATE_FILE")
    ip2=$(jq -r '.ip2 // empty' "$STATE_FILE")
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    
    if [ -z "$ip1" ] || [ -z "$ip2" ]; then
        log "IP addresses not found in state" "ERROR"
        return 1
    fi
    
    echo "Checking IP health status..."
    echo
    
    echo -n "Primary IP ($ip1): "
    local health1
    health1=$(check_ip_health "$ip1")
    if [ "$health1" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    echo -n "Backup IP ($ip2): "
    local health2
    health2=$(check_ip_health "$ip2")
    if [ "$health2" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    echo
    echo "CNAME: $cname"
    echo
    echo "Note: This is a manual check only."
    echo "No DNS records were modified."
}

# =============================================
# MANUAL IP MANAGEMENT
# =============================================

manual_ip_management() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          MANUAL IP MANAGEMENT"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No dual-IP setup found" "ERROR"
        return 1
    fi
    
    local cname ip1 ip2 record_id1 record_id2 strategy
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    ip1=$(jq -r '.ip1 // empty' "$STATE_FILE")
    ip2=$(jq -r '.ip2 // empty' "$STATE_FILE")
    record_id1=$(jq -r '.record_id1 // empty' "$STATE_FILE")
    record_id2=$(jq -r '.record_id2 // empty' "$STATE_FILE")
    strategy=$(jq -r '.strategy // "round-robin"' "$STATE_FILE")
    
    echo "Current Configuration:"
    echo "  CNAME: $cname"
    echo "  IP1: $ip1"
    echo "  IP2: $ip2"
    echo "  Strategy: $strategy"
    echo
    
    echo "Options:"
    echo "1. Switch to use only IP1"
    echo "2. Switch to use only IP2"
    echo "3. Use both IPs (round-robin)"
    echo "4. Update IP addresses"
    echo "5. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log "Switching to use only IP1 ($ip1)..." "INFO"
            if [ "$strategy" = "round-robin" ]; then
                # Delete second A record
                delete_dns_record "$record_id2"
                log "Now using only IP1 ($ip1)" "SUCCESS"
            else
                # Update CNAME to point to host1
                update_cname_target "$cname" "${cname%-*}-a1.${BASE_HOST}"
                log "Switched to IP1 ($ip1)" "SUCCESS"
            fi
            ;;
        2)
            log "Switching to use only IP2 ($ip2)..." "INFO"
            if [ "$strategy" = "round-robin" ]; then
                # Delete first A record, keep second
                delete_dns_record "$record_id1"
                log "Now using only IP2 ($ip2)" "SUCCESS"
            else
                # Update CNAME to point to host2
                update_cname_target "$cname" "${cname%-*}-a2.${BASE_HOST}"
                log "Switched to IP2 ($ip2)" "SUCCESS"
            fi
            ;;
        3)
            log "Enabling both IPs (round-robin)..." "INFO"
            if [ "$strategy" = "weight-based" ]; then
                # Create A records for both IPs
                delete_dns_record "$record_id1"
                delete_dns_record "$record_id2"
                
                record_id1=$(create_dns_record "$cname" "A" "$ip1")
                record_id2=$(create_dns_record "$cname" "A" "$ip2")
                
                if [ -n "$record_id1" ] && [ -n "$record_id2" ]; then
                    # Update state
                    local temp_file
                    temp_file=$(mktemp)
                    jq --arg strategy "round-robin" \
                       --arg record_id1 "$record_id1" \
                       --arg record_id2 "$record_id2" \
                       '.strategy = $strategy | .record_id1 = $record_id1 | .record_id2 = $record_id2' \
                       "$STATE_FILE" > "$temp_file"
                    mv "$temp_file" "$STATE_FILE"
                    
                    log "Enabled round-robin with both IPs" "SUCCESS"
                fi
            else
                log "Already using round-robin" "INFO"
            fi
            ;;
        4)
            update_ip_addresses
            ;;
        5)
            return
            ;;
        *)
            log "Invalid option" "ERROR"
            ;;
    esac
}

update_ip_addresses() {
    echo
    echo "Update IP Addresses:"
    echo "--------------------"
    
    local new_ip1 new_ip2
    
    while true; do
        read -rp "New first IP: " new_ip1
        if validate_ip "$new_ip1"; then
            break
        fi
        log "Invalid IPv4 address" "ERROR"
    done
    
    while true; do
        read -rp "New second IP: " new_ip2
        if validate_ip "$new_ip2"; then
            break
        fi
        log "Invalid IPv4 address" "ERROR"
    done
    
    log "Updating IP addresses..." "INFO"
    
    # Get current strategy
    local strategy
    strategy=$(jq -r '.strategy // "round-robin"' "$STATE_FILE")
    
    if [ "$strategy" = "round-robin" ]; then
        # Update both A records
        local record_id1 record_id2
        record_id1=$(jq -r '.record_id1 // empty' "$STATE_FILE")
        record_id2=$(jq -r '.record_id2 // empty' "$STATE_FILE")
        
        # Delete old records
        delete_dns_record "$record_id1"
        delete_dns_record "$record_id2"
        
        # Create new records
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE")
        
        record_id1=$(create_dns_record "$cname" "A" "$new_ip1")
        record_id2=$(create_dns_record "$cname" "A" "$new_ip2")
        
        if [ -n "$record_id1" ] && [ -n "$record_id2" ]; then
            # Update state
            local temp_file
            temp_file=$(mktemp)
            jq --arg ip1 "$new_ip1" \
               --arg ip2 "$new_ip2" \
               --arg record_id1 "$record_id1" \
               --arg record_id2 "$record_id2" \
               '.ip1 = $ip1 | .ip2 = $ip2 | .record_id1 = $record_id1 | .record_id2 = $record_id2' \
               "$STATE_FILE" > "$temp_file"
            mv "$temp_file" "$STATE_FILE"
            
            log "IP addresses updated successfully" "SUCCESS"
        fi
    else
        # For weight-based, update the A records
        local host1 host2 record_id1 record_id2
        host1="${cname%-*}-a1.${BASE_HOST}"
        host2="${cname%-*}-a2.${BASE_HOST}"
        
        record_id1=$(get_record_id_by_name "$host1" "A")
        record_id2=$(get_record_id_by_name "$host2" "A")
        
        if [ -n "$record_id1" ]; then
            # Delete and recreate with new IP
            delete_dns_record "$record_id1"
            create_dns_record "$host1" "A" "$new_ip1"
        fi
        
        if [ -n "$record_id2" ]; then
            delete_dns_record "$record_id2")
            create_dns_record "$host2" "A" "$new_ip2"
        fi
        
        # Update state
        local temp_file
        temp_file=$(mktemp)
        jq --arg ip1 "$new_ip1" \
           --arg ip2 "$new_ip2" \
           '.ip1 = $ip1 | .ip2 = $ip2' \
           "$STATE_FILE" > "$temp_file"
        mv "$temp_file" "$STATE_FILE"
        
        log "IP addresses updated successfully" "SUCCESS"
    fi
}

update_cname_target() {
    local cname="$1"
    local target="$2"
    
    # Get CNAME record ID
    local record_id
    record_id=$(get_record_id_by_name "$cname" "CNAME")
    
    if [ -z "$record_id" ]; then
        log "CNAME record not found: $cname" "ERROR"
        return 1
    fi
    
    local data
    data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$cname",
  "content": "$target",
  "ttl": $DNS_TTL,
  "proxied": false
}
EOF
)
    
    local response
    response=$(api_request "PUT" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        log "Updated CNAME: $cname → $target" "SUCCESS"
        return 0
    else
        log "Failed to update CNAME" "ERROR"
        echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

# =============================================
# STATUS AND INFO FUNCTIONS
# =============================================

show_status() {
    echo
    echo "════════════════════════════════════════════════"
    echo "           CURRENT STATUS"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ -f "$STATE_FILE" ]; then
        local cname ip1 ip2 strategy created_at
        cname=$(jq -r '.cname // empty' "$STATE_FILE")
        ip1=$(jq -r '.ip1 // empty' "$STATE_FILE")
        ip2=$(jq -r '.ip2 // empty' "$STATE_FILE")
        strategy=$(jq -r '.strategy // "round-robin"' "$STATE_FILE")
        created_at=$(jq -r '.created_at // empty' "$STATE_FILE")
        
        if [ -n "$cname" ]; then
            echo -e "${GREEN}Dual-IP DNS Configuration:${NC}"
            echo "  CNAME: $cname"
            echo "  IP1: $ip1"
            echo "  IP2: $ip2"
            echo "  Strategy: $strategy"
            echo "  Created: $created_at"
            echo
            
            # Show current DNS records
            echo -e "${CYAN}Current DNS Records:${NC}"
            
            if [ "$strategy" = "round-robin" ]; then
                echo "  $cname → $ip1 (A)"
                echo "  $cname → $ip2 (A)"
                echo "  Traffic: Distributed equally"
            else
                local host1 host2
                host1="${cname%-*}-a1.${BASE_HOST}"
                host2="${cname%-*}-a2.${BASE_HOST}"
                echo "  $cname → $host1 (CNAME)"
                echo "  $host1 → $ip1 (A)"
                echo "  $host2 → $ip2 (A)"
                echo "  Traffic: 70% primary, 30% backup"
            fi
        fi
    else
        echo -e "${YELLOW}No dual-IP DNS configuration found${NC}"
        echo
    fi
    
    # API status
    echo
    echo -e "${PURPLE}API Status:${NC}"
    if load_config && test_api; then
        echo -e "  Connection: ${GREEN}✓ OK${NC}"
        if test_zone; then
            echo -e "  Zone Access: ${GREEN}✓ OK${NC}"
        else
            echo -e "  Zone Access: ${RED}✗ FAILED${NC}"
        fi
    else
        echo -e "  Connection: ${RED}✗ NOT CONFIGURED${NC}"
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
            echo "           YOUR DUAL-IP DNS RECORD"
            echo "════════════════════════════════════════════════"
            echo
            echo -e "  ${GREEN}$cname${NC}"
            echo
            echo "This CNAME distributes traffic between two IPs."
            echo
            echo "Usage:"
            echo "  • Use $cname in your applications"
            echo "  • DNS will distribute traffic automatically"
            echo "  • No automatic failover (stable operation)"
            echo
            echo "DNS propagation: Usually 2-5 minutes"
            echo
        else
            log "No dual-IP DNS record found" "ERROR"
        fi
    else
        log "No dual-IP DNS record found" "ERROR"
    fi
}

# =============================================
# CLEANUP FUNCTION
# =============================================

cleanup() {
    echo
    log "WARNING: This will delete ALL dual-IP DNS records!" "WARNING"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No dual-IP setup found to cleanup" "ERROR"
        return 1
    fi
    
    local cname ip1 ip2 record_id1 record_id2 strategy
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    ip1=$(jq -r '.ip1 // empty' "$STATE_FILE")
    ip2=$(jq -r '.ip2 // empty' "$STATE_FILE")
    record_id1=$(jq -r '.record_id1 // empty' "$STATE_FILE")
    record_id2=$(jq -r '.record_id2 // empty' "$STATE_FILE")
    strategy=$(jq -r '.strategy // "round-robin"' "$STATE_FILE")
    
    if [ -z "$cname" ]; then
        log "No active dual-IP setup found" "ERROR"
        return 1
    fi
    
    echo "Records to delete:"
    echo "  CNAME: $cname"
    echo "  IP1: $ip1"
    echo "  IP2: $ip2"
    echo "  Strategy: $strategy"
    echo
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    log "Deleting DNS records..." "INFO"
    
    # Delete records based on strategy
    if [ "$strategy" = "round-robin" ]; then
        # Delete both A records
        delete_dns_record "$record_id1"
        delete_dns_record "$record_id2"
    else
        # Delete CNAME and A records
        local cname_record_id
        cname_record_id=$(get_record_id_by_name "$cname" "CNAME")
        delete_dns_record "$cname_record_id"
        
        # Delete A records
        delete_dns_record "$record_id1"
        delete_dns_record "$record_id2"
    fi
    
    # Delete state file
    rm -f "$STATE_FILE"
    
    log "Cleanup completed!" "SUCCESS"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE DUAL-IP DNS MANAGER v3.0       ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Create Dual-IP DNS Record               ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                     ║"
    echo -e "║  ${GREEN}3.${NC} Manual IP Management                    ║"
    echo -e "║  ${GREEN}4.${NC} Check IP Health (Manual)                ║"
    echo -e "║  ${GREEN}5.${NC} Show My CNAME                           ║"
    echo -e "║  ${GREEN}6.${NC} Cleanup (Delete All)                    ║"
    echo -e "║  ${GREEN}7.${NC} Configure API Settings                  ║"
    echo -e "║  ${GREEN}8.${NC} Exit                                    ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname ip1 ip2 strategy
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        ip1=$(jq -r '.ip1 // empty' "$STATE_FILE" 2>/dev/null || echo "")
        ip2=$(jq -r '.ip2 // empty' "$STATE_FILE" 2>/dev/null || echo "")
        strategy=$(jq -r '.strategy // "round-robin"' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$cname" ]; then
            echo -e "║  ${CYAN}Active: $cname${NC}"
            echo -e "║  ${CYAN}IPs: $ip1 / $ip2${NC}"
            echo -e "║  ${CYAN}Strategy: $strategy${NC}"
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
                    setup_dual_ip_dns
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
                    manual_ip_management
                else
                    log "Please configure API settings first (option 7)" "ERROR"
                fi
                pause
                ;;
            4)
                if load_config; then
                    check_health_status
                else
                    log "Please configure API settings first (option 7)" "ERROR"
                fi
                pause
                ;;
            5)
                show_cname
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
