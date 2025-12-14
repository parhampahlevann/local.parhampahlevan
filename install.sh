#!/bin/bash

# ===========================================================
# Complete Cloudflare CNAME with Two IPv4 Setup Script
# With full error handling and step-by-step execution
# ===========================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
LOG_FILE="/var/log/cloudflare_cname_setup.log"
CONFIG_FILE="/etc/cloudflare_cname_config.conf"

# Initialize log
init_log() {
    echo "=== Cloudflare CNAME Setup Log ===" > "$LOG_FILE"
    echo "Start Time: $(date)" >> "$LOG_FILE"
    echo "=================================" >> "$LOG_FILE"
}

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "$2$1${NC}"
}

# Error handler
error_exit() {
    log "ERROR: $1" "$RED"
    echo -e "${RED}Setup failed. Check $LOG_FILE for details.${NC}"
    exit 1
}

# Check requirements
check_requirements() {
    log "Checking system requirements..." "$BLUE"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Use: sudo bash $0"
    fi
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        log "Installing curl..." "$YELLOW"
        apt-get update > /dev/null 2>&1 || error_exit "Failed to update package list"
        apt-get install -y curl > /dev/null 2>&1 || error_exit "Failed to install curl"
        log "curl installed successfully" "$GREEN"
    fi
    
    # Check for jq (for JSON parsing)
    if ! command -v jq &> /dev/null; then
        log "Installing jq for JSON processing..." "$YELLOW"
        apt-get install -y jq > /dev/null 2>&1 || error_exit "Failed to install jq"
        log "jq installed successfully" "$GREEN"
    fi
}

# Validate IPv4 address
validate_ipv4() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        if [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]; then
            stat=0
        fi
    fi
    return $stat
}

# Get current server public IP
get_public_ip() {
    log "Detecting public IP address..." "$BLUE"
    
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )
    
    for service in "${services[@]}"; do
        log "Trying $service..." "$CYAN"
        ip=$(curl -s -4 --connect-timeout 5 "$service" 2>/dev/null | tr -d '[:space:]')
        
        if validate_ipv4 "$ip"; then
            log "Public IP detected: $ip" "$GREEN"
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# Get user inputs
get_user_inputs() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        CLOUDFLARE CNAME WITH DUAL IPv4 SETUP                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log "Starting user input collection..." "$BLUE"
    
    # Cloudflare credentials
    echo -e "\n${YELLOW}STEP 1: Cloudflare API Credentials${NC}"
    echo "────────────────────────────────────────"
    
    while true; do
        read -p "Enter Cloudflare account email: " CF_EMAIL
        if [[ -n "$CF_EMAIL" ]]; then
            break
        fi
        echo -e "${RED}Email cannot be empty!${NC}"
    done
    
    while true; do
        read -p "Enter Cloudflare Global API Key: " CF_API_KEY
        if [[ -n "$CF_API_KEY" ]]; then
            break
        fi
        echo -e "${RED}API Key cannot be empty!${NC}"
    done
    
    while true; do
        read -p "Enter Cloudflare Zone ID: " CF_ZONE_ID
        if [[ -n "$CF_ZONE_ID" ]]; then
            break
        fi
        echo -e "${RED}Zone ID cannot be empty!${NC}"
    done
    
    # Domain information
    echo -e "\n${YELLOW}STEP 2: Domain Configuration${NC}"
    echo "────────────────────────────────────────"
    
    while true; do
        read -p "Enter your domain (e.g., example.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        echo -e "${RED}Domain cannot be empty!${NC}"
    done
    
    while true; do
        read -p "Enter subdomain (e.g., www, app, or press Enter for root): " SUBDOMAIN
        if [[ -z "$SUBDOMAIN" ]]; then
            SUBDOMAIN="@"
            log "Using root domain (@)" "$CYAN"
            break
        elif [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
            break
        else
            echo -e "${RED}Invalid subdomain format! Use only letters, numbers, and hyphens.${NC}"
        fi
    done
    
    # Server IP addresses
    echo -e "\n${YELLOW}STEP 3: Server IP Addresses${NC}"
    echo "────────────────────────────────────────"
    
    # Auto-detect current server IP
    CURRENT_IP=$(get_public_ip)
    if [[ -n "$CURRENT_IP" ]]; then
        echo -e "${GREEN}Detected this server's IP: $CURRENT_IP${NC}"
        read -p "Use this IP for Server 1? (Y/n): " USE_DETECTED
        
        if [[ "$USE_DETECTED" =~ ^[Nn]$ ]]; then
            while true; do
                read -p "Enter Server 1 IPv4 address: " IP1
                if validate_ipv4 "$IP1"; then
                    break
                else
                    echo -e "${RED}Invalid IPv4 address format!${NC}"
                fi
            done
        else
            IP1="$CURRENT_IP"
        fi
    else
        while true; do
            read -p "Enter Server 1 IPv4 address: " IP1
            if validate_ipv4 "$IP1"; then
                break
            else
                echo -e "${RED}Invalid IPv4 address format!${NC}"
            fi
        done
    fi
    
    # Second server IP
    while true; do
        read -p "Enter Server 2 IPv4 address: " IP2
        if validate_ipv4 "$IP2"; then
            if [[ "$IP1" == "$IP2" ]]; then
                echo -e "${RED}Server 2 IP cannot be the same as Server 1 IP!${NC}"
            else
                break
            fi
        else
            echo -e "${RED}Invalid IPv4 address format!${NC}"
        fi
    done
    
    # TTL setting
    echo -e "\n${YELLOW}STEP 4: DNS Settings${NC}"
    echo "────────────────────────────────────────"
    
    while true; do
        read -p "Enter TTL value (120-7200 seconds, default: 120): " TTL
        if [[ -z "$TTL" ]]; then
            TTL=120
            break
        elif [[ "$TTL" =~ ^[0-9]+$ ]] && [[ "$TTL" -ge 120 ]] && [[ "$TTL" -le 7200 ]]; then
            break
        else
            echo -e "${RED}TTL must be between 120 and 7200 seconds!${NC}"
        fi
    done
    
    # Proxy through Cloudflare?
    while true; do
        read -p "Proxy through Cloudflare? (y/N): " PROXIED
        if [[ -z "$PROXIED" ]]; then
            PROXIED="false"
            break
        elif [[ "$PROXIED" =~ ^[Yy]$ ]]; then
            PROXIED="true"
            break
        elif [[ "$PROXIED" =~ ^[Nn]$ ]]; then
            PROXIED="false"
            break
        else
            echo -e "${RED}Please answer y or n${NC}"
        fi
    done
}

