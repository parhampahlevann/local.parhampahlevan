#!/usr/bin/env bash
# Cloudflare WARP Manager (Parham + CFwarp integration)
# Ubuntu 20/22/24

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

# ===== CFwarp helper =====
ensure_cfwarp() {
  if have_cmd cf; then
    echo_ok "CFwarp helper (cf) is already installed."
    return
  fi

  echo_info "Installing CFwarp helper command: cf ..."
  curl -sSL -o /usr/bin/cf -L https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh
  chmod +x /usr/bin/cf

  if have_cmd cf; then
    echo_ok "CFwarp installed as 'cf'."
  else
    echo_err "Failed to install CFwarp."
    exit 1
  fi
}

# ===== OPTION 1: Install WARP IPv4 FULL tunnel (CFwarp Plan 1 -> IPv4 single stack) =====
install_warp_ipv4_cfwarp() {
  ensure_cfwarp

  echo_info "Running CFwarp: Plan 1 (WARP-GO) + IPv4 single stack..."
  echo_info "Equivalent to manually choosing:"
  echo "  1) 方案一：安装/切换WARP-GO"
  echo "  1) 安装/切换WARP单栈IPV4"
  echo

  # Temporarily disable 'exit on error' so if cf returns non-zero we don't kill this script
  set +e
  printf "1\n1\n" | cf
  cf_exit=$?
  set -e

  if [[ $cf_exit -ne 0 ]]; then
    echo_warn "CFwarp returned non-zero exit code ($cf_exit)."
    echo_warn "It may still have configured WARP. We will check status now."
  fi

  show_status
}

# ===== OPTION 2: Show WARP status =====
show_status() {
  echo "--------------------------------------------------"
  echo " WARP Status"
  echo "--------------------------------------------------"

  echo_info "Cloudflare trace (IPv4):"
  local trace
  trace=$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace || true)
  if [[ -n "$trace" ]]; then
    # Print only key info
    echo "$trace" | grep -E 'ip=|warp=|loc=' || echo "$trace"
  else
    echo "  Unable to reach Cloudflare trace."
  fi

  echo
  echo_info "Outbound IPv4:"
  curl -4 -s https://ipv4.icanhazip.com || echo "  (failed to fetch IP)"
  echo
}

# ===== OPTION 3: Disable WARP (stop warp-go / wgcf / wg-quick) =====
disable_warp() {
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

  echo_ok "WARP has been disabled (services stopped, not removed)."

  echo
  echo_info "Current outbound IPv4 after disabling WARP:"
  curl -4 -s https://ipv4.icanhazip.com || echo "  (failed to fetch IP)"
  echo
}

# ===== OPTION 4: FULL UNINSTALL (all WARP: CFwarp + wgcf + warp-go + warp-cli) =====
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
  rm -f /etc/wireguard/wgcf.conf 2>/dev/null || true

  echo_info "Removing wgcf account and binary if present..."
  rm -f /etc/wireguard/wgcf-account.toml 2>/dev/null || true
  rm -f /usr/local/bin/wgcf 2>/dev/null || true

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

# ===== OPTION 5: Open original CFwarp menu (Chinese) =====
open_cfwarp_menu() {
  ensure_cfwarp
  echo_info "Opening original CFwarp menu (Chinese)."
  echo_info "You can still manually choose options there if you want."
  cf
}

# ===== Menu =====
menu() {
  clear
  echo "=============================================="
  echo " Cloudflare WARP Manager (CFwarp-based, IPv4)"
  echo "=============================================="
  echo " 1) Install WARP IPv4 FULL tunnel (CFwarp Plan 1 -> IPv4)"
  echo " 2) Show WARP status"
  echo " 3) Disable WARP (stop warp-go / wgcf / wg-quick)"
  echo " 4) FULL UNINSTALL all WARP (CFwarp + wgcf + warp-go + warp-cli)"
  echo " 5) Open original CFwarp menu (Chinese)"
  echo " 0) Exit"
  echo
}

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) install_warp_ipv4_cfwarp ;;
    2) show_status ;;
    3) disable_warp ;;
    4) full_uninstall ;;
    5) open_cfwarp_menu ;;
    0) exit 0 ;;
    *) echo_err "Invalid option."; sleep 1 ;;
  esac
  echo
  read -rp "Press ENTER to continue..." _
done
