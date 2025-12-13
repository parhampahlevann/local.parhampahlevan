#!/bin/bash

# Simple Failover Manager
# Save as: /usr/local/bin/failover

echo "========================================="
echo "    SIMPLE FAILOVER MANAGER"
echo "========================================="

CONFIG_DIR="/etc/failover"
CONFIG_FILE="$CONFIG_DIR/config.sh"

# Create config directory if not exists
mkdir -p "$CONFIG_DIR"

# Function to load config
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        echo "❌ Config not found. Please run 'failover setup' first."
        return 1
    fi
}

# Function to save config
save_config() {
    cat > "$CONFIG_FILE" << EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
CF_DOMAIN="$CF_DOMAIN"
PRIMARY_IP="$PRIMARY_IP"
BACKUP_IP="$BACKUP_IP"
CNAME="$CNAME"
CNAME_ID="$CNAME_ID"
PRIMARY_HOST="$PRIMARY_HOST"
BACKUP_HOST="$BACKUP_HOST"
CURRENT_IP="$CURRENT_IP"
EOF
    echo "✅ Config saved to $CONFIG_FILE"
}

# Setup function
setup() {
    echo "🔧 SETUP FAILOVER SYSTEM"
    echo "========================="
    
    echo
    echo "Step 1: Cloudflare API Information"
    echo "----------------------------------"
    read -p "Enter Cloudflare API Token: " CF_API_TOKEN
    read -p "Enter Zone ID: " CF_ZONE_ID
    read -p "Enter Domain (example.com): " CF_DOMAIN
    
    echo
    echo "Step 2: Server IP Addresses"
    echo "---------------------------"
    read -p "Enter Primary Server IP: " PRIMARY_IP
    read -p "Enter Backup Server IP: " BACKUP_IP
    
    # Generate unique names
    RAND=$(date +%s | tail -c 4)
    CNAME="app-$RAND.$CF_DOMAIN"
    PRIMARY_HOST="primary-$RAND.$CF_DOMAIN"
    BACKUP_HOST="backup-$RAND.$CF_DOMAIN"
    CURRENT_IP="$PRIMARY_IP"
    
    echo
    echo "Step 3: Creating DNS Records..."
    echo "-------------------------------"
    
    # Create Primary A Record
    echo "Creating Primary A record..."
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$PRIMARY_HOST\",\"content\":\"$PRIMARY_IP\",\"ttl\":300,\"proxied\":false}" \
        >/dev/null 2>&1
    
    # Create Backup A Record
    echo "Creating Backup A record..."
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$BACKUP_HOST\",\"content\":\"$BACKUP_IP\",\"ttl\":300,\"proxied\":false}" \
        >/dev/null 2>&1
    
    # Create CNAME Record
    echo "Creating CNAME record..."
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"CNAME\",\"name\":\"$CNAME\",\"content\":\"$PRIMARY_HOST\",\"ttl\":300,\"proxied\":false}")
    
    # Extract CNAME ID from response
    CNAME_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    if [ -z "$CNAME_ID" ]; then
        echo "❌ Failed to get CNAME record ID"
        return 1
    fi
    
    # Save configuration
    save_config
    
    echo
    echo "✅ SETUP COMPLETED SUCCESSFULLY!"
    echo "================================="
    echo
    echo "📋 YOUR CNAME: $CNAME"
    echo
    echo "Primary Server: $PRIMARY_IP"
    echo "Backup Server:  $BACKUP_IP"
    echo
    echo "⚡ Commands:"
    echo "  failover status      - Show current status"
    echo "  failover check       - Check primary server"
    echo "  failover to-backup   - Switch to backup"
    echo "  failover to-primary  - Switch back to primary"
    echo
}

# Status function
status() {
    if ! load_config; then
        return 1
    fi
    
    echo "📊 CURRENT STATUS"
    echo "================="
    echo
    echo "CNAME: $CNAME"
    echo "Primary IP: $PRIMARY_IP"
    echo "Backup IP:  $BACKUP_IP"
    echo "Current IP: $CURRENT_IP"
    echo
    echo "Last update: $(date)"
    echo
}

# Check function (manual check)
check() {
    if ! load_config; then
        return 1
    fi
    
    echo "🔍 CHECKING PRIMARY SERVER..."
    echo "IP: $PRIMARY_IP"
    echo
    
    # Simple ping check
    if ping -c 2 -W 3 "$PRIMARY_IP" >/dev/null 2>&1; then
        echo "✅ Primary server is UP"
        
        # If we're on backup and primary is up, ask to switch back
        if [ "$CURRENT_IP" = "$BACKUP_IP" ]; then
            echo
            read -p "Primary is up. Switch back to primary? (y/n): " choice
            if [ "$choice" = "y" ]; then
                switch_to_primary
            fi
        fi
    else
        echo "❌ Primary server is DOWN"
        
        # If we're on primary and it's down, ask to switch to backup
        if [ "$CURRENT_IP" = "$PRIMARY_IP" ]; then
            echo
            read -p "Switch to backup server? (y/n): " choice
            if [ "$choice" = "y" ]; then
                switch_to_backup
            fi
        fi
    fi
}

# Switch to backup
switch_to_backup() {
    if ! load_config; then
        return 1
    fi
    
    echo "🔄 Switching to backup server..."
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$BACKUP_HOST\"}" \
        >/dev/null 2>&1
    
    # Update config
    CURRENT_IP="$BACKUP_IP"
    save_config
    
    echo "✅ Switched to backup: $BACKUP_IP"
    echo "DNS may take a few minutes to update globally."
}

# Switch to primary
switch_to_primary() {
    if ! load_config; then
        return 1
    fi
    
    echo "🔄 Switching back to primary server..."
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$PRIMARY_HOST\"}" \
        >/dev/null 2>&1
    
    # Update config
    CURRENT_IP="$PRIMARY_IP"
    save_config
    
    echo "✅ Switched to primary: $PRIMARY_IP"
    echo "DNS may take a few minutes to update globally."
}

# Help function
show_help() {
    echo "Usage: failover [command]"
    echo
    echo "Commands:"
    echo "  setup       - First time setup"
    echo "  status      - Show current status"
    echo "  check       - Check primary server manually"
    echo "  to-backup   - Switch to backup server"
    echo "  to-primary  - Switch back to primary server"
    echo "  help        - Show this help"
    echo
    echo "Example:"
    echo "  failover setup      # Run once"
    echo "  failover check      # Check server when needed"
    echo "  failover to-backup  # Manual failover"
    echo
}

# Main script
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
    "to-backup")
        switch_to_backup
        ;;
    "to-primary")
        switch_to_primary
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        echo "Simple Failover Manager"
        echo
        show_help
        ;;
esac
