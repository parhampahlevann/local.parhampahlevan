#!/bin/bash
set -euo pipefail

# =============================================
# CLOUDFLARE DUAL-IP MANAGER (NO FAILOVER)
# =============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.cf-auto-failover"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
LAST_CNAME_FILE="$CONFIG_DIR/last_cname.txt"

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================
# LOGGING
# =============================================

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "${CYAN}[$ts] [$level]${NC} $msg"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

# =============================================
# CONFIG
# =============================================

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_HOST="$BASE_HOST"
EOF
    log "Config saved" "SUCCESS"
}

# =============================================
# API
# =============================================

api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [ -n "$data" ]; then
        curl -s -X "$method" "$CF_API_BASE$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data"
    else
        curl -s -X "$method" "$CF_API_BASE$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN"
    fi
}

test_api() {
    api_request GET "/user/tokens/verify" | jq -e '.success==true' >/dev/null
}

test_zone() {
    api_request GET "/zones/$CF_ZONE_ID" | jq -e '.success==true' >/dev/null
}

# =============================================
# DNS
# =============================================

create_dns_record() {
    local name="$1"
    local type="$2"
    local content="$3"

    api_request POST "/zones/$CF_ZONE_ID/dns_records" "$(cat <<EOF
{
  "type":"$type",
  "name":"$name",
  "content":"$content",
  "ttl":60,
  "proxied":false
}
EOF
)" | jq -r '.success'
}

# =============================================
# VALIDATION
# =============================================

validate_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# =============================================
# SETUP (DUAL ACTIVE)
# =============================================

setup_dual_ip() {
    echo
    echo "════════════════════════════════════════════════"
    echo "   DUAL IP SETUP (NO FAILOVER - STABLE MODE)"
    echo "════════════════════════════════════════════════"
    echo

    local ip1 ip2

    while true; do
        read -rp "Enter First IP: " ip1
        validate_ip "$ip1" && break
        log "Invalid IP" "ERROR"
    done

    while true; do
        read -rp "Enter Second IP: " ip2
        validate_ip "$ip2" && break
        log "Invalid IP" "ERROR"
    done

    local id cname
    id=$(date +%s%N | md5sum | cut -c1-8)
    cname="app-$id.$BASE_HOST"

    log "Creating DNS records..." "INFO"

    create_dns_record "$cname" "A" "$ip1" || exit 1
    create_dns_record "$cname" "A" "$ip2" || exit 1

    cat > "$STATE_FILE" <<EOF
{
  "cname":"$cname",
  "ip1":"$ip1",
  "ip2":"$ip2",
  "mode":"dual-active"
}
EOF

    echo "$cname" > "$LAST_CNAME_FILE"

    echo
    log "SETUP COMPLETED SUCCESSFULLY" "SUCCESS"
    echo
    echo "CNAME:"
    echo -e "  ${GREEN}$cname${NC}"
    echo
    echo "Active IPs:"
    echo "  - $ip1"
    echo "  - $ip2"
    echo
    echo "✔ No failover"
    echo "✔ No switching"
    echo "✔ No downtime"
}

# =============================================
# INFO
# =============================================

show_status() {
    if [ ! -f "$STATE_FILE" ]; then
        log "No setup found" "ERROR"
        return
    fi

    jq .
}

show_cname() {
    [ -f "$LAST_CNAME_FILE" ] && cat "$LAST_CNAME_FILE" || log "No CNAME" "ERROR"
}

cleanup() {
    rm -f "$STATE_FILE" "$LAST_CNAME_FILE"
    log "Local state cleaned (DNS records not deleted)" "WARNING"
}

# =============================================
# API CONFIG
# =============================================

configure_api() {
    read -rp "API Token: " CF_API_TOKEN
    test_api || { log "Invalid token" "ERROR"; return; }

    read -rp "Zone ID: " CF_ZONE_ID
    test_zone || { log "Invalid zone" "ERROR"; return; }

    read -rp "Base domain (example.com): " BASE_HOST
    save_config
}

# =============================================
# MENU
# =============================================

main() {
    ensure_dir
    load_config

    while true; do
        clear
        echo "════════════════════════════════════"
        echo "  CLOUDFLARE DUAL IP MANAGER"
        echo "════════════════════════════════════"
        echo "1) Complete Setup"
        echo "2) Show Status"
        echo "3) Start Monitor (Disabled)"
        echo "4) Stop Monitor (Disabled)"
        echo "5) Manual Failover (Disabled)"
        echo "6) Show CNAME"
        echo "7) Cleanup"
        echo "8) Configure API"
        echo "9) Exit"
        echo

        read -rp "Select: " c
        case $c in
            1) setup_dual_ip ;;
            2) show_status ;;
            3) log "Monitor disabled" "WARNING" ;;
            4) log "Monitor disabled" "WARNING" ;;
            5) log "Failover disabled" "WARNING" ;;
            6) show_cname ;;
            7) cleanup ;;
            8) configure_api ;;
            9) exit 0 ;;
        esac
        read -rp "Press Enter..."
    done
}

main
