#!/usr/bin/env bash
# Simple Cloudflare WARP Menu (Parham Edition)
# Works on Ubuntu 24 (noble mapped to jammy)
# Modes:
#  - Proxy mode: SOCKS5 127.0.0.1:10808
#  - Full system mode: all server traffic via WARP (warp)

# ================= Auto-install on first run =================
SCRIPT_PATH="/usr/local/bin/warp-menu"

if [[ "$0" != "$SCRIPT_PATH" ]]; then
  if [[ -f "$0" ]]; then
    echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "[✓] Installed! Next time just run: sudo warp-menu"
  else
    echo "[*] Running from non-regular file (pipe/FIFO), skipping auto-install."
  fi
fi

# ================= Colors & Version =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="3.0-parham-ubuntu24-warp-full"

# ================= Root check =================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Please run this script as root (sudo).${NC}"
  exit 1
fi

# ================= Paths & Files =================
CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
CURRENT_ENDPOINT_FILE="${CONFIG_DIR}/current_endpoint"

mkdir -p "$CONFIG_DIR"
touch "$ENDPOINTS_FILE" 2>/dev/null || true

# ================= Core Checks =================
warp_is_installed() {
  command -v warp-cli &>/dev/null
}

warp_is_connected() {
  warp-cli status 2>/dev/null | grep -iq "Connected"
}

# ================= Helper: preload endpoints (Germany first) =================
warp_preload_endpoints() {
  if [[ ! -s "$ENDPOINTS_FILE" ]]; then
    cat << EOF > "$ENDPOINTS_FILE"
Germany-1|188.114.98.10:2408
Germany-2|188.114.99.10:2408
Netherlands-1|162.159.192.10:2408
Netherlands-2|162.159.193.10:2408
Romania-1|188.114.96.10:2408
Romania-2|188.114.97.10:2408
France-1|162.159.195.10:2408
UK-1|162.159.204.10:2408
USA-1|162.159.208.10:2408
USA-2|162.159.209.10:2408
EOF
  fi
}

