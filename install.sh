#!/usr/bin/env bash

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

WARP_DIR="/opt/warp-go"
WG_CONF="/etc/wireguard/warp.conf"
WG_IF="wgwarp"

echo_info() { echo -e "${CYAN}[*]${NC} $1"; }
echo_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
echo_err()  { echo -e "${RED}[ERR]${NC} $1"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo_err "Please run as root."
    exit 1
  fi
}

install_dependencies() {
  apt update -y
  apt install -y curl wireguard wireguard-tools resolvconf
}

install_warp() {
  check_root

  echo_info "Installing warp-go (WARP engine)..."

  mkdir -p "$WARP_DIR"
  cd "$WARP_DIR"

  curl -sLO https://gitlab.com/ProjectWARP/warp-go/-/raw/main/warp-go
  chmod +x warp-go

  echo_info "Registering WARP identity..."
  ./warp-go --register >/tmp/warp-temp.json 2>/dev/null || true

  if [[ ! -f /tmp/warp-temp.json ]]; then
    echo_err "Registration failed."
    exit 1
  fi

  echo_info "Generating Warp WireGuard config..."

  ./warp-go --export-wireguard >/etc/wireguard/warp.conf
  chmod 600 /etc/wireguard/warp.conf

  echo_ok "WARP installed successfully."
}

enable_warp_ipv4() {
  check_root

  if [[ ! -f "$WG_CONF" ]]; then
    echo_err "WARP is not installed. Install first."
    exit 1
  fi

  echo_info "Enabling WARP IPv4 FULL Tunnel..."

  wg-quick down "$WG_IF" 2>/dev/null || true
  cp "$WG_CONF" "/etc/wireguard/${WG_IF}.conf"

  wg-quick up "$WG_IF"

  # Set default route over warp
  ip -4 route replace default dev "$WG_IF"

  echo_ok "WARP IPv4 FULL Tunnel is now active."

  echo_info "Checking outbound IPv4..."
  IP=$(curl -4 -s https://ipv4.icanhazip.com || true)

  if [[ -n "$IP" ]]; then
    echo_ok "Your WARP IPv4: $IP"
  else
    echo_err "Could not fetch IPv4 – check connection."
  fi
}

disable_warp() {
  check_root
  echo_info "Disabling WARP..."
  wg-quick down "$WG_IF" 2>/dev/null || true

  echo_info "Restoring default routing..."
  dhclient -4 -r 2>/dev/null || true
  dhclient -4 2>/dev/null || true

  echo_ok "WARP disabled."
}

show_status() {
  echo_info "Checking WARP interface..."

  if ip a | grep -q "$WG_IF"; then
    echo_ok "WARP interface is active: $WG_IF"
  else
    echo_err "WARP interface is NOT active."
  fi

  echo_info "Checking outbound IPv4..."
  IP=$(curl -4 -s https://ipv4.icanhazip.com || true)

  if [[ -n "$IP" ]]; then
    echo_ok "Outbound IPv4 = $IP"
  else
    echo_err "Cannot reach IPv4."
  fi
}

uninstall_warp() {
  check_root

  echo_info "Stopping WARP..."
  wg-quick down "$WG_IF" 2>/dev/null || true

  echo_info "Removing warp-go & configs..."
  rm -rf "$WARP_DIR"
  rm -rf /etc/wireguard/warp.conf
  rm -rf /etc/wireguard/${WG_IF}.conf

  echo_info "Restoring routing..."
  dhclient -4 -r 2>/dev/null || true
  dhclient -4 2>/dev/null || true

  echo_ok "WARP fully removed. System is restored."
}

menu() {
  clear
  echo "=============================================="
  echo "   Cloudflare WARP Manager (English Edition)"
  echo "=============================================="
  echo " 1) Install WARP (warp-go engine)"
  echo " 2) Enable WARP IPv4 FULL tunnel"
  echo " 3) Disable WARP"
  echo " 4) Show WARP status"
  echo " 5) Uninstall WARP completely"
  echo " 0) Exit"
  echo
}

check_root

while true; do
  menu
  read -rp "Choose an option: " c

  case "$c" in
    1) install_dependencies; install_warp ;;
    2) enable_warp_ipv4 ;;
    3) disable_warp ;;
    4) show_status ;;
    5) uninstall_warp ;;
    0) exit 0 ;;
    *) echo_err "Invalid option." ;;
  esac

  read -rp "Press ENTER to continue..."
done
