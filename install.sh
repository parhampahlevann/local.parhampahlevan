#!/usr/bin/env bash
#
# Ultimate Network Optimizer
# - General TCP/UDP + BBR throughput tuning
# - Gaming / CS2 low-latency tuning
# - SOCKS / Telegram proxy tuning
# - Backhule Premium menu (BBR + Wss Mux)
#

set -euo pipefail

LOGFILE="/var/log/optimize.log"
BACKUP_DIR="/root/sysctl_backups"
mkdir -p "$BACKUP_DIR"

die() {
  echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo -e "\e[32m[INFO]\e[0m $1" | tee -a "$LOGFILE"
}

# Root check
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (use sudo)."
fi

backup_sysctl() {
  local ts
  ts=$(date +%F_%H-%M-%S)
  log "Backing up /etc/sysctl.conf to ${BACKUP_DIR}/sysctl.conf.bak_${ts}"
  cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak_${ts}"
}

# -----------------------------------------------------------
# Detect default interface and /24 CIDR
# -----------------------------------------------------------
get_iface_and_cidr() {
  local IFACE IP CIDR

  IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')
  [[ -z "${IFACE:-}" ]] && die "Could not detect default network interface."

  IP=$(ip -o -4 addr show "$IFACE" | awk '{print $4}' | head -n1)
  [[ -z "${IP:-}" ]] && die "Could not detect IPv4 address on interface $IFACE."

  CIDR=$(echo "$IP" | awk -F'[./]' '{printf "%s.%s.%s.0/24\n", $1, $2, $3}')
  echo "$IFACE" "$CIDR"
}

install_ethtool_if_needed() {
  if ! command -v ethtool &>/dev/null; then
    log "ethtool not found. Installing..."
    apt-get update && apt-get install -y ethtool
  fi
}

# -----------------------------------------------------------
# NIC optimization – throughput oriented
# -----------------------------------------------------------
optimize_nics_throughput() {
  log "Optimizing NICs for high throughput (general profile)..."
  install_ethtool_if_needed

  for iface in $(ls /sys/class/net | grep -Ev 'lo|docker|veth|br-|virbr|tap'); do
    log "Configuring NIC: $iface (throughput-focused)"
    ethtool -K "$iface" gro on  gso on tso on rx on tx on 2>/dev/null || true
    ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
    ethtool -C "$iface" rx-usecs 25 rx-frames 64 tx-usecs 25 tx-frames 64 2>/dev/null || true
  done

  if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -q irqbalance.service; then
    log "Enabling irqbalance service..."
    systemctl enable irqbalance 2>/dev/null || true
    systemctl start irqbalance 2>/dev/null || true
  fi
}

# -----------------------------------------------------------
# NIC optimization – low latency (gaming)
# -----------------------------------------------------------
optimize_nics_low_latency() {
  log "Optimizing NICs for low latency (gaming profile)..."
  install_ethtool_if_needed

  for iface in $(ls /sys/class/net | grep -Ev 'lo|docker|veth|br-|virbr|tap'); do
    log "Configuring NIC: $iface (latency-focused)"
    ethtool -G "$iface" rx 1024 tx 1024 2>/dev/null || true
    ethtool -C "$iface" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 2>/dev/null || true

    # Uncomment below lines for ultra-low-latency (may reduce throughput)
    # ethtool -K "$iface" gro off gso off tso off 2>/dev/null || true
  done
}

# -----------------------------------------------------------
# 1) GENERAL TCP/UDP + BBR PROFILE (THROUGHPUT)
# -----------------------------------------------------------
apply_udp_tcp_bbr_profile() {
  log "Applying GENERAL TCP/UDP + BBR throughput profile..."

  backup_sysctl
  local SYSCTL_FILE="/etc/sysctl.d/90-general-udp-tcp-bbr.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# GENERAL TCP/UDP + BBR – HIGH THROUGHPUT PROFILE
########################################################

# === Socket buffers (system-wide) ===
net.core.rmem_default = 262144
net.core.rmem_max     = 268435456        # 256 MB
net.core.wmem_default = 262144
net.core.wmem_max     = 268435456        # 256 MB

# === TCP per-socket buffers ===
# min, default, max
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432

# === UDP memory/buffer control ===
# Values are in pages; tuned for high bandwidth
net.ipv4.udp_mem  = 8388608 12582912 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# === Queues and backlog ===
net.core.netdev_max_backlog = 250000
net.core.somaxconn          = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# === General TCP features ===
net.ipv4.tcp_sack           = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing    = 1
net.ipv4.tcp_base_mss       = 1024
net.ipv4.tcp_adv_win_scale  = 1

# Faster recycle / reuse of TIME_WAIT (safe variant)
net.ipv4.tcp_tw_reuse   = 1
net.ipv4.tcp_fin_timeout = 20

# Enable TCP Fast Open (client + server)
net.ipv4.tcp_fastopen  = 3
net.ipv4.tcp_low_latency = 1

# Local port range – wide for many connections
net.ipv4.ip_local_port_range = 1024 65535

# === IP Forwarding and security ===
net.ipv4.ip_forward = 1

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === Conntrack for NAT / firewall-heavy setups ===
net.netfilter.nf_conntrack_max                 = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 60

# === BBR congestion control ===
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  optimize_nics_throughput

  log "GENERAL TCP/UDP + BBR profile applied. Reboot is recommended."
}

