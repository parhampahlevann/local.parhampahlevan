#!/bin/bash

# =============================================
# CLOUDFLARE SMART LOAD BALANCER v4.1
# =============================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-smart-lb"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
HEALTH_LOG="$CONFIG_DIR/health.log"
LOCK_FILE="/tmp/cf-lb.lock"

# Cloudflare API
CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

# Smart Load Balancer Settings
PRIMARY_IP=""
BACKUP_IP=""
CNAME=""
DNS_TTL=60  # 1 minute TTL for fast failover

# Health Check Settings
HEALTH_CHECK_INTERVAL=30  # Check every 30 seconds
HEALTH_CHECK_TIMEOUT=10   # Increased to 10 seconds for better protocol handling
MAX_FAILURES=3            # 3 failures = 90 seconds downtime before failover
RECOVERY_THRESHOLD=5      # 5 successful checks = 150 seconds before recovery

# Protocol Settings
ENABLE_QUIC=false
ENABLE_HTTPS=true
PREFERRED_PORTS=(443 80 22)  # Try HTTPS first, then HTTP, then SSH
CUSTOM_PORTS=()  # User can add custom ports

# Performance Settings
ENABLE_PERFORMANCE_MONITOR=true
MIN_RESPONSE_TIME_MS=100
MAX_RESPONSE_TIME_MS=3000  # Increased for QUIC/HTTPS handshakes

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
NC='\033[0m'

# =============================================
# LOCK MANAGEMENT (Prevent Multiple Instances)
# =============================================

acquire_lock() {
    local max_retries=10
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
            trap 'release_lock' EXIT
            return 0
        fi
        
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
        fi
        
        sleep 1
        retry_count=$((retry_count + 1))
    done
    
    log "Could not acquire lock after $max_retries attempts" "ERROR"
    return 1
}

release_lock() {
    rm -f "$LOCK_FILE"
}

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
        "HEALTH")
            echo -e "${BLUE}[$timestamp] [HEALTH]${NC} $msg" >> "$HEALTH_LOG"
            ;;
        "DEBUG")
            echo -e "${PURPLE}[$timestamp] [DEBUG]${NC} $msg" >> "$LOG_FILE"
            ;;
        "PERF")
            echo -e "${ORANGE}[$timestamp] [PERF]${NC} $msg" >> "$LOG_FILE"
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
    touch "$HEALTH_LOG" 2>/dev/null || true
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
    
    # Check timeout
    if ! command -v timeout &>/dev/null; then
        log "timeout is not installed" "ERROR"
        echo "Install with: sudo apt-get install coreutils"
        missing=1
    fi
    
    # Check for nc (netcat) for TCP checks
    if ! command -v nc &>/dev/null; then
        log "netcat is not installed (optional, but recommended)" "WARNING"
        echo "Install with: sudo apt-get install netcat"
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
        
        # Load additional configs
        if [ -f "$STATE_FILE" ]; then
            PRIMARY_IP=$(jq -r '.primary_ip // empty' "$STATE_FILE")
            BACKUP_IP=$(jq -r '.backup_ip // empty' "$STATE_FILE")
            CNAME=$(jq -r '.cname // empty' "$STATE_FILE")
        fi
        
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
HEALTH_CHECK_INTERVAL="$HEALTH_CHECK_INTERVAL"
HEALTH_CHECK_TIMEOUT="$HEALTH_CHECK_TIMEOUT"
MAX_FAILURES="$MAX_FAILURES"
RECOVERY_THRESHOLD="$RECOVERY_THRESHOLD"
ENABLE_PERFORMANCE_MONITOR="$ENABLE_PERFORMANCE_MONITOR"
MIN_RESPONSE_TIME_MS="$MIN_RESPONSE_TIME_MS"
MAX_RESPONSE_TIME_MS="$MAX_RESPONSE_TIME_MS"
ENABLE_QUIC="$ENABLE_QUIC"
ENABLE_HTTPS="$ENABLE_HTTPS"
PREFERRED_PORTS=(${PREFERRED_PORTS[@]})
CUSTOM_PORTS=(${CUSTOM_PORTS[@]})
EOF
    log "Configuration saved" "SUCCESS"
}

