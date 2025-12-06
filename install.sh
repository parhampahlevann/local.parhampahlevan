#!/bin/bash
#
# Backhule Premium Menu
# 1) Install BBR Backhule Premium
# 2) Uninstall BBR
# 3) Install Wss Mux Backuhle Premium
# 4) Uninstall Wss Mux
# 5) Reboot server
# 6) Exit
#

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

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

# -----------------------------------------------------------
# Shared: get default interface and auto /24 CIDR
# -----------------------------------------------------------
get_iface_and_cidr() {
  local IFACE
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}') || die "Cannot detect default interface."
  local IP_ADDR
  IP_ADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1) || die "Cannot read IP for interface $IFACE."
  local BASE
  BASE=$(echo "$IP_ADDR" | cut -d. -f1-3)
  local CIDR="${BASE}.0/24"
  echo "$IFACE" "$CIDR"
}

# -----------------------------------------------------------
# 1) Install BBR Backhule Premium (original optimize script)
# -----------------------------------------------------------

declare -A sysctl_opts=(
  # Queueing: prefer cake, fallback to fq_codel if unsupported
  ["net.core.default_qdisc"]="cake"

  # Congestion Control
  ["net.ipv4.tcp_congestion_control"]="bbr"

  # TCP Fast Open
  ["net.ipv4.tcp_fastopen"]="3"

  # MTU Probing
  ["net.ipv4.tcp_mtu_probing"]="1"

  # Window Scaling
  ["net.ipv4.tcp_window_scaling"]="1"

  # Backlog / SYN Queue
  ["net.core.somaxconn"]="1024"
  ["net.ipv4.tcp_max_syn_backlog"]="2048"
  ["net.core.netdev_max_backlog"]="500000"

  # Buffer sizes
  ["net.core.rmem_default"]="262144"
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_default"]="262144"
  ["net.core.wmem_max"]="134217728"
  ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
  ["net.ipv4.tcp_wmem"]="4096 65536 67108864"

  # TIME-WAIT reuse
  ["net.ipv4.tcp_tw_reuse"]="1"
  # ["net.ipv4.tcp_tw_recycle"]="1"   # Disabled to avoid NAT issues

  # FIN_TIMEOUT and Keepalive
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_keepalive_time"]="300"
  ["net.ipv4.tcp_keepalive_intvl"]="30"
  ["net.ipv4.tcp_keepalive_probes"]="5"

  # TCP No Metrics Save
  ["net.ipv4.tcp_no_metrics_save"]="1"
)

install_bbr_backhule_premium() {
  log "Starting network tuning for low-latency and throughput..."

  log "Applying sysctl settings..."
  for key in "${!sysctl_opts[@]}"; do
    value="${sysctl_opts[$key]}"

    if sysctl -w "$key=$value" >/dev/null 2>&1; then
      grep -qxF "$key = $value" /etc/sysctl.conf || echo "$key = $value" >> /etc/sysctl.conf
      log "Applied and saved: $key = $value"
    else
      if [[ "$key" == "net.core.default_qdisc" ]]; then
        fallback="fq_codel"
        sysctl -w "$key=$fallback" >/dev/null 2>&1 || die "Cannot set $key to $fallback"
        grep -qxF "$key = $fallback" /etc/sysctl.conf || echo "$key = $fallback" >> /etc/sysctl.conf
        log "Fallback applied for $key: $fallback"
      else
        die "Failed to apply sysctl: $key=$value"
      fi
    fi
  done

  sysctl -p >/dev/null 2>&1 || die "Failed to reload sysctl"
  log "All sysctl settings applied and saved."

  log "Loading tcp_bbr module..."
  if ! lsmod | grep -q '^tcp_bbr'; then
    modprobe tcp_bbr || die "Failed to load tcp_bbr module"
    echo "tcp_bbr" >/etc/modules-load.d/bbr.conf
    log "tcp_bbr loaded and set for boot."
  else
    log "tcp_bbr module was already loaded."
  fi

  read IFACE CIDR < <(get_iface_and_cidr)
  log "Default interface: $IFACE   Auto CIDR: $CIDR"

  current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
  if [ "$current_mtu" != "1420" ]; then
    ip link set dev "$IFACE" mtu 1420 || die "Failed to set MTU to 1420 for $IFACE"
    log "MTU set to 1420 for $IFACE"
  else
    log "MTU for $IFACE already set to 1420."
  fi

  if ! ip route show | grep -qw "$CIDR"; then
    ip route add "$CIDR" dev "$IFACE" || die "Failed to add route $CIDR to $IFACE"
    log "Route $CIDR added to interface $IFACE."
  else
    log "Route $CIDR already exists."
  fi

  log "Disabling NIC offloads on $IFACE..."
  ethtool -K "$IFACE" gro off gso off tso off lro off \
    && log "Offloads disabled." \
    || log "Warning: NIC offloads not supported or already disabled."

  log "Reducing interrupt coalescing on $IFACE..."
  ethtool -C "$IFACE" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 \
    && log "Interrupt coalescing configured for 1 interrupt per packet." \
    || log "Warning: coalescing not supported or not configurable."

  log "Assigning IRQ affinity for $IFACE to CPU core #1..."
  for irq in $(grep -R "$IFACE" /proc/interrupts | awk -F: '{print $1}'); do
    echo 2 > /proc/irq/"$irq"/smp_affinity \
      && log "Assigned IRQ $irq to CPU core #1." \
      || log "Warning: Failed to assign IRQ $irq to core #1."
  done

  log "All low-latency and throughput settings have been applied."
  log "To verify:"
  log "  • TCP Congestion Control:  sysctl net.ipv4.tcp_congestion_control"
  log "  • MTU:                     ip link show $IFACE"
  log "  • Route /24:               ip route show | grep \"$CIDR\""
  log "  • Offloads:                ethtool -k $IFACE | grep -E 'gso|gro|tso|lro'"
  log "  • Coalescing:              ethtool -c $IFACE"
  log "  • IRQ affinity:            grep \"$IFACE\" /proc/interrupts"

  echo -e "\n\e[34m>>> Settings applied. Now test with ping and iperf3.\e[0m\n"
}

