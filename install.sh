#!/usr/bin/env bash
# Cloudflare WARP IPv4 Manager (Ubuntu 20/22/24)
# Uses wgcf + wireguard, with full uninstall option

set -e

# ===== Colors & helpers =====
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo_info() { echo -e "${CYAN}[*]${NC} $1"; }
echo_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_err()  { echo -e "${RED}[ERR]${NC} $1"; }

have_cmd() { command -v "$1" &>/dev/null; }

if [[ $EUID -ne 0 ]]; then
  echo_err "Please run this script as root (use sudo)."
  exit 1
fi

WGCF_BIN="/usr/local/bin/wgcf"
WG_DIR="/etc/wireguard"
WGCF_ACCOUNT="${WG_DIR}/wgcf-account.toml"
WGCF_CONF="${WG_DIR}/wgcf.conf"
WG_IF="wgcf"
SERVICE_NAME="wg-quick@${WG_IF}"

# ===== Install dependencies =====
install_deps() {
  echo_info "Updating APT and installing dependencies (wireguard, curl, wget, resolvconf)..."
  apt update -y
  apt install -y wireguard wireguard-tools resolvconf curl wget
  echo_ok "Dependencies installed."
}

# ===== Install wgcf (official WARP CLI for WireGuard) =====
install_wgcf() {
  if [[ -x "$WGCF_BIN" ]]; then
    echo_ok "wgcf already installed at $WGCF_BIN"
    return
  fi

  install_deps

  local arch wgcf_arch url
  arch=$(uname -m)
  case "$arch" in
    x86_64) wgcf_arch="amd64" ;;
    aarch64|arm64) wgcf_arch="arm64" ;;
    *)
      echo_err "Unsupported architecture: $arch"
      exit 1
      ;;
  esac

  echo_info "Downloading wgcf (${wgcf_arch}) from GitHub..."
  url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${wgcf_arch}"
  wget -O "$WGCF_BIN" "$url"
  chmod +x "$WGCF_BIN"

  if [[ -x "$WGCF_BIN" ]]; then
    echo_ok "wgcf installed: $WGCF_BIN"
  else
    echo_err "Failed to install wgcf."
    exit 1
  fi
}

# ===== Generate wgcf config for IPv4 FULL tunnel =====
generate_wgcf_config() {
  install_wgcf
  mkdir -p "$WG_DIR"

  if [[ ! -f "$WGCF_ACCOUNT" ]]; then
    echo_info "Registering new WARP account with wgcf..."
    yes | "$WGCF_BIN" register
    mv wgcf-account.toml "$WGCF_ACCOUNT"
    echo_ok "Account file saved to $WGCF_ACCOUNT"
  else
    echo_info "Using existing WARP account: $WGCF_ACCOUNT"
  fi

  echo_info "Generating wgcf WARP profile..."
  rm -f wgcf-profile.conf || true
  "$WGCF_BIN" generate
  local profile="wgcf-profile.conf"
  if [[ ! -f "$profile" ]]; then
    echo_err "wgcf-profile.conf not generated."
    exit 1
  fi

  mv "$profile" "$WGCF_CONF"

  # IPv4 only: remove IPv6 route and IPv6 addresses
  sed -i '/::\/0/d' "$WGCF_CONF"
  sed -i '/Address = .*:/d' "$WGCF_CONF"

  # MTU tuning
  if grep -q "^MTU" "$WGCF_CONF"; then
    sed -i 's/^MTU.*/MTU = 1280/' "$WGCF_CONF"
  else
    sed -i '/^\[Interface\]/a MTU = 1280' "$WGCF_CONF"
  fi

  echo_ok "WARP wgcf config created at $WGCF_CONF (IPv4 only)."
}

# ===== Enable WARP IPv4 FULL tunnel =====
enable_warp_ipv4() {
  generate_wgcf_config

  echo_info "Preparing WireGuard config for interface ${WG_IF}..."
  cp "$WGCF_CONF" "${WG_DIR}/${WG_IF}.conf"

  echo_info "Enabling and starting ${SERVICE_NAME}..."
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" || systemctl start "$SERVICE_NAME"

  sleep 3

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo_ok "WARP service ${SERVICE_NAME} is active."
  else
    echo_err "WARP service failed to start. Check: systemctl status ${SERVICE_NAME}"
    return 1
  fi

  show_status
}

# ===== Show WARP status =====
show_status() {
  echo "--------------------------------------------------"
  echo " WARP Status"
  echo "--------------------------------------------------"

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e " Service: ${GREEN}active${NC} (${SERVICE_NAME})"
  else
    echo -e " Service: ${YELLOW}inactive${NC} (${SERVICE_NAME})"
  fi

  echo
  echo_info "Cloudflare trace (IPv4):"
  local trace
  trace=$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace || true)
  if [[ -n "$trace" ]]; then
    echo "$trace" | grep -E 'warp=|ip=' || echo "$trace"
  else
    echo "  Unable to reach Cloudflare trace."
  fi

  echo
  echo_info "Outbound IPv4 (should be WARP IP when active):"
  curl -4 -s https://ipv4.icanhazip.com || echo "  (failed to fetch IP)"
  echo
}

