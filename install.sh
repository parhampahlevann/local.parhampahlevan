#!/bin/bash
set -euo pipefail

# =============================================
# CLOUDFLARE DUAL-IP STABLE (NO PROXY)
# =============================================

CONFIG_DIR="$HOME/.cf-auto-failover"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
LAST_CNAME_FILE="$CONFIG_DIR/last_cname.txt"

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""

TTL=600   # 10 minutes - key for stability

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================
# UTILS
# =============================================

log() {
    local msg="$1"
    local lvl="${2:-INFO}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[$ts] [$lvl]${NC} $msg"
    echo "[$ts] [$lvl] $msg" >> "$LOG_FILE"
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

pause() {
    read -rp "Press Enter to continue..."
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
    log "Configuration saved" "SUCCESS"
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
    local ip="$2"

    api_request POST "/zones/$CF_ZONE_ID/dns_records" "$(cat <<EOF
{
  "type": "A",
  "name": "$name",
  "content": "$ip",
  "ttl": $TTL,
  "proxied": false
}
EOF
)" | jq -e '.success==true' >/dev/null
}

validate_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# =============================================
# SETUP
# =============================================

setup_dual_ip() {
    echo
    echo "════════════════════════════════════════════════"
    echo "   DUAL IP SETUP (NO PROXY - STABLE DNS)"
    echo "════════════════════════════════════════════════"
    echo

    local ip1 ip2

    while true; do
        read -rp "Primary IP: " ip1
        validate_ip "$ip1" && break
        log "Invalid IP" "ERROR"
    done

    while true; do
        read -rp "Backup IP: " ip2
        validate_ip "$ip2" && break
        log "Invalid IP" "ERROR"
    done

    local id cname
    id=$(date +%s%N | md5sum | cut -c1-8)
    cname="app-$id.$BASE_HOST"

    log "Creating stable DNS records (TTL=$TTL)..." "INFO"

    create_dns_record "$cname" "$ip1"
    create_dns_record "$cname" "$ip2"

    cat > "$STATE_FILE" <<EOF
{
  "cname": "$cname",
  "primary_ip": "$ip1",
  "backup_ip": "$ip2",
  "ttl": $TTL,
  "mode": "dual-dns-stable"
}
EOF

    echo "$cname" > "$LAST_CNAME_FILE"

    echo
    log "SETUP COMPLETED — STABLE MODE" "SUCCESS"
    echo
    echo "CNAME:"
    echo -e "  ${GREEN}$cname${NC}"
    echo
    echo "IPs:"
    echo "  - $ip1 (Primary)"
    echo "  - $ip2 (Backup)"
    echo
    echo "✔ No proxy"
    echo "✔ No DNS switching"
    echo "✔ Long TTL prevents reconnect"
}

# =============================================
# INFO
# =============================================

show_status() {
    [ -f "$STATE_FILE" ] && jq . "$STATE_FILE" || log "No setup found" "ERROR"
}

show_cname() {
    [ -f "$LAST_CNAME_FILE" ] && cat "$LAST_CNAME_FILE" || log "No CNAME" "ERROR"
}

cleanup() {
    rm -f "$STATE_FILE" "$LAST_CNAME_FILE"
    log "Local state removed (DNS untouched)" "WARNING"
}

# =============================================
# CONFIG
# =============================================

configure_api() {
    read -rp "API Token: " CF_API_TOKEN
    test_api || { log "Invalid API token" "ERROR"; return; }

    read -rp "Zone ID: " CF_ZONE_ID
    test_zone || { log "Invalid Zone ID" "ERROR"; return; }

    read -rp "Base domain: " BASE_HOST
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
        echo "  CLOUDFLARE DUAL IP (NO PROXY)"
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
            3|4|5) log "This feature is disabled" "WARNING" ;;
            6) show_cname ;;
            7) cleanup ;;
            8) configure_api ;;
            9) exit 0 ;;
        esac
        pause
    done
}

main