# ================= Helpers: IP detection =================
warp_get_out_ip4() {
  local proxy_ip="127.0.0.1"
  local proxy_port="10808"
  local ip=""
  local timeout_sec=6

  local services=(
    "https://ipv4.icanhazip.com"
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
    "https://ifconfig.me/ip"
    "https://ipecho.net/plain"
  )

  for s in "${services[@]}"; do
    ip=$(timeout "$timeout_sec" curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" "$s" 2>/dev/null | tr -d ' \r\n')
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  echo ""
  return 1
}

warp_get_out_ip6() {
  local proxy_ip="127.0.0.1"
  local proxy_port="10808"
  local ip=""
  local timeout_sec=8

  local services=(
    "https://ipv6.icanhazip.com"
    "https://api64.ipify.org"
    "https://ifconfig.co/ip"
  )

  for s in "${services[@]}"; do
    ip=$(timeout "$timeout_sec" curl -6 -s --socks5 "${proxy_ip}:${proxy_port}" "$s" 2>/dev/null | tr -d ' \r\n')
    if [[ -n "$ip" && "$ip" =~ : ]]; then
      echo "$ip"
      return 0
    fi
  done

  echo ""
  return 1
}

# ================= Helpers: Endpoint =================
warp_set_custom_endpoint() {
  local endpoint="$1"
  if [[ -z "$endpoint" ]]; then
    echo -e "${RED}Endpoint is empty.${NC}"
    return 1
  fi

  echo -e "${CYAN}Setting custom endpoint to ${YELLOW}${endpoint}${NC}"
  warp-cli clear-custom-endpoint 2>/dev/null || true
  sleep 1
  warp-cli set-custom-endpoint "$endpoint" 2>/dev/null || warp-cli custom-endpoint "$endpoint" 2>/dev/null || true
  sleep 1
}

# ================= Core: install =================
warp_install() {
  if warp_is_installed && warp_is_connected; then
    echo -e "${GREEN}WARP already installed and connected.${NC}"
    read -r -p "Reinstall? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && return
  fi

  echo -e "${CYAN}Installing Cloudflare WARP...${NC}"
  local codename
  codename=$(lsb_release -cs 2>/dev/null || echo "")

  # Map Ubuntu 24 (noble) and future to jammy
  if [[ -z "$codename" ]]; then
    codename="jammy"
  elif [[ "$codename" == "oracular" || "$codename" == "plucky" || "$codename" == "noble" ]]; then
    codename="jammy"
  fi

  apt update
  apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo jq bc iputils-ping

  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  apt update
  apt install -y cloudflare-warp

  warp_connect_initial
}

# ================= Core: initial connect (proxy mode + Germany) =================
warp_connect_initial() {
  echo -e "${BLUE}Initial WARP setup...${NC}"

  yes | warp-cli registration new 2>/dev/null || \
  warp-cli registration new 2>/dev/null || \
  warp-cli register 2>/dev/null

  warp-cli set-mode proxy 2>/dev/null || warp-cli mode proxy
  warp-cli set-proxy-port 10808 2>/dev/null || warp-cli proxy port 10808

  # default endpoint: Germany
  warp_set_custom_endpoint "188.114.98.10:2408"
  echo "Germany-1|188.114.98.10:2408" > "$CURRENT_ENDPOINT_FILE"

  warp-cli connect
  sleep 3

  if warp_is_connected; then
    echo -e "${GREEN}WARP connected (Germany endpoint, proxy mode).${NC}"
  else
    echo -e "${YELLOW}Germany endpoint failed. Trying auto endpoint...${NC}"
    warp-cli clear-custom-endpoint 2>/dev/null || true
    warp-cli connect
    sleep 3
  fi

  warp_status
}

# ================= Core: connect / disconnect / status =================
warp_connect() {
  echo -e "${BLUE}Connecting WARP...${NC}"

  if ! warp_is_installed; then
    echo -e "${RED}cloudflare-warp not installed. Use option 1 first.${NC}"
    return 1
  fi

  if ! warp-cli registration show >/dev/null 2>&1; then
    yes | warp-cli registration new 2>/dev/null || \
    warp-cli registration new 2>/dev/null || \
    warp-cli register 2>/dev/null
  fi

  warp-cli connect
  sleep 3

  if warp_is_connected; then
    echo -e "${GREEN}Connected.${NC}"
  else
    echo -e "${RED}Failed to connect.${NC}"
  fi
}

warp_disconnect() {
  echo -e "${YELLOW}Disconnecting WARP...${NC}"
  warp-cli disconnect 2>/dev/null || true
  sleep 1
}

warp_status() {
  echo -e "${CYAN}=== WARP Status (warp-cli) ===${NC}"
  if warp_is_installed; then
    warp-cli status 2>/dev/null || echo -e "${RED}warp-cli status error${NC}"
  else
    echo -e "${RED}warp-cli not installed.${NC}"
  fi
  echo

  if warp_is_connected; then
    echo -e "${CYAN}=== Proxy and IP Info (if in proxy mode) ===${NC}"
    local ip4 ip6
    ip4=$(warp_get_out_ip4)
    ip6=$(warp_get_out_ip6)

    if [[ -n "$ip4" ]]; then
      echo -e "  IPv4 via WARP SOCKS5 (127.0.0.1:10808): ${GREEN}$ip4${NC}"
    else
      echo -e "  ${YELLOW}IPv4 via SOCKS5: N/A (maybe in full system mode)${NC}"
    fi

    if [[ -n "$ip6" ]]; then
      echo -e "  IPv6 via WARP/Cloudflare: ${GREEN}$ip6${NC}"
    else
      echo -e "  ${YELLOW}IPv6 via WARP: Not detected or blocked${NC}"
    fi
  else
    echo -e "${YELLOW}WARP is not connected.${NC}"
  fi
}

warp_test_proxy() {
  echo -e "${CYAN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}"

  if ! warp_is_connected; then
    echo -e "${RED}WARP is not connected.${NC}"
    return 1
  fi

  local ip4 ip6
  ip4=$(warp_get_out_ip4)
  ip6=$(warp_get_out_ip6)

  if [[ -n "$ip4" ]]; then
    echo -e "[OK] IPv4 via WARP: ${GREEN}$ip4${NC}"
  else
    echo -e "[FAIL] ${RED}Could not get IPv4 via proxy.${NC}"
  fi

  if [[ -n "$ip6" ]]; then
    echo -e "[OK] IPv6 via WARP: ${GREEN}$ip6${NC}"
  else
    echo -e "[INFO] IPv6 via WARP not detected (may be normal)."
  fi
}

warp_remove() {
  echo -e "${RED}Removing WARP...${NC}"
  warp-cli disconnect 2>/dev/null || true
  sleep 1
  apt remove --purge -y cloudflare-warp 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
  apt autoremove -y 2>/dev/null || true
  echo -e "${GREEN}WARP removed.${NC}"
}

# ================= IP Change =================
warp_quick_change_ip() {
  if ! warp_is_connected; then
    echo -e "${RED}WARP is not connected.${NC}"
    return 1
  fi

  echo -e "${CYAN}Quick IP change (disconnect/connect)...${NC}"
  local old_ip new_ip
  old_ip=$(warp_get_out_ip4)
  echo -e "Old IPv4: ${YELLOW}${old_ip:-N/A}${NC}"

  for i in {1..3}; do
    echo "Attempt $i/3..."
    warp_disconnect
    warp_connect
    sleep 2
    new_ip=$(warp_get_out_ip4)
    if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
      echo -e "New IPv4: ${GREEN}$new_ip${NC}"
      return 0
    fi
  done

  echo -e "${YELLOW}IP did not change. Try New Identity.${NC}"
}

warp_new_identity() {
  if ! warp_is_installed; then
    echo -e "${RED}WARP not installed.${NC}"
    return 1
  fi

  echo -e "${CYAN}New identity (re-registration)...${NC}"
  local old_ip new_ip
  old_ip=$(warp_get_out_ip4)
  echo -e "Old IPv4: ${YELLOW}${old_ip:-N/A}${NC}"

  warp_disconnect

  warp-cli registration delete 2>/dev/null || \
  warp-cli deregister 2>/dev/null || \
  warp-cli registration revoke 2>/dev/null || true

  sleep 1

  yes | warp-cli registration new 2>/dev/null || \
  warp-cli registration new 2>/dev/null || \
  warp-cli register 2>/dev/null

  warp-cli connect
  sleep 3

  new_ip=$(warp_get_out_ip4)
  if [[ -n "$new_ip" ]]; then
    if [[ "$new_ip" != "$old_ip" ]]; then
      echo -e "New IPv4: ${GREEN}$new_ip${NC}"
    else
      echo -e "${YELLOW}New identity but same IP; try again later.${NC}"
    fi
  else
    echo -e "${RED}Failed to get new IP.${NC}"
  fi
}

# ================= Multi-location =================
warp_list_endpoints() {
  if [[ ! -s "$ENDPOINTS_FILE" ]]; then
    echo -e "${YELLOW}No endpoints saved.${NC}"
    return 1
  fi

  echo -e "${CYAN}Saved endpoints:${NC}"
  echo "----------------------------------------"
  local i=1
  while IFS='|' read -r name addr; do
    [[ -z "$name" ]] && continue
    printf " %2d) %-15s %s\n" "$i" "$name" "$addr"
    i=$((i+1))
  done < "$ENDPOINTS_FILE"
}

warp_apply_endpoint() {
  if [[ ! -s "$ENDPOINTS_FILE" ]]; then
    echo -e "${YELLOW}No endpoints saved.${NC}"
    return 1
  fi

  warp_list_endpoints
  echo
  read -r -p "Select endpoint number (0 to cancel): " idx
  [[ -z "$idx" ]] && return

  if [[ "$idx" -eq 0 ]]; then
    echo "Cancelled."
    return
  fi

  local line
  line=$(sed -n "${idx}p" "$ENDPOINTS_FILE" 2>/dev/null || true)
  if [[ -z "$line" ]]; then
    echo -e "${RED}Invalid selection.${NC}"
    return 1
  fi

  local name addr
  name="${line%%|*}"
  addr="${line#*|}"

  echo -e "${CYAN}Applying endpoint: ${YELLOW}${name}${NC} -> ${GREEN}${addr}${NC}"
  warp_disconnect
  warp_set_custom_endpoint "$addr"
  echo "${name}|${addr}" > "$CURRENT_ENDPOINT_FILE"
  warp_connect
  warp_status
}

warp_multiloc_menu() {
  while true; do
    clear
    echo "================ Multi-location Manager ================"
    warp_list_endpoints
    echo
    echo " 1) Apply endpoint from list"
    echo " 0) Back to main menu"
    echo "======================================================="
    echo -ne "${YELLOW}Select option: ${NC}"
    read -r ch

    case "$ch" in
      1) warp_apply_endpoint ;;
      0) break ;;
      *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac

    echo
    echo "Press Enter to continue..."
    read -r
  done
}

