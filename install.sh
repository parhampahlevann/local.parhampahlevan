#!/usr/bin/env bash

# Ubuntu UDP / BBR / Gaming (CS2) Optimizer
# + Backhule Premium Menu
#
# Backhule Premium Menu
# 1) Install BBR Backhule Premium
# 2) Uninstall BBR
# 3) Install Wss Mux Backuhle Premium
# 4) Uninstall Wss Mux
# 5) Reboot server
# 6) Exit

# Safety flags / shell options
set -e
set -o errexit
set -o nounset
set -o pipefail

LOGFILE="/var/log/optimize.log"

die() {
  echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo -e "\e[32m[INFO]\e[0m $1" | tee -a "$LOGFILE"
}

# First root check (from original optimizer script)
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root (use sudo)."
  exit 1
fi

# Second root check (from Backhule script – kept intact)
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

BACKUP_DIR="/root/sysctl_backups"
mkdir -p "$BACKUP_DIR"

backup_sysctl() {
  local ts
  ts=$(date +%F_%H-%M-%S)
  log "Backing up /etc/sysctl.conf to ${BACKUP_DIR}/sysctl.conf.bak_${ts}"
  cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak_${ts}"
}

# -----------------------------------------------------------
# Shared: get default interface and auto /24 CIDR (completed)
# -----------------------------------------------------------
get_iface_and_cidr() {
  local IFACE
  local IP
  local CIDR

  # Try to get default interface via ip route
  IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')
  if [[ -z "${IFACE:-}" ]]; then
    die "Could not detect default network interface."
  fi

  IP=$(ip -o -4 addr show "$IFACE" | awk '{print $4}' | head -n1)
  if [[ -z "${IP:-}" ]]; then
    die "Could not detect IPv4 address on interface $IFACE."
  fi

  # Convert to /24 CIDR (e.g. 192.168.1.10/24 -> 192.168.1.0/24)
  CIDR=$(echo "$IP" | awk -F'[./]' '{printf "%s.%s.%s.0/24\n", $1, $2, $3}')

  echo "$IFACE" "$CIDR"
}

install_ethtool_if_needed() {
  if ! command -v ethtool &> /dev/null; then
    log "ethtool is not installed. Installing..."
    apt-get update && apt-get install -y ethtool
  fi
}

# -----------------------------------------------------------
# NIC optimization – throughput profile (from original script)
# -----------------------------------------------------------
optimize_nics_throughput() {
  log "Optimizing NICs for high throughput (general UDP/BBR profile)..."
  install_ethtool_if_needed

  for iface in $(ls /sys/class/net | grep -Ev 'lo|docker|veth|br-|virbr|tap'); do
    log "Configuring NIC: $iface (throughput-focused)"
    # Enable offloads for better throughput (may slightly increase latency)
    ethtool -K "$iface" gro on  2>/dev/null || true
    ethtool -K "$iface" gso on  2>/dev/null || true
    ethtool -K "$iface" tso on  2>/dev/null || true
    ethtool -K "$iface" rx on   2>/dev/null || true
    ethtool -K "$iface" tx on   2>/dev/null || true

    # Increase ring buffers if supported
    ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true

    # Moderate interrupt coalescing to reduce CPU overhead
    ethtool -C "$iface" rx-usecs 25 rx-frames 64 tx-usecs 25 tx-frames 64 2>/dev/null || true
  done

  # Enable irqbalance if available
  if command -v systemctl &> /dev/null; then
    if systemctl list-unit-files | grep -q irqbalance.service; then
      log "Enabling irqbalance service..."
      systemctl enable irqbalance 2>/dev/null || true
      systemctl start irqbalance 2>/dev/null || true
    fi
  fi
}

# -----------------------------------------------------------
# NIC optimization – low latency (CS2 / gaming profile)
# -----------------------------------------------------------
optimize_nics_low_latency() {
  log "Optimizing NICs for low latency (CS2 / gaming profile)..."
  install_ethtool_if_needed

  for iface in $(ls /sys/class/net | grep -Ev 'lo|docker|veth|br-|virbr|tap'); do
    log "Configuring NIC: $iface (latency-focused)"
    # Slightly reduce buffering to lower latency
    ethtool -G "$iface" rx 1024 tx 1024 2>/dev/null || true

    # Reduce interrupt coalescing (more interrupts, lower latency)
    ethtool -C "$iface" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 2>/dev/null || true

    # Optional ultra-low-latency mode – uncomment if you want:
    # ethtool -K "$iface" gro off 2>/dev/null || true
    # ethtool -K "$iface" gso off 2>/dev/null || true
    # ethtool -K "$iface" tso off 2>/dev/null || true
  done
}

