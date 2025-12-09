#!/usr/bin/env bash

set -e

if [[ $EUID -ne 0 ]]; then
  echo "[*] Running as root required. Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_PATH="/usr/local/bin/warp-menu"
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

if [[ "$CURRENT_PATH" != "$SCRIPT_PATH" && -f "$CURRENT_PATH" ]]; then
  echo "[*] Installing warp-menu to $SCRIPT_PATH ..."
  cp "$CURRENT_PATH" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "[OK] Installed. Use: warp-menu"
fi

### Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

have_cmd() { command -v "$1" &>/dev/null; }

### Install CFwarp
install_cfwarp() {
  if have_cmd cf; then
    echo "[OK] CFwarp already installed."
    return
  fi

  echo "[*] Installing CFwarp (warp-yg: yonggekkk)..."
  curl -sSL -o /usr/bin/cf -L https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh
  chmod +x /usr/bin/cf

  if have_cmd cf; then
    echo "[OK] CFwarp installed."
  else
    echo "[ERR] Failed to install CFwarp."
    exit 1
  fi
}

### Auto-enable WARP IPv4 FULL MODE
enable_ipv4_warp() {
  install_cfwarp

  echo "[*] Activating WARP IPv4 FULL tunnel (English mode)..."
  echo "[*] Running: cf i"
  sleep 1

  # This is the CFwarp internal command for IPv4-only Warp
  cf i

  echo "[*] Checking outbound IP..."
  sleep 3

  NEW_IP=$(curl -4 -s https://ipv4.icanhazip.com || true)

  if [[ -n "$NEW_IP" ]]; then
    echo -e "[OK] New IPv4 WARP IP: ${GREEN}${NEW_IP}${NC}"
  else
    echo -e "[ERR] Unable to fetch IPv4 after activating WARP."
  fi
}

### Disable warp-go
disable_ipv4_warp() {
  if ! have_cmd cf; then
    echo "[ERR] CFwarp not installed."
    return
  fi

  echo "[*] Disabling WARP IPv4..."
  cf x

  echo "[*] Checking outbound IP..."
  sleep 2
  curl -4 https://ipv4.icanhazip.com
}

### Main menu
menu() {
  clear
  echo "=============================================="
  echo " Cloudflare WARP Manager (English Edition)"
  echo "=============================================="
  echo " 1) Enable WARP IPv4 FULL Tunnel (Auto-English)"
  echo " 2) Disable WARP IPv4"
  echo " 3) Open CFwarp original menu (Chinese)"
  echo " 0) Exit"
  echo
}

while true; do
  menu
  read -rp "Choose: " c

  case "$c" in
    1) enable_ipv4_warp ;;
    2) disable_ipv4_warp ;;
    3) install_cfwarp; cf ;;
    0) exit 0 ;;
    *) echo "[ERR] Invalid option" ;;
  esac

  echo
  read -rp "Press ENTER to continue..."
done