# -----------------------------------------------------------
# 2) GAMING / CS2 PROFILE (LOW LATENCY)
# -----------------------------------------------------------
apply_cs2_gaming_profile() {
  log "Applying GAMING / CS2 low-latency profile..."

  backup_sysctl
  local SYSCTL_FILE="/etc/sysctl.d/90-gaming-cs2.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# GAMING / CS2 – LOW LATENCY PROFILE
########################################################

# Keep TCP low latency
net.ipv4.tcp_low_latency = 1

# Slightly smaller min UDP buffers (less queuing delay)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Reasonable backlog – high enough but not crazy
net.core.netdev_max_backlog = 65536
net.core.somaxconn          = 32768

# TCP settings focused on responsiveness
net.ipv4.tcp_sack          = 1
net.ipv4.tcp_timestamps    = 1
net.ipv4.tcp_ecn           = 0   # Disable ECN – some routers misbehave
net.ipv4.tcp_mtu_probing   = 1
net.ipv4.tcp_frto          = 0

net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 262144 8388608

# Keep TIME_WAIT and retries modest
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse    = 1
net.ipv4.tcp_retries2    = 8

# Tight port range is fine for gaming clients/servers
net.ipv4.ip_local_port_range = 20000 60999

# VM settings – avoid swapping and I/O spikes
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Scheduler hints – improve interactive responsiveness
kernel.sched_min_granularity_ns = 10000000
kernel.sched_latency_ns         = 60000000
kernel.sched_migration_cost_ns  = 500000

EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  optimize_nics_low_latency

  # Helper script to run CS2 with high priority & specific cores
  local HELPER="/usr/local/bin/run_cs2_prio.sh"
  cat > "$HELPER" << 'EOF'
#!/usr/bin/env bash
# Run CS2 with higher CPU priority and CPU affinity.
# Usage:
#   run_cs2_prio.sh <your-cs2-command>

CS2_CMD="$*"

if [[ -z "$CS2_CMD" ]]; then
  echo "Usage: run_cs2_prio.sh <your-cs2-command>"
  echo "Example (server): run_cs2_prio.sh ./cs2_server.sh"
  exit 1
fi

echo "Running CS2 with high priority on cores 0-3..."
exec nice -n -5 taskset -c 0-3 $CS2_CMD
EOF

  chmod +x "$HELPER"

  log "GAMING / CS2 profile applied. Helper: /usr/local/bin/run_cs2_prio.sh"
  log "Reboot is recommended for consistent behavior."
}

# -----------------------------------------------------------
# 3) SOCKS / TELEGRAM PROXY PROFILE
# -----------------------------------------------------------
apply_socks_telegram_profile() {
  log "Applying SOCKS / Telegram proxy profile..."

  backup_sysctl
  local SYSCTL_FILE="/etc/sysctl.d/90-socks-telegram.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# SOCKS / TELEGRAM PROXY – MANY CONNECTIONS + LOW LATENCY
########################################################

# Allow many pending connections
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Faster cleanup of connections
net.ipv4.tcp_tw_reuse    = 1
net.ipv4.tcp_fin_timeout = 15

# Wide ephemeral port range – proxies need many ports
net.ipv4.ip_local_port_range = 1024 65535

# Enable SYN cookies to protect against SYN flood
net.ipv4.tcp_syncookies = 1

# TCP keepalive – clean dead clients
net.ipv4.tcp_keepalive_time   = 600
net.ipv4.tcp_keepalive_intvl  = 30
net.ipv4.tcp_keepalive_probes = 10

# TCP buffers optimized for many mid-sized flows
net.ipv4.tcp_rmem = 4096 524288 16777216
net.ipv4.tcp_wmem = 4096 524288 16777216

# Enable TCP Fast Open (useful for short lived connections)
net.ipv4.tcp_fastopen = 3

# Conntrack – important if running behind NAT or firewall
net.netfilter.nf_conntrack_max                   = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 300
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  # Increase file descriptor limits for lots of SOCKS connections
  local LIMITS_FILE="/etc/security/limits.d/90-socks-proxy.conf"
  cat > "$LIMITS_FILE" << 'EOF'
* soft nofile 512000
* hard nofile 512000
EOF

  log "SOCKS / Telegram proxy profile applied."
  log "FD limits set in /etc/security/limits.d/90-socks-proxy.conf (relogin or reboot needed)."
}

show_current_congestion_control() {
  echo "Current TCP congestion control:"
  sysctl net.ipv4.tcp_congestion_control
}

