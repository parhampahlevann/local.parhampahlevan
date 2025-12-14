#!/bin/bash

# ==================================================
# Cloudflare TCP Load Balancer Setup (Zero Downtime)
# ==================================================

set -e

API_BASE="https://api.cloudflare.com/client/v4"
LOG_FILE="/tmp/cloudflare_tcp_lb.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo "$(date '+%F %T') - $1" >> "$LOG_FILE"
    echo -e "$2$1${NC}"
}

error_exit() {
    log "ERROR: $1" "$RED"
    exit 1
}

validate_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
}

# ================= USER INPUT =================

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Cloudflare TCP Load Balancer (REAL LB)    ║"
echo "║          Zero Downtime – No DNS TTL         ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "API Token: " API_TOKEN
read -p "Account ID: " ACCOUNT_ID
read -p "Zone ID: " ZONE_ID
read -p "Domain (example.com): " DOMAIN

SUBDOMAIN="app"

while true; do
    read -p "Server 1 IP: " IP1
    validate_ipv4 "$IP1" && break
done

while true; do
    read -p "Server 2 IP: " IP2
    validate_ipv4 "$IP2" && [[ "$IP2" != "$IP1" ]] && break
done

read -p "TCP Port (e.g. 25565 / 443 / 8080): " TCP_PORT

LB_NAME="${SUBDOMAIN}.${DOMAIN}"

log "Starting TCP Load Balancer setup for $LB_NAME" "$CYAN"

# ================= VERIFY TOKEN =================

curl -s -X GET "$API_BASE/user/tokens/verify" \
 -H "Authorization: Bearer $API_TOKEN" | grep -q '"success":true' \
 || error_exit "Invalid API Token"

log "API Token verified" "$GREEN"

# ================= CREATE MONITOR =================

log "Creating TCP Health Monitor..." "$YELLOW"

MONITOR_ID=$(curl -s -X POST "$API_BASE/accounts/$ACCOUNT_ID/load_balancers/monitors" \
 -H "Authorization: Bearer $API_TOKEN" \
 -H "Content-Type: application/json" \
 --data "{
   \"type\": \"tcp\",
   \"description\": \"TCP Monitor on port $TCP_PORT\",
   \"interval\": 30,
   \"timeout\": 5,
   \"retries\": 2,
   \"port\": $TCP_PORT
 }" | jq -r '.result.id')

[[ "$MONITOR_ID" != "null" ]] || error_exit "Monitor creation failed"

log "Monitor created: $MONITOR_ID" "$GREEN"

# ================= CREATE POOL =================

log "Creating Pool with 2 origins..." "$YELLOW"

POOL_ID=$(curl -s -X POST "$API_BASE/accounts/$ACCOUNT_ID/load_balancers/pools" \
 -H "Authorization: Bearer $API_TOKEN" \
 -H "Content-Type: application/json" \
 --data "{
   \"name\": \"tcp-pool-$SUBDOMAIN\",
   \"monitor\": \"$MONITOR_ID\",
   \"origins\": [
     { \"name\": \"server1\", \"address\": \"$IP1\", \"enabled\": true },
     { \"name\": \"server2\", \"address\": \"$IP2\", \"enabled\": true }
   ]
 }" | jq -r '.result.id')

[[ "$POOL_ID" != "null" ]] || error_exit "Pool creation failed"

log "Pool created: $POOL_ID" "$GREEN"

# ================= CREATE LOAD BALANCER =================

log "Creating TCP Load Balancer..." "$YELLOW"

curl -s -X POST "$API_BASE/accounts/$ACCOUNT_ID/load_balancers" \
 -H "Authorization: Bearer $API_TOKEN" \
 -H "Content-Type: application/json" \
 --data "{
   \"name\": \"$LB_NAME\",
   \"default_pools\": [\"$POOL_ID\"],
   \"fallback_pool\": \"$POOL_ID\",
   \"proxied\": true
 }" | grep -q '"success":true' \
 || error_exit "Load Balancer creation failed"

log "Load Balancer successfully created 🎉" "$GREEN"

# ================= SUMMARY =================

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════╗"
echo "║        TCP LOAD BALANCER READY 🚀            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

echo "Domain:      $LB_NAME"
echo "Protocol:    TCP"
echo "Port:        $TCP_PORT"
echo "Server 1:    $IP1"
echo "Server 2:    $IP2"
echo ""
echo -e "${GREEN}Zero Downtime – No TTL – No DNS Switch${NC}"