# -----------------------------------------------------------
# 2) Uninstall BBR – revert settings as much as possible
# -----------------------------------------------------------
uninstall_bbr() {
  log "Reverting BBR and network tuning settings (best effort)..."

  for key in "${!sysctl_opts[@]}"; do
    sed -i "/^$key = /d" /etc/sysctl.conf 2>/dev/null || true
  done

  sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_fastopen=1 >/dev/null 2>&1 || true
  sysctl -p >/dev/null 2>&1 || log "Warning: failed to reload sysctl"

  rm -f /etc/modules-load.d/bbr.conf
  if lsmod | grep -q '^tcp_bbr'; then
    modprobe -r tcp_bbr 2>/dev/null || log "Warning: could not unload tcp_bbr module"
  fi

  read IFACE CIDR < <(get_iface_and_cidr)
  log "Default interface: $IFACE   Auto CIDR: $CIDR"

  current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
  if [ "$current_mtu" != "1500" ]; then
    ip link set dev "$IFACE" mtu 1500 2>/dev/null || log "Warning: failed to reset MTU to 1500 for $IFACE"
  fi

  if ip route show | grep -qw "$CIDR"; then
    ip route del "$CIDR" dev "$IFACE" 2>/dev/null || log "Warning: failed to delete route $CIDR"
  fi

  ethtool -K "$IFACE" gro on gso on tso on lro on 2>/dev/null || log "Warning: could not re-enable NIC offloads"
  ethtool -C "$IFACE" rx-usecs 0 rx-frames 0 tx-usecs 0 tx-frames 0 2>/dev/null || log "Warning: could not reset interrupt coalescing"

  local nproc mask
  nproc=$(nproc 2>/dev/null || echo 1)
  mask=$(printf "%x" $(( (1 << nproc) - 1 )))
  for irq in $(grep -R "$IFACE" /proc/interrupts | awk -F: '{print $1}'); do
    echo "$mask" > /proc/irq/"$irq"/smp_affinity 2>/dev/null || log "Warning: failed to reset IRQ $irq affinity"
  done

  log "Uninstall BBR & revert completed (best effort). A reboot is recommended."
}

# -----------------------------------------------------------
# 3) Install Wss Mux Backuhle Premium (write TOML configs)
# -----------------------------------------------------------
install_wss_mux_backuhle_premium() {
  log "Installing Wss Mux Backuhle Premium configs..."

  cat >/root/wssmux_server.toml <<'EOF'
[server]
bind_addr = "0.0.0.0:443"
transport = "wssmux"
token = "your_token" 
keepalive_period = 75
nodelay = true 
heartbeat = 40 
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768 
mux_recievebuffer = 4194304
mux_streambuffer = 65536 
tls_cert = "/root/server.crt"      
tls_key = "/root/server.key"
sniffer = false 
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
ports = []
EOF

  cat >/root/wssmux_client.toml <<'EOF'
[client]
remote_addr = "0.0.0.0:443"
edge_ip = "" 
transport = "wssmux"
token = "your_token" 
keepalive_period = 75
dial_timeout = 10
nodelay = true
retry_interval = 3
connection_pool = 8
aggressive_pool = false
mux_version = 1
mux_framesize = 32768 
mux_recievebuffer = 4194304
mux_streambuffer = 65536  
sniffer = false 
web_port = 2060
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF

  log "Wss Mux Backuhle Premium configs created:"
  log "  • /root/wssmux_server.toml"
  log "  • /root/wssmux_client.toml"
  echo -e "\n\e[34m>>> You can now point your WSS Mux binary to these TOML configs.\e[0m\n"
}

# -----------------------------------------------------------
# 4) Uninstall Wss Mux – remove TOML configs
# -----------------------------------------------------------
uninstall_wss_mux() {
  log "Uninstalling Wss Mux Backuhle Premium configs..."
  rm -f /root/wssmux_server.toml /root/wssmux_client.toml
  log "Configs removed (if they existed):"
  log "  • /root/wssmux_server.toml"
  log "  • /root/wssmux_client.toml"
}

# -----------------------------------------------------------
# Menu
# -----------------------------------------------------------

while true; do
  echo -e "\n\e[36m===== Backhule Premium Menu =====\e[0m"
  echo "1) Install BBR Backhule Premium"
  echo "2) Uninstall BBR"
  echo "3) Install Wss Mux Backuhle Premium"
  echo "4) Uninstall Wss Mux"
  echo "5) Reboot server"
  echo "6) Exit"
  read -rp "Enter your choice [1-6]: " choice

  case "$choice" in
    1)
      install_bbr_backhule_premium
      ;;
    2)
      uninstall_bbr
      ;;
    3)
      install_wss_mux_backuhle_premium
      ;;
    4)
      uninstall_wss_mux
      ;;
    5)
      log "Rebooting server..."
      reboot
      ;;
    6)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid choice, please select 1–6."
      ;;
  esac
done