save_state() {
    local cname="$1"
    local primary_ip="$2"
    local backup_ip="$3"
    local primary_record_id="$4"
    local backup_record_id="$5"
    local cname_record_id="$6"
    
    cat > "$STATE_FILE" << EOF
{
  "cname": "$cname",
  "primary_ip": "$primary_ip",
  "backup_ip": "$backup_ip",
  "primary_record_id": "$primary_record_id",
  "backup_record_id": "$backup_record_id",
  "cname_record_id": "$cname_record_id",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "active_ip": "$primary_ip",
  "health_status": {
    "primary": "unknown",
    "backup": "unknown"
  },
  "failure_count": 0,
  "recovery_count": 0,
  "last_health_check": "$(date '+%Y-%m-%d %H:%M:%S')",
  "total_failovers": 0,
  "last_failover": null,
  "protocol_settings": {
    "enable_quic": "$ENABLE_QUIC",
    "enable_https": "$ENABLE_HTTPS",
    "preferred_ports": "${PREFERRED_PORTS[*]}",
    "custom_ports": "${CUSTOM_PORTS[*]}"
  }
}
EOF
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

increment_counter() {
    local key="$1"
    
    if [ -f "$STATE_FILE" ]; then
        local current_value
        current_value=$(jq -r ".[\"$key\"] // 0" "$STATE_FILE")
        local new_value=$((current_value + 1))
        
        local temp_file
        temp_file=$(mktemp)
        jq --arg key "$key" --argjson new_value "$new_value" '.[$key] = $new_value' "$STATE_FILE" > "$temp_file"
        mv "$temp_file" "$STATE_FILE"
    fi
}

# =============================================
# IMPROVED HEALTH CHECK SYSTEM
# =============================================

perform_health_check() {
    local ip="$1"
    local check_type="${2:-smart}"
    
    local start_time
    start_time=$(date +%s%N)
    local result="unhealthy"
    local response_time=0
    local protocol_used=""
    
    # Combine preferred ports and custom ports
    local all_ports=("${PREFERRED_PORTS[@]}" "${CUSTOM_PORTS[@]}")
    
    # Try different protocols and ports with adaptive timeout
    for port in "${all_ports[@]}"; do
        # Skip if port is empty
        [ -z "$port" ] && continue
        
        # Determine protocol based on port
        local protocol="tcp"
        local curl_opts=""
        
        if [ "$port" -eq 443 ] || [ "$port" -eq 8443 ]; then
            if [ "$ENABLE_HTTPS" = "true" ]; then
                protocol="https"
                curl_opts="-k"  # Don't verify SSL for speed
                
                if [ "$ENABLE_QUIC" = "true" ] && command -v nghttp2 &>/dev/null; then
                    # Try HTTP/3 (QUIC) first if enabled
                    if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f $curl_opts --http3 "https://$ip:$port" &>/dev/null; then
                        result="healthy"
                        protocol_used="http3"
                        break
                    fi
                fi
                
                # Try HTTP/2
                if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f $curl_opts --http2 "https://$ip:$port" &>/dev/null; then
                    result="healthy"
                    protocol_used="https"
                    break
                fi
            fi
        elif [ "$port" -eq 80 ]; then
            protocol="http"
        elif [ "$port" -eq 22 ]; then
            protocol="ssh"
        fi
        
        # Try the connection with appropriate method
        case $protocol in
            "https")
                if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f $curl_opts "https://$ip:$port" &>/dev/null; then
                    result="healthy"
                    protocol_used="https"
                    break
                fi
                ;;
            "http")
                if timeout "$HEALTH_CHECK_TIMEOUT" curl -s -f "http://$ip:$port" &>/dev/null; then
                    result="healthy"
                    protocol_used="http"
                    break
                fi
                ;;
            "ssh")
                # SSH check (just banner, not full login)
                if command -v nc &>/dev/null; then
                    if timeout "$HEALTH_CHECK_TIMEOUT" bash -c "echo 'SSH-2.0-HealthCheck' | nc -w 2 $ip $port | grep -i ssh" &>/dev/null; then
                        result="healthy"
                        protocol_used="ssh"
                        break
                    fi
                elif timeout "$HEALTH_CHECK_TIMEOUT" bash -c "echo > /dev/tcp/$ip/$port" &>/dev/null; then
                    result="healthy"
                    protocol_used="tcp"
                    break
                fi
                ;;
            *)
                # Generic TCP check
                if command -v nc &>/dev/null; then
                    if timeout "$HEALTH_CHECK_TIMEOUT" nc -z -w 2 "$ip" "$port" &>/dev/null; then
                        result="healthy"
                        protocol_used="tcp"
                        break
                    fi
                elif timeout "$HEALTH_CHECK_TIMEOUT" bash -c "echo > /dev/tcp/$ip/$port" &>/dev/null; then
                    result="healthy"
                    protocol_used="tcp"
                    break
                fi
                ;;
        esac
    done
    
    # If no port worked, try a simple ICMP ping (if allowed)
    if [ "$result" = "unhealthy" ] && ping -c 1 -W 2 "$ip" &>/dev/null; then
        result="reachable"  # Host is reachable but no service responding
        protocol_used="icmp"
    fi
    
    # Calculate response time
    local end_time
    end_time=$(date +%s%N)
    response_time=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds
    
    # Log protocol used if successful
    if [ "$result" = "healthy" ] && [ -n "$protocol_used" ]; then
        log "Health check for $ip succeeded via $protocol_used (${response_time}ms)" "DEBUG"
    fi
    
    # Performance monitoring
    if [ "$ENABLE_PERFORMANCE_MONITOR" = "true" ]; then
        if [ "$result" = "healthy" ]; then
            if [ "$response_time" -gt "$MAX_RESPONSE_TIME_MS" ]; then
                result="degraded"
                log "Performance degraded for $ip via $protocol_used: ${response_time}ms" "PERF"
            elif [ "$response_time" -lt "$MIN_RESPONSE_TIME_MS" ]; then
                log "Excellent performance for $ip via $protocol_used: ${response_time}ms" "PERF"
            fi
        fi
    fi
    
    echo "$result:$response_time:$protocol_used"
}

# =============================================
# DNS MANAGEMENT (FIXED CNAME HANDLING)
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
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        log "Created $type record: $name → $content (ID: $record_id)" "DEBUG"
        echo "$record_id"
        return 0
    else
        log "Failed to create $type record: $name → $content" "ERROR"
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$response")
        log "API Error: $error_msg" "DEBUG"
        return 1
    fi
}

