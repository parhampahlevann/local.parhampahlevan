#!/bin/bash
set -euo pipefail

# =============================================
# CLOUDFLARE DNS SWITCH - CLEAN MANUAL ONLY
# =============================================

CONFIG_DIR="$HOME/.cf-dns-switch"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"
LOCK_FILE="/tmp/cf-dns-switch.lock"

CF_API_BASE="https://api.cloudflare.com/client/v4"

DNS_TTL=300

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================
# BASIC UTILS
# =============================================

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

ensure_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

pause() {
    read -rp "Press Enter to continue..." _
}

check_prerequisites() {
    command -v curl >/dev/null || { echo "curl missing"; exit 1; }
    command -v jq >/dev/null || { echo "jq missing"; exit 1; }
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
DNS_TTL="$DNS_TTL"
EOF
    log "Config saved" "SUCCESS"
}

# =============================================
# API
# =============================================

api() {
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

# =============================================
# DNS
# =============================================

create_record() {
    local name="$1" type="$2" content="$3"

    api POST "/zones/$CF_ZONE_ID/dns_records" "{
      \"type\":\"$type\",
      \"name\":\"$name\",
      \"content\":\"$content\",
      \"ttl\":$DNS_TTL,
      \"proxied\":false
    }" | jq -r '.result.id'
}

update_cname() {
    local cname="$1" target="$2"
    local id

    id=$(api GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$cname" | jq -r '.result[0].id')

    api PUT "/zones/$CF_ZONE_ID/dns_records/$id" "{
      \"type\":\"CNAME\",
      \"name\":\"$cname\",
      \"content\":\"$target\",
      \"ttl\":$DNS_TTL,
      \"proxied\":false
    }" >/dev/null

    log "CNAME updated: $cname → $target" "SUCCESS"
}

delete_record() {
    [ -n "$1" ] && api DELETE "/zones/$CF_ZONE_ID/dns_records/$1" >/dev/null
}

# =============================================
# SETUP
# =============================================

setup_switch() {
    read -rp "Primary IP: " primary_ip
    read -rp "Backup IP: " backup_ip

    local id cname primary_host backup_host
    id=$(date +%s | sha1sum | cut -c1-6)

    cname="switch-$id.$BASE_HOST"
    primary_host="primary-$id.$BASE_HOST"
    backup_host="backup-$id.$BASE_HOST"

    p_id=$(create_record "$primary_host" A "$primary_ip")
    b_id=$(create_record "$backup_host" A "$backup_ip")
    c_id=$(create_record "$cname" CNAME "$primary_host")

    cat > "$STATE_FILE" <<EOF
{
  "cname":"$cname",
  "primary_ip":"$primary_ip",
  "backup_ip":"$backup_ip",
  "primary_host":"$primary_host",
  "backup_host":"$backup_host",
  "primary_record_id":"$p_id",
  "backup_record_id":"$b_id",
  "cname_record_id":"$c_id",
  "active":"primary",
  "created_at":"$(date)"
}
EOF

    log "DNS switch created" "SUCCESS"
    echo -e "${GREEN}CNAME:${NC} $cname"
}

# =============================================
# MANUAL SWITCH ONLY
# =============================================

manual_switch() {
    local cname primary_host backup_host active

    cname=$(jq -r '.cname' "$STATE_FILE")
    primary_host=$(jq -r '.primary_host' "$STATE_FILE")
    backup_host=$(jq -r '.backup_host' "$STATE_FILE")
    active=$(jq -r '.active' "$STATE_FILE")

    echo "1) Switch to PRIMARY"
    echo "2) Switch to BACKUP"
    read -rp "Select: " c

    case "$c" in
        1)
            update_cname "$cname" "$primary_host"
            jq '.active="primary"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
            ;;
        2)
            update_cname "$cname" "$backup_host"
            jq '.active="backup"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
            ;;
    esac
}

# =============================================
# STATUS
# =============================================

status() {
    jq . "$STATE_FILE"
}

# =============================================
# CLEANUP
# =============================================

cleanup() {
    local p b c
    p=$(jq -r '.primary_record_id' "$STATE_FILE")
    b=$(jq -r '.backup_record_id' "$STATE_FILE")
    c=$(jq -r '.cname_record_id' "$STATE_FILE")

    delete_record "$c"
    delete_record "$p"
    delete_record "$b"

    rm -f "$STATE_FILE"
    log "All records deleted" "SUCCESS"
}

# =============================================
# MENU
# =============================================

main() {
    ensure_dir
    check_prerequisites
    load_config

    while true; do
        clear
        echo "1) Create DNS Switch"
        echo "2) Manual Switch"
        echo "3) Status"
        echo "4) Cleanup"
        echo "5) Configure API"
        echo "6) Exit"
        read -rp "> " m

        case "$m" in
            1) setup_switch; pause ;;
            2) manual_switch; pause ;;
            3) status; pause ;;
            4) cleanup; pause ;;
            5)
                read -rp "API Token: " CF_API_TOKEN
                read -rp "Zone ID: " CF_ZONE_ID
                read -rp "Base Domain: " BASE_HOST
                save_config
                ;;
            6) exit ;;
        esac
    done
}

main
