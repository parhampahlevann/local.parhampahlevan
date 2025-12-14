#!/bin/bash

# ==================================================
# Cloudflare CNAME Setup Script for Two IPv4
# Creates a CNAME with .app subdomain pointing to two IPs
# Uses Cloudflare API Token (NOT Global API Key)
# ==================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
LOG_FILE="/tmp/cloudflare_cname_setup.log"
API_BASE="https://api.cloudflare.com/client/v4"

# Initialize log
echo "=== Cloudflare CNAME Setup Log ===" > "$LOG_FILE"
echo "Start Time: $(date)" >> "$LOG_FILE"

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo -e "$2$1${NC}"
}

# Error handler
error_exit() {
    log "ERROR: $1" "$RED"
    exit 1
}

# Validate IPv4 address
validate_ipv4() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
        return $?
    fi
    return 1
}

# Get user inputs
get_user_inputs() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Cloudflare CNAME Setup with Two IPv4 Addresses    ║"
    echo "║          (Uses API Token, No Email Required)        ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Get Cloudflare API Token
    echo -e "\n${YELLOW}STEP 1: Cloudflare API Token${NC}"
    echo "────────────────────────────────────"
    while true; do
        read -p "Enter Cloudflare API Token: " API_TOKEN
        if [[ -n "$API_TOKEN" ]]; then
            break
        fi
        echo -e "${RED}API Token cannot be empty!${NC}"
    done
    
    # Get Zone ID
    echo -e "\n${YELLOW}STEP 2: Zone Information${NC}"
    echo "────────────────────────────────────"
    while true; do
        read -p "Enter Cloudflare Zone ID: " ZONE_ID
        if [[ -n "$ZONE_ID" ]]; then
            break
        fi
        echo -e "${RED}Zone ID cannot be empty!${NC}"
    done
    
    # Get domain
    while true; do
        read -p "Enter your domain (e.g., example.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        echo -e "${RED}Domain cannot be empty!${NC}"
    done
    
    # Set fixed .app subdomain as requested
    SUBDOMAIN="app"
    
    # Get IP addresses
    echo -e "\n${YELLOW}STEP 3: Server IP Addresses${NC}"
    echo "────────────────────────────────────"
    
    # Get first IP
    while true; do
        read -p "Enter first IPv4 address: " IP1
        if validate_ipv4 "$IP1"; then
            break
        else
            echo -e "${RED}Invalid IPv4 address format!${NC}"
        fi
    done
    
    # Get second IP
    while true; do
        read -p "Enter second IPv4 address: " IP2
        if validate_ipv4 "$IP2"; then
            if [[ "$IP1" == "$IP2" ]]; then
                echo -e "${RED}Second IP cannot be the same as first IP!${NC}"
            else
                break
            fi
        else
            echo -e "${RED}Invalid IPv4 address format!${NC}"
        fi
    done
    
    # Set record names
    A1_NAME="server1-${SUBDOMAIN}.${DOMAIN}"  # e.g., server1-app.example.com
    A2_NAME="server2-${SUBDOMAIN}.${DOMAIN}"  # e.g., server2-app.example.com
    CNAME_NAME="${SUBDOMAIN}.${DOMAIN}"        # e.g., app.example.com
}