update_cname_target() {
    local cname="$1"
    local target_host="$2"
    
    # Get existing CNAME record ID
    local response
    response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${cname}")
    
    if echo "$response" | jq -e '.success == true' &>/dev/null; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result[0].id // empty')
        
        if [ -z "$record_id" ]; then
            log "CNAME record not found: $cname" "ERROR"
            return 1
        fi
        
        local data
        data=$(cat << EOF
{
  "type": "CNAME",
  "name": "$cname",
  "content": "$target_host",
  "ttl": $DNS_TTL,
  "proxied": false
}
EOF
)
        
        local update_response
        update_response=$(api_request "PUT" "/zones/${CF_ZONE_ID}/dns_records/$record_id" "$data")
        
        if echo "$update_response" | jq -e '.success == true' &>/dev/null; then
            log "Updated CNAME: $cname → $target_host" "SUCCESS"
            
            # Verify the update
            sleep 2  # Small delay for Cloudflare propagation
            local verify_response
            verify_response=$(api_request "GET" "/zones/${CF_ZONE_ID}/dns_records/$record_id")
            
            if echo "$verify_response" | jq -e '.success == true' &>/dev/null; then
                local current_target
                current_target=$(echo "$verify_response" | jq -r '.result.content')
                if [ "$current_target" = "$target_host" ]; then
                    log "CNAME update verified: $cname → $current_target" "DEBUG"
                    return 0
                else
                    log "CNAME update mismatch. Expected: $target_host, Got: $current_target" "WARNING"
                    return 0  # Still return success as update was accepted
                fi
            fi
            return 0
        else
            log "Failed to update CNAME" "ERROR"
            local error_msg
            error_msg=$(echo "$update_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "$update_response")
            log "API Error: $error_msg" "DEBUG"
            return 1
        fi
    else
        log "Failed to fetch CNAME record: $cname" "ERROR"
        return 1
    fi
}

# =============================================
# ENHANCED SETUP WITH PROTOCOL OPTIONS
# =============================================

setup_smart_load_balancer() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          SMART LOAD BALANCER SETUP"
    echo "════════════════════════════════════════════════"
    echo
    echo "This creates an intelligent load balancer with:"
    echo "  • Multi-protocol health checks (HTTP/HTTPS/QUIC/TCP)"
    echo "  • Primary IP priority (always used if healthy)"
    echo "  • Automatic failover to Backup IP"
    echo "  • Automatic recovery to Primary IP"
    echo "  • Performance monitoring"
    echo
    
    # Get IP addresses
    local primary_ip backup_ip
    
    echo "Enter IP addresses:"
    echo "-------------------"
    
    # Primary IP
    while true; do
        read -rp "Primary IP (main server - ALWAYS used if healthy): " primary_ip
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
    
    # Protocol configuration
    echo
    echo "Protocol Configuration:"
    echo "----------------------"
    read -rp "Enable HTTPS health checks? (y/n, default: y): " enable_https
    if [[ "$enable_https" =~ ^[Nn]$ ]]; then
        ENABLE_HTTPS="false"
        # Remove port 443 from preferred ports if HTTPS disabled
        PREFERRED_PORTS=(${PREFERRED_PORTS[@]/443})
    fi
    
    if [ "$ENABLE_HTTPS" = "true" ]; then
        read -rp "Enable QUIC/HTTP3 checks? (y/n, default: n): " enable_quic
        if [[ "$enable_quic" =~ ^[Yy]$ ]]; then
            ENABLE_QUIC="true"
        fi
    fi
    
    # Custom ports
    echo
    echo "Custom Ports (optional):"
    echo "Enter additional ports to check (space-separated, e.g., 8080 8443)"
    read -rp "Custom ports: " custom_ports_input
    if [ -n "$custom_ports_input" ]; then
        CUSTOM_PORTS=($custom_ports_input)
    fi
    
    # Generate unique names
    local random_id
    random_id=$(date +%s%N | md5sum | cut -c1-8)
    local cname="lb-${random_id}.${BASE_HOST}"
    local primary_host="primary-${random_id}.${BASE_HOST}"
    local backup_host="backup-${random_id}.${BASE_HOST}"
    
    echo
    log "Creating Smart Load Balancer..." "INFO"
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
    save_state "$cname" "$primary_ip" "$backup_ip" "$primary_record_id" "$backup_record_id" "$cname_record_id"
    
    echo
    echo "════════════════════════════════════════════════"
    log "SMART LOAD BALANCER CREATED SUCCESSFULLY!" "SUCCESS"
    echo "════════════════════════════════════════════════"
    echo
    echo "Your Load Balancer CNAME:"
    echo -e "  ${GREEN}$cname${NC}"
    echo
    echo "Configuration:"
    echo "  Primary: $primary_host → $primary_ip"
    echo "  Backup:  $backup_host → $backup_ip"
    echo "  CNAME:   $cname → $primary_host"
    echo
    echo "Protocol Settings:"
    echo "  HTTPS enabled: $ENABLE_HTTPS"
    echo "  QUIC enabled: $ENABLE_QUIC"
    echo "  Default ports: ${PREFERRED_PORTS[*]}"
    if [ ${#CUSTOM_PORTS[@]} -gt 0 ]; then
        echo "  Custom ports: ${CUSTOM_PORTS[*]}"
    fi
    echo
    echo "Smart Failover Settings:"
    echo "  Health Check: Every ${HEALTH_CHECK_INTERVAL} seconds"
    echo "  Health Timeout: ${HEALTH_CHECK_TIMEOUT} seconds"
    echo "  Failover after: $((HEALTH_CHECK_INTERVAL * MAX_FAILURES)) seconds"
    echo "  Recovery after: $((HEALTH_CHECK_INTERVAL * RECOVERY_THRESHOLD)) seconds"
    echo "  DNS TTL: ${DNS_TTL} seconds (fast propagation)"
    echo
    echo "To start the load balancer monitor:"
    echo "  Run this script → Start Load Balancer Service"
    echo
}

# =============================================
# ENHANCED MONITOR SERVICE WITH PROTOCOL INFO
# =============================================

monitor_service() {
    if ! acquire_lock; then
        log "Another monitor instance is already running" "ERROR"
        return 1
    fi
    
    log "Starting Smart Load Balancer Monitor..." "INFO"
    log "Health Check Interval: ${HEALTH_CHECK_INTERVAL} seconds" "INFO"
    log "Health Check Timeout: ${HEALTH_CHECK_TIMEOUT} seconds" "INFO"
    
    if [ "$ENABLE_QUIC" = "true" ]; then
        log "QUIC/HTTP3 checks enabled" "INFO"
    fi
    
    if [ ${#CUSTOM_PORTS[@]} -gt 0 ]; then
        log "Custom ports: ${CUSTOM_PORTS[*]}" "INFO"
    fi
    
    # Load initial state
    local state
    state=$(load_state)
    
    local cname
    cname=$(echo "$state" | jq -r '.cname // empty')
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found. Please run setup first." "ERROR"
        release_lock
        return 1
    fi
    
    log "Monitoring load balancer: $cname" "SUCCESS"
    log "Press Ctrl+C to stop monitoring" "INFO"
    
    # Trap signals
    trap 'cleanup_monitor' INT TERM EXIT
    
    # Main monitoring loop
    local monitoring=true
    while $monitoring; do
        # Check if config still exists
        if [ ! -f "$STATE_FILE" ]; then
            log "Load balancer configuration removed. Stopping monitor." "INFO"
            monitoring=false
            break
        fi
        
        state=$(load_state)
        
        local primary_ip backup_ip active_ip failure_count recovery_count
        primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
        backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
        active_ip=$(echo "$state" | jq -r '.active_ip // empty')
        failure_count=$(echo "$state" | jq -r '.failure_count // 0')
        recovery_count=$(echo "$state" | jq -r '.recovery_count // 0')
        
        # Update last check time
        update_state "last_health_check" "$(date '+%Y-%m-%d %H:%M:%S')"
        
        # Check primary IP health
        log "Checking Primary IP ($primary_ip) health..." "HEALTH"
        local health_result
        health_result=$(perform_health_check "$primary_ip")
        local primary_health="${health_result%%:*}"
        local rest="${health_result#*:}"
        local primary_response_time="${rest%%:*}"
        local primary_protocol="${rest#*:}"
        
        # Update health status with protocol info
        update_state "health_status.primary" "$primary_health"
        update_state "health_status.primary_protocol" "$primary_protocol"
        update_state "health_status.primary_response_time" "$primary_response_time"
        
        # Check backup IP health (less frequently)
        local backup_check_interval=$((HEALTH_CHECK_INTERVAL * 3))
        local current_time
        current_time=$(date +%s)
        local last_backup_check
        last_backup_check=$(echo "$state" | jq -r '.last_backup_check // 0')
        
        if [ $((current_time - last_backup_check)) -ge $backup_check_interval ]; then
            log "Checking Backup IP ($backup_ip) health..." "HEALTH"
            local backup_health_result
            backup_health_result=$(perform_health_check "$backup_ip")
            local backup_health="${backup_health_result%%:*}"
            local backup_rest="${backup_health_result#*:}"
            local backup_response_time="${backup_rest%%:*}"
            local backup_protocol="${backup_rest#*:}"
            
            update_state "health_status.backup" "$backup_health"
            update_state "health_status.backup_protocol" "$backup_protocol"
            update_state "health_status.backup_response_time" "$backup_response_time"
            update_state "last_backup_check" "$current_time"
        fi
        
        # Handle primary IP health status
        if [ "$primary_health" = "healthy" ] || [ "$primary_health" = "degraded" ] || [ "$primary_health" = "reachable" ]; then
            # Primary is healthy, degraded but functional, or at least reachable
            update_state "failure_count" "0"
            
            # If currently on backup and primary is healthy/degraded, start recovery count
            if [ "$active_ip" = "$backup_ip" ]; then
                local new_recovery_count=$((recovery_count + 1))
                update_state "recovery_count" "$new_recovery_count"
                
                if [ "$primary_health" = "healthy" ]; then
                    log "Primary IP ($primary_ip) is healthy via $primary_protocol (${primary_response_time}ms). Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "HEALTH"
                elif [ "$primary_health" = "degraded" ]; then
                    log "Primary IP ($primary_ip) is degraded via $primary_protocol (${primary_response_time}ms). Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "HEALTH"
                else
                    log "Primary IP ($primary_ip) is reachable but services not responding. Recovery count: $new_recovery_count/$RECOVERY_THRESHOLD" "HEALTH"
                fi
                
                # Check if we should switch back to primary
                if [ "$new_recovery_count" -ge "$RECOVERY_THRESHOLD" ] && { [ "$primary_health" = "healthy" ] || [ "$primary_health" = "degraded" ]; }; then
                    perform_recovery
                fi
            else
                # Reset recovery count if already on primary
                update_state "recovery_count" "0"
                if [ "$primary_health" = "degraded" ]; then
                    log "Primary IP ($primary_ip) performance degraded via $primary_protocol: ${primary_response_time}ms" "WARNING"
                elif [ "$primary_health" = "reachable" ]; then
                    log "Primary IP ($primary_ip) reachable but services not responding" "WARNING"
                fi
            fi
        else
            # Primary is unhealthy
            local new_failure_count=$((failure_count + 1))
            update_state "failure_count" "$new_failure_count"
            
            log "Primary IP ($primary_ip) is unhealthy. Failure count: $new_failure_count/$MAX_FAILURES" "HEALTH"
            
            # Check backup health before failover
            local backup_health
            backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
            
            # Check if we should switch to backup
            if [ "$new_failure_count" -ge "$MAX_FAILURES" ] && [ "$active_ip" = "$primary_ip" ]; then
                if [ "$backup_health" = "healthy" ] || [ "$backup_health" = "degraded" ] || [ "$backup_health" = "reachable" ]; then
                    perform_failover
                else
                    log "Backup IP ($backup_ip) is also unhealthy. Cannot failover!" "ERROR"
                    update_state "failure_count" "$((MAX_FAILURES - 1))"  # Reset to keep checking but not trigger failover
                fi
            fi
            
            # Reset recovery count when primary is down
            update_state "recovery_count" "0"
        fi
        
        # Sleep before next check
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    
    cleanup_monitor
}

# =============================================
# ENHANCED MANUAL CONTROL WITH PROTOCOL INFO
# =============================================

manual_control() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          MANUAL LOAD BALANCER CONTROL"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    local state
    state=$(load_state)
    
    local cname primary_ip backup_ip active_ip primary_health backup_health
    cname=$(echo "$state" | jq -r '.cname // empty')
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    primary_health=$(echo "$state" | jq -r '.health_status.primary // "unknown"')
    backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
    
    echo "Current Status:"
    echo "  CNAME: $cname"
    echo "  Active IP: $active_ip"
    echo "  Primary IP ($primary_ip): $primary_health"
    echo "  Backup IP ($backup_ip): $backup_health"
    echo
    
    echo "Manual Control Options:"
    echo "1. Force switch to Primary IP"
    echo "2. Force switch to Backup IP"
    echo "3. Run immediate health check"
    echo "4. Test specific port/protocol"
    echo "5. View detailed status"
    echo "6. Back to main menu"
    echo
    
    read -rp "Select option: " choice
    
    case $choice in
        1)
            log "Forcing switch to Primary IP ($primary_ip)..." "INFO"
            local primary_host
            primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$primary_host"; then
                update_state "active_ip" "$primary_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Primary IP ($primary_ip)" "SUCCESS"
            fi
            ;;
        2)
            log "Forcing switch to Backup IP ($backup_ip)..." "INFO"
            local backup_host
            backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
            if update_cname_target "$cname" "$backup_host"; then
                update_state "active_ip" "$backup_ip"
                update_state "failure_count" "0"
                update_state "recovery_count" "0"
                log "Switched to Backup IP ($backup_ip)" "SUCCESS"
            fi
            ;;
        3)
            echo
            echo "Running immediate health checks..."
            echo "---------------------------------"
            
            echo -n "Primary IP ($primary_ip): "
            local health_result
            health_result=$(perform_health_check "$primary_ip")
            local health="${health_result%%:*}"
            local rest="${health_result#*:}"
            local response_time="${rest%%:*}"
            local protocol="${rest#*:}"
            
            if [ "$health" = "healthy" ]; then
                echo -e "${GREEN}✓ HEALTHY${NC} via $protocol (${response_time}ms)"
            elif [ "$health" = "degraded" ]; then
                echo -e "${YELLOW}⚠ DEGRADED${NC} via $protocol (${response_time}ms)"
            elif [ "$health" = "reachable" ]; then
                echo -e "${YELLOW}⚠ REACHABLE${NC} but no service response"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            
            echo -n "Backup IP ($backup_ip): "
            health_result=$(perform_health_check "$backup_ip")
            health="${health_result%%:*}"
            rest="${health_result#*:}"
            response_time="${rest%%:*}"
            protocol="${rest#*:}"
            
            if [ "$health" = "healthy" ]; then
                echo -e "${GREEN}✓ HEALTHY${NC} via $protocol (${response_time}ms)"
            elif [ "$health" = "degraded" ]; then
                echo -e "${YELLOW}⚠ DEGRADED${NC} via $protocol (${response_time}ms)"
            elif [ "$health" = "reachable" ]; then
                echo -e "${YELLOW}⚠ REACHABLE${NC} but no service response"
            else
                echo -e "${RED}✗ UNHEALTHY${NC}"
            fi
            
            # Update state
            update_state "health_status.primary" "$health"
            update_state "health_status.primary_protocol" "$protocol"
            update_state "health_status.backup" "$health"
            update_state "health_status.backup_protocol" "$protocol"
            ;;
        4)
            echo
            echo "Test Specific Port/Protocol:"
            echo "---------------------------"
            read -rp "Enter IP address: " test_ip
            read -rp "Enter port (default: 80): " test_port
            test_port=${test_port:-80}
            read -rp "Protocol (http/https/tcp, default: http): " test_protocol
            test_protocol=${test_protocol:-http}
            
            echo -n "Testing $test_protocol://$test_ip:$test_port... "
            
            local start_time
            start_time=$(date +%s%N)
            local success=false
            
            case $test_protocol in
                "https")
                    if timeout 10 curl -s -f -k "https://$test_ip:$test_port" &>/dev/null; then
                        success=true
                    fi
                    ;;
                "http")
                    if timeout 10 curl -s -f "http://$test_ip:$test_port" &>/dev/null; then
                        success=true
                    fi
                    ;;
                "tcp")
                    if command -v nc &>/dev/null; then
                        if timeout 10 nc -z -w 2 "$test_ip" "$test_port" &>/dev/null; then
                            success=true
                        fi
                    elif timeout 10 bash -c "echo > /dev/tcp/$test_ip/$test_port" &>/dev/null; then
                        success=true
                    fi
                    ;;
            esac
            
            local end_time
            end_time=$(date +%s%N)
            local response_time=$(( (end_time - start_time) / 1000000 ))
            
            if $success; then
                echo -e "${GREEN}SUCCESS${NC} (${response_time}ms)"
            else
                echo -e "${RED}FAILED${NC}"
            fi
            ;;
        5)
            show_detailed_status
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
# ENHANCED STATUS WITH PROTOCOL INFO
# =============================================