# -----------------------------------------------------------
# GENERAL UDP + BBR OPTIMIZATION PROFILE (original option 1)
# -----------------------------------------------------------
apply_udp_bbr_profile() {
  log "Applying general UDP + BBR network optimization profile..."

  backup_sysctl

  local SYSCTL_FILE="/etc/sysctl.d/99-udp-bbr-tuning.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# UDP / TCP / NETWORK TUNING – GENERAL OPTIMIZATION
########################################################

# 1) UDP / socket buffers
net.core.rmem_default = 262144
net.core.rmem_max     = 134217728
net.core.wmem_default = 262144
net.core.wmem_max     = 134217728

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# 2) Queues and backlog
net.core.netdev_max_backlog = 250000
net.core.somaxconn          = 65535

# 3) Low latency & general TCP optimization
net.ipv4.tcp_fastopen  = 3
net.ipv4.tcp_low_latency = 1

# 4) IP forwarding & routing settings
net.ipv4.ip_forward = 1

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# 5) Conntrack (for NAT / firewall heavy setups)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# 6) General TCP behavior
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_sack           = 1

net.ipv4.tcp_tw_reuse   = 1
net.ipv4.tcp_tw_recycle = 0

net.ipv4.ip_local_port_range = 1024 65535

# 7) BBR congestion control (if supported by kernel)
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  optimize_nics_throughput

  log "General UDP + BBR profile applied. A reboot is recommended."
}

# -----------------------------------------------------------
# GAMING / CS2 PROFILE (original option 2)
# -----------------------------------------------------------
apply_cs2_gaming_profile() {
  log "Applying CS2 / gaming-oriented optimization profile..."

  backup_sysctl

  local SYSCTL_FILE="/etc/sysctl.d/99-gaming-cs2-tuning.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# GAMING / CS2-ORIENTED SYSTEM TUNING
# Focus: lower latency and more consistent frame times.
########################################################

# Keep TCP low latency
net.ipv4.tcp_low_latency = 1

# Slightly smaller minimum UDP buffers (reduce queuing)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Keep backlog decent but not extremely large (less queuing delay)
net.core.netdev_max_backlog = 65536

# Memory / swapping behavior (try to avoid swapping when gaming)
vm.swappiness = 10

# Keep dirty pages under tighter control for more consistent I/O
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Scheduler tweaks (optional, can improve responsiveness on some systems)
kernel.sched_min_granularity_ns = 10000000
kernel.sched_latency_ns         = 60000000
kernel.sched_migration_cost_ns  = 500000

EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  optimize_nics_low_latency

  # Helper for CS2 with higher priority
  local HELPER="/usr/local/bin/run_cs2_prio.sh"
  cat > "$HELPER" << 'EOF'
#!/usr/bin/env bash
# Example helper: run CS2 with higher CPU priority and CPU affinity.
# Adjust the command below to match your actual CS2 launch command (client or server).

CS2_CMD="$*"

if [[ -z "$CS2_CMD" ]]; then
  echo "Usage: run_cs2_prio.sh <your-cs2-command>"
  echo "Example (server): run_cs2_prio.sh ./cs2_server.sh"
  exit 1
fi

echo "Running CS2 with high priority on selected CPU cores..."
exec nice -n -5 taskset -c 0-3 $CS2_CMD
EOF

  chmod +x "$HELPER"

  log "CS2 / gaming profile applied. Reboot is recommended."
  log "Helper script created: /usr/local/bin/run_cs2_prio.sh"
}

# -----------------------------------------------------------
# SOCKS (Telegram) optimization profile – NEW OPTION
# -----------------------------------------------------------
apply_socks_telegram_profile() {
  log "Applying SOCKS (Telegram) optimization profile..."

  backup_sysctl

  local SYSCTL_FILE="/etc/sysctl.d/99-socks-telegram-tuning.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# SOCKS / TELEGRAM PROXY OPTIMIZATION
# Focus: many short TCP connections, low latency, low TIME_WAIT pressure.
########################################################

# Allow more pending connections
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Faster TIME_WAIT recycling / reuse (use with care, typical for high-load proxies)
net.ipv4.tcp_tw_reuse    = 1
net.ipv4.tcp_tw_recycle  = 0
net.ipv4.tcp_fin_timeout = 15

# Ephemeral port range – wide range for many connections
net.ipv4.ip_local_port_range = 1024 65535

# Enable syncookies to protect from SYN flood
net.ipv4.tcp_syncookies = 1

# Keepalive settings – reduce dead connections
net.ipv4.tcp_keepalive_time     = 600
net.ipv4.tcp_keepalive_intvl    = 30
net.ipv4.tcp_keepalive_probes   = 10

# Conntrack for NATed SOCKS proxies
net.netfilter.nf_conntrack_max                 = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 300
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  # Increase file descriptor limits (good for many SOCKS connections)
  local LIMITS_FILE="/etc/security/limits.d/99-socks-proxy.conf"
  cat > "$LIMITS_FILE" << 'EOF'
* soft nofile 512000
* hard nofile 512000
EOF

  log "SOCKS / Telegram profile applied."
  log "File descriptor limits updated in /etc/security/limits.d/99-socks-proxy.conf (relogin or reboot required)."
}