# ================= New: FULL system WARP / Proxy mode =================
warp_enable_system_warp() {
  echo -e "${CYAN}Switching WARP to FULL system mode (warp)...${NC}"

  if ! warp_is_installed; then
    echo -e "${RED}WARP is not installed. Use Install first.${NC}"
    return 1
  fi

  warp_disconnect
  sleep 1

  warp-cli set-mode warp 2>/dev/null || warp-cli mode warp 2>/dev/null || true

  warp-cli connect
  sleep 3

  if warp_is_connected; then
    echo -e "${GREEN}WARP is now in FULL system mode.${NC}"
    echo "All server traffic (including x-ui / v2ray) goes through WARP."
  else
    echo -e "${RED}Failed to enable FULL system mode.${NC}"
  fi
}

warp_enable_proxy_mode() {
  echo -e "${CYAN}Switching WARP to PROXY mode (SOCKS5 127.0.0.1:10808)...${NC}"

  if ! warp_is_installed; then
    echo -e "${RED}WARP is not installed. Use Install first.${NC}"
    return 1
  fi

  warp_disconnect
  sleep 1

  warp-cli set-mode proxy 2>/dev/null || warp-cli mode proxy 2>/dev/null || true
  warp-cli set-proxy-port 10808 2>/dev/null || warp-cli proxy port 10808 2>/dev/null || true

  warp-cli connect
  sleep 3

  if warp_is_connected; then
    echo -e "${GREEN}WARP is now in PROXY mode (SOCKS5 127.0.0.1:10808).${NC}"
  else
    echo -e "${RED}Failed to enable PROXY mode.${NC}"
  fi
}

