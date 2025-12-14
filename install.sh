#!/bin/bash

# ============================================================================
# Cloudflare CNAME with Dual IPv4 Setup Script
# Automatically configures DNS records for load balancing between two servers
# Version: 1.0
# Author: [Your Name]
# Repository: [Your GitHub Repo URL]
# ============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file path
CONFIG_FILE="/etc/cloudflare_dns_setup.conf"
LOG_FILE="/var/log/cloudflare_setup.log"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to display colored output
print_status() {
    echo -e "${2}$1${NC}" | tee -a "$LOG_FILE"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_status "This script must be run as root!" "$RED"
        print_status "Try: sudo bash install.sh" "$YELLOW"
        exit 1
    fi
}

# Function to check system requirements
check_system() {
    print_status "Checking system requirements..." "$BLUE"
    
    # Check Ubuntu version
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            print_status "Warning: This script is optimized for Ubuntu. You're running $ID" "$YELLOW"
        fi
    else
        print_status "Warning: Cannot detect OS type" "$YELLOW"
    fi
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        print_status "Installing curl..." "$BLUE"
        apt-get update > /dev/null 2>&1
        apt-get install -y curl > /dev/null 2>&1
        print_status "curl installed successfully" "$GREEN"
    fi
    
    # Check for jq (JSON processor)
    if ! command -v jq &> /dev/null; then
        print_status "Installing jq for JSON processing..." "$BLUE"
        apt-get install -y jq > /dev/null 2>&1
        print_status "jq installed successfully" "$GREEN"
    fi
}

# Function to validate IPv4 address
validate_ip() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Function to get current server's public IP
get_public_ip() {
    local ip
    ip=$(curl -s -4 https://ifconfig.me 2>/dev/null || curl -s -4 https://api.ipify.org 2>/dev/null || curl -s -4 https://ipinfo.io/ip 2>/dev/null)
    
    if validate_ip "$ip"; then
        echo "$ip"
        return 0
    else
        return 1
    fi
}

# Function to detect if this is first or second server
detect_server_role() {
    local ip1 ip2
    
    print_status "Detecting server role..." "$BLUE"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        if validate_ip "$SERVER1_IP"; then
            CURRENT_IP=$(get_public_ip)
            
            if [[ "$CURRENT_IP" == "$SERVER1_IP" ]]; then
                print_status "This is Server 1 (already configured)" "$GREEN"
                echo "server1"
                return 0
            else
                print_status "This is Server 2" "$GREEN"
                echo "server2"
                return 0
            fi
        fi
    fi
    
    # Ask user if this is first or second server
    while true; do
        echo ""
        print_status "Is this the FIRST server or SECOND server in your setup?" "$CYAN"
        echo "1) First server (will create DNS configuration)"
        echo "2) Second server (will join existing configuration)"
        read -p "Enter your choice (1 or 2): " choice
        
        case $choice in
            1)
                print_status "Configuring as FIRST server..." "$GREEN"
                echo "server1"
                return 0
                ;;
            2)
                print_status "Configuring as SECOND server..." "$GREEN"
                echo "server2"
                return 0
                ;;
            *)
                print_status "Invalid choice. Please enter 1 or 2." "$RED"
                ;;
        esac
    done
}

