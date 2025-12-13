#!/bin/bash
set -euo pipefail

# =====================================================
# CLOUDFLARE STABLE LOAD BALANCER WITH MENU
# =====================================================

CONFIG_DIR="$HOME/.cf-stable"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state.json"
LOG_FILE="$CONFIG_DIR/activity.log"

CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_DOMAIN=""
SUBDOMAIN="app"
SERVICE_PORT=443

# ---------------- UTILITIES ----------------
log() {
  local msg="$1"
  local lvl="${2:-INFO}"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts][$lvl] $msg"
  echo "[$ts][$lvl] $msg" >> "$LOG_FILE"
}

pause() {
  read -rp "Press Enter to continue..."
}

ensure_dir() {
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"
}

# ---------------- CONFIG ----------------
load_config() {
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_DOMAIN="$BASE_DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
SERVICE_PORT="$SERVICE_PORT"
EOF
  log "Configuration saved" "SUCCESS"
}

# ---------------- API ----------------
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
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

check_api() {
  api GET "/user/tokens/verify" | jq -e '.success==true' >/dev/null
}

check_zone() {
  api GET "/zones/$CF_ZONE_ID" | jq -e '.success==true' >/dev/null
}

# ---------------- SETUP ----------------
setup_load_balancer() {
  clear
  echo "======================================"
  echo "     Stable Load Balancer Setup"
  echo "======================================"
  echo

  read -rp "Primary IP: " PRIMARY_IP
  read -rp "Backup IP:  " BACKUP_IP

  HOSTNAME="${SUBDOMAIN}.${BASE_DOMAIN}"

  log "Creating health monitor..." "INFO"
  MONITOR_ID=$(api POST "/user/load_balancers/monitors" "{
    \"type\":\"tcp\",
    \"interval\":30,
    \"timeout\":5,
    \"retries\":2,
    \"port\":$SERVICE_PORT
  }" | jq -r '.result.id')

  log "Creating primary pool..." "INFO"
  PRIMARY_POOL=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"primary-pool\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"primary\",\"address\":\"$PRIMARY_IP\",\"enabled\":true}]
  }" | jq -r '.result.id')

  log "Creating backup pool..." "INFO"
  BACKUP_POOL=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"backup-pool\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"backup\",\"address\":\"$BACKUP_IP\",\"enabled\":true}]
  }" | jq -r '.result.id')

  log "Creating Load Balancer DNS..." "INFO"
  api POST "/zones/$CF_ZONE_ID/load_balancers" "{
    \"name\":\"$HOSTNAME\",
    \"default_pools\":[\"$PRIMARY_POOL\"],
    \"fallback_pool\":\"$BACKUP_POOL\",
    \"proxied\":false,
    \"ttl\":300
  }" | jq -e '.success==true' >/dev/null

  cat > "$STATE_FILE" <<EOF
{
  "hostname":"$HOSTNAME",
  "primary_ip":"$PRIMARY_IP",
  "backup_ip":"$BACKUP_IP",
  "type":"cloudflare-load-balancer"
}
EOF

  log "Setup completed successfully" "SUCCESS"
  echo
  echo "CNAME / Hostname:"
  echo "  $HOSTNAME"
  echo
}

# ---------------- INFO ----------------
show_status() {
  if [ -f "$STATE_FILE" ]; then
    jq . "$STATE_FILE"
  else
    log "No active setup found" "WARNING"
  fi
}

show_hostname() {
  if [ -f "$STATE_FILE" ]; then
    jq -r '.hostname' "$STATE_FILE"
  else
    echo "N/A"
  fi
}

cleanup() {
  rm -f "$STATE_FILE"
  log "Local state removed (Cloudflare resources untouched)" "WARNING"
}

# ---------------- CONFIG MENU ----------------
configure_api() {
  read -rp "API Token: " CF_API_TOKEN
  check_api || { log "Invalid API token" "ERROR"; return; }

  read -rp "Zone ID: " CF_ZONE_ID
  check_zone || { log "Invalid Zone ID" "ERROR"; return; }

  read -rp "Base domain (example.com): " BASE_DOMAIN

  read -rp "Subdomain [app]: " tmp
  [ -n "$tmp" ] && SUBDOMAIN="$tmp"

  read -rp "Service port [443]: " tmp
  [ -n "$tmp" ] && SERVICE_PORT="$tmp"

  save_config
}

# ---------------- MENU ----------------
main() {
  ensure_dir
  load_config

  while true; do
    clear
    echo "======================================"
    echo " Cloudflare Stable Load Balancer Menu"
    echo "======================================"
    echo "1) Complete Setup"
    echo "2) Show Status"
    echo "3) Start Monitor (Disabled)"
    echo "4) Stop Monitor (Disabled)"
    echo "5) Manual Failover (Disabled)"
    echo "6) Show Hostname"
    echo "7) Cleanup (local)"
    echo "8) Configure API"
    echo "9) Exit"
    echo

    read -rp "Select option (1-9): " c
    case "$c" in
      1)
        if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ] || [ -z "${BASE_DOMAIN:-}" ]; then
          log "API not configured. Please run option 8 first." "ERROR"
        else
          setup_load_balancer
        fi
        ;;
      2) show_status ;;
      3|4|5) log "This option is intentionally disabled" "INFO" ;;
      6) show_hostname ;;
      7) cleanup ;;
      8) configure_api ;;
      9) exit 0 ;;
      *) log "Invalid option" "ERROR" ;;
    esac
    pause
  done
}

main
