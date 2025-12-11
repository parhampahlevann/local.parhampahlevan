#!/usr/bin/env bash
# Cloudflare multi-IP CNAME creator with two A records
# Creates: 
#   srv-xxxx-1.base.tld -> IP1
#   srv-xxxx-2.base.tld -> IP2  
#   srv-xxxx.base.tld (CNAME) -> srv-xxxx-1.base.tld & srv-xxxx-2.base.tld

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
  curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
       -H "Content-Type: application/json" \
       -G "$url" \
       "$@" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"curl failed"}]}'
}

api_post() {
  local url="$1"
  local data="$2"
  
  curl -sS -X POST "$url" \
       -H "Authorization: Bearer $CF_API_TOKEN" \
       -H "Content-Type: application/json" \
       --data "$data" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"curl failed"}]}'
}

api_delete() {
  local url="$1"
  
  curl -sS -X DELETE "$url" \
       -H "Authorization: Bearer $CF_API_TOKEN" \
       -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false,"errors":[{"code":0,"message":"curl failed"}]}'
}

test_config() {
  echo "==> Testing Cloudflare Zone ID and API token..."
  local url resp success zone_name
  url="${CF_API_BASE}/zones/${CF_ZONE_ID}"
  resp=$(api_get "$url")

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
    echo "   Records will only work correctly if BASE_HOST is the zone or its subdomain."
    echo "   Example for this zone: $zone_name or nodes.$zone_name"
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
  echo "You need a Cloudflare API token with:"
  echo "  - Zone.DNS (Edit) permissions"
  echo
  read -rp "Enter Cloudflare API Token: " CF_API_TOKEN
  read -rp "Enter Cloudflare Zone ID: " CF_ZONE_ID
  read -rp "Enter base hostname (e.g. example.com or nodes.example.com): " BASE_HOST

  CF_PROXY="false"   # always DNS only
  echo "Cloudflare proxy will be disabled (DNS only)."
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

cleanup_on_error() {
  echo
  echo "⚠️  Cleaning up due to error..."
  
  if [[ -n "${created_records[@]}" ]]; then
    for rec_id in "${created_records[@]}"; do
      if [[ -n "$rec_id" ]]; then
        echo "  Deleting record: $rec_id"
        api_delete "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${rec_id}" >/dev/null
      fi
    done
  fi
  
  echo "Cleanup completed."
}

create_dns_record() {
  local name="$1"
  local type="$2"
  local content="$3"
  
  local data
  data=$(cat <<EOF
{
  "type": "$type",
  "name": "$name",
  "content": "$content",
  "ttl": 1,
  "proxied": $CF_PROXY
}
EOF
)

  local url="${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records"
  local resp
  resp=$(api_post "$url" "$data")

  local success
  success=$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo "false")

  if [[ "$success" != "true" ]]; then
    echo "❌ Cloudflare error while creating $type record for $name:"
    echo "$resp" | jq -r '.errors[]? | "- \(.code): \(.message)"' 2>/dev/null || echo "$resp"
    return 1
  fi

  local rec_id
  rec_id=$(echo "$resp" | jq -r '.result.id // empty')
  echo "✅ Created $type record: $name -> $content (ID: $rec_id)"
  
  # Log the creation
  echo "$(date +'%Y-%m-%d %H:%M:%S') CREATE $name $type $content $rec_id" >> "$LOG_FILE"
  
  # Return the record ID
  echo "$rec_id"
  return 0
}