# Function to collect configuration from user
collect_config() {
    print_status "Cloudflare DNS Configuration Setup" "$CYAN"
    echo "=========================================="
    
    # Get Cloudflare credentials
    while [[ -z "$CF_EMAIL" ]]; do
        read -p "Enter Cloudflare account email: " CF_EMAIL
        if [[ -z "$CF_EMAIL" ]]; then
            print_status "Email cannot be empty!" "$RED"
        fi
    done
    
    while [[ -z "$CF_API_KEY" ]]; do
        read -p "Enter Cloudflare Global API Key: " CF_API_KEY
        if [[ -z "$CF_API_KEY" ]]; then
            print_status "API Key cannot be empty!" "$RED"
        fi
    done
    
    # Get Zone ID
    while [[ -z "$CF_ZONE_ID" ]]; do
        read -p "Enter Cloudflare Zone ID: " CF_ZONE_ID
        if [[ -z "$CF_ZONE_ID" ]]; then
            print_status "Zone ID cannot be empty!" "$RED"
        fi
    done
    
    # Get domain information
    while [[ -z "$DOMAIN" ]]; do
        read -p "Enter your main domain (e.g., example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; do
            print_status "Domain cannot be empty!" "$RED"
        fi
    done
    
    while [[ -z "$SUBDOMAIN" ]]; do
        read -p "Enter subdomain (e.g., app, www, or press Enter for root domain): " SUBDOMAIN
        if [[ -z "$SUBDOMAIN" ]]; then
            SUBDOMAIN="@"
            print_status "Using root domain (@)" "$YELLOW"
        fi
    done
    
    # Generate CNAME record name
    if [[ "$SUBDOMAIN" == "@" ]]; then
        CNAME_NAME="$DOMAIN"
    else
        CNAME_NAME="${SUBDOMAIN}.${DOMAIN}"
    fi
    
    # Generate unique A record names
    A1_NAME="srv1-${SUBDOMAIN}.${DOMAIN}"
    A2_NAME="srv2-${SUBDOMAIN}.${DOMAIN}"
    
    # Get first server IP (current server's IP)
    SERVER1_IP=$(get_public_ip)
    if [[ -z "$SERVER1_IP" ]]; then
        print_status "Could not detect public IP address!" "$RED"
        while true; do
            read -p "Enter this server's public IPv4 address: " SERVER1_IP
            if validate_ip "$SERVER1_IP"; then
                break
            else
                print_status "Invalid IP address format!" "$RED"
            fi
        done
    else
        print_status "Detected public IP: $SERVER1_IP" "$GREEN"
        read -p "Press Enter to use this IP or enter a different one: " user_ip
        if [[ -n "$user_ip" ]]; then
            if validate_ip "$user_ip"; then
                SERVER1_IP="$user_ip"
            else
                print_status "Invalid IP, using detected IP: $SERVER1_IP" "$YELLOW"
            fi
        fi
    fi
    
    # Ask for second server IP
    print_status "Second Server Configuration" "$CYAN"
    echo "Please provide the second server's IP address for load balancing."
    
    while true; do
        read -p "Enter second server's public IPv4 address: " SERVER2_IP
        if validate_ip "$SERVER2_IP"; then
            break
        else
            print_status "Invalid IP address format! Please try again." "$RED"
        fi
    done
    
    # Summary
    print_status "Configuration Summary:" "$CYAN"
    echo "=========================================="
    print_status "Domain: $DOMAIN" "$YELLOW"
    print_status "Subdomain: $SUBDOMAIN" "$YELLOW"
    print_status "CNAME Record: $CNAME_NAME" "$YELLOW"
    print_status "Server 1 IP: $SERVER1_IP" "$YELLOW"
    print_status "Server 2 IP: $SERVER2_IP" "$YELLOW"
    print_status "A Record 1: $A1_NAME" "$YELLOW"
    print_status "A Record 2: $A2_NAME" "$YELLOW"
    echo ""
    
    read -p "Proceed with this configuration? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_status "Configuration cancelled!" "$RED"
        exit 0
    fi
}

# Function to save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Cloudflare DNS Setup Configuration
# Generated: $(date)
CF_EMAIL="$CF_EMAIL"
CF_API_KEY="$CF_API_KEY"
CF_ZONE_ID="$CF_ZONE_ID"
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
CNAME_NAME="$CNAME_NAME"
SERVER1_IP="$SERVER1_IP"
SERVER2_IP="$SERVER2_IP"
A1_NAME="$A1_NAME"
A2_NAME="$A2_NAME"
SETUP_COMPLETED="false"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE" "$GREEN"
}

# Function to create DNS records via Cloudflare API
create_dns_records() {
    local record_name=$1
    local record_content=$2
    local record_type=$3
    local comment=$4
    
    print_status "Creating $record_type record: $record_name -> $record_content" "$BLUE"
    
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"$record_type\",
            \"name\": \"$record_name\",
            \"content\": \"$record_content\",
            \"ttl\": 120,
            \"proxied\": false,
            \"comment\": \"$comment\"
        }")
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        local record_id
        record_id=$(echo "$response" | jq -r '.result.id')
        print_status "✓ $record_type record created successfully (ID: $record_id)" "$GREEN"
        echo "$record_id"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
        print_status "✗ Failed to create $record_type record: $error_msg" "$RED"
        return 1
    fi
}

# Function to check if record already exists
check_existing_record() {
    local record_name=$1
    local record_type=$2
    
    print_status "Checking for existing $record_type record: $record_name" "$BLUE"
    
    local response
    response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=$record_type&name=$record_name" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY")
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.result | length')
        if [[ $count -gt 0 ]]; then
            local existing_id
            existing_id=$(echo "$response" | jq -r '.result[0].id')
            print_status "⚠ $record_type record already exists (ID: $existing_id)" "$YELLOW"
            echo "$existing_id"
            return 0
        fi
    fi
    return 1
}

