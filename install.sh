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

# مقادیر پیش‌فرض (اگر در فایل config وجود نداشته باشند)
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
  if [ -f "$CONFIG_FILE" ]; then
    # ایمن‌سازی: فقط فایل config خودمان را source کنیم
    if grep -q "CF_API_TOKEN\|CF_ZONE_ID\|BASE_DOMAIN" "$CONFIG_FILE"; then
      # حذف دستورات خطرناک احتمالی
      source <(grep -E '^(CF_API_TOKEN|CF_ZONE_ID|BASE_DOMAIN|SUBDOMAIN|SERVICE_PORT)=' "$CONFIG_FILE")
      log "Configuration loaded from $CONFIG_FILE" "INFO"
    fi
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_DOMAIN="$BASE_DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
SERVICE_PORT="$SERVICE_PORT"
EOF
  chmod 600 "$CONFIG_FILE"
  log "Configuration saved" "SUCCESS"
}

# ---------------- API ----------------
api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local response
  if [ -n "$data" ]; then
    response=$(curl -s -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")
  else
    response=$(curl -s -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")
  fi
  
  echo "$response"
}

check_api() {
  if ! command -v jq &> /dev/null; then
    log "jq is not installed. Please install it with: apt install jq" "ERROR"
    return 1
  fi
  
  local response
  response=$(api GET "/user/tokens/verify" 2>/dev/null || true)
  echo "$response" | jq -e '.success==true' >/dev/null 2>&1
}

check_zone() {
  if ! command -v jq &> /dev/null; then
    return 1
  fi
  
  local response
  response=$(api GET "/zones/$CF_ZONE_ID" 2>/dev/null || true)
  echo "$response" | jq -e '.success==true' >/dev/null 2>&1
}

# ---------------- SETUP ----------------
setup_load_balancer() {
  clear
  echo "======================================"
  echo "     Stable Load Balancer Setup"
  echo "======================================"
  echo

  if ! command -v jq &> /dev/null; then
    log "jq is required but not installed. Please install it first." "ERROR"
    echo "Run: sudo apt install jq"
    return 1
  fi

  read -rp "Primary IP: " PRIMARY_IP
  read -rp "Backup IP:  " BACKUP_IP

  HOSTNAME="${SUBDOMAIN}.${BASE_DOMAIN}"

  log "Creating health monitor..." "INFO"
  local monitor_response
  monitor_response=$(api POST "/user/load_balancers/monitors" "{
    \"type\":\"tcp\",
    \"interval\":30,
    \"timeout\":5,
    \"retries\":2,
    \"port\":$SERVICE_PORT
  }")
  
  MONITOR_ID=$(echo "$monitor_response" | jq -r '.result.id')
  
  if [ -z "$MONITOR_ID" ] || [ "$MONITOR_ID" = "null" ]; then
    log "Failed to create monitor" "ERROR"
    echo "Response: $monitor_response"
    return 1
  fi

  log "Creating primary pool..." "INFO"
  local primary_response
  primary_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"primary-pool\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"primary\",\"address\":\"$PRIMARY_IP\",\"enabled\":true}]
  }")
  
  PRIMARY_POOL=$(echo "$primary_response" | jq -r '.result.id')
  
  if [ -z "$PRIMARY_POOL" ] || [ "$PRIMARY_POOL" = "null" ]; then
    log "Failed to create primary pool" "ERROR"
    echo "Response: $primary_response"
    return 1
  fi

  log "Creating backup pool..." "INFO"
  local backup_response
  backup_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"backup-pool\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"backup\",\"address\":\"$BACKUP_IP\",\"enabled\":true}]
  }")
  
  BACKUP_POOL=$(echo "$backup_response" | jq -r '.result.id')
  
  if [ -z "$BACKUP_POOL" ] || [ "$BACKUP_POOL" = "null" ]; then
    log "Failed to create backup pool" "ERROR"
    echo "Response: $backup_response"
    return 1
  fi

  log "Creating Load Balancer DNS..." "INFO"
  local lb_response
  lb_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers" "{
    \"name\":\"$HOSTNAME\",
    \"default_pools\":[\"$PRIMARY_POOL\"],
    \"fallback_pool\":\"$BACKUP_POOL\",
    \"proxied\":false,
    \"ttl\":300
  }")
  
  if ! echo "$lb_response" | jq -e '.success==true' >/dev/null 2>&1; then
    log "Failed to create load balancer" "ERROR"
    echo "Response: $lb_response"
    return 1
  fi

  cat > "$STATE_FILE" <<EOF
{
  "hostname":"$HOSTNAME",
  "primary_ip":"$PRIMARY_IP",
  "backup_ip":"$BACKUP_IP",
  "type":"cloudflare-load-balancer",
  "primary_pool":"$PRIMARY_POOL",
  "backup_pool":"$BACKUP_POOL",
  "monitor_id":"$MONITOR_ID"
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
    if command -v jq &> /dev/null; then
      jq . "$STATE_FILE"
    else
      cat "$STATE_FILE"
    fi
  else
    log "No active setup found" "WARNING"
  fi
}

show_hostname() {
  if [ -f "$STATE_FILE" ]; then
    if command -v jq &> /dev/null; then
      jq -r '.hostname' "$STATE_FILE"
    else
      grep '"hostname"' "$STATE_FILE" | cut -d'"' -f4
    fi
  else
    echo "N/A"
  fi
}

cleanup() {
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log "Local state removed (Cloudflare resources untouched)" "WARNING"
  else
    log "No state file to remove" "INFO"
  fi
}

# ---------------- CONFIG MENU ----------------
configure_api() {
  echo
  echo "API Configuration"
  echo "================="
  
  read -rp "API Token: " CF_API_TOKEN
  echo "Verifying API token..."
  
  if ! check_api; then
    log "Invalid API token or API error" "ERROR"
    CF_API_TOKEN=""
    return 1
  fi
  
  echo "Token verified successfully."
  
  read -rp "Zone ID: " CF_ZONE_ID
  echo "Verifying Zone ID..."
  
  if ! check_zone; then
    log "Invalid Zone ID or zone access error" "ERROR"
    CF_ZONE_ID=""
    return 1
  fi
  
  echo "Zone verified successfully."
  
  read -rp "Base domain (example.com): " BASE_DOMAIN
  
  read -rp "Subdomain [app]: " tmp
  [ -n "$tmp" ] && SUBDOMAIN="$tmp"
  
  read -rp "Service port [443]: " tmp
  if [ -n "$tmp" ]; then
    if [[ "$tmp" =~ ^[0-9]+$ ]] && [ "$tmp" -ge 1 ] && [ "$tmp" -le 65535 ]; then
      SERVICE_PORT="$tmp"
    else
      log "Invalid port number. Using default 443." "WARNING"
    fi
  fi
  
  save_config
  return 0
}

# ---------------- MENU ----------------
main() {
  ensure_dir
  load_config
  
  # بررسی نصب jq
  if ! command -v jq &> /dev/null; then
    echo "Warning: jq is not installed. Some features may not work properly."
    echo "Install it with: sudo apt install jq"
    echo
  fi
  
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
    echo "Current config:"
    echo "  Domain: ${BASE_DOMAIN:-Not set}"
    echo "  Subdomain: ${SUBDOMAIN}"
    echo "  Port: ${SERVICE_PORT}"
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
      6) 
          echo "Hostname: $(show_hostname)"
          ;;
      7) cleanup ;;
      8) configure_api ;;
      9) 
          echo "Exiting..."
          exit 0
          ;;
      *) log "Invalid option" "ERROR" ;;
    esac
    pause
  done
}

main
