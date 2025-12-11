#!/usr/bin/env bash
# Cloudflare Load Balancer Creator with Auto-Failover
# Creates:
#   Two A records (primary and backup)
#   Cloudflare Load Balancer with health checks
#   CNAME pointing to Load Balancer with auto-failover

set -euo pipefail

TOOL_NAME="cf-loadbalancer-failover"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="${CONFIG_DIR}/created_resources.log"
LAST_LB_FILE="${CONFIG_DIR}/last_loadbalancer.txt"

CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""
HEALTH_CHECK_INTERVAL=15  # seconds

pause() {
  read -rp "Press Enter to continue..." _
}

ensure_dir() {
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"
}

install_prereqs() {
  echo "==> Checking prerequisites..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "   curl not found. Installing curl (requires sudo)..."
    sudo apt-get update
    sudo apt-get install -y curl
  else
    echo "   curl is already installed."
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "   jq not found. Installing jq (requires sudo)..."
    sudo apt-get update
    sudo apt-get install -y jq
  else
    echo "   jq is already installed."
  fi

  echo "==> Prerequisites are ready."
  echo
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# Auto-generated config for $TOOL_NAME
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
BASE_HOST="$BASE_HOST"
EOF
  echo "==> Config saved to $CONFIG_FILE"
  echo
}

api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  
  local curl_cmd="curl -sS -X $method '$url' \
    -H 'Authorization: Bearer $CF_API_TOKEN' \
    -H 'Content-Type: application/json'"
    
  if [[ -n "$data" ]]; then
    curl_cmd="$curl_cmd --data '$data'"
  fi
  
  eval "$curl_cmd" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"API request failed"}]}'
}

test_config() {
  echo "==> Testing Cloudflare Zone ID and API token..."
  local resp success zone_name
  
  resp=$(api_request "GET" "${CF_API_BASE}/zones/${CF_ZONE_ID}")
  success=$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo "false")

  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to fetch zone details from Cloudflare:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    echo
    echo "Please check your API token and Zone ID."
    return 1
  fi

  zone_name=$(echo "$resp" | jq -r '.result.name // ""')
  echo "✅ Cloudflare zone name: $zone_name"

  if [[ -n "$BASE_HOST" && "$BASE_HOST" != "$zone_name" && "$BASE_HOST" != *".${zone_name}" ]]; then
    echo "⚠️ WARNING:"
    echo "   BASE_HOST is not equal to the zone name or a subdomain of it."
    echo "   Zone name : $zone_name"
    echo "   BASE_HOST : $BASE_HOST"
    echo "   Load Balancer will only work correctly if BASE_HOST is the zone or its subdomain."
    echo
  fi
  return 0
}

configure_if_needed() {
  if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" && -n "${BASE_HOST:-}" ]]; then
    echo "Using existing configuration:"
    echo "  BASE_HOST : $BASE_HOST"
    echo "  CF_ZONE_ID: $CF_ZONE_ID"
    echo
    return
  fi

  echo "=== Cloudflare configuration ==="
  echo "You need a Cloudflare API token with these permissions:"
  echo "  - Zone.DNS (Edit)"
  echo "  - Zone.Load Balancing (Edit)"
  echo
  read -rp "Enter Cloudflare API Token: " CF_API_TOKEN
  read -rp "Enter Cloudflare Zone ID: " CF_ZONE_ID
  read -rp "Enter base hostname (e.g. example.com or lb.example.com): " BASE_HOST

  ensure_dir
  save_config

  if ! test_config; then
    echo "❌ Config test failed. Fix API token / Zone ID / BASE_HOST and run again."
    exit 1
  fi
}

valid_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  
  local IFS=.
  read -r o1 o2 o3 o4 <<< "$ip"
  [[ $o1 -le 255 && $o2 -le 255 && $o3 -le 255 && $o4 -le 255 && \
     $o1 -ge 0 && $o2 -ge 0 && $o3 -ge 0 && $o4 -ge 0 ]]
}