# Function to update existing record
update_dns_record() {
    local record_id=$1
    local record_name=$2
    local record_content=$3
    local comment=$4
    
    print_status "Updating record: $record_name -> $record_content" "$BLUE"
    
    local response
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"A\",
            \"name\": \"$record_name\",
            \"content\": \"$record_content\",
            \"ttl\": 120,
            \"proxied\": false,
            \"comment\": \"$comment\"
        }")
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        print_status "✓ Record updated successfully" "$GREEN"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown error")
        print_status "✗ Failed to update record: $error_msg" "$RED"
        return 1
    fi
}

# Main setup function for first server
setup_first_server() {
    print_status "Starting DNS setup for Server 1..." "$CYAN"
    
    # Check for existing records
    local existing_a1 existing_a2 existing_cname
    
    existing_a1=$(check_existing_record "$A1_NAME" "A")
    existing_a2=$(check_existing_record "$A2_NAME" "A")
    existing_cname=$(check_existing_record "$CNAME_NAME" "CNAME")
    
    # Create or update A record for server 1
    if [[ -n "$existing_a1" ]]; then
        update_dns_record "$existing_a1" "$A1_NAME" "$SERVER1_IP" "Server 1 - Primary"
        A1_RECORD_ID="$existing_a1"
    else
        A1_RECORD_ID=$(create_dns_records "$A1_NAME" "$SERVER1_IP" "A" "Server 1 - Primary")
        if [[ -z "$A1_RECORD_ID" ]]; then
            print_status "Failed to create A record for Server 1!" "$RED"
            return 1
        fi
    fi
    
    # Create A record for server 2
    if [[ -n "$existing_a2" ]]; then
        update_dns_record "$existing_a2" "$A2_NAME" "$SERVER2_IP" "Server 2 - Secondary"
        A2_RECORD_ID="$existing_a2"
    else
        A2_RECORD_ID=$(create_dns_records "$A2_NAME" "$SERVER2_IP" "A" "Server 2 - Secondary")
        if [[ -z "$A2_RECORD_ID" ]]; then
            print_status "Failed to create A record for Server 2!" "$RED"
            return 1
        fi
    fi
    
    # Create CNAME record pointing to first A record
    if [[ -n "$existing_cname" ]]; then
        print_status "CNAME record already exists. Skipping creation." "$YELLOW"
        CNAME_RECORD_ID="$existing_cname"
    else
        CNAME_RECORD_ID=$(create_dns_records "$CNAME_NAME" "$A1_NAME" "CNAME" "Load balancing between $SERVER1_IP and $SERVER2_IP")
        if [[ -z "$CNAME_RECORD_ID" ]]; then
            print_status "Failed to create CNAME record!" "$RED"
            return 1
        fi
    fi
    
    # Update configuration file with record IDs
    cat >> "$CONFIG_FILE" << EOF
A1_RECORD_ID="$A1_RECORD_ID"
A2_RECORD_ID="$A2_RECORD_ID"
CNAME_RECORD_ID="$CNAME_RECORD_ID"
SETUP_COMPLETED="true"
EOF
    
    print_status "✓ DNS setup completed successfully!" "$GREEN"
    
    # Display final configuration
    print_status "==========================================" "$CYAN"
    print_status "FINAL DNS CONFIGURATION" "$CYAN"
    print_status "==========================================" "$CYAN"
    print_status "Domain: $DOMAIN" "$GREEN"
    print_status "CNAME Record: $CNAME_NAME" "$GREEN"
    print_status "  ↳ Points to: $A1_NAME" "$YELLOW"
    print_status "Server 1: $A1_NAME → $SERVER1_IP" "$YELLOW"
    print_status "Server 2: $A2_NAME → $SERVER2_IP" "$YELLOW"
    print_status ""
    print_status "For true load balancing, you can:" "$CYAN"
    print_status "1. Use Cloudflare Load Balancer (Enterprise feature)" "$CYAN"
    print_status "2. Implement round-robin DNS manually" "$CYAN"
    print_status "3. Use the CNAME for failover configuration" "$CYAN"
    print_status ""
    print_status "To enable round-robin, manually update the CNAME record" "$CYAN"
    print_status "to point to either $A1_NAME or $A2_NAME as needed." "$CYAN"
    print_status "==========================================" "$CYAN"
    
    return 0
}

