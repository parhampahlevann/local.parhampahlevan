#!/usr/bin/env bash
# Cloudflare Dual-IP Failover Manager
# Uses DNS Round Robin with manual failover - Works on all Cloudflare plans

set -euo pipefail

TOOL_NAME="cf-dualip-manager"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${CONFIG_DIR}/state.json"
LOG_FILE="${CONFIG_DIR}/activity.log"
LAST_CNAME_FILE="${CONFIG_DIR}/last_cname.txt"
HEALTH_LOG="${CONFIG_DIR}/health.log"

CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}✗${NC} $1"
    echo "[ERROR] $1" >> "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
    echo "[SUCCESS] $1" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}→${NC} $1"
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE" "$HEALTH_LOG"
}

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

install_prereqs() {
    info "Checking prerequisites..."
    
    local missing=0
    
    # Check curl
    if ! command -v curl >/dev/null 2>&1; then
        error "curl not found. Installing..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y curl
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y curl
        else
            error "Please install curl manually"
            missing=1
        fi
    fi
    
    # Check jq
    if ! command -v jq >/dev/null 2>&1; then
        error "jq not found. Installing..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y jq
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq
        else
            error "Please install jq manually"
            missing=1
        fi
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
    "primary_ip": "$1",
    "backup_ip": "$2",
    "cname": "$3",
    "primary_record_id": "$4",
    "backup_record_id": "$5",
    "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
    "active_ip": "$1"
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
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${CF_API_BASE}${endpoint}"
    local response
    
    if [[ -n "$data" ]]; then
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"Connection failed"}]}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"Connection failed"}]}')
    fi
    
    echo "$response"
}

test_api() {
    info "Testing API token..."
    local response
    response=$(api_request "GET" "/user/tokens/verify")
    
    local success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        local email=$(echo "$response" | jq -r '.result.email // "Unknown"')
        success "API Token valid (User: $email)"
        return 0
    else
        error "Invalid API token"
        return 1
    fi
}

test_zone() {
    info "Testing zone access..."
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}")
    
    local success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        local zone=$(echo "$response" | jq -r '.result.name // "Unknown"')
        success "Zone access confirmed: $zone"
        return 0
    else
        error "Invalid zone ID"
        return 1
    fi
}

configure_api() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "        CLOUDFLARE API CONFIGURATION"
    echo "═══════════════════════════════════════════════"
    echo
    
    echo "1. Get your API Token from:"
    echo "   https://dash.cloudflare.com/profile/api-tokens"
    echo "   Required permissions: Zone.DNS (Edit)"
    echo
    
    while true; do
        read -rp "Enter API Token: " CF_API_TOKEN
        if [[ -z "$CF_API_TOKEN" ]]; then
            error "API Token cannot be empty"
            continue
        fi
        
        if test_api; then
            break
        fi
    done
    
    echo
    echo "2. Get your Zone ID from Cloudflare Dashboard"
    echo "   Your Site → Overview → API Section"
    echo
    
    while true; do
        read -rp "Enter Zone ID: " CF_ZONE_ID
        if [[ -z "$CF_ZONE_ID" ]]; then
            error "Zone ID cannot be empty"
            continue
        fi
        
        if test_zone; then
            break
        fi
    done
    
    echo
    echo "3. Enter your base domain"
    echo "   Example: example.com or api.example.com"
    echo
    
    while true; do
        read -rp "Base domain: " BASE_HOST
        if [[ -z "$BASE_HOST" ]]; then
            error "Domain cannot be empty"
        else
            break
        fi
    done
    
    save_config
    success "Configuration saved!"
}

valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    
    local IFS=.
    read -r a b c d <<< "$ip"
    [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 ]]
}

generate_name() {
    date +"%Y%m%d%H%M%S" | md5sum | cut -c1-8
}

create_dns_record() {
    local name="$1"
    local type="$2"
    local content="$3"
    
    local data=$(cat <<EOF
{
    "type": "$type",
    "name": "$name",
    "content": "$content",
    "ttl": 120,
    "proxied": false,
    "comment": "Created by cf-dualip-manager"
}
EOF
)
    
    local response
    response=$(api_request "POST" "/zones/${CF_ZONE_ID}/dns_records" "$data")
    
    local success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        local record_id=$(echo "$response" | jq -r '.result.id // ""')
        echo "$record_id"
        return 0
    else
        error "Failed to create DNS record: $name"
        echo "$response" | jq -r '.errors[].message' 2>/dev/null || echo "$response"
        return 1
    fi
}

