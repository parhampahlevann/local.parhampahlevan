#!/bin/bash

# FRP Installation Script (Final - Matches Telegram bot exactly)
# No unnecessary apt update/install curl (assumes curl is already present)
# Uses Go template with parseNumberRangePair
# transport.useCompression = true
# IPv6 without brackets

show_menu() {
    clear
    echo "=================================="
    echo "     FRP Reverse Tunnel Setup     "
    echo "=================================="
    echo "1) Install FRP on Iran (Server - frps)"
    echo "2) Install FRP on Kharej (Client - frpc)"
    echo "3) Remove FRP"
    echo "4) Exit"
    echo "=================================="
    read -p "Choose an option [1-4]: " choice
}

install_server() {
    echo "=== Installing FRP Server (frps) on Iran ==="

    curl -L -o /usr/local/bin/frps http://81.12.32.210/downloads/frps
    chmod +x /usr/local/bin/frps

    mkdir -p /root/frp/server

    cat > /root/frp/server/server-3090.toml <<'EOF'
# Auto-generated frps config
bindAddr = "::"
bindPort = 3090

transport.heartbeatTimeout = 90
transport.maxPoolCount = 65535
transport.tcpMux = false
transport.tcpMuxKeepaliveInterval = 10
transport.tcpKeepalive = 120

auth.method = "token"
auth.token = "tun100"
EOF

    cat > /etc/systemd/system/frps@.service <<'EOF'
[Unit]
Description=FRP Server Service (%i)
Documentation=https://gofrp.org/en/docs/overview/
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/frps -c /root/frp/server/%i.toml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frps@server-3090.service
    systemctl start frps@server-3090.service

    # Crontab reload every 3 hours
    (crontab -l 2>/dev/null | grep -v 'pkill -10' ; echo '0 */3 * * * pkill -10 -x frpc; pkill -10 -x frps') | crontab -

    echo "FRP Server installed and started!"
    echo "Listening on port 3090 with token 'tun100'"
}

install_client() {
    echo "=== Installing FRP Client (frpc) on Kharej ==="

    curl -L -o /usr/local/bin/frpc https://raw.githubusercontent.com/lostsoul6/frp-file/refs/heads/main/frpc
    chmod +x /usr/local/bin/frpc

    mkdir -p /root/frp/client

    read -p "Enter Iran server address (IPv4 or IPv6, e.g. 1.2.3.4 or 2a10:250:56ff:feb4:3b26): " server_addr
    read -p "Enter inbound ports to forward (comma-separated or ranges, e.g. 1194 or 6000-6005,8443) [default: 8080]: " ports
    ports=${ports:-8080}

    # Escape quotes for safe insertion into the template
    escaped_ports=$(printf '%s' "$ports" | sed 's/"/\\"/g')

    cat > /root/frp/client/client-3090.toml <<EOF
serverAddr = "$server_addr"
serverPort = 3090

loginFailExit = false

auth.method = "token"
auth.token = "tun100"

transport.protocol = "tcp"
transport.tcpMux = false
transport.tcpMuxKeepaliveInterval = 10
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 120
transport.poolCount = 20
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.tls.enable = false
transport.quic.keepalivePeriod = 10
transport.quic.maxIdleTimeout = 30
transport.quic.maxIncomingStreams = 100000

{{- range \$_, \$v := parseNumberRangePair "$escaped_ports" "$escaped_ports" }}
[[proxies]]
name = "tcp-{{ \$v.First }}"
type = "tcp"
localIP = "127.0.0.1"
localPort = {{ \$v.First }}
remotePort = {{ \$v.Second }}
transport.useEncryption = false
transport.useCompression = false
{{- end }}
EOF

    cat > /etc/systemd/system/frpc@.service <<'EOF'
[Unit]
Description=FRP Client Service (%i)
Documentation=https://gofrp.org/en/docs/overview/
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/frpc -c /root/frp/client/%i.toml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable frpc@client-3090.service
    systemctl start frpc@client-3090.service

    # Crontab reload every 3 hours
    (crontab -l 2>/dev/null | grep -v 'pkill -10' ; echo '0 */3 * * * pkill -10 -x frpc; pkill -10 -x frps') | crontab -

    echo "FRP Client installed and started!"
    echo "Connecting to $server_addr:3090"
    echo "Forwarding ports: $ports"
    echo "Config uses Go template - frpc renders the proxy sections at runtime."
}

remove_frp() {
    echo "=== Removing FRP ==="

    systemctl stop frps@server-3090.service frpc@client-3090.service 2>/dev/null || true
    systemctl disable frps@server-3090.service frpc@client-3090.service 2>/dev/null || true
    rm -f /etc/systemd/system/frps@.service /etc/systemd/system/frpc@.service
    rm -rf /root/frp
    rm -f /usr/local/bin/frps /usr/local/bin/frpc
    systemctl daemon-reload

    # Remove crontab entries
    (crontab -l 2>/dev/null | grep -v 'pkill -10') | crontab -

    echo "FRP removed successfully!"
}

while true; do
    show_menu
    case $choice in
        1) install_server ;;
        2) install_client ;;
        3) remove_frp ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
    echo
    read -p "Press Enter to continue..."
done
