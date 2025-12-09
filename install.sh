#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo_info() { echo -e "${CYAN}[*]${NC} $1"; }
echo_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
echo_err()  { echo -e "${RED}[ERR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  echo_err "Run this script as root (use sudo)."
  exit 1
fi

WGCF_BIN="/usr/local/bin/wgcf"
WG_DIR="/etc/wireguard"
WGCF_ACCOUNT="${WG_DIR}/wgcf-account.toml"
WGCF_CONF="${WG_DIR}/wgcf.conf"
WG_IF="wgcf"
SERVICE_NAME="wg-quick@wgcf"

install_deps() {
  echo_info "Installing dependencies (wireguard, curl, wget, resolvconf)..."
  apt update -y >/dev/null 2>&1
  apt install -y wireguard wireguard-tools resolvconf curl wget >/dev/null 2>&1
  echo_ok "Dependencies installed."
}

install_wgcf() {
  if [[ -x "$WGCF_BIN" ]]; then
    echo_ok "wgcf already installed at $WGCF_BIN"
    return
  fi

  install_deps

  arch=$(uname -m)
  url_base="https://raw.githubusercontent.com/cf-dm/CFwarp/main"

  case "$arch" in
    x86_64)
      f="wgcf_2.2.22_amd64"
      ;;
    aarch64|arm64)
      f="wgcf_2.2.22_arm64"
      ;;
    *)
      echo_err "Unsupported architecture: $arch"
      exit 1
      ;;
  esac

  echo_info "Downloading wgcf ($f)..."
  wget -qO "$WGCF_BIN" "$url_base/$f"
  if [[ $? -ne 0 ]]; then
    echo_err "Failed to download wgcf."
    rm -f "$WGCF_BIN"
    exit 1
  fi

  chmod +x "$WGCF_BIN"

  "$WGCF_BIN" -h >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo_err "wgcf binary is invalid or not executable."
    exit 1
  fi

  echo_ok "wgcf installed successfully."
}

generate_wgcf_config() {
  install_wgcf
  mkdir -p "$WG_DIR"

  if [[ -f wgcf-account.toml && ! -f "$WGCF_ACCOUNT" ]]; then
    echo_info "Found local wgcf-account.toml, moving to $WGCF_ACCOUNT"
    mv wgcf-account.toml "$WGCF_ACCOUNT"
  fi

  if [[ ! -f "$WGCF_ACCOUNT" ]]; then
    echo_info "Registering new WARP account with wgcf..."
    "$WGCF_BIN" register --accept-tos
    if [[ -f wgcf-account.toml && ! -f "$WGCF_ACCOUNT" ]]; then
      mv wgcf-account.toml "$WGCF_ACCOUNT"
    fi
    if [[ ! -f "$WGCF_ACCOUNT" ]]; then
      echo_err "Failed to create wgcf account file."
      exit 1
    fi
  else
    echo_info "Using existing WARP account: $WGCF_ACCOUNT"
  fi

  echo_info "Generating WARP profile..."
  rm -f wgcf-profile.conf 2>/dev/null
  "$WGCF_BIN" generate
  if [[ ! -f wgcf-profile.conf ]]; then
    echo_err "wgcf-profile.conf was not generated."
    exit 1
  fi

  mv wgcf-profile.conf "$WGCF_CONF"

  sed -i '/::\/0/d' "$WGCF_CONF"
  sed -i '/Address = .*:/d' "$WGCF_CONF"

  if grep -q "^MTU" "$WGCF_CONF"; then
    sed -i 's/^MTU.*/MTU = 1280/' "$WGCF_CONF"
  else
    sed -i '/^\[Interface\]/a MTU = 1280' "$WGCF_CONF"
  fi

  echo_ok "WARP config ready at $WGCF_CONF (IPv4 only)."
}

enable_warp_ipv4() {
  generate_wgcf_config

  echo_info "Copying config to $WG_DIR/$WG_IF.conf"
  cp "$WGCF_CONF" "$WG_DIR/$WG_IF.conf"

  echo_info "Starting WireGuard interface $SERVICE_NAME"
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$SERVICE_NAME" >/dev/null 2>&1

  sleep 3

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo_ok "Service $SERVICE_NAME is active."
  else
    echo_err "Service $SERVICE_NAME failed to start. Check: systemctl status $SERVICE_NAME"
  fi

  echo_info "Setting default route via $WG_IF..."
  ip -4 route replace default dev "$WG_IF" 2>/dev/null || echo_err "Failed to set default route via WARP."

  show_status
}

disable_warp_ipv4() {
  echo_info "Stopping WARP interface..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  ip link set "$WG_IF" down 2>/dev/null || true

  echo_info "Restoring default route with DHCP..."
  dhclient -4 -r 2>/dev/null || true
  dhclient -4 2>/dev/null || true

  show_status
}

show_status() {
  echo
  echo_info "Cloudflare trace:"
  curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep -E 'ip=|warp=|loc=' || echo "trace failed"

  echo
  echo_info "Outbound IPv4:"
  curl -4 -s https://ipv4.icanhazip.com || echo "IP check failed"
  echo
}

full_uninstall() {
  echo_info "Stopping and removing WARP..."

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  ip link set "$WG_IF" down 2>/dev/null || true

  rm -f "$WG_DIR/$WG_IF.conf"
  rm -f "$WGCF_CONF"
  rm -f "$WGCF_ACCOUNT"
  rm -f "$WGCF_BIN"

  echo_ok "WARP (wgcf + config) removed."
}

menu() {
  clear
  echo "=============================="
  echo "      WARP IPv4 Manager       "
  echo "=============================="
  echo "1) Install WARP engine (wgcf)"
  echo "2) Enable WARP IPv4 FULL"
  echo "3) Disable WARP"
  echo "4) Show Status"
  echo "5) FULL Uninstall"
  echo "0) Exit"
  echo
}

while true; do
  menu
  read -rp "Choose: " x

  case "$x" in
    1) install_wgcf ;;
    2) enable_warp_ipv4 ;;
    3) disable_warp_ipv4 ;;
    4) show_status ;;
    5) full_uninstall ;;
    0) exit 0 ;;
    *) echo_err "Invalid option" ;;
  esac

  echo
  read -rp "Press ENTER to continue..." dummy
done