delete_dns_record() {
    local record_id="$1"
    
    if [[ -z "$record_id" ]]; then
        return 0
    fi
    
    local response
    response=$(api_request "DELETE" "/zones/${CF_ZONE_ID}/dns_records/$record_id")
    
    local success=$(echo "$response" | jq -r '.success // false')
    if [[ "$success" == "true" ]]; then
        log "Deleted record: $record_id"
        return 0
    else
        error "Failed to delete record: $record_id"
        return 1
    fi
}

setup_dual_ip() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "         DUAL IP FAILOVER SETUP"
    echo "═══════════════════════════════════════════════"
    echo
    
    # Get IPs
    local primary_ip backup_ip
    
    while true; do
        read -rp "Enter PRIMARY IP (active): " primary_ip
        if valid_ipv4 "$primary_ip"; then
            break
        fi
        error "Invalid IP address"
    done
    
    while true; do
        read -rp "Enter BACKUP IP (failover): " backup_ip
        if valid_ipv4 "$backup_ip"; then
            if [[ "$primary_ip" == "$backup_ip" ]]; then
                warning "Warning: Primary and Backup IPs are the same!"
                read -rp "Continue anyway? (y/n): " ans
                [[ "$ans" =~ ^[Yy]$ ]] && break
            else
                break
            fi
        else
            error "Invalid IP address"
        fi
    done
    
    # Generate unique names
    local unique_id=$(generate_name)
    local cname_host="app-${unique_id}.${BASE_HOST}"
    local primary_host="primary-${unique_id}.${BASE_HOST}"
    local backup_host="backup-${unique_id}.${BASE_HOST}"
    
    info "Creating DNS records..."
    
    # Create A record for primary
    info "Creating Primary A record: $primary_host → $primary_ip"
    local primary_record_id
    primary_record_id=$(create_dns_record "$primary_host" "A" "$primary_ip")
    [[ -z "$primary_record_id" ]] && return 1
    
    # Create A record for backup
    info "Creating Backup A record: $backup_host → $backup_ip"
    local backup_record_id
    backup_record_id=$(create_dns_record "$backup_host" "A" "$backup_ip")
    [[ -z "$backup_record_id" ]] && return 1
    
    # Create CNAME record pointing to primary
    info "Creating CNAME: $cname_host → $primary_host"
    local cname_record_id
    cname_record_id=$(create_dns_record "$cname_host" "CNAME" "$primary_host")
    [[ -z "$cname_record_id" ]] && return 1
    
    # Save state
    save_state "$primary_ip" "$backup_ip" "$cname_host" "$primary_record_id" "$backup_record_id"
    
    # Save CNAME to file
    echo "$cname_host" > "$LAST_CNAME_FILE"
    
    echo
    success "═══════════════════════════════════════════════"
    success "         SETUP COMPLETED SUCCESSFULLY!"
    success "═══════════════════════════════════════════════"
    echo
    echo "Your CNAME is:"
    echo -e "  ${GREEN}$cname_host${NC}"
    echo
    echo "DNS Configuration:"
    echo "  Primary: $primary_host → $primary_ip"
    echo "  Backup:  $backup_host → $backup_ip"
    echo "  CNAME:   $cname_host → $primary_host"
    echo
    echo "Current traffic is routed to: ${GREEN}PRIMARY IP ($primary_ip)${NC}"
    echo
    echo "To manually switch to backup IP:"
    echo "  1. Run this script"
    echo "  2. Choose option 3 (Manual Failover)"
    echo "  3. Select 'Switch to Backup'"
    echo
}

