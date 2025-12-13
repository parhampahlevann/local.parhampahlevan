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

# مقادیر پیش‌فرض
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
    # بارگذاری امن config
    while IFS='=' read -r key value; do
      # حذف کامنت‌ها و فضاهای خالی
      key=$(echo "$key" | xargs)
      value=$(echo "$value" | xargs)
      
      case "$key" in
        CF_API_TOKEN)
          CF_API_TOKEN="$value"
          ;;
        CF_ZONE_ID)
          CF_ZONE_ID="$value"
          ;;
        BASE_DOMAIN)
          BASE_DOMAIN="$value"
          ;;
        SUBDOMAIN)
          SUBDOMAIN="$value"
          ;;
        SERVICE_PORT)
          SERVICE_PORT="$value"
          ;;
      esac
    done < <(grep -E '^(CF_API_TOKEN|CF_ZONE_ID|BASE_DOMAIN|SUBDOMAIN|SERVICE_PORT)=' "$CONFIG_FILE" 2>/dev/null || true)
    
    log "Configuration loaded" "INFO"
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
  log "Configuration saved to $CONFIG_FILE" "SUCCESS"
}

# ---------------- API ----------------
api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local curl_cmd="curl -s -X '$method' '$CF_API_BASE$endpoint' \
    -H 'Authorization: Bearer $CF_API_TOKEN' \
    -H 'Content-Type: application/json'"
  
  if [ -n "$data" ]; then
    curl_cmd="$curl_cmd --data '$data'"
  fi
  
  # اجرای دستور curl
  eval "$curl_cmd"
}

check_api() {
  if [ -z "$CF_API_TOKEN" ]; then
    log "API Token is empty" "ERROR"
    return 1
  fi
  
  local response
  response=$(curl -s -X GET "$CF_API_BASE/user/tokens/verify" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" 2>/dev/null || true)
  
  if [ -z "$response" ]; then
    log "No response from API. Check your internet connection." "ERROR"
    return 1
  fi
  
  if echo "$response" | jq -e '.success==true' >/dev/null 2>&1; then
    log "API Token verified successfully" "SUCCESS"
    return 0
  else
    local error_msg
    error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Invalid response")
    log "API verification failed: $error_msg" "ERROR"
    return 1
  fi
}

check_zone() {
  if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ]; then
    log "API Token or Zone ID is empty" "ERROR"
    return 1
  fi
  
  local response
  response=$(curl -s -X GET "$CF_API_BASE/zones/$CF_ZONE_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" 2>/dev/null || true)
  
  if [ -z "$response" ]; then
    log "No response from API for zone check" "ERROR"
    return 1
  fi
  
  if echo "$response" | jq -e '.success==true' >/dev/null 2>&1; then
    log "Zone verified successfully" "SUCCESS"
    return 0
  else
    local error_msg
    error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Invalid response")
    log "Zone verification failed: $error_msg" "ERROR"
    return 1
  fi
}