show_detailed_status() {
    echo
    echo "════════════════════════════════════════════════"
    echo "          LOAD BALANCER DETAILED STATUS"
    echo "════════════════════════════════════════════════"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found" "ERROR"
        return 1
    fi
    
    local state
    state=$(load_state)
    
    local cname primary_ip backup_ip active_ip created_at
    local failure_count recovery_count total_failovers last_failover
    local primary_health backup_health last_health_check
    local primary_protocol backup_protocol
    local primary_response_time backup_response_time
    
    cname=$(echo "$state" | jq -r '.cname // empty')
    primary_ip=$(echo "$state" | jq -r '.primary_ip // empty')
    backup_ip=$(echo "$state" | jq -r '.backup_ip // empty')
    active_ip=$(echo "$state" | jq -r '.active_ip // empty')
    created_at=$(echo "$state" | jq -r '.created_at // empty')
    failure_count=$(echo "$state" | jq -r '.failure_count // 0')
    recovery_count=$(echo "$state" | jq -r '.recovery_count // 0')
    total_failovers=$(echo "$state" | jq -r '.total_failovers // 0')
    last_failover=$(echo "$state" | jq -r '.last_failover // "Never"')
    primary_health=$(echo "$state" | jq -r '.health_status.primary // "unknown"')
    backup_health=$(echo "$state" | jq -r '.health_status.backup // "unknown"')
    primary_protocol=$(echo "$state" | jq -r '.health_status.primary_protocol // ""')
    backup_protocol=$(echo "$state" | jq -r '.health_status.backup_protocol // ""')
    primary_response_time=$(echo "$state" | jq -r '.health_status.primary_response_time // ""')
    backup_response_time=$(echo "$state" | jq -r '.health_status.backup_response_time // ""')
    last_health_check=$(echo "$state" | jq -r '.last_health_check // "Never"')
    
    echo -e "${GREEN}Load Balancer Configuration:${NC}"
    echo "  CNAME: $cname"
    echo "  Created: $created_at"
    echo
    
    echo -e "${CYAN}IP Status:${NC}"
    echo -n "  Primary ($primary_ip): "
    if [ "$primary_health" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    elif [ "$primary_health" = "degraded" ]; then
        echo -e "${YELLOW}⚠ DEGRADED${NC}"
    elif [ "$primary_health" = "reachable" ]; then
        echo -e "${YELLOW}⚠ REACHABLE${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    if [ -n "$primary_protocol" ] && [ -n "$primary_response_time" ]; then
        echo "    Protocol: $primary_protocol, Response: ${primary_response_time}ms"
    fi
    
    echo -n "  Backup ($backup_ip): "
    if [ "$backup_health" = "healthy" ]; then
        echo -e "${GREEN}✓ HEALTHY${NC}"
    elif [ "$backup_health" = "degraded" ]; then
        echo -e "${YELLOW}⚠ DEGRADED${NC}"
    elif [ "$backup_health" = "reachable" ]; then
        echo -e "${YELLOW}⚠ REACHABLE${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY${NC}"
    fi
    
    if [ -n "$backup_protocol" ] && [ -n "$backup_response_time" ]; then
        echo "    Protocol: $backup_protocol, Response: ${backup_response_time}ms"
    fi
    
    echo -n "  Active IP: "
    if [ "$active_ip" = "$primary_ip" ]; then
        echo -e "${GREEN}$active_ip (PRIMARY)${NC}"
    else
        echo -e "${YELLOW}$active_ip (BACKUP - FAILOVER)${NC}"
    fi
    echo
    
    echo -e "${PURPLE}Failover Status:${NC}"
    echo "  Failure Count: $failure_count/$MAX_FAILURES"
    echo "  Recovery Count: $recovery_count/$RECOVERY_THRESHOLD"
    echo "  Total Failovers: $total_failovers"
    echo "  Last Failover: $last_failover"
    echo "  Last Health Check: $last_health_check"
    echo
    
    # Protocol Settings
    echo -e "${ORANGE}Protocol Settings:${NC}"
    echo "  HTTPS Enabled: $ENABLE_HTTPS"
    echo "  QUIC Enabled: $ENABLE_QUIC"
    echo "  Default Ports: ${PREFERRED_PORTS[*]}"
    if [ ${#CUSTOM_PORTS[@]} -gt 0 ]; then
        echo "  Custom Ports: ${CUSTOM_PORTS[*]}"
    fi
    
    # Check monitor status
    echo -e "${ORANGE}Monitor Status:${NC}"
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo -e "  Status: ${GREEN}RUNNING${NC} (PID: $lock_pid)"
        else
            echo -e "  Status: ${RED}STOPPED${NC}"
            rm -f "$LOCK_FILE"
        fi
    else
        echo -e "  Status: ${YELLOW}NOT RUNNING${NC}"
    fi
    
    echo
    echo "════════════════════════════════════════════════"
}

# =============================================
# API FUNCTIONS (unchanged from your original)
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
            --max-time 10 \
            --retry 2 \
            --retry-delay 1 \
            --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"message":"API Connection failed"}]}')
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            --retry 2 \
            --retry-delay 1 \
            2>/dev/null || echo '{"success":false,"errors":[{"message":"API Connection failed"}]}')
    fi
    
    echo "$response"
}

