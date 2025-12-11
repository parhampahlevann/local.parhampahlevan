#!/usr/bin/env bash
# Simple Cloudflare multi-IP hostname helper
# Creates a random hostname with two A records and lets you delete them later.

set -euo pipefail

# ===================== Paths & Globals =====================

TOOL_NAME="cf-multi-ip-cname"
CONFIG_DIR="$HOME/.${TOOL_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="${CONFIG_DIR}/created_hosts.log"

CF_API_BASE="https://api.cloudflare.com/client/v4"

# These will be loaded from config file if it exists
CF_API_TOKEN=""
CF_ZONE_ID=""
BASE_HOST=""   # e.g. "mydns.cam"
CF_PROXY="true"   # "true" or "false" (Cloudflare orange-cloud on/off)

# ===================== Helpers =====================

pause() {
  read -rp "Press Enter to continue..." _
}

ensure_dir() {
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"
}

install_prereqs() {
  echo "Checking prerequisites..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found. Installing curl (requires sudo)..."
    sudo apt-get update
    sudo apt-get install -y curl
  else
    echo "curl is already installed."
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found. Installing jq (requires sudo)..."
    sudo apt-get update
    sudo apt-get install -y jq
  else
    echo "jq is already installed."
  fi

  echo "Prerequisites are ready."
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
  echo "Config saved to $CONFIG_FILE"
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
  echo "Testing Cloudflare Zone ID and API token..."
  local url resp success zone_name
  url="${CF_API_BASE}/zones/${CF_ZONE_ID}"
  resp=$(api_get "$url")
  success=$(echo "$resp" | jq -r '.success // false')

  if [[ "$success" != "true" ]]; then
    echo "❌ Failed to fetch zone details from Cloudflare:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"'
    echo "Please make sure the API token and Zone ID are correct."
    pause
    return 1
  fi

  zone_name=$(echo "$resp" | jq -r '.result.name')
  echo "✅ Cloudflare zone name: $zone_name"

  if [[ -n "$BASE_HOST" && "$BASE_HOST" != "$zone_name" && "$BASE_HOST" != *".${zone_name}" ]]; then
    echo "⚠️ WARNING:"
    echo "  BASE_HOST is not equal to the zone name or a subdomain of it."
    echo "  Zone name  : $zone_name"
    echo "  BASE_HOST  : $BASE_HOST"
    echo "  DNS records will only work correctly if BASE_HOST is the zone or a subdomain of it."
    echo "  Example for this zone: $zone_name or something like nodes.$zone_name"
  fi
  pause
  return 0
}

configure_cloudflare() {
  echo "=== Cloudflare configuration ==="
  read -rp "Enter Cloudflare API Token: " CF_API_TOKEN
  read -rp "Enter Cloudflare Zone ID: " CF_ZONE_ID
  read -rp "Enter base hostname (e.g. mydns.cam or nodes.mydns.cam): " BASE_HOST

  local proxy_choice
  read -rp "Use Cloudflare proxy (orange cloud)? [y/n] (default: y): " proxy_choice
  proxy_choice="${proxy_choice:-y}"
  if [[ "$proxy_choice" =~ ^[Yy]$ ]]; then
    CF_PROXY="true"
  else
    CF_PROXY="false"
  fi

  ensure_dir
  save_config
  test_config || echo "Config test failed; you can reconfigure from the menu."
}

require_config() {
  if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ZONE_ID:-}" || -z "${BASE_HOST:-}" ]]; then
    echo "Cloudflare not fully configured yet."
    echo "Please configure it first."
    pause
    configure_cloudflare
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
  # 8 characters a-z0-9
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

api_delete() {
  local url="$1"
  curl -sS -X DELETE "$url" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json"
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
  resp=$(api_post "$url" "$data")

  local success
  success=$(echo "$resp" | jq -r '.success // false')

  if [[ "$success" != "true" ]]; then
    echo "❌ Cloudflare error while creating A record for $name ($ip):"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"'
    return 1
  fi

  local rec_id
  rec_id=$(echo "$resp" | jq -r '.result.id')
  echo "Created A record id: $rec_id for $name -> $ip"
  echo "$(date +'%Y-%m-%d %H:%M:%S') CREATE $name A $ip $rec_id" >> "$LOG_FILE"
  return 0
}

