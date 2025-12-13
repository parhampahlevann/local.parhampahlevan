# 1. ایجاد فایل
cat > /root/failover.sh << 'EOF'
#!/bin/bash

# ============================================
# SIMPLE FAILOVER SCRIPT
# ============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Config file
CONFIG_FILE="/root/failover_config.txt"

# ============================================
# CONFIG FUNCTIONS
# ============================================

save_config() {
    cat > "$CONFIG_FILE" << CONFIG_EOF
API_TOKEN=$1
ZONE_ID=$2
DOMAIN=$3
PRIMARY_IP=$4
BACKUP_IP=$5
CNAME=$6
PRIMARY_HOST=$7
BACKUP_HOST=$8
CNAME_ID=$9
CURRENT_IP=${10}
CONFIG_EOF
    echo -e "${GREEN}Config saved${NC}"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ ! $key =~ ^# ]]; then
                export "$key"="$value"
            fi
        done < "$CONFIG_FILE"
        return 0
    else
        echo -e "${RED}Config not found. Run 'setup' first.${NC}"
        return 1
    fi
}

# ============================================
# MAIN FUNCTIONS
# ============================================

setup() {
    echo "=== FAILOVER SETUP ==="
    echo ""
    
    # Get inputs
    read -p "Cloudflare API Token: " API_TOKEN
    read -p "Zone ID: " ZONE_ID
    read -p "Domain (example.com): " DOMAIN
    read -p "Primary Server IP: " PRIMARY_IP
    read -p "Backup Server IP: " BACKUP_IP
    
    # Generate names
    RAND=$(date +%s | tail -c 4)
    CNAME="app${RAND}.${DOMAIN}"
    PRIMARY_HOST="primary${RAND}.${DOMAIN}"
    BACKUP_HOST="backup${RAND}.${DOMAIN}"
    
    echo ""
    echo "Creating DNS records..."
    
    # Create Primary A record
    echo "Creating: $PRIMARY_HOST → $PRIMARY_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$PRIMARY_HOST\",\"content\":\"$PRIMARY_IP\",\"ttl\":300,\"proxied\":false}" \
        > /dev/null
    
    # Create Backup A record
    echo "Creating: $BACKUP_HOST → $BACKUP_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$BACKUP_HOST\",\"content\":\"$BACKUP_IP\",\"ttl\":300,\"proxied\":false}" \
        > /dev/null
    
    # Create CNAME
    echo "Creating: $CNAME → $PRIMARY_HOST"
    CNAME_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"CNAME\",\"name\":\"$CNAME\",\"content\":\"$PRIMARY_HOST\",\"ttl\":300,\"proxied\":false}")
    
    # Extract CNAME ID
    CNAME_ID=$(echo "$CNAME_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    CURRENT_IP="$PRIMARY_IP"
    
    # Save config
    save_config "$API_TOKEN" "$ZONE_ID" "$DOMAIN" "$PRIMARY_IP" "$BACKUP_IP" "$CNAME" "$PRIMARY_HOST" "$BACKUP_HOST" "$CNAME_ID" "$CURRENT_IP"
    
    echo ""
    echo "=== SETUP COMPLETE ==="
    echo ""
    echo -e "${GREEN}Your CNAME: $CNAME${NC}"
    echo ""
    echo "Commands:"
    echo "  ./failover.sh status    - Show status"
    echo "  ./failover.sh check     - Check primary server"
    echo "  ./failover.sh backup    - Switch to backup"
    echo "  ./failover.sh primary   - Switch to primary"
    echo ""
}

status() {
    if load_config; then
        echo "=== CURRENT STATUS ==="
        echo ""
        echo "CNAME: $CNAME"
        echo "Primary: $PRIMARY_IP"
        echo "Backup:  $BACKUP_IP"
        echo "Current: $CURRENT_IP"
        echo ""
        echo "Last update: $(date)"
    fi
}

check() {
    if ! load_config; then
        return 1
    fi
    
    echo "Checking primary server: $PRIMARY_IP"
    echo ""
    
    # Ping check
    if ping -c 2 -W 3 "$PRIMARY_IP" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Primary server is UP${NC}"
    else
        echo -e "${RED}✗ Primary server is DOWN${NC}"
    fi
}

backup() {
    if ! load_config; then
        return 1
    fi
    
    echo "Switching to backup server..."
    echo ""
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$BACKUP_HOST\"}" \
        > /dev/null
    
    # Update config
    CURRENT_IP="$BACKUP_IP"
    save_config "$API_TOKEN" "$ZONE_ID" "$DOMAIN" "$PRIMARY_IP" "$BACKUP_IP" "$CNAME" "$PRIMARY_HOST" "$BACKUP_HOST" "$CNAME_ID" "$CURRENT_IP"
    
    echo -e "${GREEN}✓ Switched to backup: $BACKUP_IP${NC}"
}

primary() {
    if ! load_config; then
        return 1
    fi
    
    echo "Switching to primary server..."
    echo ""
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$PRIMARY_HOST\"}" \
        > /dev/null
    
    # Update config
    CURRENT_IP="$PRIMARY_IP"
    save_config "$API_TOKEN" "$ZONE_ID" "$DOMAIN" "$PRIMARY_IP" "$BACKUP_IP" "$CNAME" "$PRIMARY_HOST" "$BACKUP_HOST" "$CNAME_ID" "$CURRENT_IP"
    
    echo -e "${GREEN}✓ Switched to primary: $PRIMARY_IP${NC}"
}

help() {
    echo "Failover Script - Usage:"
    echo ""
    echo "  ./failover.sh setup     - First time setup"
    echo "  ./failover.sh status    - Show current status"
    echo "  ./failover.sh check     - Check primary server"
    echo "  ./failover.sh backup    - Switch to backup server"
    echo "  ./failover.sh primary   - Switch to primary server"
    echo "  ./failover.sh help      - Show this help"
    echo ""
}

# ============================================
# MAIN EXECUTION
# ============================================

case "$1" in
    "setup")
        setup
        ;;
    "status")
        status
        ;;
    "check")
        check
        ;;
    "backup")
        backup
        ;;
    "primary")
        primary
        ;;
    "help"|"--help"|"-h")
        help
        ;;
    *)
        echo "Simple Failover Script"
        echo ""
        help
        ;;
esac
EOF

# 2. قابل اجرا کردن
chmod +x /root/failover.sh

# 3. نمایش کمک
echo "Script created at /root/failover.sh"
echo ""
echo "To use:"
echo "  cd /root"
echo "  ./failover.sh setup     # First time"
echo "  ./failover.sh status    # Check status"
echo "  ./failover.sh check     # Check server"