# =============================================
# IP VALIDATION (unchanged from your original)
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
# MAIN MENU (updated with protocol info)
# =============================================

show_menu() {
    clear
    echo
    echo "╔════════════════════════════════════════════════╗"
    echo "║    CLOUDFLARE SMART LOAD BALANCER v4.1       ║"
    echo "╠════════════════════════════════════════════════╣"
    echo "║                                                ║"
    echo -e "║  ${GREEN}1.${NC} Create Smart Load Balancer               ║"
    echo -e "║  ${GREEN}2.${NC} Show Detailed Status                     ║"
    echo -e "║  ${GREEN}3.${NC} Start Load Balancer Service              ║"
    echo -e "║  ${GREEN}4.${NC} Stop Load Balancer Service               ║"
    echo -e "║  ${GREEN}5.${NC} Manual Control                           ║"
    echo -e "║  ${GREEN}6.${NC} Show My CNAME                            ║"
    echo -e "║  ${GREEN}7.${NC} Cleanup (Delete All)                     ║"
    echo -e "║  ${GREEN}8.${NC} Configure API Settings                   ║"
    echo -e "║  ${GREEN}9.${NC} Exit                                     ║"
    echo "║                                                ║"
    echo "╠════════════════════════════════════════════════╣"
    
    # Show current status
    if [ -f "$STATE_FILE" ]; then
        local cname active_ip primary_health primary_protocol
        cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
        active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
        primary_health=$(jq -r '.health_status.primary // "unknown"' "$STATE_FILE" 2>/dev/null || echo "")
        primary_protocol=$(jq -r '.health_status.primary_protocol // ""' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$cname" ]; then
            local monitor_status=""
            
            if [ -f "$LOCK_FILE" ]; then
                local lock_pid
                lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
                if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                    monitor_status="${GREEN}●${NC}"
                else
                    monitor_status="${RED}●${NC}"
                fi
            else
                monitor_status="${YELLOW}○${NC}"
            fi
            
            local health_status=""
            if [ "$primary_health" = "healthy" ]; then
                health_status="${GREEN}✓${NC}"
            elif [ "$primary_health" = "degraded" ] || [ "$primary_health" = "reachable" ]; then
                health_status="${YELLOW}⚠${NC}"
            else
                health_status="${RED}✗${NC}"
            fi
            
            local protocol_info=""
            if [ -n "$primary_protocol" ]; then
                protocol_info=" via $primary_protocol"
            fi
            
            echo -e "║  ${CYAN}LB: $cname${NC}"
            echo -e "║  ${CYAN}Active: $active_ip ${health_status}${protocol_info} ${monitor_status}${NC}"
        fi
    fi
    
    echo "╚════════════════════════════════════════════════╝"
    echo
}

# =============================================
# MAIN FUNCTION (unchanged)
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
                    setup_smart_load_balancer
                else
                    log "Please configure API settings first (option 8)" "ERROR"
                fi
                pause
                ;;
            2)
                show_detailed_status
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

