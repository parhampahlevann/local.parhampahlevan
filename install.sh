#!/bin/bash
set -e

CONFIG_DIR="/etc/tcp-zero-flap"
CONFIG_FILE="$CONFIG_DIR/config"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

log() { echo "[INFO] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Run as root: sudo bash $0"
    fi
}

install_deps() {
    log "Installing dependencies..."
    apt update -y || err "apt update failed"
    apt install -y haproxy || err "haproxy install failed"
}

port_free() {
    ss -lnt | awk '{print $4}' | grep -q ":$1$" && return 1 || return 0
}

configure() {
    echo
    read -rp "Listening port on proxy (e.g. 8443): " LISTEN_PORT

    port_free "$LISTEN_PORT" || err "Port $LISTEN_PORT is already in use"

    echo
    echo "Primary backend"
    read -rp "Primary IP: " PRIMARY_IP
    read -rp "Primary port: " PRIMARY_PORT

    echo
    echo "Backup backend"
    read -rp "Backup IP: " BACKUP_IP
    read -rp "Backup port: " BACKUP_PORT

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
LISTEN_PORT=$LISTEN_PORT
PRIMARY_IP=$PRIMARY_IP
PRIMARY_PORT=$PRIMARY_PORT
BACKUP_IP=$BACKUP_IP
BACKUP_PORT=$BACKUP_PORT
EOF
}

write_haproxy() {
    source "$CONFIG_FILE"

    log "Writing HAProxy config..."

    cat > "$HAPROXY_CFG" <<EOF
global
    daemon
    maxconn 100000

defaults
    mode tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend tcp_in
    bind 0.0.0.0:${LISTEN_PORT}
    default_backend backends

backend backends
    balance first
    option tcp-check
    default-server inter 3s fall 2 rise 1

    server primary ${PRIMARY_IP}:${PRIMARY_PORT} check
    server backup  ${BACKUP_IP}:${BACKUP_PORT} check backup
EOF
}

restart_haproxy() {
    log "Validating HAProxy config..."
    haproxy -c -f "$HAPROXY_CFG" || err "Invalid HAProxy config"

    log "Restarting HAProxy..."
    systemctl enable haproxy
    systemctl restart haproxy || err "HAProxy failed to start"
    systemctl status haproxy --no-pager
}

menu() {
    echo
    echo "1) Install / Configure"
    echo "2) Restart HAProxy"
    echo "3) Exit"
}

main() {
    require_root
    install_deps

    while true; do
        menu
        read -rp "> " c
        case "$c" in
            1)
                configure
                write_haproxy
                restart_haproxy
                ;;
            2)
                restart_haproxy
                ;;
            3)
                exit ;;
        esac
    done
}

main