warp_show_mode() {
  echo -e "${CYAN}Current WARP settings:${NC}"
  warp-cli settings 2>/dev/null || echo -e "${RED}warp-cli settings failed${NC}"
}

# ================= Menu =================
warp_draw_menu() {
  clear
  local status="NOT INSTALLED"
  local status_color="$RED"
  local ip4="N/A"

  if warp_is_installed; then
    if warp_is_connected; then
      status="CONNECTED"
      status_color="$GREEN"
      ip4=$(warp_get_out_ip4 || echo "N/A")
    else
      status="DISCONNECTED"
      status_color="$YELLOW"
    fi
  fi

  echo "======================================================="
  echo "               WARP Manager v${VERSION}"
  echo "======================================================="
  echo -e " Status : ${status_color}${status}${NC}"
  echo -e " SOCKS5 : 127.0.0.1:10808 (proxy mode)"
  echo -e " IPv4   : ${YELLOW}${ip4}${NC}"
  echo "-------------------------------------------------------"
  echo " 1) Install WARP"
  echo " 2) Status & Info"
  echo " 3) Test Proxy (IPv4/IPv6)"
  echo " 4) Remove WARP"
  echo " 5) Quick IP Change"
  echo " 6) New Identity (re-register)"
  echo " 7) Multi-location (Germany/NL/...)"
  echo " 8) Enable FULL system WARP (all server traffic via WARP)"
  echo " 9) Enable PROXY mode (SOCKS5 127.0.0.1:10808)"
  echo "10) Show WARP settings/mode"
  echo " 0) Exit"
  echo "-------------------------------------------------------"
  echo -ne "${YELLOW}Select option: ${NC}"
}

warp_main_menu() {
  warp_preload_endpoints

  while true; do
    warp_draw_menu
    read -r choice
    case "$choice" in
      1) warp_install ;;
      2) warp_status ;;
      3) warp_test_proxy ;;
      4) warp_remove ;;
      5) warp_quick_change_ip ;;
      6) warp_new_identity ;;
      7) warp_multiloc_menu ;;
      8) warp_enable_system_warp ;;
      9) warp_enable_proxy_mode ;;
      10) warp_show_mode ;;
      0) echo -e "${GREEN}Bye.${NC}"; exit 0 ;;
      *) echo -e "${RED}Invalid choice.${NC}" ;;
    esac

    echo
    echo "Press Enter to return to menu..."
    read -r
  done
}

# ================= Start =================
warp_main_menu
