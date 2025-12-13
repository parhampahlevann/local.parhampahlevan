#!/bin/bash

# =============================================
# ON-DEMAND FAILOVER SCRIPT
# =============================================

# Config file
CONFIG_FILE="$HOME/.failover-config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================
# SETUP (فقط یک بار)
# =============================================

setup() {
    echo "🔧 Failover Setup"
    echo "================="
    
    # Get Cloudflare info
    echo
    read -p "Cloudflare API Token: " API_TOKEN
    read -p "Zone ID: " ZONE_ID
    read -p "Domain (example.com): " DOMAIN
    
    # Get IPs
    echo
    read -p "Primary Server IP: " PRIMARY_IP
    read -p "Backup Server IP: " BACKUP_IP
    
    # Generate names
    RANDOM_ID=$(date +%s | tail -c 4)
    CNAME="app-${RANDOM_ID}.${DOMAIN}"
    PRIMARY_HOST="primary-${RANDOM_ID}.${DOMAIN}"
    BACKUP_HOST="backup-${RANDOM_ID}.${DOMAIN}"
    
    echo
    echo "Creating DNS records..."
    
    # Create Primary A record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$PRIMARY_HOST\",\"content\":\"$PRIMARY_IP\",\"ttl\":600,\"proxied\":false}" \
        >/dev/null 2>&1
    
    # Create Backup A record
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$BACKUP_HOST\",\"content\":\"$BACKUP_IP\",\"ttl\":600,\"proxied\":false}" \
        >/dev/null 2>&1
    
    # Create CNAME pointing to primary
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"CNAME\",\"name\":\"$CNAME\",\"content\":\"$PRIMARY_HOST\",\"ttl\":600,\"proxied\":false}" \
        >/dev/null 2>&1
    
    # Get CNAME record ID
    sleep 2
    RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME&name=$CNAME" \
        -H "Authorization: Bearer $API_TOKEN")
    
    CNAME_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    # Save config
    cat > "$CONFIG_FILE" << EOF
API_TOKEN="$API_TOKEN"
ZONE_ID="$ZONE_ID"
DOMAIN="$DOMAIN"
PRIMARY_IP="$PRIMARY_IP"
BACKUP_IP="$BACKUP_IP"
CNAME="$CNAME"
PRIMARY_HOST="$PRIMARY_HOST"
BACKUP_HOST="$BACKUP_HOST"
CNAME_ID="$CNAME_ID"
CURRENT_IP="$PRIMARY_IP"
EOF
    
    echo
    echo -e "${GREEN}✅ Setup completed!${NC}"
    echo
    echo "Your CNAME: $CNAME"
    echo
    echo "Manual commands:"
    echo "  To switch to backup:  $0 switch backup"
    echo "  To switch to primary: $0 switch primary"
    echo
    echo "Auto-check (run manually when needed):"
    echo "  $0 check"
    echo
}

# =============================================
# LOAD CONFIG
# =============================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" 2>/dev/null
        return 0
    else
        echo -e "${RED}Config not found. Run 'setup' first.${NC}"
        return 1
    fi
}

# =============================================
# MANUAL SWITCH (بدون چک کردن)
# =============================================

switch_to() {
    TARGET="$1"
    
    load_config || return 1
    
    if [ "$TARGET" = "backup" ]; then
        NEW_HOST="$BACKUP_HOST"
        NEW_IP="$BACKUP_IP"
        echo "Switching to backup server..."
    elif [ "$TARGET" = "primary" ]; then
        NEW_HOST="$PRIMARY_HOST"
        NEW_IP="$PRIMARY_IP"
        echo "Switching back to primary server..."
    else
        echo "Usage: $0 switch [primary|backup]"
        return 1
    fi
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$NEW_HOST\"}" \
        >/dev/null 2>&1
    
    # Update config
    sed -i "s/CURRENT_IP=.*/CURRENT_IP=\"$NEW_IP\"/" "$CONFIG_FILE"
    
    echo -e "${GREEN}✅ Switched to $NEW_IP${NC}"
    echo "DNS update may take a few minutes to propagate."
}

# =============================================
# SINGLE CHECK (فقط یک بار چک کن)
# =============================================

check_once() {
    load_config || return 1
    
    echo "Checking primary server ($PRIMARY_IP)..."
    
    # فقط 2 پینگ با timeout بالا
    if ping -c 2 -W 5 "$PRIMARY_IP" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Primary server is UP${NC}"
        
        # اگر روی backup هستیم و primary up شده، برگردیم
        if [ "$CURRENT_IP" = "$BACKUP_IP" ]; then
            echo "Primary is back up. Switching back..."
            switch_to "primary"
        fi
    else
        echo -e "${RED}❌ Primary server is DOWN${NC}"
        
        # اگر روی primary هستیم و down شده، برویم backup
        if [ "$CURRENT_IP" = "$PRIMARY_IP" ]; then
            echo "Switching to backup..."
            switch_to "backup"
        fi
    fi
}

# =============================================
# CRON CHECK (هر 5 دقیقه یک بار - اختیاری)
# =============================================

setup_cron() {
    load_config || return 1
    
    # Add to crontab (هر 5 دقیقه یک بار)
    (crontab -l 2>/dev/null | grep -v "$0"; echo "*/5 * * * * $PWD/$0 check") | crontab -
    
    echo -e "${GREEN}✅ Cron job added (every 5 minutes)${NC}"
    echo "To remove: crontab -e"
}

# =============================================
# STATUS
# =============================================

status() {
    if load_config; then
        echo "📊 Failover Status"
        echo "================="
        echo
        echo "CNAME: $CNAME"
        echo "Primary: $PRIMARY_IP"
        echo "Backup:  $BACKUP_IP"
        echo "Current: $CURRENT_IP"
        echo
        echo "Last check: $(date)"
        echo
        echo "Commands:"
        echo "  $0 check         - Check once"
        echo "  $0 switch backup - Switch to backup"
        echo "  $0 switch primary - Switch to primary"
    fi
}

# =============================================
# MAIN
# =============================================

case "${1:-}" in
    "setup")
        setup
        ;;
    "check")
        check_once
        ;;
    "switch")
        switch_to "${2:-}"
        ;;
    "cron")
        setup_cron
        ;;
    "status")
        status
        ;;
    *)
        echo "Usage: $0 [command]"
        echo
        echo "Commands:"
        echo "  setup                   - Initial setup"
        echo "  check                   - Check once (no auto monitoring)"
        echo "  switch [primary|backup] - Manual switch"
        echo "  cron                    - Setup 5-min checks (optional)"
        echo "  status                  - Show status"
        echo
        echo "Example workflow:"
        echo "  1. $0 setup          # One-time setup"
        echo "  2. $0 check          # Manual check when needed"
        echo "  3. $0 switch backup  # Manual switch if server down"
        echo
        echo "Note: No automatic monitoring by default!"
        echo "      You control when to check."
        ;;
esac