# Include missing functions from original script
# (These functions remain unchanged from your original version)

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

perform_failover() {
    acquire_lock || return 1
    
    local cname primary_ip backup_ip active_ip
    cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found for failover" "ERROR"
        release_lock
        return 1
    fi
    
    if [ "$active_ip" = "$backup_ip" ]; then
        log "Already using Backup IP ($backup_ip)" "INFO"
        release_lock
        return 0
    fi
    
    log "Primary IP ($primary_ip) is unhealthy! Initiating failover..." "WARNING"
    
    local backup_host
    backup_host="backup-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
    log "Switching CNAME to backup: $cname → $backup_host" "INFO"
    
    if update_cname_target "$cname" "$backup_host"; then
        update_state "active_ip" "$backup_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        increment_counter "total_failovers"
        update_state "last_failover" "$(date '+%Y-%m-%d %H:%M:%S')"
        log "Failover completed! Now using Backup IP ($backup_ip)" "SUCCESS"
        release_lock
        return 0
    else
        log "Failed to perform failover" "ERROR"
        release_lock
        return 1
    fi
}

perform_recovery() {
    acquire_lock || return 1
    
    local cname primary_ip backup_ip active_ip
    cname=$(jq -r '.cname // empty' "$STATE_FILE" 2>/dev/null || echo "")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    active_ip=$(jq -r '.active_ip // empty' "$STATE_FILE" 2>/dev/null || echo "")
    
    if [ -z "$cname" ]; then
        log "No load balancer setup found for recovery" "ERROR"
        release_lock
        return 1
    fi
    
    if [ "$active_ip" = "$primary_ip" ]; then
        log "Already using Primary IP ($primary_ip)" "INFO"
        release_lock
        return 0
    fi
    
    log "Primary IP ($primary_ip) is healthy again! Switching back..." "INFO"
    
    local primary_host
    primary_host="primary-$(echo "$cname" | cut -d'.' -f1 | sed 's/lb-//').${BASE_HOST}"
    log "Switching CNAME to primary: $cname → $primary_host" "INFO"
    
    if update_cname_target "$cname" "$primary_host"; then
        update_state "active_ip" "$primary_ip"
        update_state "failure_count" "0"
        update_state "recovery_count" "0"
        log "Recovery completed! Now using Primary IP ($primary_ip)" "SUCCESS"
        release_lock
        return 0
    else
        log "Failed to perform recovery" "ERROR"
        release_lock
        return 1
    fi
}

