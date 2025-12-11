#!/usr/bin/env bash
# One-shot Cloudflare multi-IP hostname helper
# - Installs prerequisites (curl, jq)
# - Asks for CF API token / Zone ID / BASE_HOST once and saves them
# - Tests Cloudflare access
# - Asks for two IPv4 addresses
# - Creates srv-xxxx.BASE_HOST with two A records
# - Prints final CNAME target for you to use, and saves it to last_cname.txt

set -euo pipefail

TOOL_NAME="cf-multi-ip-cname"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="${CONFIG_DIR}/created_hosts.log"
LAST_CNAME_FILE="${CONFIG_DIR}/last_cname.txt"

CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""
CF_PROXY="false"   # always DNS-only (proxy off)

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
CF_PROXY="$CF_PROXY"
EOF
  echo "==> Config saved to $CONFIG_FILE"
  echo
}

api_get() {
  local url="$1"
  shift || true
  curl -sS -G "$url" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

test_config() {
  echo "==> Testing Cloudflare Zone ID and API token..."
  local url resp success zone_name
  url="${CF_API_BASE}/zones/${CF_ZONE_ID}"
  resp=$(api_get "$url" || true)

  success=$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo "false")

  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to fetch zone details from Cloudflare:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    echo
    echo "Please check your API token and Zone ID."
    return 1
  fi

  zone_name=$(echo "$resp" | jq -r '.result.name')
  echo "✅ Cloudflare zone name: $zone_name"

  if [[ -n "$BASE_HOST" && "$BASE_HOST" != "$zone_name" && "$BASE_HOST" != *".${zone_name}" ]]; then
    echo "⚠️ WARNING:"
    echo "   BASE_HOST is not equal to the zone name or a subdomain of it."
    echo "   Zone name : $zone_name"
    echo "   BASE_HOST : $BASE_HOST"
    echo "   Records will only work correctly if BASE_HOST is the zone or its subdomain."
    echo "   Example for this zone: $zone_name or nodes.$zone_name"
  fi
  echo
  return 0
}

configure_if_needed() {
  if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" && -n "${BASE_HOST:-}" ]]; then
    # already configured
    return
  fi

  echo "=== First-time Cloudflare configuration ==="
  read -rp "Enter Cloudflare API Token: " CF_API_TOKEN
  read -rp "Enter Cloudflare Zone ID: " CF_ZONE_ID
  read -rp "Enter base hostname (e.g. cloudmahann.ir or nodes.cloudmahann.ir): " BASE_HOST

  CF_PROXY="false"   # always DNS only
  echo "Cloudflare proxy is disabled on created records (proxied = false)."
  echo

  ensure_dir
  save_config

  if ! test_config; then
    echo "❌ Config test failed. Fix API token / Zone ID / BASE_HOST and run again."
    exit 1
  fi
}

valid_ipv4() {
  local ip="$1"
  local IFS=.
  read -r o1 o2 o3 o4 <<< "$ip" || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

random_subdomain() {
  tr -dc 'a-z0-9' </dev/urandom | head -c 8
}

api_post() {
  local url="$1"
  local data="$2"

  curl -sS -X POST "$url" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$data"
}

create_a_record() {
  local name="$1"
  local ip="$2"

  local data
  data=$(cat <<EOF
{
  "type": "A",
  "name": "$name",
  "content": "$ip",
  "ttl": 1,
  "proxied": $CF_PROXY
}
EOF
)

  local url="${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records"
  local resp
  resp=$(api_post "$url" "$data" || true)

  local success
  success=$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo "false")

  if [[ "$success" != "true" ]]; then
    echo "❌ Cloudflare error while creating A record for $name ($ip):"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi

  local rec_id
  rec_id=$(echo "$resp" | jq -r '.result.id')
  echo "   Created A record id: $rec_id for $name -> $ip"
  echo "$(date +'%Y-%m-%d %H:%M:%S') CREATE $name A $ip $rec_id" >> "$LOG_FILE"
  return 0
}

main_flow() {
  echo "=== Cloudflare multi-IP hostname creator ==="
  echo

  # 1) make sure config exists
  configure_if_needed

  echo "Using configuration:"
  echo "  BASE_HOST : $BASE_HOST"
  echo "  CF_ZONE_ID: $CF_ZONE_ID"
  echo

  # 2) ask for two IPv4 addresses
  local ip1 ip2
  while true; do
    read -rp "Enter first IPv4: " ip1
    read -rp "Enter second IPv4: " ip2

    if valid_ipv4 "$ip1" && valid_ipv4 "$ip2"; then
      break
    fi
    echo "❌ One or both IPs are invalid. Please enter two valid IPv4 addresses."
  done

  # 3) generate hostname
  local rand sub full_name
  rand=$(random_subdomain)
  sub="srv-${rand}"
  full_name="${sub}.${BASE_HOST}"

  echo
  echo "==> Creating hostname on Cloudflare:"
  echo "    Hostname: $full_name"
  echo "    IPs     : $ip1 , $ip2"
  echo

  echo "   Creating first A record..."
  if ! create_a_record "$full_name" "$ip1"; then
    echo "❌ Failed to create first A record. Aborting."
    exit 1
  fi

  echo "   Creating second A record..."
  if ! create_a_record "$full_name" "$ip2"; then
    echo "❌ Failed to create second A record."
    echo "Note: the first A record was already created; you may want to delete it manually."
    exit 1
  fi

  # 4) print and save final CNAME target
  echo
  echo "==============================================="
  echo "✅ DONE!"
  echo
  echo "Your CNAME target (hostname with both IPs) is:"
  echo
  echo "   $full_name"
  echo
  echo "You can use it like this in any other domain:"
  echo
  echo "   mysub.yourdomain.com    CNAME    $full_name"
  echo
  echo "Both IPs $ip1 and $ip2 are now attached to:"
  echo "   $full_name"
  echo "==============================================="
  echo

  echo "$full_name" > "$LAST_CNAME_FILE"
  echo "Last CNAME target has been saved to:"
  echo "   $LAST_CNAME_FILE"
  echo

  read -rp "Press Enter to exit..." _
}

# ===================== Entry point =====================

ensure_dir
install_prereqs
load_config
main_flow
