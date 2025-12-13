#!/bin/bash

# =============================================
# SIMPLE PING FAILOVER
# =============================================

# Configuration
CONFIG_DIR="$HOME/.simple-failover"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="$CONFIG_DIR/failover.log"
PID_FILE="$CONFIG_DIR/pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================
# BASIC SETUP
# =============================================

setup() {
    echo "🔧 Setting up Simple Failover"
    echo "=============================="
    
    mkdir -p "$CONFIG_DIR"
    
    # Get configuration
    echo
    read -p "Enter Cloudflare API Token: " api_token
    read -p "Enter Zone ID: " zone_id
    read -p "Enter Domain (example.com): " domain
    read -p "Enter Primary Server IP: " primary_ip
    read -p "Enter Backup Server IP: " backup_ip
    
    # Validate IPs
    if ! [[ $primary_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Invalid primary IP${NC}"
        return 1
    fi
    
    if ! [[ $backup_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Invalid backup IP${NC}"
        return 1
    fi
    
    # Create unique subdomain
    timestamp=$(date +%s)
    cname="failover-${timestamp}.${domain}"
    primary_host="primary-${timestamp}.${domain}"
    backup_host="backup-${timestamp}.${domain}"
    
    echo
    echo "Creating DNS records..."
    
    # Create Primary A record
    primary_data='{
        "type": "A",
        "name": "'"$primary_host"'",
        "content": "'"$primary_ip"'",
        "ttl": 300,
        "proxied": false
    }'
    
    primary_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        --data "$primary_data")
    
    primary_record_id=$(echo "$primary_response" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -1)
    
    if [ -z "$primary_record_id" ]; then
        echo -e "${RED}Failed to create primary record${NC}"
        return 1
    fi
    
    # Create Backup A record
    backup_data='{
        "type": "A",
        "name": "'"$backup_host"'",
        "content": "'"$backup_ip"'",
        "ttl": 300,
        "proxied": false
    }'
    
    backup_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        --data "$backup_data")
    
    backup_record_id=$(echo "$backup_response" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -1)
    
    if [ -z "$backup_record_id" ]; then
        echo -e "${RED}Failed to create backup record${NC}"
        return 1
    fi
    
    # Create CNAME
    cname_data='{
        "type": "CNAME",
        "name": "'"$cname"'",
        "content": "'"$primary_host"'",
        "ttl": 300,
        "proxied": false
    }'
    
    cname_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        --data "$cname_data")
    
    cname_record_id=$(echo "$cname_response" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -1)
    
    if [ -z "$cname_record_id" ]; then
        echo -e "${RED}Failed to create CNAME record${NC}"
        return 1
    fi
    
    # Save config
    cat > "$CONFIG_FILE" << EOF
API_TOKEN="$api_token"
ZONE_ID="$zone_id"
DOMAIN="$domain"
PRIMARY_IP="$primary_ip"
BACKUP_IP="$backup_ip"
CNAME="$cname"
PRIMARY_HOST="$primary_host"
BACKUP_HOST="$backup_host"
CNAME_RECORD_ID="$cname_record_id"
PRIMARY_RECORD_ID="$primary_record_id"
BACKUP_RECORD_ID="$backup_record_id"
CURRENT_IP="$primary_ip"
EOF
    
    echo
    echo -e "${GREEN}✅ Setup completed!${NC}"
    echo
    echo "Your CNAME: $cname"
    echo "Primary: $primary_ip"
    echo "Backup: $backup_ip"
    echo
    echo "To start monitoring:"
    echo "  $0 start"
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
        echo -e "${RED}No configuration found. Run 'setup' first.${NC}"
        return 1
    fi
}

# =============================================
# MONITORING FUNCTIONS
# =============================================

check_ping() {
    ip="$1"
    if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
        echo "up"
    else
        echo "down"
    fi
}

switch_dns() {
    target_host="$1"
    target_ip="$2"
    
    echo "Switching to $target_ip..."
    
    update_data='{
        "content": "'"$target_host"'"
    }'
    
    response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$update_data")
    
    if echo "$response" | grep -q '"success":true'; then
        echo "$(date): Switched to $target_ip" >> "$LOG_FILE"
        sed -i "s/CURRENT_IP=.*/CURRENT_IP=\"$target_ip\"/" "$CONFIG_FILE"
        echo -e "${GREEN}✅ Switched to $target_ip${NC}"
        return 0
    else
        echo "$(date): Failed to switch to $target_ip" >> "$LOG_FILE"
        echo -e "${RED}❌ Failed to switch${NC}"
        return 1
    fi
}

monitor() {
    load_config || exit 1
    
    echo "🔄 Starting failover monitor"
    echo "Primary: $PRIMARY_IP"
    echo "Backup: $BACKUP_IP"
    echo "Check every 10 seconds"
    echo "Switch after 60 seconds downtime"
    echo "Return after 60 seconds stability"
    echo
    
    down_counter=0
    stable_counter=0
    on_backup=false
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    while true; do
        # Check primary
        status=$(check_ping "$PRIMARY_IP")
        
        if [ "$status" = "up" ]; then
            # Primary is up
            down_counter=0
            
            if [ "$on_backup" = true ]; then
                stable_counter=$((stable_counter + 10))
                echo "Primary up. Stable for ${stable_counter}s/60s"
                
                if [ $stable_counter -ge 60 ]; then
                    if switch_dns "$PRIMARY_HOST" "$PRIMARY_IP"; then
                        on_backup=false
                        stable_counter=0
                    fi
                fi
            else
                stable_counter=0
            fi
            
        else
            # Primary is down
            stable_counter=0
            
            if [ "$on_backup" = false ]; then
                down_counter=$((down_counter + 10))
                echo "Primary down. Down for ${down_counter}s/60s"
                
                if [ $down_counter -ge 60 ]; then
                    # Check backup before switching
                    backup_status=$(check_ping "$BACKUP_IP")
                    if [ "$backup_status" = "up" ]; then
                        if switch_dns "$BACKUP_HOST" "$BACKUP_IP"; then
                            on_backup=true
                            down_counter=0
                        fi
                    else
                        echo "Backup also down, not switching"
                    fi
                fi
            else
                echo "Already on backup"
            fi
        fi
        
        sleep 10
    done
}

start() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️  Monitor is already running (PID: $pid)${NC}"
            return 0
        fi
    fi
    
    # Start in background
    monitor &
    
    echo -e "${GREEN}✅ Monitor started${NC}"
    echo "Check status with: $0 status"
    echo "Stop with: $0 stop"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill "$pid" 2>/dev/null; then
            echo -e "${GREEN}✅ Monitor stopped${NC}"
            rm -f "$PID_FILE"
        else
            echo -e "${YELLOW}⚠️  Monitor not running${NC}"
            rm -f "$PID_FILE"
        fi
    else
        echo -e "${YELLOW}⚠️  Monitor not running${NC}"
    fi
}

status() {
    if ! load_config; then
        return 1
    fi
    
    echo "📊 Failover Status"
    echo "================="
    echo
    echo "CNAME: $CNAME"
    echo "Primary IP: $PRIMARY_IP"
    echo "Backup IP: $BACKUP_IP"
    echo "Current IP: $CURRENT_IP"
    echo
    
    # Check ping status
    echo "Ping Status:"
    if ping -c 1 -W 2 "$PRIMARY_IP" >/dev/null 2>&1; then
        echo -e "  Primary: ${GREEN}UP${NC}"
    else
        echo -e "  Primary: ${RED}DOWN${NC}"
    fi
    
    if ping -c 1 -W 2 "$BACKUP_IP" >/dev/null 2>&1; then
        echo -e "  Backup: ${GREEN}UP${NC}"
    else
        echo -e "  Backup: ${RED}DOWN${NC}"
    fi
    
    echo
    echo "Monitor:"
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if ps -p "$pid" >/dev/null 2>&1; then
            echo -e "  ${GREEN}ACTIVE${NC} (PID: $pid)"
        else
            echo -e "  ${RED}INACTIVE${NC}"
            rm -f "$PID_FILE"
        fi
    else
        echo -e "  ${YELLOW}NOT RUNNING${NC}"
    fi
    
    echo
    if [ -f "$LOG_FILE" ]; then
        echo "Recent logs:"
        tail -5 "$LOG_FILE"
    fi
}

cleanup() {
    if ! load_config; then
        echo -e "${RED}No configuration to cleanup${NC}"
        return 1
    fi
    
    echo "⚠️  WARNING: This will delete all DNS records!"
    read -p "Type 'DELETE' to confirm: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        echo "Cancelled"
        return 0
    fi
    
    # Stop monitor
    stop
    
    # Delete DNS records
    echo "Deleting DNS records..."
    
    if [ -n "$CNAME_RECORD_ID" ]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CNAME_RECORD_ID" \
            -H "Authorization: Bearer $API_TOKEN" >/dev/null 2>&1
    fi
    
    if [ -n "$PRIMARY_RECORD_ID" ]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$PRIMARY_RECORD_ID" \
            -H "Authorization: Bearer $API_TOKEN" >/dev/null 2>&1
    fi
    
    if [ -n "$BACKUP_RECORD_ID" ]; then
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$BACKUP_RECORD_ID" \
            -H "Authorization: Bearer $API_TOKEN" >/dev/null 2>&1
    fi
    
    # Remove files
    rm -rf "$CONFIG_DIR"
    
    echo -e "${GREEN}✅ Cleanup completed${NC}"
}

# =============================================
# MAIN MENU
# =============================================

show_menu() {
    echo
    echo "╔══════════════════════════════════════════╗"
    echo "║         SIMPLE FAILOVER MANAGER         ║"
    echo "╠══════════════════════════════════════════╣"
    echo "║                                          ║"
    echo -e "║  ${GREEN}1.${NC} Setup                              ║"
    echo -e "║  ${GREEN}2.${NC} Start Monitoring                  ║"
    echo -e "║  ${GREEN}3.${NC} Stop Monitoring                   ║"
    echo -e "║  ${GREEN}4.${NC} Status                            ║"
    echo -e "║  ${GREEN}5.${NC} Cleanup                           ║"
    echo -e "║  ${GREEN}6.${NC} Exit                              ║"
    echo "║                                          ║"
    echo "╚══════════════════════════════════════════╝"
    echo
}

main() {
    # Check for required commands
    if ! command -v curl >/dev/null 2>&1; then
        echo "Please install curl: sudo apt-get install curl"
        exit 1
    fi
    
    if ! command -v ping >/dev/null 2>&1; then
        echo "Please install ping: sudo apt-get install iputils-ping"
        exit 1
    fi
    
    # Handle command line arguments
    case "${1:-}" in
        "setup")
            setup
            ;;
        "start")
            start
            ;;
        "stop")
            stop
            ;;
        "status")
            status
            ;;
        "cleanup")
            cleanup
            ;;
        *)
            # Show interactive menu
            while true; do
                show_menu
                read -p "Select option (1-6): " choice
                
                case $choice in
                    1) setup ;;
                    2) start ;;
                    3) stop ;;
                    4) status ;;
                    5) cleanup ;;
                    6) 
                        echo "Goodbye!"
                        exit 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                
                echo
                read -p "Press Enter to continue..."
            done
            ;;
    esac
}

# Run the script
main "$@"