# ===== Disable WARP (keep config) =====
disable_warp_ipv4() {
  echo_info "Stopping WARP WireGuard interface..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true

  # Bring interface down if still present
  ip link set "$WG_IF" down 2>/dev/null || true

  echo_ok "WARP service stopped and disabled."

  echo
  echo_info "Current outbound IPv4 after disabling WARP:"
  curl -4 -s https://ipv4.icanhazip.com || echo "  (failed to fetch IP)"
  echo
}

# ===== Full uninstall: remove ALL WARP stuff (wgcf + warp-go + CFwarp + warp-cli) =====
full_uninstall() {
  echo "=================================================="
  echo " FULL WARP UNINSTALL:"
  echo " - Stop and disable wg-quick@wgcf/warp/wgwarp"
  echo " - Kill warp-go/warp-svc if they exist"
  echo " - Remove wgcf binary & configs"
  echo " - Remove CFwarp script (cf) if exists"
  echo " - Remove Cloudflare warp-cli package if installed"
  echo "=================================================="
  read -rp "Are you sure you want to remove ALL WARP components? [y/N]: " ans
  [[ ! "$ans" =~ ^[Yy]$ ]] && { echo "Canceled."; return; }

  echo_info "Stopping wg-quick WARP interfaces..."
  systemctl stop wg-quick@wgcf 2>/dev/null || true
  systemctl stop wg-quick@warp 2>/dev/null || true
  systemctl stop wg-quick@wgwarp 2>/dev/null || true

  systemctl disable wg-quick@wgcf 2>/dev/null || true
  systemctl disable wg-quick@warp 2>/dev/null || true
  systemctl disable wg-quick@wgwarp 2>/dev/null || true

  echo_info "Bringing down any active WireGuard interfaces named wg*..."
  for ifc in $(ip -o link show | awk -F': ' '{print $2}' | grep '^wg' || true); do
    ip link set "$ifc" down 2>/dev/null || true
  done

  echo_info "Stopping warp-go / warp-svc services if present..."
  systemctl stop warp-go 2>/dev/null || true
  systemctl disable warp-go 2>/dev/null || true
  systemctl stop warp-svc 2>/dev/null || true
  systemctl disable warp-svc 2>/dev/null || true

  echo_info "Killing warp-go / warp-svc processes if running..."
  pkill warp-go 2>/dev/null || true
  pkill warp-svc 2>/dev/null || true

  echo_info "Removing WireGuard configs related to WARP..."
  rm -f /etc/wireguard/warp.conf 2>/dev/null || true
  rm -f /etc/wireguard/wgcf.conf 2>/dev/null || true
  rm -f /etc/wireguard/wgwarp.conf 2>/dev/null || true
  rm -f "/etc/wireguard/${WG_IF}.conf" 2>/dev/null || true

  echo_info "Removing wgcf account and binary..."
  rm -f "$WGCF_ACCOUNT" 2>/dev/null || true
  rm -f "$WGCF_BIN" 2>/dev/null || true

  echo_info "Removing warp-go, CFwarp scripts, and leftovers..."
  rm -rf /opt/warp-go 2>/dev/null || true
  rm -f /usr/bin/cf 2>/dev/null || true
  rm -f /root/CFwarp.sh 2>/dev/null || true
  rm -rf /root/warpip 2>/dev/null || true
  rm -f /root/WARP-UP.sh 2>/dev/null || true

  echo_info "Removing Cloudflare WARP (warp-cli) package if installed..."
  if dpkg -l | grep -q cloudflare-warp; then
    apt remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    apt autoremove -y || true
  fi

  echo_ok "All known WARP components have been removed."

  echo
  echo_info "Checking current outbound IPv4 (should be ORIGINAL VPS IP now):"
  curl -4 -s https://ipv4.icanhazip.com || echo "  (failed to fetch IP)"
  echo
}

# ===== Menu =====
menu() {
  clear
  echo "=============================================="
  echo " Cloudflare WARP IPv4 Manager (wgcf + WireGuard)"
  echo "=============================================="
  echo " 1) Install WARP (wgcf engine)"
  echo " 2) Enable WARP IPv4 FULL tunnel"
  echo " 3) Disable WARP (keep config)"
  echo " 4) Show WARP status"
  echo " 5) FULL UNINSTALL all WARP (wgcf + warp-go + CFwarp + warp-cli)"
  echo " 0) Exit"
  echo
}

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) install_wgcf ;;
    2) enable_warp_ipv4 ;;
    3) disable_warp_ipv4 ;;
    4) show_status ;;
    5) full_uninstall ;;
    0) exit 0 ;;
    *) echo_err "Invalid option."; sleep 1 ;;
  esac
  echo
  read -rp "Press ENTER to continue..." _
done