# Verify Cloudflare credentials
verify_cloudflare() {
    log "Verifying Cloudflare credentials..." "$BLUE"
    
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        error_exit "No response from Cloudflare API. Check network connection."
    fi
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        local zone_name
        zone_name=$(echo "$response" | jq -r '.result.name')
        log "✓ Cloudflare credentials verified for zone: $zone_name" "$GREEN"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
        error_exit "Cloudflare API error: $error_msg"
    fi
}

# Create DNS record with retry
create_dns_record() {
    local record_type=$1
    local record_name=$2
    local record_content=$3
    local comment=$4
    local max_retries=3
    local retry_count=0
    
    # Clean record name for root domain
    if [[ "$record_name" == "@.$DOMAIN" ]]; then
        record_name="$DOMAIN"
    fi
    
    while [[ $retry_count -lt $max_retries ]]; do
        log "Creating $record_type record: $record_name → $record_content (Attempt $((retry_count + 1))/$max_retries)" "$BLUE"
        
        local response
        response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_API_KEY" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"$record_type\",
                \"name\": \"$record_name\",
                \"content\": \"$record_content\",
                \"ttl\": $TTL,
                \"proxied\": $PROXIED,
                \"comment\": \"$comment\"
            }" 2>/dev/null)
        
        if [[ -z "$response" ]]; then
            log "No response from Cloudflare API, retrying..." "$YELLOW"
            retry_count=$((retry_count + 1))
            sleep 2
            continue
        fi
        
        if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
            local record_id
            record_id=$(echo "$response" | jq -r '.result.id')
            log "✓ $record_type record created successfully (ID: $record_id)" "$GREEN"
            echo "$record_id"
            return 0
        else
            local error_msg
            error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
            
            # Check if record already exists
            if [[ "$error_msg" == *"already exists"* ]] || [[ "$error_msg" == *"duplicate"* ]]; then
                log "Record already exists, checking..." "$YELLOW"
                handle_existing_record "$record_name" "$record_type" "$record_content"
                return $?
            fi
            
            log "Failed to create record: $error_msg, retrying..." "$YELLOW"
            retry_count=$((retry_count + 1))
            sleep 2
        fi
    done
    
    error_exit "Failed to create $record_type record after $max_retries attempts"
}

# Handle existing DNS record
handle_existing_record() {
    local record_name=$1
    local record_type=$2
    local new_content=$3
    
    log "Checking existing $record_type record: $record_name" "$BLUE"
    
    # Get existing record
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=$record_type&name=$record_name" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" 2>/dev/null)
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        local existing_count
        existing_count=$(echo "$response" | jq '.result | length')
        
        if [[ $existing_count -gt 0 ]]; then
            local existing_id
            existing_id=$(echo "$response" | jq -r '.result[0].id')
            local existing_content
            existing_content=$(echo "$response" | jq -r '.result[0].content')
            
            if [[ "$existing_content" == "$new_content" ]]; then
                log "✓ Record already exists with correct content" "$GREEN"
                echo "$existing_id"
                return 0
            else
                log "Updating existing record from $existing_content to $new_content..." "$YELLOW"
                update_dns_record "$existing_id" "$record_name" "$record_type" "$new_content"
                return $?
            fi
        fi
    fi
    
    return 1
}