# ---------------- SETUP ----------------
setup_load_balancer() {
  clear
  echo "======================================"
  echo "     Stable Load Balancer Setup"
  echo "======================================"
  echo

  # بررسی وجود jq
  if ! command -v jq &> /dev/null; then
    log "jq is required but not installed. Please install it first." "ERROR"
    echo "Run: sudo apt install jq"
    pause
    return 1
  fi

  # بررسی مجدد اعتبار API
  echo "Verifying API credentials..."
  if ! check_api; then
    log "Please reconfigure API credentials (option 8)" "ERROR"
    pause
    return 1
  fi

  if ! check_zone; then
    log "Please reconfigure Zone ID (option 8)" "ERROR"
    pause
    return 1
  fi

  echo
  read -rp "Primary IP (e.g., 192.168.1.100): " PRIMARY_IP
  read -rp "Backup IP (e.g., 192.168.1.101):  " BACKUP_IP

  HOSTNAME="${SUBDOMAIN}.${BASE_DOMAIN}"

  echo
  echo "Creating resources for $HOSTNAME..."
  echo "Primary IP: $PRIMARY_IP"
  echo "Backup IP: $BACKUP_IP"
  echo "Port: $SERVICE_PORT"
  echo

  log "Creating health monitor..." "INFO"
  local monitor_response
  monitor_response=$(api POST "/user/load_balancers/monitors" "{
    \"type\":\"tcp\",
    \"interval\":30,
    \"timeout\":5,
    \"retries\":2,
    \"port\":$SERVICE_PORT
  }")
  
  echo "Monitor Response: $monitor_response" >> "$LOG_FILE"
  
  if [ -z "$monitor_response" ]; then
    log "Empty response from API. Check API token permissions." "ERROR"
    return 1
  fi
  
  MONITOR_ID=$(echo "$monitor_response" | jq -r '.result.id // empty')
  
  if [ -z "$MONITOR_ID" ] || [ "$MONITOR_ID" = "null" ]; then
    log "Failed to create monitor" "ERROR"
    echo "Full response: $monitor_response"
    
    local error_msg
    error_msg=$(echo "$monitor_response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null || echo "Invalid response format")
    log "Error: $error_msg" "ERROR"
    
    # بررسی مجوزهای API Token
    log "Please ensure your API Token has permissions for:" "INFO"
    log "1. Zone:Zone:Read" "INFO"
    log "2. Zone:Load Balancer:Edit" "INFO"
    log "3. Account:Load Balancer:Edit" "INFO"
    return 1
  fi

  log "Monitor created with ID: $MONITOR_ID" "SUCCESS"

  log "Creating primary pool..." "INFO"
  local primary_response
  primary_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"primary-pool-$HOSTNAME\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"primary\",\"address\":\"$PRIMARY_IP\",\"enabled\":true}]
  }")
  
  echo "Primary Pool Response: $primary_response" >> "$LOG_FILE"
  
  PRIMARY_POOL=$(echo "$primary_response" | jq -r '.result.id // empty')
  
  if [ -z "$PRIMARY_POOL" ] || [ "$PRIMARY_POOL" = "null" ]; then
    log "Failed to create primary pool" "ERROR"
    echo "Response: $primary_response"
    return 1
  fi

  log "Primary pool created with ID: $PRIMARY_POOL" "SUCCESS"

  log "Creating backup pool..." "INFO"
  local backup_response
  backup_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers/pools" "{
    \"name\":\"backup-pool-$HOSTNAME\",
    \"monitor\":\"$MONITOR_ID\",
    \"origins\":[{\"name\":\"backup\",\"address\":\"$BACKUP_IP\",\"enabled\":true}]
  }")
  
  echo "Backup Pool Response: $backup_response" >> "$LOG_FILE"
  
  BACKUP_POOL=$(echo "$backup_response" | jq -r '.result.id // empty')
  
  if [ -z "$BACKUP_POOL" ] || [ "$BACKUP_POOL" = "null" ]; then
    log "Failed to create backup pool" "ERROR"
    echo "Response: $backup_response"
    return 1
  fi

  log "Backup pool created with ID: $BACKUP_POOL" "SUCCESS"

  log "Creating Load Balancer DNS..." "INFO"
  local lb_response
  lb_response=$(api POST "/zones/$CF_ZONE_ID/load_balancers" "{
    \"name\":\"$HOSTNAME\",
    \"default_pools\":[\"$PRIMARY_POOL\"],
    \"fallback_pool\":\"$BACKUP_POOL\",
    \"proxied\":false,
    \"ttl\":300
  }")
  
  echo "Load Balancer Response: $lb_response" >> "$LOG_FILE"
  
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
  "monitor_id":"$MONITOR_ID",
  "created_at":"$(date -Iseconds)"
}
EOF

  log "Setup completed successfully!" "SUCCESS"
  echo
  echo "========================================"
  echo "        SETUP COMPLETED"
  echo "========================================"
  echo "CNAME / Hostname: $HOSTNAME"
  echo "Primary IP: $PRIMARY_IP"
  echo "Backup IP: $BACKUP_IP"
  echo "Port: $SERVICE_PORT"
  echo "Monitor ID: $MONITOR_ID"
  echo "Primary Pool ID: $PRIMARY_POOL"
  echo "Backup Pool ID: $BACKUP_POOL"
  echo "========================================"
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
      jq -r '.hostname // empty' "$STATE_FILE"
    else
      grep '"hostname"' "$STATE_FILE" | cut -d'"' -f4
    fi
  else
    echo "N/A"
  fi
}

cleanup() {
  if [ -f "$STATE_FILE" ]; then
    echo "Current state:"
    show_status
    echo
    read -rp "Are you sure you want to remove local state? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      rm -f "$STATE_FILE"
      log "Local state removed (Cloudflare resources untouched)" "WARNING"
    fi
  else
    log "No state file to remove" "INFO"
  fi
}