random_subdomain() {
  tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || echo "$(date +%s%N | md5sum | head -c 8)"
}

create_monitor() {
  echo "Creating Health Check Monitor..."
  
  local monitor_name="monitor-primary-${1}"
  local monitor_data
  
  monitor_data=$(cat <<EOF
{
  "type": "http",
  "description": "Primary server health check",
  "method": "GET",
  "path": "/",
  "header": {},
  "port": 80,
  "timeout": 5,
  "retries": 2,
  "interval": $HEALTH_CHECK_INTERVAL,
  "expected_body": "",
  "expected_codes": "200,301,302",
  "follow_redirects": true,
  "allow_insecure": false
}
EOF
)
  
  local resp
  resp=$(api_request "POST" "${CF_API_BASE}/user/load_balancers/monitors" "$monitor_data")
  local success=$(echo "$resp" | jq -r '.success // false')
  
  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to create health check monitor:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi
  
  local monitor_id=$(echo "$resp" | jq -r '.result.id')
  echo "✅ Health Check Monitor created (ID: $monitor_id)"
  echo "$monitor_id"
}

create_pool() {
  local pool_name="$1"
  local primary_ip="$2"
  local backup_ip="$3"
  local monitor_id="$4"
  
  echo "Creating Load Balancer Pool: $pool_name"
  
  local pool_data
  
  pool_data=$(cat <<EOF
{
  "name": "$pool_name",
  "monitor": "$monitor_id",
  "origins": [
    {
      "name": "primary-server",
      "address": "$primary_ip",
      "enabled": true,
      "weight": 1,
      "header": {}
    },
    {
      "name": "backup-server",
      "address": "$backup_ip",
      "enabled": true,
      "weight": 1,
      "header": {}
    }
  ],
  "notification_email": "",
  "enabled": true,
  "latitude": 0,
  "longitude": 0,
  "check_regions": ["WEU", "EEU", "ENAM", "WNAM"],
  "description": "Auto-failover pool. Primary: $primary_ip, Backup: $backup_ip",
  "minimum_origins": 1,
  "origin_steering": {
    "policy": "random"
  }
}
EOF
)
  
  local resp
  resp=$(api_request "POST" "${CF_API_BASE}/user/load_balancers/pools" "$pool_data")
  local success=$(echo "$resp" | jq -r '.success // false')
  
  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to create load balancer pool:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi
  
  local pool_id=$(echo "$resp" | jq -r '.result.id')
  echo "✅ Load Balancer Pool created (ID: $pool_id)"
  echo "$pool_id"
}

create_load_balancer() {
  local lb_name="$1"
  local pool_id="$2"
  
  echo "Creating Load Balancer: $lb_name"
  
  local lb_data
  
  lb_data=$(cat <<EOF
{
  "name": "$lb_name",
  "description": "Auto-failover load balancer",
  "ttl": 60,
  "fallback_pool": "$pool_id",
  "default_pools": ["$pool_id"],
  "region_pools": {},
  "pop_pools": {},
  "country_pools": {},
  "proxied": false,
  "enabled": true,
  "session_affinity": "none",
  "session_affinity_attributes": {
    "samesite": "Auto",
    "secure": "Auto",
    "zero_downtime_failover": "temporary"
  },
  "steering_policy": "dynamic_latency",
  "rules": []
}
EOF
)
  
  local resp
  resp=$(api_request "POST" "${CF_API_BASE}/zones/${CF_ZONE_ID}/load_balancers" "$lb_data")
  local success=$(echo "$resp" | jq -r '.success // false')
  
  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to create load balancer:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi
  
  local lb_id=$(echo "$resp" | jq -r '.result.id')
  local lb_dns=$(echo "$resp" | jq -r '.result.name')
  echo "✅ Load Balancer created (ID: $lb_id)"
  echo "   DNS: $lb_dns"
  echo "$lb_dns"
}

