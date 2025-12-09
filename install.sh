#!/usr/bin/env bash
# Cloudflare WARP Manager (Parham + CFwarp integration)
# Ubuntu 24.x friendly

set -e

### === Root check & auto-sudo ===
if [[ $EUID -ne 0 ]]; then
  echo "[*] This script must run as root. Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

### === Auto-install path ===
SCRIPT_PATH="/usr/local/bin/warp-menu"
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

if [[ "$CURRENT_PATH" != "$SCRIPT_PATH" && -f "$CURRENT_PATH" ]]; then
  echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
  cp "$CURRENT_PATH" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "[OK] warp-menu installed. Next time you can just run: warp-menu"
fi

### === Colors & version ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
VERSION="4.0-parham-cfwarp"

### === Helper print functions ===
msg_info()  { echo -e "${CYAN}[*]${NC} $1"; }
msg_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_err()   { echo -e "${RED}[ERR]${NC} $1"; }

### === Check command existence ===
have_cmd() { command -v "$1" &>/dev/null; }

### === WARP-CLI (Cloudflare official) section ===

warpcli_is_installed() {
  have_cmd warp-cli
}

warpcli_status_connected() {
  warp-cli status 2>/dev/null | grep -iq "Connected"
}

warpcli_ensure_repo() {
  if [[ ! -f /etc/apt/sources.list.d/cloudflare-client.list ]]; then
    msg_info "Adding Cloudflare WARP APT repository..."
    apt update
    apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo

    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    case "$codename" in
      oracular|plucky|noble) codename="jammy" ;;
    esac

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
      > /etc/apt/sources.list.d/cloudflare-client.list
  fi
}

warpcli_install() {
  if warpcli_is_installed; then
    msg_warn "warp-cli is already installed."
    read -rp "Reinstall anyway? [y/N]: " r
    [[ ! "$r" =~ ^[Yy]$ ]] && return
  fi

  msg_info "Installing warp-cli..."
  warpcli_ensure_repo
  apt update
  apt install -y cloudflare-warp

  msg_info "Initial registration and setup..."
  warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register

  warpcli_set_proxy_mode
  warpcli_connect

  msg_ok "warp-cli installation finished."
  warpcli_show_status
}

warpcli_set_proxy_mode() {
  msg_info "Setting warp-cli to proxy mode (SOCKS5 127.0.0.1:10808)..."
  warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli --accept-tos mode proxy
  warp-cli --accept-tos set-proxy-port 10808 2>/dev/null || warp-cli --accept-tos proxy port 10808
  sleep 2
}

warpcli_connect() {
  msg_info "Connecting warp-cli..."
  warp-cli --accept-tos connect || true
  sleep 3
  local n=0
  while [[ $n -lt 10 ]]; do
    if warpcli_status_connected; then
      msg_ok "WARP (warp-cli) is connected."
      return 0
    fi
    sleep 1
    n=$((n+1))
  done
  msg_err "Failed to connect warp-cli."
  return 1
}

warpcli_disconnect() {
  msg_info "Disconnecting warp-cli..."
  warp-cli --accept-tos disconnect 2>/dev/null || true
  sleep 2
}

warpcli_remove() {
  msg_warn "Removing warp-cli and Cloudflare WARP package..."
  warpcli_disconnect || true
  if [[ -f /etc/apt/sources.list.d/cloudflare-client.list ]]; then
    apt remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt autoremove -y || true
  fi
  msg_ok "warp-cli removed."
}

warpcli_test_proxy() {
  if ! warpcli_is_installed; then
    msg_err "warp-cli is not installed."
    return 1
  fi
  if ! warpcli_status_connected; then
    msg_warn "warp-cli is not connected; trying to connect..."
    warpcli_connect || return 1
  fi

  msg_info "Testing SOCKS5 proxy (127.0.0.1:10808)..."
  local url ip
  url="https://ipv4.icanhazip.com"
  ip=$(timeout 10 curl -4 -s --socks5 127.0.0.1:10808 "$url" 2>/dev/null | tr -d ' \r\n')
  if [[ -n "$ip" ]]; then
    msg_ok "Proxy works. Outbound IP: ${ip}"
  else
    msg_err "Failed to get IP via SOCKS5 proxy."
  fi
}

warpcli_show_status() {
  echo -e "${CYAN}===== warp-cli status =====${NC}"
  if warpcli_is_installed; then
    warp-cli status 2>/dev/null || msg_err "warp-cli status failed."
  else
    msg_warn "warp-cli is not installed."
    return
  fi

  if warpcli_status_connected; then
    local ip
    ip=$(timeout 10 curl -4 -s --socks5 127.0.0.1:10808 https://ipv4.icanhazip.com 2>/dev/null | tr -d ' \r\n')
    if [[ -n "$ip" ]]; then
      echo -e "${GREEN}Proxy outbound IP:${NC} ${YELLOW}${ip}${NC}"
    fi
  fi
  echo
}

### === CFwarp integration (yonggekkk script) ===
# This integrates the known-stable Chinese CFwarp script.
# It installs a 'cf' command that manages system-level WARP (IPv4 / IPv6 / dual stack).

cfwarp_is_installed() {
  have_cmd cf
}

cfwarp_install() {
  if cfwarp_is_installed; then
    msg_ok "CFwarp (command 'cf') is already installed."
    return 0
  fi

  msg_info "Installing CFwarp (yonggekkk warp-yg script)..."
  curl -sSL -o /usr/bin/cf -L https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh
  chmod +x /usr/bin/cf

  if cfwarp_is_installed; then
    msg_ok "CFwarp installed. You can run its menu with: cf"
  else
    msg_err "Failed to install CFwarp."
    return 1
  fi
}

cfwarp_menu() {
  cfwarp_install || return 1

  cat <<EOF

============================================================
  CFwarp system-level WARP manager (command: cf)
============================================================

- This is the script you said works perfectly:
  * Gives a stable Cloudflare IP on IPv4
  * Routes all traffic correctly without drops.

- After opening the 'cf' menu you can:
  * Choose WARP mode: IPv4 only, IPv6 only or dual stack
  * Tune MTU / endpoints and other options

Important:
- When you enable system-level WARP IPv4 via CFwarp,
  all server traffic (including x-ui / Xray "direct" outbound)
  will automatically exit through the WARP IP.

Now entering CFwarp menu...

EOF

  read -rp "Press Enter to open CFwarp menu... " _
  cf
}

### === Main menu ===

draw_menu() {
  clear
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${BOLD}         Cloudflare WARP Manager - Parham Edition${NC}"
  echo -e "                       Version: ${PURPLE}${VERSION}${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo
  echo -e "${BOLD}Options:${NC}"
  echo "  1) Install / setup WARP with warp-cli (SOCKS5 proxy mode)"
  echo "  2) Show warp-cli status and test SOCKS5 proxy"
  echo "  3) Reconnect warp-cli"
  echo "  4) Disconnect and remove warp-cli"
  echo
  echo "  5) Manage system-level WARP using CFwarp (command: cf)"
  echo
  echo "  0) Exit"
  echo
}

main_loop() {
  while true; do
    draw_menu
    read -rp "Select an option: " ans
    case "$ans" in
      1) warpcli_install ;;
      2) warpcli_show_status; warpcli_test_proxy ;;
      3) warpcli_connect ;;
      4) warpcli_remove ;;
      5) cfwarp_menu ;;
      0) echo -e "${GREEN}Exit.${NC}"; exit 0 ;;
      *) msg_err "Invalid option."; sleep 1 ;;
    esac
    echo
    read -rp "Press Enter to continue... " _
  done
}

### === Entry point ===

main_loop
```0