# Verify Cloudflare API Token
verify_token() {
    log "Verifying Cloudflare API Token..." "$BLUE"
    
    local response
    response=$(curl -s -X GET "${API_BASE}/user/tokens/verify" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        error_exit "No response from Cloudflare API. Check network connection."
    fi
    
    if echo "$response" | grep -q '"success":true'; then
        local token_status
        token_status=$(echo "$response" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
        log "✓ API Token verified successfully (Status: $token_status)" "$GREEN"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | grep -o '"message":"[^"]*' | cut -d'"' -f4)
        error_exit "API Token verification failed: ${error_msg:-Unknown error}"
    fi
}

# Create or update DNS record
manage_dns_record() {
    local record_name=$1
    local record_content=$2
    local record_type=$3
    local comment=$4
    
    log "Managing $record_type record: $record_name -> $record_content" "$BLUE"
    
    # First, check if record exists
    local response
    response=$(curl -s -X GET "${API_BASE}/zones/${ZONE_ID}/dns_records?type=${record_type}&name=${record_name}" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    if echo "$response" | grep -q '"success":true'; then
        # Check if record exists
        local record_count
        record_count=$(echo "$response" | grep -o '"count":[0-9]*' | cut -d: -f2)
        
        if [[ "$record_count" -gt 0 ]]; then
            # Record exists, update it
            local record_id
            record_id=$(echo "$response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
            
            log "Record exists (ID: $record_id), updating..." "$YELLOW"
            
            local update_response
            update_response=$(curl -s -X PUT "${API_BASE}/zones/${ZONE_ID}/dns_records/${record_id}" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                    \"type\": \"${record_type}\",
                    \"name\": \"${record_name}\",
                    \"content\": \"${record_content}\",
                    \"ttl\": 1,
                    \"proxied\": false,
                    \"comment\": \"${comment}\"
                }" 2>/dev/null)
            
            if echo "$update_response" | grep -q '"success":true'; then
                log "✓ Record updated successfully" "$GREEN"
                echo "$record_id"
                return 0
            else
                error_exit "Failed to update $record_type record"
            fi
        else
            # Record doesn't exist, create it
            log "Creating new $record_type record..." "$YELLOW"
            
            local create_response
            create_response=$(curl -s -X POST "${API_BASE}/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                --data "{
                    \"type\": \"${record_type}\",
                    \"name\": \"${record_name}\",
                    \"content\": \"${record_content}\",
                    \"ttl\": 1,
                    \"proxied\": false,
                    \"comment\": \"${comment}\"
                }" 2>/dev/null)
            
            if echo "$create_response" | grep -q '"success":true'; then
                local record_id
                record_id=$(echo "$create_response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
                log "✓ Record created successfully (ID: $record_id)" "$GREEN"
                echo "$record_id"
                return 0
            else
                error_exit "Failed to create $record_type record"
            fi
        fi
    else
        error_exit "Failed to check existing $record_type records"
    fi
}

# Main setup function
setup_dns() {
    log "Starting DNS setup process..." "$CYAN"
    
    # Verify API token first
    verify_token
    
    # Create A record for first IP
    echo ""
    log "Creating A record for first IP ($IP1)..." "$BLUE"
    A1_ID=$(manage_dns_record "$A1_NAME" "$IP1" "A" "Server 1 - Primary")
    
    # Create A record for second IP
    log "Creating A record for second IP ($IP2)..." "$BLUE"
    A2_ID=$(manage_dns_record "$A2_NAME" "$IP2" "A" "Server 2 - Secondary")
    
    # Create CNAME record pointing to first A record
    log "Creating CNAME record (.app subdomain)..." "$BLUE"
    CNAME_ID=$(manage_dns_record "$CNAME_NAME" "$A1_NAME" "CNAME" "CNAME for load balancing - Points to Server 1")
    
    # Save configuration
    save_configuration "$A1_ID" "$A2_ID" "$CNAME_ID"
}

# Save configuration to file
save_configuration() {
    local a1_id=$1
    local a2_id=$2
    local cname_id=$3
    
    local config_file="/root/cloudflare_cname_config.conf"
    
    cat > "$config_file" << EOF
# Cloudflare CNAME Configuration
# Generated: $(date)

# Cloudflare API
API_TOKEN="$API_TOKEN"
ZONE_ID="$ZONE_ID"

# Domain Settings
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"

# Server IPs
IP1="$IP1"
IP2="$IP2"

# DNS Records
A1_NAME="$A1_NAME"
A2_NAME="$A2_NAME"
CNAME_NAME="$CNAME_NAME"

# Record IDs
A1_RECORD_ID="$a1_id"
A2_RECORD_ID="$a2_id"
CNAME_RECORD_ID="$cname_id"

# Management Commands:
# To switch CNAME to Server 1: curl -X PUT "${API_BASE}/zones/${ZONE_ID}/dns_records/${cname_id}" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data '{"type":"CNAME","name":"${CNAME_NAME}","content":"${A1_NAME}","ttl":1,"proxied":false}'
# To switch CNAME to Server 2: curl -X PUT "${API_BASE}/zones/${ZONE_ID}/dns_records/${cname_id}" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data '{"type":"CNAME","name":"${CNAME_NAME}","content":"${A2_NAME}","ttl":1,"proxied":false}'
EOF
    
    chmod 600 "$config_file"
    log "Configuration saved to $config_file" "$GREEN"
}

# Create management script
create_management_script() {
    local mgmt_script="/usr/local/bin/manage_cname.sh"
    
    cat > "$mgmt_script" << EOF
#!/bin/bash

# CNAME Management Script
# Switch CNAME between Server 1 and Server 2

CONFIG_FILE="/root/cloudflare_cname_config.conf"
API_BASE="https://api.cloudflare.com/client/v4"

if [[ ! -f "\$CONFIG_FILE" ]]; then
    echo "Configuration file not found: \$CONFIG_FILE"
    exit 1
fi

# Load configuration
source "\$CONFIG_FILE"

case "\$1" in
    "server1")
        echo "Switching CNAME to Server 1 (\$IP1)..."
        curl -s -X PUT "\${API_BASE}/zones/\${ZONE_ID}/dns_records/\${CNAME_RECORD_ID}" \
            -H "Authorization: Bearer \$API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"CNAME\",
                \"name\": \"\$CNAME_NAME\",
                \"content\": \"\$A1_NAME\",
                \"ttl\": 1,
                \"proxied\": false
            }"
        echo "✓ CNAME now points to Server 1 (\$A1_NAME)"
        ;;
    "server2")
        echo "Switching CNAME to Server 2 (\$IP2)..."
        curl -s -X PUT "\${API_BASE}/zones/\${ZONE_ID}/dns_records/\${CNAME_RECORD_ID}" \
            -H "Authorization: Bearer \$API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"CNAME\",
                \"name\": \"\$CNAME_NAME\",
                \"content\": \"\$A2_NAME\",
                \"ttl\": 1,
                \"proxied\": false
            }"
        echo "✓ CNAME now points to Server 2 (\$A2_NAME)"
        ;;
    "status")
        echo "Current CNAME Configuration:"
        echo "============================"
        echo "CNAME Record: \$CNAME_NAME"
        echo "Server 1: \$A1_NAME -> \$IP1"
        echo "Server 2: \$A2_NAME -> \$IP2"
        echo ""
        echo "To check current CNAME target:"
        echo "  dig \$CNAME_NAME CNAME +short"
        ;;
    *)
        echo "Usage: \$0 {server1|server2|status}"
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
}