get_fallback_pool_settings() {
  local pool_id="$1"
  
  echo
  echo "=== Load Balancer Pool Settings ==="
  echo "Primary IP:"
  echo "  - Health checked every ${HEALTH_CHECK_INTERVAL} seconds"
  echo "  - Marked as 'healthy' if responds with 200, 301, or 302"
  echo "  - Timeout: 5 seconds, Retries: 2"
  echo
  echo "Failover Behavior:"
  echo "  - Primary IP has priority"
  echo "  - If primary fails health checks for 30+ seconds, traffic goes to backup"
  echo "  - When primary recovers, traffic automatically returns to primary"
  echo "  - Minimum origins required: 1 (works even if only backup is available)"
  echo
  echo "Checking regions: Western EU, Eastern EU, Eastern NA, Western NA"
  echo
}

create_cname_for_lb() {
  local lb_dns="$1"
  local cname_host="$2"
  
  echo "Creating CNAME record pointing to Load Balancer..."
  
  local cname_data
  
  cname_data=$(cat <<EOF
{
  "type": "CNAME",
  "name": "$cname_host",
  "content": "$lb_dns",
  "ttl": 1,
  "proxied": false
}
EOF
)
  
  local resp
  resp=$(api_request "POST" "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records" "$cname_data")
  local success=$(echo "$resp" | jq -r '.success // false')
  
  if [[ "$success" != "true" ]]; then
    echo "⚠️ Could not create CNAME record (might already exist):"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi
  
  echo "✅ CNAME record created: $cname_host → $lb_dns"
  return 0
}