start_monitor() {
    # Check if monitor is already running
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "Load balancer monitor is already running (PID: $lock_pid)" "INFO"
            return 0
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Start monitor in background
    monitor_service &
    local monitor_pid=$!
    
    log "Load balancer monitor started in background (PID: $monitor_pid)" "SUCCESS"
    log "Health logs: $HEALTH_LOG" "INFO"
    log "Activity logs: $LOG_FILE" "INFO"
}

stop_monitor() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE")
        
        if [ -n "$lock_pid" ]; then
            if kill "$lock_pid" 2>/dev/null; then
                log "Stopped load balancer monitor (PID: $lock_pid)" "SUCCESS"
            else
                log "Monitor was not running" "INFO"
            fi
        fi
        
        rm -f "$LOCK_FILE"
    else
        log "Load balancer monitor is not running" "INFO"
    fi
}

show_cname() {
    if [ -f "$STATE_FILE" ]; then
        local cname
        cname=$(jq -r '.cname // empty' "$STATE_FILE")
        
        if [ -n "$cname" ]; then
            echo
            echo "════════════════════════════════════════════════"
            echo "           YOUR LOAD BALANCER CNAME"
            echo "════════════════════════════════════════════════"
            echo
            echo -e "  ${GREEN}$cname${NC}"
            echo
            echo "Smart Load Balancer Features:"
            echo "  • Always uses Primary IP if healthy"
            echo "  • Auto-failover to Backup if Primary fails"
            echo "  • Auto-recovery when Primary is healthy again"
            echo "  • Multi-protocol health checks"
            echo "  • Performance monitoring"
            echo "  • Health checks every ${HEALTH_CHECK_INTERVAL}s"
            echo "  • DNS TTL: ${DNS_TTL}s (fast propagation)"
            echo
            echo "Use this CNAME in your applications."
            echo "The load balancer will handle everything automatically."
            echo
        else
            log "No load balancer setup found" "ERROR"
        fi
    else
        log "No load balancer setup found" "ERROR"
    fi
}