# ---------------- CONFIG MENU ----------------
configure_api() {
  clear
  echo "======================================"
  echo "     API Configuration"
  echo "======================================"
  echo
  
  # نمایش تنظیمات فعلی
  echo "Current configuration:"
  echo "  Base Domain: ${BASE_DOMAIN:-Not set}"
  echo "  Subdomain: ${SUBDOMAIN}"
  echo "  Port: ${SERVICE_PORT}"
  echo "  Zone ID: ${CF_ZONE_ID:-Not set}"
  echo
  
  echo "Instructions:"
  echo "1. Get API Token from: https://dash.cloudflare.com/profile/api-tokens"
  echo "2. Create token with these permissions:"
  echo "   - Zone:Zone:Read"
  echo "   - Zone:Load Balancer:Edit"
  echo "   - Account:Load Balancer:Edit"
  echo "3. Get Zone ID from your domain's Overview page"
  echo
  
  read -rp "API Token (leave empty to keep current): " new_token
  if [ -n "$new_token" ]; then
    # تست API Token جدید
    OLD_TOKEN="$CF_API_TOKEN"
    CF_API_TOKEN="$new_token"
    
    if check_api; then
      log "API Token verified and updated" "SUCCESS"
    else
      CF_API_TOKEN="$OLD_TOKEN"
      log "Keeping old API Token" "WARNING"
      pause
      return 1
    fi
  fi
  
  read -rp "Zone ID (leave empty to keep current): " new_zone
  if [ -n "$new_zone" ]; then
    OLD_ZONE="$CF_ZONE_ID"
    CF_ZONE_ID="$new_zone"
    
    if check_zone; then
      log "Zone ID verified and updated" "SUCCESS"
    else
      CF_ZONE_ID="$OLD_ZONE"
      log "Keeping old Zone ID" "WARNING"
    fi
  fi
  
  read -rp "Base domain (example.com): " new_domain
  [ -n "$new_domain" ] && BASE_DOMAIN="$new_domain"

  read -rp "Subdomain [${SUBDOMAIN}]: " tmp
  [ -n "$tmp" ] && SUBDOMAIN="$tmp"

  read -rp "Service port [${SERVICE_PORT}]: " tmp
  if [ -n "$tmp" ]; then
    if [[ "$tmp" =~ ^[0-9]+$ ]] && [ "$tmp" -ge 1 ] && [ "$tmp" -le 65535 ]; then
      SERVICE_PORT="$tmp"
    else
      log "Invalid port number. Keeping current: $SERVICE_PORT" "WARNING"
    fi
  fi
  
  save_config
  
  echo
  echo "Configuration saved!"
  echo "Current settings:"
  echo "  Domain: $BASE_DOMAIN"
  echo "  Full hostname: ${SUBDOMAIN}.${BASE_DOMAIN}"
  echo "  Port: $SERVICE_PORT"
  echo "  Zone ID: $CF_ZONE_ID"
  echo
}

# ---------------- MENU ----------------
main() {
  ensure_dir
  load_config
  
  # بررسی وجود jq
  if ! command -v jq &> /dev/null; then
    echo "⚠️  Warning: jq is not installed."
    echo "Some features will not work properly."
    echo "Install it with: sudo apt install jq"
    echo
    pause
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
    echo "──────────── Current Status ────────────"
    if [ -f "$STATE_FILE" ]; then
      echo "✓ Load Balancer: $(show_hostname)"
    else
      echo "✗ No active setup"
    fi
    
    if [ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_ZONE_ID:-}" ] && [ -n "${BASE_DOMAIN:-}" ]; then
      echo "✓ API: Configured"
      echo "✓ Zone: Ready"
      echo "✓ Domain: $BASE_DOMAIN"
    else
      echo "⚠️  API: Not configured (run option 8)"
    fi
    echo "──────────────────────────────────────"
    echo

    read -rp "Select option (1-9): " c
    case "$c" in
      1)
        if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ] || [ -z "${BASE_DOMAIN:-}" ]; then
          log "API not configured. Please run option 8 first." "ERROR"
          pause
        else
          setup_load_balancer
        fi
        ;;
      2) 
          show_status
          ;;
      3|4|5) 
          log "This option is intentionally disabled" "INFO" 
          ;;
      6) 
          echo "Hostname: $(show_hostname)"
          ;;
      7) 
          cleanup 
          ;;
      8) 
          configure_api 
          ;;
      9) 
          echo "Exiting..."
          exit 0
          ;;
      *) 
          log "Invalid option" "ERROR" 
          ;;
    esac
    pause
  done
}

main