show_status() {
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    if [[ -z "$cname" ]]; then
        error "No dual-IP setup found. Please run setup first."
        return 1
    fi
    
    echo
    echo "═══════════════════════════════════════════════"
    echo "           CURRENT STATUS"
    echo "═══════════════════════════════════════════════"
    echo
    echo -e "CNAME: ${GREEN}$cname${NC}"
    echo
    echo "IP Addresses:"
    echo -e "  Primary: $primary_ip $( [[ "$active_ip" == "$primary_ip" ]] && echo -e "${GREEN}[ACTIVE]${NC}" )"
    echo -e "  Backup:  $backup_ip $( [[ "$active_ip" == "$backup_ip" ]] && echo -e "${GREEN}[ACTIVE]${NC}" )"
    echo
    
    # Test connectivity
    info "Testing connectivity..."
    echo
    
    # Test primary IP
    echo -e "Primary IP ($primary_ip):"
    if ping -c 2 -W 1 "$primary_ip" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Reachable${NC}"
    else
        echo -e "  ${RED}✗ Unreachable${NC}"
    fi
    
    # Test backup IP
    echo -e "Backup IP ($backup_ip):"
    if ping -c 2 -W 1 "$backup_ip" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Reachable${NC}"
    else
        echo -e "  ${RED}✗ Unreachable${NC}"
    fi
    
    # Test CNAME
    echo -e "CNAME ($cname):"
    if command -v dig >/dev/null 2>&1; then
        local resolved_ip
        resolved_ip=$(dig +short "$cname" 2>/dev/null | head -1)
        if [[ -n "$resolved_ip" ]]; then
            echo -e "  ${GREEN}✓ Resolves to: $resolved_ip${NC}"
        else
            echo -e "  ${RED}✗ DNS resolution failed${NC}"
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        echo -n "  "
        nslookup "$cname" 2>/dev/null | grep "Address:" | tail -1
    else
        echo "  (Install dig or nslookup for DNS test)"
    fi
    
    echo
    echo "═══════════════════════════════════════════════"
}

manual_failover() {
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').${BASE_HOST}"
    local backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/app-//').${BASE_HOST}"
    local cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    if [[ -z "$cname" ]]; then
        error "No setup found"
        return 1
    fi
    
    echo
    echo "═══════════════════════════════════════════════"
    echo "           MANUAL FAILOVER CONTROL"
    echo "═══════════════════════════════════════════════"
    echo
    echo "Current CNAME: $cname"
    echo
    echo "1. Switch to Primary IP ($primary_ip)"
    echo "2. Switch to Backup IP ($backup_ip)"
    echo "3. Test both IPs and auto-select"
    echo "4. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            info "Switching to Primary IP..."
            # First delete existing CNAME
            if [[ -n "$cname_record_id" ]]; then
                delete_dns_record "$cname_record_id"
            fi
            
            # Create new CNAME pointing to primary
            local new_record_id
            new_record_id=$(create_dns_record "$cname" "CNAME" "$primary_host")
            if [[ -n "$new_record_id" ]]; then
                # Update state
                local state_json
                state_json=$(echo "$state" | jq --arg ip "$primary_ip" --arg id "$new_record_id" \
                    '.active_ip = $ip | .cname_record_id = $id')
                echo "$state_json" > "$STATE_FILE"
                
                success "Switched to Primary IP! DNS may take a few minutes to propagate."
                echo "CNAME $cname now points to $primary_host → $primary_ip"
            fi
            ;;
        2)
            info "Switching to Backup IP..."
            # First delete existing CNAME
            if [[ -n "$cname_record_id" ]]; then
                delete_dns_record "$cname_record_id"
            fi
            
            # Create new CNAME pointing to backup
            local new_record_id
            new_record_id=$(create_dns_record "$cname" "CNAME" "$backup_host")
            if [[ -n "$new_record_id" ]]; then
                # Update state
                local state_json
                state_json=$(echo "$state" | jq --arg ip "$backup_ip" --arg id "$new_record_id" \
                    '.active_ip = $ip | .cname_record_id = $id')
                echo "$state_json" > "$STATE_FILE"
                
                success "Switched to Backup IP! DNS may take a few minutes to propagate."
                echo "CNAME $cname now points to $backup_host → $backup_ip"
            fi
            ;;
        3)
            info "Testing IPs and auto-selecting..."
            
            local primary_ok=false
            local backup_ok=false
            
            # Test primary
            if ping -c 2 -W 1 "$primary_ip" >/dev/null 2>&1; then
                info "Primary IP ($primary_ip) is reachable"
                primary_ok=true
            else
                warning "Primary IP ($primary_ip) is unreachable"
            fi
            
            # Test backup
            if ping -c 2 -W 1 "$backup_ip" >/dev/null 2>&1; then
                info "Backup IP ($backup_ip) is reachable"
                backup_ok=true
            else
                warning "Backup IP ($backup_ip) is unreachable"
            fi
            
            if $primary_ok; then
                info "Auto-selecting Primary IP (preferred)"
                # Switch to primary
                if [[ -n "$cname_record_id" ]]; then
                    delete_dns_record "$cname_record_id"
                fi
                local new_record_id
                new_record_id=$(create_dns_record "$cname" "CNAME" "$primary_host")
                if [[ -n "$new_record_id" ]]; then
                    local state_json
                    state_json=$(echo "$state" | jq --arg ip "$primary_ip" --arg id "$new_record_id" \
                        '.active_ip = $ip | .cname_record_id = $id')
                    echo "$state_json" > "$STATE_FILE"
                    success "Auto-switched to Primary IP"
                fi
            elif $backup_ok; then
                info "Auto-selecting Backup IP (primary is down)"
                # Switch to backup
                if [[ -n "$cname_record_id" ]]; then
                    delete_dns_record "$cname_record_id"
                fi
                local new_record_id
                new_record_id=$(create_dns_record "$cname" "CNAME" "$backup_host")
                if [[ -n "$new_record_id" ]]; then
                    local state_json
                    state_json=$(echo "$state" | jq --arg ip "$backup_ip" --arg id "$new_record_id" \
                        '.active_ip = $ip | .cname_record_id = $id')
                    echo "$state_json" > "$STATE_FILE"
                    success "Auto-switched to Backup IP"
                fi
            else
                error "Both IPs are unreachable!"
            fi
            ;;
    esac
    
    pause
}