show_current_congestion_control() {
  echo "Current TCP congestion control:"
  sysctl net.ipv4.tcp_congestion_control
}

# -----------------------------------------------------------
# BACKHULE PREMIUM FUNCTIONS (templates)
# -----------------------------------------------------------

install_bbr_backhule_premium() {
  log "Installing BBR Backhule Premium profile..."

  local SYSCTL_FILE="/etc/sysctl.d/90-backhule-bbr.conf"

  cat > "$SYSCTL_FILE" << 'EOF'
########################################################
# Backhule Premium – BBR Profile
########################################################

net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# You can place your exact Backhule BBR tuning parameters here.
# This is a safe minimal BBR config; extend it with your original Backhule values.
EOF

  log "Reloading sysctl configuration..."
  sysctl --system

  log "Backhule BBR profile installed. Reboot is recommended."
}

uninstall_bbr_backhule() {
  log "Uninstalling Backhule BBR profile..."
  local SYSCTL_FILE="/etc/sysctl.d/90-backhule-bbr.conf"

  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    sysctl --system
    log "Backhule BBR profile removed."
  else
    log "Backhule BBR profile not found; nothing to remove."
  fi
}

install_wss_mux_backuhle_premium() {
  log "Installing Wss Mux Backuhle Premium..."

  # Detect interface / CIDR (if needed by your Wss Mux script)
  local IFACE CIDR
  read -r IFACE CIDR < <(get_iface_and_cidr)
  log "Detected interface: $IFACE, CIDR: $CIDR"

  # -------- PLACEHOLDER AREA --------
  # Put your real Wss Mux Backuhle install commands here.
  # For example (pseudo-code):
  #
  #  curl -o /usr/local/bin/wss-mux-backhule https://your-script-url
  #  chmod +x /usr/local/bin/wss-mux-backhule
  #  /usr/local/bin/wss-mux-backhule install --iface "$IFACE" --cidr "$CIDR"
  #
  # -----------------------------------

  log "Wss Mux Backuhle Premium install placeholder executed."
  log "Replace the placeholder block with your actual Wss Mux installation logic."
}

uninstall_wss_mux() {
  log "Uninstalling Wss Mux Backuhle Premium..."

  # -------- PLACEHOLDER AREA --------
  # Put your real Wss Mux uninstall commands here.
  # For example:
  #
  #  systemctl stop wss-mux-backhule.service || true
  #  systemctl disable wss-mux-backhule.service || true
  #  rm -f /etc/systemd/system/wss-mux-backhule.service
  #  rm -f /usr/local/bin/wss-mux-backhule
  #  systemctl daemon-reload
  #
  # -----------------------------------

  log "Wss Mux uninstall placeholder executed."
  log "Replace the placeholder block with your actual Wss Mux uninstall logic."
}

reboot_server() {
  log "Rebooting server..."
  reboot
}

# -----------------------------------------------------------
# MAIN MENU – Combined
# -----------------------------------------------------------
main_menu() {
  while true; do
    echo "======================================"
    echo "   Ultimate Network / Gaming / Backhule Menu"
    echo "======================================"
    echo "1) Apply GENERAL UDP + BBR optimization"
    echo "2) Apply GAMING (CS2-focused) optimization"
    echo "3) Apply SOCKS (Telegram) optimization"
    echo "4) Install BBR Backhule Premium"
    echo "5) Uninstall BBR Backhule Premium"
    echo "6) Install Wss Mux Backuhle Premium"
    echo "7) Uninstall Wss Mux Backuhle Premium"
    echo "8) Show current TCP congestion control"
    echo "9) Reboot server"
    echo "10) Exit"
    echo "--------------------------------------"
    read -rp "Choose an option [1-10]: " choice

    case "$choice" in
      1)
        apply_udp_bbr_profile
        ;;
      2)
        apply_cs2_gaming_profile
        ;;
      3)
        apply_socks_telegram_profile
        ;;
      4)
        install_bbr_backhule_premium
        ;;
      5)
        uninstall_bbr_backhule
        ;;
      6)
        install_wss_mux_backuhle_premium
        ;;
      7)
        uninstall_wss_mux
        ;;
      8)
        show_current_congestion_control
        ;;
      9)
        reboot_server
        ;;
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