# Update existing DNS record
update_dns_record() {
    local record_id=$1
    local record_name=$2
    local record_type=$3
    local new_content=$4
    
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"$record_type\",
            \"name\": \"$record_name\",
            \"content\": \"$new_content\",
            \"ttl\": $TTL,
            \"proxied\": $PROXIED
        }" 2>/dev/null)
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        log "✓ Record updated successfully" "$GREEN"
        echo "$record_id"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
        error_exit "Failed to update record: $error_msg"
    fi
}

# Display configuration summary
show_summary() {
    echo -e "\n${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                CONFIGURATION SUMMARY                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Cloudflare Settings:${NC}"
    echo "  Email: $CF_EMAIL"
    echo "  Zone ID: $CF_ZONE_ID"
    echo "  TTL: $TTL seconds"
    echo "  Proxied: $PROXIED"
    
    echo -e "\n${YELLOW}Domain Settings:${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Subdomain: $SUBDOMAIN"
    
    echo -e "\n${YELLOW}Server IP Addresses:${NC}"
    echo "  Server 1: $IP1"
    echo "  Server 2: $IP2"
    
    echo -e "\n${YELLOW}DNS Records to be created:${NC}"
    echo "  A Record 1: srv1-${SUBDOMAIN}.${DOMAIN} → $IP1"
    echo "  A Record 2: srv2-${SUBDOMAIN}.${DOMAIN} → $IP2"
    echo "  CNAME Record: ${SUBDOMAIN}.${DOMAIN} → srv1-${SUBDOMAIN}.${DOMAIN}"
    
    echo -e "\n${MAGENTA}Press Enter to continue or Ctrl+C to cancel...${NC}"
    read -r
}

# Main setup function
setup_dns_records() {
    log "Starting DNS records creation..." "$BLUE"
    
    # Create A record for Server 1
    A1_NAME="srv1-${SUBDOMAIN}.${DOMAIN}"
    A1_ID=$(create_dns_record "A" "$A1_NAME" "$IP1" "Primary server - $IP1")
    
    # Create A record for Server 2
    A2_NAME="srv2-${SUBDOMAIN}.${DOMAIN}"
    A2_ID=$(create_dns_record "A" "$A2_NAME" "$IP2" "Secondary server - $IP2")
    
    # Create CNAME record
    if [[ "$SUBDOMAIN" == "@" ]]; then
        CNAME_NAME="$DOMAIN"
    else
        CNAME_NAME="${SUBDOMAIN}.${DOMAIN}"
    fi
    CNAME_ID=$(create_dns_record "CNAME" "$CNAME_NAME" "$A1_NAME" "Load balancing between $IP1 and $IP2")
    
    # Save configuration
    save_configuration "$A1_ID" "$A2_ID" "$CNAME_ID"
}

# Save configuration to file
save_configuration() {
    local a1_id=$1
    local a2_id=$2
    local cname_id=$3
    
    cat > "$CONFIG_FILE" << EOF
# Cloudflare CNAME Configuration
# Generated: $(date)

# Cloudflare Credentials
CF_EMAIL="$CF_EMAIL"
CF_API_KEY="$CF_API_KEY"
CF_ZONE_ID="$CF_ZONE_ID"

# Domain Settings
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
TTL="$TTL"
PROXIED="$PROXIED"

# Server IPs
SERVER1_IP="$IP1"
SERVER2_IP="$IP2"

# DNS Records
A1_NAME="srv1-${SUBDOMAIN}.${DOMAIN}"
A2_NAME="srv2-${SUBDOMAIN}.${DOMAIN}"
CNAME_NAME="${SUBDOMAIN}.${DOMAIN}"

# Record IDs
A1_RECORD_ID="$a1_id"
A2_RECORD_ID="$a2_id"
CNAME_RECORD_ID="$cname_id"

# Usage Notes:
# The CNAME (\$CNAME_NAME) points to \$A1_NAME (\$SERVER1_IP)
# For load balancing, update the CNAME record to point to:
# - \$A1_NAME for Server 1
# - \$A2_NAME for Server 2
EOF
    
    chmod 600 "$CONFIG_FILE"
    log "Configuration saved to $CONFIG_FILE" "$GREEN"
}