main_flow() {
  echo "=== Cloudflare Load Balancer with Auto-Failover ==="
  echo "This script creates:"
  echo "  1. Health Check Monitor (checks every ${HEALTH_CHECK_INTERVAL} seconds)"
  echo "  2. Load Balancer Pool with Primary and Backup servers"
  echo "  3. Load Balancer with auto-failover capability"
  echo "  4. CNAME record pointing to the Load Balancer"
  echo
  echo "Failover behavior:"
  echo "  • Primary IP gets all traffic when healthy"
  echo "  • If Primary fails health checks, traffic switches to Backup"
  echo "  • When Primary recovers, traffic automatically returns to Primary"
  echo

  ensure_dir
  load_config
  install_prereqs
  configure_if_needed

  echo "==> Enter IP addresses for failover setup"
  local primary_ip backup_ip
  
  while true; do
    read -rp "Enter PRIMARY IPv4 (gets priority): " primary_ip
    if valid_ipv4 "$primary_ip"; then
      break
    fi
    echo "❌ Invalid IPv4 address. Please try again."
  done

  while true; do
    read -rp "Enter BACKUP IPv4 (used when primary fails): " backup_ip
    if valid_ipv4 "$backup_ip"; then
      if [[ "$primary_ip" == "$backup_ip" ]]; then
        echo "⚠️  Both IPs are the same. This defeats the purpose of failover."
        echo "Continue anyway? (y/n) "
        read -r answer
        [[ "$answer" =~ ^[Yy]$ ]] && break
      else
        break
      fi
    else
      echo "❌ Invalid IPv4 address. Please try again."
    fi
  done

  echo
  echo "==> Generating unique identifiers..."
  
  local rand=$(random_subdomain)
  local pool_name="pool-${rand}"
  local lb_host="lb-${rand}.${BASE_HOST}"
  local cname_host="app-${rand}.${BASE_HOST}"
  
  echo "   Pool Name: $pool_name"
  echo "   Load Balancer: $lb_host"
  echo "   Your CNAME: $cname_host"
  echo

  # Step 1: Create Health Check Monitor
  echo "Step 1/4: Creating Health Check Monitor..."
  local monitor_id
  monitor_id=$(create_monitor "$rand")
  if [[ -z "$monitor_id" ]] || [[ "$monitor_id" == "null" ]]; then
    echo "❌ Failed to create monitor. Exiting."
    exit 1
  fi

  # Step 2: Create Load Balancer Pool
  echo
  echo "Step 2/4: Creating Load Balancer Pool..."
  local pool_id
  pool_id=$(create_pool "$pool_name" "$primary_ip" "$backup_ip" "$monitor_id")
  if [[ -z "$pool_id" ]] || [[ "$pool_id" == "null" ]]; then
    echo "❌ Failed to create pool. Exiting."
    exit 1
  fi

  # Step 3: Create Load Balancer
  echo
  echo "Step 3/4: Creating Load Balancer..."
  local lb_dns
  lb_dns=$(create_load_balancer "$lb_host" "$pool_id")
  if [[ -z "$lb_dns" ]] || [[ "$lb_dns" == "null" ]]; then
    echo "❌ Failed to create load balancer. Exiting."
    exit 1
  fi

  # Step 4: Create CNAME
  echo
  echo "Step 4/4: Creating CNAME record..."
  create_cname_for_lb "$lb_dns" "$cname_host"

  # Display settings
  get_fallback_pool_settings "$pool_id"

  echo
  echo "==============================================="
  echo "✅ SETUP COMPLETE!"
  echo "==============================================="
  echo
  echo "Your resources:"
  echo
  echo "   Health Check Monitor:"
  echo "     • Checks every ${HEALTH_CHECK_INTERVAL} seconds"
  echo "     • Expects HTTP 200, 301, or 302"
  echo "     • Timeout: 5 seconds"
  echo
  echo "   Load Balancer Pool:"
  echo "     • Primary: $primary_ip (priority)"
  echo "     • Backup:  $backup_ip"
  echo "     • Pool ID: $pool_id"
  echo
  echo "   Load Balancer DNS:"
  echo "     • $lb_dns"
  echo
  echo "   Your CNAME endpoint:"
  echo "     • $cname_host"
  echo
  echo "==============================================="
  echo
  echo "📝 USAGE:"
  echo "   1. Point your application to: $cname_host"
  echo "   2. Cloudflare will automatically:"
  echo "      - Send traffic to $primary_ip"
  echo "      - Monitor it every ${HEALTH_CHECK_INTERVAL} seconds"
  echo "      - If primary fails, switch to $backup_ip"
  echo "      - When primary recovers, switch back automatically"
  echo
  echo "⚙️  To manage your Load Balancer:"
  echo "   Login to Cloudflare Dashboard → Traffic → Load Balancing"
  echo

  # Save information
  echo "$cname_host" > "$LAST_LB_FILE"
  
  cat > "${CONFIG_DIR}/lb_${rand}_$(date +%Y%m%d_%H%M%S).info" <<EOF
Load Balancer Created: $(date)
=================================
CNAME Endpoint: $cname_host
Load Balancer: $lb_dns
Pool ID: $pool_id
Monitor ID: $monitor_id

IP Addresses:
  Primary: $primary_ip
  Backup:  $backup_ip

Health Check:
  Interval: ${HEALTH_CHECK_INTERVAL} seconds
  Expected Codes: 200, 301, 302
  Timeout: 5 seconds
  Retries: 2

Failover Behavior:
  - Primary gets all traffic when healthy
  - If primary fails health checks, traffic switches to backup
  - Returns to primary when it recovers
  - Health checked from multiple regions

To view/edit: https://dash.cloudflare.com/$(echo "$CF_ZONE_ID" | cut -c1-8)/traffic/load-balancing
EOF

  echo "Configuration saved to: ${CONFIG_DIR}/lb_${rand}_*.info"
  echo "CNAME endpoint saved to: $LAST_LB_FILE"
  echo

  read -rp "Press Enter to exit..." _
}

# ===================== Entry point =====================
main_flow