# Function to setup second server
setup_second_server() {
    print_status "Setting up Server 2..." "$CYAN"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_status "Configuration file not found!" "$RED"
        print_status "Please run setup on Server 1 first." "$YELLOW"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    # Get current server's IP
    local current_ip
    current_ip=$(get_public_ip)
    if [[ -z "$current_ip" ]]; then
        print_status "Could not detect public IP!" "$RED"
        read -p "Enter this server's public IPv4 address: " current_ip
        if ! validate_ip "$current_ip"; then
            print_status "Invalid IP address!" "$RED"
            return 1
        fi
    fi
    
    print_status "This server's IP: $current_ip" "$GREEN"
    print_status "Updating Server 2 DNS record..." "$BLUE"
    
    # Update A record for server 2
    if [[ -n "$A2_RECORD_ID" ]]; then
        update_dns_record "$A2_RECORD_ID" "$A2_NAME" "$current_ip" "Server 2 - Updated on $(date)"
        print_status "✓ Server 2 DNS record updated successfully!" "$GREEN"
        
        # Update configuration file
        sed -i "s/SERVER2_IP=\".*\"/SERVER2_IP=\"$current_ip\"/" "$CONFIG_FILE"
    else
        print_status "A2_RECORD_ID not found in configuration!" "$RED"
        print_status "Creating new A record for Server 2..." "$BLUE"
        
        A2_RECORD_ID=$(create_dns_records "$A2_NAME" "$current_ip" "A" "Server 2 - Secondary")
        if [[ -n "$A2_RECORD_ID" ]]; then
            echo "A2_RECORD_ID=\"$A2_RECORD_ID\"" >> "$CONFIG_FILE"
            print_status "✓ Server 2 DNS record created successfully!" "$GREEN"
        else
            print_status "Failed to create DNS record for Server 2!" "$RED"
            return 1
        fi
    fi
    
    print_status "Server 2 setup completed!" "$GREEN"
    return 0
}

# Function to create a simple health check script
create_health_check() {
    local health_script="/usr/local/bin/check_dns_health.sh"
    
    cat > "$health_script" << 'EOF'
#!/bin/bash
# DNS Health Check Script
# Checks if DNS records are properly configured

CONFIG_FILE="/etc/cloudflare_dns_setup.conf"
LOG_FILE="/var/log/dns_health.log"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    
    echo "[$(date)] Checking DNS health..." >> "$LOG_FILE"
    
    # Check Server 1 A record
    if dig +short "$A1_NAME" | grep -q "$SERVER1_IP"; then
        echo "✓ Server 1 A record is correct" >> "$LOG_FILE"
    else
        echo "✗ Server 1 A record may be incorrect" >> "$LOG_FILE"
    fi
    
    # Check Server 2 A record
    if dig +short "$A2_NAME" | grep -q "$SERVER2_IP"; then
        echo "✓ Server 2 A record is correct" >> "$LOG_FILE"
    else
        echo "✗ Server 2 A record may be incorrect" >> "$LOG_FILE"
    fi
    
    # Check CNAME record
    if dig +short "$CNAME_NAME" CNAME | grep -q "$A1_NAME"; then
        echo "✓ CNAME record is correct" >> "$LOG_FILE"
    else
        echo "✗ CNAME record may be incorrect" >> "$LOG_FILE"
    fi
else
    echo "[$(date)] Configuration file not found" >> "$LOG_FILE"
fi
EOF
    
    chmod +x "$health_script"
    print_status "Health check script created: $health_script" "$GREEN"
    
    # Add to crontab for automatic checks
    (crontab -l 2>/dev/null; echo "0 */6 * * * $health_script") | crontab -
    print_status "Added health check to crontab (runs every 6 hours)" "$GREEN"
}

# Main execution flow
main() {
    clear
    
    # Display header
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Cloudflare CNAME with Dual IPv4 Setup Script         ║"
    echo "║             Automatic DNS Configuration                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check requirements
    check_root
    check_system
    
    # Create log file
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    log_message "Starting Cloudflare DNS setup script"
    
    # Detect server role
    SERVER_ROLE=$(detect_server_role)
    
    case $SERVER_ROLE in
        "server1")
            collect_config
            save_config
            setup_first_server
            if [[ $? -eq 0 ]]; then
                create_health_check
            fi
            ;;
        "server2")
            setup_second_server
            ;;
        *)
            print_status "Invalid server role detected!" "$RED"
            exit 1
            ;;
    esac
    
    # Completion message
    echo ""
    print_status "==========================================" "$CYAN"
    print_status "Setup process completed!" "$GREEN"
    print_status "Check $LOG_FILE for detailed logs" "$YELLOW"
    print_status "Configuration saved in $CONFIG_FILE" "$YELLOW"
    print_status "==========================================" "$CYAN"
    
    log_message "Setup script completed successfully"
}

# Execute main function
main "$@"