# Test DNS resolution
test_dns_resolution() {
    log "Testing DNS resolution..." "$BLUE"
    
    echo -e "\n${YELLOW}Waiting for DNS propagation (30 seconds)...${NC}"
    sleep 30
    
    local records_to_test=(
        "srv1-${SUBDOMAIN}.${DOMAIN}"
        "srv2-${SUBDOMAIN}.${DOMAIN}"
        "${SUBDOMAIN}.${DOMAIN}"
    )
    
    for record in "${records_to_test[@]}"; do
        # Clean record name for root domain
        if [[ "$record" == "@.$DOMAIN" ]]; then
            record="$DOMAIN"
        fi
        
        log "Testing $record..." "$CYAN"
        local resolved_ip
        resolved_ip=$(dig +short "$record" A 2>/dev/null | head -n1)
        
        if [[ -n "$resolved_ip" ]]; then
            log "✓ $record resolves to: $resolved_ip" "$GREEN"
        else
            log "⚠ $record not resolving yet (DNS propagation may take time)" "$YELLOW"
        fi
    done
}

# Create management script
create_management_script() {
    local mgmt_script="/usr/local/bin/manage_cname.sh"
    
    cat > "$mgmt_script" << 'EOF'
#!/bin/bash

# CNAME Management Script
# Switch between Server 1 and Server 2

CONFIG_FILE="/etc/cloudflare_cname_config.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Configuration file not found!"
    exit 1
fi

source "$CONFIG_FILE"

case "$1" in
    "server1")
        echo "Switching to Server 1 ($SERVER1_IP)..."
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CNAME_RECORD_ID" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_API_KEY" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"CNAME\",
                \"name\": \"$CNAME_NAME\",
                \"content\": \"$A1_NAME\",
                \"ttl\": $TTL,
                \"proxied\": $PROXIED
            }"
        echo "✓ CNAME now points to Server 1"
        ;;
    "server2")
        echo "Switching to Server 2 ($SERVER2_IP)..."
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CNAME_RECORD_ID" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_API_KEY" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"CNAME\",
                \"name\": \"$CNAME_NAME\",
                \"content\": \"$A2_NAME\",
                \"ttl\": $TTL,
                \"proxied\": $PROXIED
            }"
        echo "✓ CNAME now points to Server 2"
        ;;
    "status")
        echo "Current CNAME configuration:"
        echo "CNAME: $CNAME_NAME"
        echo "Server 1: $A1_NAME → $SERVER1_IP"
        echo "Server 2: $A2_NAME → $SERVER2_IP"
        ;;
    *)
        echo "Usage: $0 {server1|server2|status}"
        echo ""
        echo "Commands:"
        echo "  server1  - Switch CNAME to point to Server 1"
        echo "  server2  - Switch CNAME to point to Server 2"
        echo "  status   - Show current configuration"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$mgmt_script"
    log "Management script created: $mgmt_script" "$GREEN"
    log "Use: manage_cname.sh server1  (switch to Server 1)" "$CYAN"
    log "Use: manage_cname.sh server2  (switch to Server 2)" "$CYAN"
    log "Use: manage_cname.sh status   (show current config)" "$CYAN"
}

# Main execution
main() {
    # Initialize
    init_log
    log "Starting Cloudflare CNAME setup" "$CYAN"
    
    # Check requirements
    check_requirements
    
    # Get user inputs
    get_user_inputs
    
    # Show summary
    show_summary
    
    # Verify Cloudflare credentials
    verify_cloudflare
    
    # Setup DNS records
    setup_dns_records
    
    # Create management script
    create_management_script
    
    # Test DNS
    test_dns_resolution
    
    # Final message
    echo -e "\n${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    SETUP COMPLETED!                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}Summary:${NC}"
    echo "  ✓ A Record 1: srv1-${SUBDOMAIN}.${DOMAIN} → $IP1"
    echo "  ✓ A Record 2: srv2-${SUBDOMAIN}.${DOMAIN} → $IP2"
    echo "  ✓ CNAME Record: ${SUBDOMAIN}.${DOMAIN} → srv1-${SUBDOMAIN}.${DOMAIN}"
    echo ""
    echo -e "${YELLOW}Files created:${NC}"
    echo "  Configuration: $CONFIG_FILE"
    echo "  Log file: $LOG_FILE"
    echo "  Management script: /usr/local/bin/manage_cname.sh"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Access your site at: ${SUBDOMAIN}.${DOMAIN}"
    echo "  2. To switch between servers:"
    echo "     - manage_cname.sh server1  (for Server 1)"
    echo "     - manage_cname.sh server2  (for Server 2)"
    echo ""
    echo -e "${GREEN}Setup completed successfully!${NC}"
    log "Setup completed successfully" "$GREEN"
}

# Run main function
main "$@"