main_flow() {
  echo "=== Cloudflare Multi-IP CNAME Creator ==="
  echo "This script will create:"
  echo "  1. Two A records with different subdomains"
  echo "  2. One CNAME record pointing to both A records"
  echo "  3. Final CNAME target for your use"
  echo

  # Set up error handling
  local -a created_records=()
  trap cleanup_on_error EXIT

  # Load or create config
  ensure_dir
  load_config
  configure_if_needed

  # Install prerequisites
  install_prereqs

  echo "==> Getting two IPv4 addresses"
  local ip1 ip2
  while true; do
    read -rp "Enter first IPv4 address: " ip1
    if valid_ipv4 "$ip1"; then
      break
    fi
    echo "❌ Invalid IPv4 address. Please try again."
  done

  while true; do
    read -rp "Enter second IPv4 address: " ip2
    if valid_ipv4 "$ip2"; then
      if [[ "$ip1" == "$ip2" ]]; then
        echo "⚠️  Both IPs are the same. Continue anyway? (y/n) "
        read -r answer
        [[ "$answer" =~ ^[Yy]$ ]] && break
      else
        break
      fi
    else
      echo "❌ Invalid IPv4 address. Please try again."
    fi
  done

  # Generate unique subdomain
  local rand sub1 sub2 main_sub full_main
  rand=$(random_subdomain)
  main_sub="srv-${rand}"
  sub1="${main_sub}-1"
  sub2="${main-sub}-2"
  full_main="${main_sub}.${BASE_HOST}"
  
  echo
  echo "==> Creating DNS records..."
  echo "    Main CNAME : $full_main"
  echo "    A record 1 : $sub1.$BASE_HOST -> $ip1"
  echo "    A record 2 : $sub2.$BASE_HOST -> $ip2"
  echo

  # Create first A record
  echo "1. Creating first A record..."
  local rec1_id
  rec1_id=$(create_dns_record "$sub1.$BASE_HOST" "A" "$ip1")
  if [[ $? -ne 0 ]] || [[ -z "$rec1_id" ]]; then
    echo "❌ Failed to create first A record"
    exit 1
  fi
  created_records+=("$rec1_id")

  # Create second A record
  echo "2. Creating second A record..."
  local rec2_id
  rec2_id=$(create_dns_record "$sub2.$BASE_HOST" "A" "$ip2")
  if [[ $? -ne 0 ]] || [[ -z "$rec2_id" ]]; then
    echo "❌ Failed to create second A record"
    exit 1
  fi
  created_records+=("$rec2_id")

  # IMPORTANT: In DNS, CNAME can only point to ONE target
  # For load balancing between two IPs, we have two options:
  # Option 1: Create CNAME pointing to first A record (simple)
  # Option 2: Create two CNAME records (not standard)
  
  echo "3. Creating main CNAME record (pointing to first A record)..."
  local cname_id
  cname_id=$(create_dns_record "$full_main" "CNAME" "$sub1.$BASE_HOST")
  if [[ $? -ne 0 ]] || [[ -z "$cname_id" ]]; then
    echo "❌ Failed to create CNAME record"
    exit 1
  fi
  created_records+=("$cname_id")

  # Remove cleanup trap since everything succeeded
  trap - EXIT

  echo
  echo "==============================================="
  echo "✅ SUCCESS! All records created."
  echo
  echo "Your DNS configuration:"
  echo
  echo "   $sub1.$BASE_HOST    A      $ip1"
  echo "   $sub2.$BASE_HOST    A      $ip2"
  echo "   $full_main    CNAME    $sub1.$BASE_HOST"
  echo
  echo "⚠️  IMPORTANT NOTE:"
  echo "   The CNAME points only to the first A record ($sub1.$BASE_HOST)."
  echo "   For true load balancing between both IPs, you need to:"
  echo "   1. Use DNS Round Robin manually with both A records, OR"
  echo "   2. Use Cloudflare Load Balancing service, OR"
  echo "   3. Configure your application to use both endpoints"
  echo
  echo "For DNS Round Robin, you can create TWO CNAME records elsewhere:"
  echo "   your-alias1.example.com    CNAME    $sub1.$BASE_HOST"
  echo "   your-alias2.example.com    CNAME    $sub2.$BASE_HOST"
  echo
  echo "==============================================="
  echo

  # Save the main CNAME
  echo "$full_main" > "$LAST_CNAME_FILE"
  echo "Main CNAME target saved to: $LAST_CNAME_FILE"
  
  # Also save all created records
  cat > "${CONFIG_DIR}/last_creation_$(date +%Y%m%d_%H%M%S).txt" <<EOF
Created: $(date)
Main CNAME: $full_main
A Records:
  $sub1.$BASE_HOST -> $ip1
  $sub2.$BASE_HOST -> $ip2
EOF

  echo
  read -rp "Press Enter to exit..." _
}

# ===================== Entry point =====================
main_flow
