#!/bin/bash

# Simple Cloudflare CNAME with Dual IPv4 Setup Script
# One-click installation for Ubuntu servers

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display banner
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Cloudflare CNAME with Two IPv4 Setup     ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Get user inputs
read -p "Enter Cloudflare email: " CF_EMAIL
read -p "Enter Cloudflare API Key: " CF_API_KEY
read -p "Enter Zone ID: " CF_ZONE_ID
read -p "Enter domain (e.g., example.com): " DOMAIN
read -p "Enter subdomain (e.g., app, www): " SUBDOMAIN
read -p "Enter first IPv4 address: " IP1
read -p "Enter second IPv4 address: " IP2

# Validate inputs
if [[ -z "$CF_EMAIL" || -z "$CF_API_KEY" || -z "$CF_ZONE_ID" || -z "$DOMAIN" || -z "$SUBDOMAIN" || -z "$IP1" || -z "$IP2" ]]; then
    echo -e "${RED}Error: All fields are required!${NC}"
    exit 1
fi

# Validate IPv4 format
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
        return $?
    fi
    return 1
}

if ! validate_ip "$IP1"; then
    echo -e "${RED}Error: First IPv4 address is invalid!${NC}"
    exit 1
fi

if ! validate_ip "$IP2"; then
    echo -e "${RED}Error: Second IPv4 address is invalid!${NC}"
    exit 1
fi

# Generate record names
CNAME_RECORD="${SUBDOMAIN}.${DOMAIN}"
A1_RECORD="server1-${SUBDOMAIN}.${DOMAIN}"
A2_RECORD="server2-${SUBDOMAIN}.${DOMAIN}"

echo ""
echo -e "${GREEN}Configuration Summary:${NC}"
echo "================================"
echo -e "CNAME: ${YELLOW}$CNAME_RECORD${NC}"
echo -e "A Record 1: ${YELLOW}$A1_RECORD → $IP1${NC}"
echo -e "A Record 2: ${YELLOW}$A2_RECORD → $IP2${NC}"
echo ""

read -p "Continue with setup? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Setup cancelled."
    exit 0
fi

# Function to create DNS record
create_record() {
    local record_type=$1
    local record_name=$2
    local record_content=$3
    local comment=$4
    
    echo -e "${BLUE}Creating $record_type record: $record_name → $record_content${NC}"
    
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
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
    
    if echo "$response" | grep -q '"success":true'; then
        echo -e "${GREEN}✓ $record_type record created successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to create $record_type record${NC}"
        echo "Response: $response"
        return 1
    fi
}

# Create A records
echo ""
echo -e "${BLUE}Creating DNS records...${NC}"
echo "================================"

# Create first A record
create_record "A" "$A1_RECORD" "$IP1" "Primary server for load balancing"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to create first A record. Exiting.${NC}"
    exit 1
fi

# Create second A record
create_record "A" "$A2_RECORD" "$IP2" "Secondary server for load balancing"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to create second A record. Exiting.${NC}"
    exit 1
fi

# Create CNAME record
create_record "CNAME" "$CNAME_RECORD" "$A1_RECORD" "Load balancing between $IP1 and $IP2"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to create CNAME record. Exiting.${NC}"
    exit 1
fi

# Save configuration
CONFIG_FILE="/root/cloudflare_dns_config.txt"
cat > "$CONFIG_FILE" << EOF
# Cloudflare DNS Configuration
# Generated on: $(date)

CF_EMAIL="$CF_EMAIL"
CF_ZONE_ID="$CF_ZONE_ID"
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"

# DNS Records
CNAME_RECORD="$CNAME_RECORD"
A1_RECORD="$A1_RECORD"
A2_RECORD="$A2_RECORD"

# Server IPs
IP1="$IP1"
IP2="$IP2"

# Usage notes:
# The CNAME ($CNAME_RECORD) points to $A1_RECORD
# For load balancing, you can manually update the CNAME to point to either:
# - $A1_RECORD ($IP1) for Server 1
# - $A2_RECORD ($IP2) for Server 2
EOF

echo ""
echo -e "${GREEN}✓ Setup completed successfully!${NC}"
echo "================================"
echo -e "CNAME Record: ${YELLOW}$CNAME_RECORD${NC}"
echo -e "Currently points to: ${YELLOW}$A1_RECORD ($IP1)${NC}"
echo ""
echo -e "${BLUE}How to use:${NC}"
echo "1. Access your site at: https://$CNAME_RECORD"
echo "2. For load balancing between two servers:"
echo "   - Update CNAME to point to $A1_RECORD for Server 1"
echo "   - Update CNAME to point to $A2_RECORD for Server 2"
echo ""
echo -e "Configuration saved to: ${YELLOW}$CONFIG_FILE${NC}"