# -----------------------------------------------------------
# BACKHULE PREMIUM – BBR PROFILE
# -----------------------------------------------------------
install_bbr_backhule_premium() {
  log "Installing Backhule Premium BBR profile..."

  backup_sysctl
  local SYSCTL_FILE="/etc/sysctl.d/80-backhule-bbr.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# BACKHULE PREMIUM – BBR TUNING
########################################################

# Force BBR + fq for this profile
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# Backhule-style aggressive buffers (adjust as needed)
net.core.rmem_max = 536870912   # 512 MB
net.core.wmem_max = 536870912   # 512 MB

net.ipv4.tcp_rmem = 4096 2097152 67108864
net.ipv4.tcp_wmem = 4096 2097152 67108864

# Additional performance tweaks
net.ipv4.tcp_sack           = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing    = 1
EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  log "Backhule Premium BBR profile installed. Reboot recommended."
}

uninstall_bbr_backhule() {
  log "Uninstalling Backhule Premium BBR profile..."
  local SYSCTL_FILE="/etc/sysctl.d/80-backhule-bbr.conf"

  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system
    log "Backhule Premium BBR profile removed."
  else
    log "Backhule BBR profile not found; nothing to remove."
  fi
}

# -----------------------------------------------------------
# BACKHULE PREMIUM – WSS MUX (TEMPLATES)
# -----------------------------------------------------------
install_wss_mux_backuhle_premium() {
  log "Installing Wss Mux Backuhle Premium..."

  local IFACE CIDR
  read -r IFACE CIDR < <(get_iface_and_cidr)
  log "Detected interface: $IFACE, CIDR: $CIDR"

  # === PLACEHOLDER: put your real Wss Mux install code here ===
  # Example skeleton:
  #
  #  curl -fsSL https://your-wss-mux-install-script.sh -o /usr/local/bin/wss-mux-backhule
  #  chmod +x /usr/local/bin/wss-mux-backhule
  #  /usr/local/bin/wss-mux-backhule install --iface "$IFACE" --cidr "$CIDR"
  #
  #  cat >/etc/systemd/system/wss-mux-backhule.service <<SERVICE
  #  [Unit]
  #  Description=Wss Mux Backuhle Premium
  #  After=network.target
  #
  #  [Service]
  #  ExecStart=/usr/local/bin/wss-mux-backhule run --iface "$IFACE" --cidr "$CIDR"
  #  Restart=always
  #
  #  [Install]
  #  WantedBy=multi-user.target
  #  SERVICE
  #
  #  systemctl daemon-reload
  #  systemctl enable --now wss-mux-backhule.service
  #
  # ============================================================

  log "Wss Mux Backuhle Premium install placeholder executed."
  log "Replace the placeholder block with your actual Wss Mux installation logic."
}

uninstall_wss_mux() {
  log "Uninstalling Wss Mux Backuhle Premium..."

  # === PLACEHOLDER: put your real Wss Mux uninstall code here ===
  #
  #  systemctl stop wss-mux-backhule.service || true
  #  systemctl disable wss-mux-backhule.service || true
  #  rm -f /etc/systemd/system/wss-mux-backhule.service
  #  rm -f /usr/local/bin/wss-mux-backhule
  #  systemctl daemon-reload
  #
  # =============================================================

  log "Wss Mux Backuhle Premium uninstall placeholder executed."
  log "Replace the placeholder block with your actual Wss Mux uninstall logic."
}

reboot_server() {
  log "Rebooting server..."
  reboot
}

# -----------------------------------------------------------
# MAIN MENU
# -----------------------------------------------------------
main_menu() {
  while true; do
    echo "====================================================="
    echo "        Ultimate Network / Gaming / Backhule Menu"
    echo "====================================================="
    echo " 1) GENERAL TCP/UDP + BBR (high throughput)"
    echo " 2) GAMING / CS2 (low latency)"
    echo " 3) SOCKS / Telegram proxy optimization"
    echo " 4) Install BBR Backhule Premium"
    echo " 5) Uninstall BBR Backhule Premium"
    echo " 6) Install Wss Mux Backuhle Premium"
    echo " 7) Uninstall Wss Mux Backuhle Premium"
    echo " 8) Show current TCP congestion control"
    echo " 9) Reboot server"
    echo "10) Exit"
    echo "-----------------------------------------------------"
    read -rp "Choose an option [1-10]: " choice

    case "$choice" in
      1) apply_udp_tcp_bbr_profile ;;
      2) apply_cs2_gaming_profile ;;
      3) apply_socks_telegram_profile ;;
      4) install_bbr_backhule_premium ;;
      5) uninstall_bbr_backhule ;;
      6) install_wss_mux_backuhle_premium ;;
      7) uninstall_wss_mux ;;
      8) show_current_congestion_control ;;
      9) reboot_server ;;
      10)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid choice. Please choose 1-10."
        ;;
    esac

    echo
    read -rp "Press Enter to return to the menu..." _
  done
}

main_menu
