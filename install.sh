#!/bin/bash

# Simple Failover Script
# Version 1.0

echo "======================================"
echo "    SIMPLE FAILOVER SCRIPT"
echo "======================================"

# Config file location
CONFIG="/root/failover.conf"

# Function to load config
load_config() {
    if [ -f "$CONFIG" ]; then
        # Read config line by line
        while IFS='=' read -r key value; do
            # Remove quotes and comments
            value=${value%%#*}
            value=${value%%;*}
            value=${value%\"}
            value=${value#\"}
            value=${value%\'}
            value=${value#\'}
            export "$key"="$value"
        done < "$CONFIG"
        return 0
    else
        echo "ERROR: Config file not found: $CONFIG"
        echo "Run: $0 setup"
        return 1
    fi
}

# Setup function
setup() {
    echo "=== SETUP FAILOVER ==="
    echo
    
    # Get Cloudflare info
    echo "Enter Cloudflare details:"
    read -p "API Token: " API_TOKEN
    read -p "Zone ID: " ZONE_ID
    read -p "Domain (example.com): " DOMAIN
    
    # Get server IPs
    echo
    echo "Enter server IP addresses:"
    read -p "Primary Server IP: " PRIMARY_IP
    read -p "Backup Server IP: " BACKUP_IP
    
    # Generate unique names
    RAND=$(date +%s | tail -c 3)
    CNAME="app${RAND}.${DOMAIN}"
    PRIMARY_HOST="primary${RAND}.${DOMAIN}"
    BACKUP_HOST="backup${RAND}.${DOMAIN}"
    
    echo
    echo "Creating DNS records..."
    
    # Create Primary A record
    echo "Creating Primary A record: $PRIMARY_HOST -> $PRIMARY_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$PRIMARY_HOST\",\"content\":\"$PRIMARY_IP\",\"ttl\":300,\"proxied\":false}" \
        > /tmp/curl_output.txt 2>&1
    
    # Create Backup A record
    echo "Creating Backup A record: $BACKUP_HOST -> $BACKUP_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$BACKUP_HOST\",\"content\":\"$BACKUP_IP\",\"ttl\":300,\"proxied\":false}" \
        > /tmp/curl_output.txt 2>&1
    
    # Create CNAME
    echo "Creating CNAME: $CNAME -> $PRIMARY_HOST"
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"CNAME\",\"name\":\"$CNAME\",\"content\":\"$PRIMARY_HOST\",\"ttl\":300,\"proxied\":false}")
    
    # Get CNAME ID
    CNAME_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    # Save config
    cat > "$CONFIG" << EOF
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
    echo "=== SETUP COMPLETE ==="
    echo
    echo "Your CNAME: $CNAME"
    echo "Primary: $PRIMARY_IP"
    echo "Backup:  $BACKUP_IP"
    echo
    echo "Commands:"
    echo "  $0 status      - Show status"
    echo "  $0 check       - Check primary"
    echo "  $0 backup      - Switch to backup"
    echo "  $0 primary     - Switch to primary"
    echo
}

# Show status
status() {
    if load_config; then
        echo "=== CURRENT STATUS ==="
        echo
        echo "CNAME: $CNAME"
        echo "Primary: $PRIMARY_IP"
        echo "Backup:  $BACKUP_IP"
        echo "Current: $CURRENT_IP"
        echo
        echo "Last check: $(date)"
    fi
}

# Check primary server
check() {
    if ! load_config; then
        return 1
    fi
    
    echo "Checking primary server: $PRIMARY_IP"
    
    # Simple ping check
    if ping -c 1 -W 2 "$PRIMARY_IP" > /dev/null 2>&1; then
        echo "✓ Primary server is UP"
        return 0
    else
        echo "✗ Primary server is DOWN"
        return 1
    fi
}

# Switch to backup
backup() {
    if ! load_config; then
        return 1
    fi
    
    echo "Switching to backup server: $BACKUP_IP"
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$BACKUP_HOST\"}" \
        > /tmp/curl_output.txt 2>&1
    
    # Update config
    sed -i "s/CURRENT_IP=.*/CURRENT_IP=\"$BACKUP_IP\"/" "$CONFIG"
    
    echo "✓ Switched to backup"
    echo "Note: DNS may take a few minutes to update"
}

# Switch to primary
primary() {
    if ! load_config; then
        return 1
    fi
    
    echo "Switching to primary server: $PRIMARY_IP"
    
    # Update DNS
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$PRIMARY_HOST\"}" \
        > /tmp/curl_output.txt 2>&1
    
    # Update config
    sed -i "s/CURRENT_IP=.*/CURRENT_IP=\"$PRIMARY_IP\"/" "$CONFIG"
    
    echo "✓ Switched to primary"
    echo "Note: DNS may take a few minutes to update"
}

# Auto-check function (run manually when needed)
autocheck() {
    if ! load_config; then
        return 1
    fi
    
    echo "Auto-checking primary server..."
    
    if check; then
        # Primary is up
        if [ "$CURRENT_IP" = "$BACKUP_IP" ]; then
            echo "Primary is back up. Switching back..."
            primary
        fi
    else
        # Primary is down
        if [ "$CURRENT_IP" = "$PRIMARY_IP" ]; then
            echo "Primary is down. Switching to backup..."
            backup
        fi
    fi
}

# Show help
help() {
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  setup     - First time setup"
    echo "  status    - Show current status"
    echo "  check     - Check primary server"
    echo "  backup    - Switch to backup"
    echo "  primary   - Switch to primary"
    echo "  autocheck - Auto check and switch"
    echo "  help      - Show this help"
    echo
}

# Main execution
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
    "autocheck")
        autocheck
        ;;
    "help")
        help
        ;;
    *)
        echo "Simple Failover Script"
        echo
        help
        ;;
esac
