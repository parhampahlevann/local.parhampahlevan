#!/bin/bash
set -euo pipefail

# =============================================
# TCP ZERO-FLAP PROXY INSTALLER
# =============================================

CONFIG_DIR="/etc/tcp-zero-flap"
CONFIG_FILE="$CONFIG_DIR/config"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

err() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

pause() {
    read -rp "Press Enter to continue..." _
}

ensure_root() {
    [ "$EUID" -ne 0 ] && err "Run as root"
}

install_deps() {
    log "Installing dependencies..."
    apt update -y
    apt install -y haproxy iproute2
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
LISTEN_PORT="$LISTEN_PORT"
PRIMARY_IP="$PRIMARY_IP"
PRIMARY_PORT="$PRIMARY_PORT"
BACKUP_IP="$BACKUP_IP"
BACKUP_PORT="$BACKUP_PORT"
EOF
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

write_haproxy_config() {
    log "Writing HAProxy config..."

    cat > "$HAPROXY_CFG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 100000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend tcp_in
    bind 0.0.0.0:${LISTEN_PORT}
    default_backend tcp_backends

backend tcp_backends
    balance first
    option tcp-check
    default-server inter 3s fall 2 rise 1

    server primary ${PRIMARY_IP}:${PRIMARY_PORT} check
    server backup  ${BACKUP_IP}:${BACKUP_PORT} check backup
EOF
}

restart_haproxy() {
    systemctl enable haproxy
    systemctl restart haproxy
    systemctl status haproxy --no-pager
}

setup_firewall_hint() {
    echo
    echo -e "${YELLOW}Firewall Reminder:${NC}"
    echo "Allow incoming TCP on port $LISTEN_PORT"
    echo "Example:"
    echo "  ufw allow $LISTEN_PORT/tcp"
    echo
}

configure() {
    echo
    echo "════════════════════════════════════════════"
    echo " TCP ZERO-FLAP PROXY CONFIGURATION"
    echo "════════════════════════════════════════════"
    echo

    read -rp "Listening port on proxy (e.g. 443): " LISTEN_PORT

    echo
    echo "Primary backend (MAIN server)"
    read -rp "Primary IP: " PRIMARY_IP
    read -rp "Primary port: " PRIMARY_PORT

    echo
    echo "Backup backend (ONLY if primary is down)"
    read -rp "Backup IP: " BACKUP_IP
    read -rp "Backup port: " BACKUP_PORT

    save_config
}

show_status() {
    echo
    echo "════════════════════════════════════════════"
    echo " PROXY STATUS"
    echo "════════════════════════════════════════════"
    echo

    haproxy -c -f "$HAPROXY_CFG" && echo
    ss -lntp | grep ":$LISTEN_PORT" || true
    echo
}

uninstall() {
    read -rp "Type DELETE to uninstall: " c
    [ "$c" != "DELETE" ] && return

    systemctl stop haproxy || true
    rm -rf "$CONFIG_DIR"
    log "Configuration removed. HAProxy not uninstalled."
}

menu() {
    clear
    echo "════════════════════════════════════════════"
    echo " TCP ZERO-FLAP PROXY"
    echo "════════════════════════════════════════════"
    echo
    echo "1) Install / Reconfigure"
    echo "2) Show status"
    echo "3) Restart HAProxy"
    echo "4) Uninstall config"
    echo "5) Exit"
    echo
}

main() {
    ensure_root
    install_deps
    load_config

    while true; do
        menu
        read -rp "> " c
        case "$c" in
            1)
                configure
                write_haproxy_config
                restart_haproxy
                setup_firewall_hint
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                restart_haproxy
                pause
                ;;
            4)
                uninstall
                pause
                ;;
            5)
                exit
                ;;
        esac
    done
}

main