create_hostname_with_two_ips() {
  require_config

  echo "=== Create hostname with two IPv4 addresses ==="
  echo "Base host: $BASE_HOST"
  read -rp "Enter first IPv4: " ip1
  read -rp "Enter second IPv4: " ip2

  if ! valid_ipv4 "$ip1" || ! valid_ipv4 "$ip2"; then
    echo "❌ One or both IPs are invalid. Please try again."
    pause
    return
  fi

  local rand sub full_name
  rand=$(random_subdomain)
  sub="srv-${rand}"
  full_name="${sub}.${BASE_HOST}"

  echo
  echo "Creating hostname: $full_name"
  echo "Using IPs: $ip1 and $ip2"
  echo

  echo "Creating first A record..."
  if ! create_a_record "$full_name" "$ip1"; then
    echo "Failed to create first A record. Aborting."
    pause
    return
  fi

  echo "Creating second A record..."
  if ! create_a_record "$full_name" "$ip2"; then
    echo "Failed to create second A record."
    echo "Note: the first A record was already created; you might want to delete it."
    pause
    return
  fi

  echo
  echo "======================================="
  echo "✅ Hostname created successfully:"
  echo "  $full_name"
  echo
  echo "You can now use it as a CNAME target in other domains, for example:"
  echo "  app.yourdomain.com    CNAME    $full_name"
  echo
  echo "All traffic to that CNAME will be resolved to:"
  echo "  $ip1"
  echo "  $ip2"
  echo "======================================="
  echo
  pause
}

delete_hostname_records() {
  require_config

  echo "=== Delete all DNS records for a hostname (in this zone) ==="
  echo "Base host: $BASE_HOST"
  read -rp "Enter hostname to delete (e.g. srv-xxxx.${BASE_HOST}): " host

  if [[ -z "$host" ]]; then
    echo "Hostname cannot be empty."
    pause
    return
  fi

  local url resp count
  url="${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records"
  echo "Looking up DNS records for: $host"
  resp=$(api_get "$url" --data-urlencode "name=$host")
  count=$(echo "$resp" | jq -r '.result | length')

  if [[ "$count" -eq 0 ]]; then
    echo "No DNS records found for $host in this zone."
    pause
    return
  fi

  echo "Found $count record(s):"
  echo "$resp" | jq -r '.result[] | "- ID: \(.id) | Type: \(.type) | Name: \(.name) | Content: \(.content)"'
  echo

  read -rp "Delete ALL of these records? [y/N]: " ans
  ans="${ans:-n}"
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    pause
    return
  fi

  local id
  while read -r id; do
    [[ -z "$id" || "$id" == "null" ]] && continue
    local del_url="${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${id}"
    local dresp dsuccess
    dresp=$(api_delete "$del_url")
    dsuccess=$(echo "$dresp" | jq -r '.success // false')
    if [[ "$dsuccess" == "true" ]]; then
      echo "Deleted record id: $id"
      echo "$(date +'%Y-%m-%d %H:%M:%S') DELETE $host $id" >> "$LOG_FILE"
    else
      echo "Failed to delete record id: $id"
      echo "$dresp" | jq -r '.errors[]? | "- \(.code): \(.message)"'
    fi
  done < <(echo "$resp" | jq -r '.result[]?.id')

  echo "Done."
  pause
}

show_log() {
  ensure_dir
  echo "=== Created/Deleted records log ==="
  if [[ ! -s "$LOG_FILE" ]]; then
    echo "Log is empty."
  else
    cat "$LOG_FILE"
  fi
  echo
  pause
}

uninstall_tool() {
  echo "=== Uninstall $TOOL_NAME ==="
  echo "This will remove:"
  echo "  - Config directory: $CONFIG_DIR"
  echo "  - Log file: $LOG_FILE"
  echo "It will NOT remove curl/jq or any DNS records on Cloudflare."
  echo
  read -rp "Are you sure you want to uninstall? [y/N]: " ans
  ans="${ans:-n}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    echo "Config and logs removed."
    echo "You can now delete this script file (install.sh) manually if you want."
    exit 0
  else
    echo "Uninstall cancelled."
    pause
  fi
}

main_menu() {
  while true; do
    clear
    echo "============================================"
    echo "  $TOOL_NAME - Cloudflare Multi-IP Hostname "
    echo "============================================"
    echo "Config:"
    echo "  BASE_HOST   : ${BASE_HOST:-<not set>}"
    echo "  CF_ZONE_ID  : ${CF_ZONE_ID:-<not set>}"
    echo "  CF_PROXY    : ${CF_PROXY:-<not set>}"
    echo "--------------------------------------------"
    echo "1) Configure / Change Cloudflare settings"
    echo "2) Create hostname with two IPv4 addresses"
    echo "3) Delete all DNS records for a hostname"
    echo "4) Show log of created/deleted records"
    echo "5) Uninstall this tool (remove config & logs)"
    echo "0) Exit"
    echo "--------------------------------------------"
    read -rp "Choose an option: " choice

    case "$choice" in
      1) configure_cloudflare ;;
      2) create_hostname_with_two_ips ;;
      3) delete_hostname_records ;;
      4) show_log ;;
      5) uninstall_tool ;;
      0) echo "Bye!"; exit 0 ;;
      *) echo "Invalid option."; pause ;;
    esac
  done
}

# ===================== Entry point =====================

ensure_dir
install_prereqs
load_config
main_menu