# Show final summary
show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗"
    echo -e "║               SETUP COMPLETED SUCCESSFULLY!          ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}SUMMARY:${NC}"
    echo "  Domain: $DOMAIN"
    echo "  .app CNAME: $CNAME_NAME"
    echo ""
    echo -e "${YELLOW}DNS Records Created:${NC}"
    echo "  ✓ A Record 1: $A1_NAME -> $IP1"
    echo "  ✓ A Record 2: $A2_NAME -> $IP2"
    echo "  ✓ CNAME Record: $CNAME_NAME -> $A1_NAME"
    echo ""
    echo -e "${YELLOW}TTL Setting:${NC}"
    echo "  TTL set to 1 (automatic) to prevent downtime"
    echo ""
    echo -e "${YELLOW}Management Commands:${NC}"
    echo "  Switch to Server 1:  manage_cname.sh server1"
    echo "  Switch to Server 2:  manage_cname.sh server2"
    echo "  Check status:        manage_cname.sh status"
    echo ""
    echo -e "${YELLOW}Configuration Saved:${NC}"
    echo "  /root/cloudflare_cname_config.conf"
    echo ""
    echo -e "${GREEN}Your .app CNAME is ready! To switch between servers, use the management commands above.${NC}"
}

# Main execution
main() {
    # Get user inputs
    get_user_inputs
    
    # Setup DNS records
    setup_dns
    
    # Create management script
    create_management_script
    
    # Show summary
    show_summary
}

# Run main function
main "$@"