cleanup() {
    echo
    log "WARNING: This will delete the load balancer configuration!" "WARNING"
    echo
    
    if [ ! -f "$STATE_FILE" ]; then
        log "No load balancer setup found to cleanup" "ERROR"
        return 1
    fi
    
    local cname primary_ip backup_ip primary_record_id backup_record_id cname_record_id
    cname=$(jq -r '.cname // empty' "$STATE_FILE")
    primary_ip=$(jq -r '.primary_ip // empty' "$STATE_FILE")
    backup_ip=$(jq -r '.backup_ip // empty' "$STATE_FILE")
    primary_record_id=$(jq -r '.primary_record_id // empty' "$STATE_FILE")
    backup_record_id=$(jq -r '.backup_record_id // empty' "$STATE_FILE")
    cname_record_id=$(jq -r '.cname_record_id // empty' "$STATE_FILE")
    
    if [ -z "$cname" ]; then
        log "No active load balancer found" "ERROR"
        return 1
    fi
    
    echo "Load Balancer to delete:"
    echo "  CNAME: $cname"
    echo "  Primary IP: $primary_ip"
    echo "  Backup IP: $backup_ip"
    echo
    
    read -rp "Are you sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log "Cleanup cancelled" "INFO"
        return 0
    fi
    
    # Stop monitor first
    stop_monitor
    
    log "Deleting load balancer DNS records..." "INFO"
    
    # Delete DNS records
    delete_dns_record "$cname_record_id"
    delete_dns_record "$primary_record_id"
    delete_dns_record "$backup_record_id"
    
    # Delete state files
    rm -f "$STATE_FILE" "$LOCK_FILE"
    
    log "Load balancer cleanup completed!" "SUCCESS"
}

cleanup_monitor() {
    log "Stopping Load Balancer Monitor..." "INFO"
    release_lock
    exit 0
}

# Run main function
main