auto_monitor() {
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    local backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    local active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    
    if [[ -z "$cname" ]]; then
        error "No setup found"
        return 1
    fi
    
    echo
    echo "═══════════════════════════════════════════════"
    echo "        AUTO-MONITOR & FAILOVER"
    echo "═══════════════════════════════════════════════"
    echo
    info "Monitoring started. Press Ctrl+C to stop."
    echo
    
    local check_interval=15  # seconds
    local failure_count=0
    local max_failures=2
    
    while true; do
        clear
        echo "╔═══════════════════════════════════════════════╗"
        echo "║           REAL-TIME MONITORING                ║"
        echo "╠═══════════════════════════════════════════════╣"
        echo "║  Time: $(date '+%H:%M:%S')"
        echo "║  CNAME: $cname"
        echo "╠═══════════════════════════════════════════════╣"
        
        # Check primary IP
        local primary_status
        if ping -c 1 -W 2 "$primary_ip" >/dev/null 2>&1; then
            primary_status="${GREEN}✓ ONLINE${NC}"
            failure_count=0
        else
            primary_status="${RED}✗ OFFLINE${NC}"
            failure_count=$((failure_count + 1))
        fi
        
        # Check backup IP
        local backup_status
        if ping -c 1 -W 2 "$backup_ip" >/dev/null 2>&1; then
            backup_status="${GREEN}✓ ONLINE${NC}"
        else
            backup_status="${RED}✗ OFFLINE${NC}"
        fi
        
        echo -e "║  Primary ($primary_ip): $primary_status"
        echo -e "║  Backup  ($backup_ip): $backup_status"
        echo "╠═══════════════════════════════════════════════╣"
        
        # Determine status
        if [[ "$active_ip" == "$primary_ip" ]]; then
            if [[ "$primary_status" == *"✓ ONLINE"* ]]; then
                echo -e "║  Status: ${GREEN}Using Primary IP${NC}"
                echo "║          (Normal operation)"
            else
                echo -e "║  Status: ${YELLOW}Primary failing${NC}"
                echo "║          ($failure_count/$max_failures consecutive failures)"
            fi
        else
            echo -e "║  Status: ${YELLOW}Using Backup IP${NC}"
            echo "║          (Failover active)"
        fi
        
        echo "╠═══════════════════════════════════════════════╣"
        echo "║  Failover threshold: $max_failures consecutive failures"
        echo "║  Check interval: $check_interval seconds"
        echo "║  Next check in: $check_interval seconds"
        echo "╚═══════════════════════════════════════════════╝"
        
        # Auto-failover logic
        if [[ "$active_ip" == "$primary_ip" ]] && [[ $failure_count -ge $max_failures ]]; then
            echo
            warning "Primary IP failed $failure_count times. Initiating failover..."
            # Call manual failover to switch to backup
            local state_json
            state_json=$(echo "$state" | jq --arg ip "$backup_ip" '.active_ip = $ip')
            echo "$state_json" > "$STATE_FILE"
            active_ip="$backup_ip"
            failure_count=0
            echo -e "${GREEN}Failover completed! Now using Backup IP.${NC}"
        fi
        
        # Log to health file
        echo "$(date '+%Y-%m-%d %H:%M:%S'),$primary_ip,$([[ "$primary_status" == *"✓"* ]] && echo "UP" || echo "DOWN"),$backup_ip,$([[ "$backup_status" == *"✓"* ]] && echo "UP" || echo "DOWN"),$active_ip" >> "$HEALTH_LOG"
        
        sleep "$check_interval"
    done
}

cleanup() {
    echo
    warning "This will delete ALL created DNS records!"
    echo
    
    local state
    state=$(load_state)
    
    local cname=$(echo "$state" | jq -r '.cname // empty')
    local primary_record_id=$(echo "$state" | jq -r '.primary_record_id // empty')
    local backup_record_id=$(echo "$state" | jq -r '.backup_record_id // empty')
    local cname_record_id=$(echo "$state" | jq -r '.cname_record_id // empty')
    
    if [[ -z "$cname" ]]; then
        error "No setup found to cleanup"
        return 1
    fi
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        info "Cleanup cancelled"
        return 0
    fi
    
    info "Deleting DNS records..."
    
    # Delete CNAME
    if [[ -n "$cname_record_id" ]]; then
        delete_dns_record "$cname_record_id"
    fi
    
    # Also try to find and delete by name
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?name=${cname}")
    local records=$(echo "$response" | jq -r '.result[]?.id // empty')
    for record_id in $records; do
        delete_dns_record "$record_id"
    done
    
    # Delete primary A record
    if [[ -n "$primary_record_id" ]]; then
        delete_dns_record "$primary_record_id"
    fi
    
    # Delete backup A record
    if [[ -n "$backup_record_id" ]]; then
        delete_dns_record "$backup_record_id"
    fi
    
    # Clean up files
    rm -f "$STATE_FILE" "$LAST_CNAME_FILE"
    
    success "Cleanup completed!"
}

show_cname() {
    if [[ -f "$LAST_CNAME_FILE" ]]; then
        local cname
        cname=$(cat "$LAST_CNAME_FILE")
        echo
        echo "═══════════════════════════════════════════════"
        echo "           YOUR CNAME"
        echo "═══════════════════════════════════════════════"
        echo
        echo -e "  ${GREEN}$cname${NC}"
        echo
        echo "Use this CNAME in your applications."
        echo "DNS propagation may take 1-2 minutes."
        echo
        echo "To change which IP is active:"
        echo "  Run this script → Manual Failover"
        echo
    else
        error "No CNAME found. Please run setup first."
    fi
}

show_menu() {
    clear
    echo
    echo "╔═══════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE DUAL-IP FAILOVER MANAGER       ║"
    echo "╠═══════════════════════════════════════════════╣"
    echo "║                                               ║"
    echo -e "║  ${GREEN}1.${NC} Complete Setup (Create Dual-IP CNAME)     ║"
    echo -e "║  ${GREEN}2.${NC} Show Current Status                      ║"
    echo -e "║  ${GREEN}3.${NC} Manual Failover Control                  ║"
    echo -e "║  ${GREEN}4.${NC} Auto-Monitor & Failover                  ║"
    echo -e "║  ${GREEN}5.${NC} Show My CNAME                            ║"
    echo -e "║  ${GREEN}6.${NC} Cleanup (Delete All)                     ║"
    echo -e "║  ${GREEN}7.${NC} Configure API Settings                   ║"
    echo -e "║  ${GREEN}8.${NC} Exit                                     ║"
    echo "║                                               ║"
    echo "╠═══════════════════════════════════════════════╣"
    
    # Show current CNAME if exists
    if [[ -f "$STATE_FILE" ]]; then
        local cname
        cname=$(cat "$STATE_FILE" | jq -r '.cname // empty' 2>/dev/null)
        if [[ -n "$cname" ]]; then
            local active_ip
            active_ip=$(cat "$STATE_FILE" | jq -r '.active_ip // empty' 2>/dev/null)
            echo -e "║  ${CYAN}Current: $cname${NC}          ║"
            echo -e "║  ${CYAN}Active IP: $active_ip${NC}                ║"
        fi
    fi
    
    echo "╚═══════════════════════════════════════════════╝"
    echo
}

main() {
    ensure_dir
    
    # Check prerequisites
    if ! install_prereqs; then
        error "Failed to install prerequisites"
        exit 1
    fi
    
    # Check if config exists
    if ! load_config; then
        warning "First-time setup required"
        configure_api
    fi
    
    while true; do
        show_menu
        
        read -rp "Select option (1-8): " choice
        
        case $choice in
            1)
                setup_dual_ip
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                manual_failover
                ;;
            4)
                auto_monitor
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

# Run main function
main
