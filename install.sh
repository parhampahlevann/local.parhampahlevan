#!/usr/bin/env bash
# Cloudflare WARP Menu (Parham Enhanced Edition)
# Author: Parham Pahlevan
# Enhanced with multi-location, IPv6, and Germany default endpoint

# ========== Elevate to root automatically ==========
if [[ $EUID -ne 0 ]]; then
  echo "[*] Re-running this script as root using sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ========== Auto-install path ==========
SCRIPT_PATH="/usr/local/bin/warp-menu"

# Try to resolve current script path
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Detect if CURRENT_PATH is a regular file
if [[ "$CURRENT_PATH" != "$SCRIPT_PATH" ]]; then
  if [[ -f "$CURRENT_PATH" ]]; then
    echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
    cp "$CURRENT_PATH" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "[✓] Installed warp-menu to ${SCRIPT_PATH}"
    echo "[*] You can later run it with: warp-menu"
  else
    echo "[*] Running from a pipe/FD (e.g. bash <(curl ...)), skipping auto-install."
    echo "[*] If you want persistent install, save this script to a file and run it from there."
  fi
fi

# ========== Colors & Version ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
VERSION="3.2-parham-multiloc-ipv6-germany"

# ========== Global files ==========
SCAN_RESULT_FILE="/tmp/warp_cf_scan_last.csv"
BEST_ENDPOINTS_FILE="/tmp/warp_best_endpoints.txt"

CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
CURRENT_ENDPOINT_FILE="${CONFIG_DIR}/current_endpoint"
CONNECTION_LOG="${CONFIG_DIR}/connection.log"

mkdir -p "$CONFIG_DIR"
touch "$ENDPOINTS_FILE" 2>/dev/null || true
touch "$CONNECTION_LOG" 2>/dev/null || true

# ========== Logging function ==========
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CONNECTION_LOG"
}

# ========== Preload Cloudflare endpoints ==========
parham_warp_preload_endpoints() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo "[*] Preloading Cloudflare endpoints..."
        cat << EOF > "$ENDPOINTS_FILE"
Germany-1|188.114.98.10:2408
Germany-2|188.114.99.10:2408
Netherlands-1|162.159.192.10:2408
Netherlands-2|162.159.193.10:2408
Romania-1|188.114.96.10:2408
Romania-2|188.114.97.10:2408
France-1|162.159.195.10:2408
UK-1|162.159.204.10:2408
USA-1|162.159.208.10:2408
USA-2|162.159.209.10:2408
Switzerland-1|188.114.100.10:2408
Switzerland-2|188.114.101.10:2408
Italy-1|188.114.102.10:2408
Italy-2|188.114.103.10:2408
Spain-1|188.114.104.10:2408
Spain-2|188.114.105.10:2408
Poland-1|188.114.106.10:2408
Poland-2|188.114.107.10:2408
EOF
        echo "[✓] Loaded 18 Cloudflare endpoints from multiple countries."
    fi
}

# ========== Core Checks ==========
parham_warp_is_installed() {
    command -v warp-cli &>/dev/null
}

parham_warp_is_connected() {
    warp-cli status 2>/dev/null | grep -iq "Connected"
}

parham_warp_check_connection() {
    if ! parham_warp_is_installed; then
        echo -e "${RED}WARP is not installed. Please install it first.${NC}"
        return 1
    fi

    if ! parham_warp_is_connected; then
        echo -e "${YELLOW}WARP is not connected. Trying to connect...${NC}"
        parham_warp_connect
        sleep 3
        if ! parham_warp_is_connected; then
            echo -e "${RED}Cannot establish connection. Please check WARP service.${NC}"
            return 1
        fi
    fi
    return 0
}

# ========== Helpers ==========
parham_warp_ensure_proxy_mode() {
    warp-cli set-mode proxy 2>/dev/null || warp-cli mode proxy
    warp-cli set-proxy-port 10808 2>/dev/null || warp-cli proxy port 10808
    sleep 1
}

parham_warp_get_out_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""
    local timeout_sec=5

    local services=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ifconfig.me/ip"
        "https://ipecho.net/plain"
    )

    for service in "${services[@]}"; do
        ip=$(timeout "$timeout_sec" curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" "$service" 2>/dev/null | tr -d ' \r\n')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo ""
    return 1
}

parham_warp_get_out_ipv6() {
    # IPv6 خروجی از پشت وارب
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""
    local timeout_sec=8

    local services=(
        "https://ipv6.icanhazip.com"
        "https://api64.ipify.org"
        "https://ifconfig.co/ip"
    )

    for service in "${services[@]}"; do
        ip=$(timeout "$timeout_sec" curl -6 -s --socks5 "${proxy_ip}:${proxy_port}" "$service" 2>/dev/null)
        ip=$(echo "$ip" | tr -d ' \r\n')
        if [[ -n "$ip" && "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo ""
    return 1
}

parham_warp_get_out_geo() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local country=""
    local country_code=""
    local isp=""
    local asn=""

    # اول ip-api
    local raw
    raw=$(timeout 10 curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" \
        "http://ip-api.com/line/?fields=country,countryCode,isp,as" 2>/dev/null || true)

    if [[ -n "$raw" ]]; then
        country=$(echo "$raw" | sed -n '1p')
        country_code=$(echo "$raw" | sed -n '2p')
        isp=$(echo "$raw" | sed -n '3p')
        asn=$(echo "$raw" | sed -n '4p')
    else
        # fallback به ipinfo اگر jq نصب باشد
        if command -v jq >/dev/null 2>&1; then
            local json
            json=$(timeout 10 curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" \
                "https://ipinfo.io/json" 2>/dev/null || true)
            if [[ -n "$json" ]]; then
                country_code=$(echo "$json" | jq -r '.country // ""')
                country="$country_code"
                isp=$(echo "$json" | jq -r '.org // ""')
                asn="$isp"
            fi
        fi
    fi

    echo "${country}|${country_code}|${isp}|${asn}"
}

parham_warp_set_custom_endpoint() {
    local endpoint="$1"
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Endpoint is empty.${NC}"
        return 1
    fi

    echo -e "${CYAN}Setting custom endpoint to: ${YELLOW}${endpoint}${NC}"
    log_message "Setting endpoint: $endpoint"

    warp-cli clear-custom-endpoint 2>/dev/null || true
    sleep 1
    warp-cli set-custom-endpoint "$endpoint"
    sleep 2
}

parham_warp_clear_custom_endpoint() {
    echo -e "${CYAN}Clearing custom endpoint...${NC}"
    warp-cli clear-custom-endpoint 2>/dev/null || true
    sleep 2
}

parham_warp_restart_warp_service() {
    echo -e "${CYAN}Restarting WARP service...${NC}"
    systemctl restart warp-svc 2>/dev/null || true
    sleep 3
}

# ========== Core Functions ==========
parham_warp_install() {
    if parham_warp_is_installed && parham_warp_is_connected; then
        echo -e "${GREEN}WARP is already installed and connected.${NC}"
        read -r -p "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${CYAN}Installing WARP-CLI...${NC}"
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "")

    # اوبونتو ۲۴ (noble) رو به jammy مپ می‌کنیم مثل اسکریپت dev-ir
    if [[ -z "$codename" ]]; then
        codename="jammy"
    elif [[ "$codename" == "oracular" || "$codename" == "plucky" || "$codename" == "noble" ]]; then
        codename="jammy"
    fi

    apt update
    # Dependencies
    apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo jq bc iputils-ping

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt update
    apt install -y cloudflare-warp

    echo -e "${CYAN}Initializing WARP...${NC}"
    yes | warp-cli registration new 2>/dev/null || warp-cli registration new || warp-cli register
    parham_warp_ensure_proxy_mode
    warp-cli connect
    sleep 5

    # بعد از نصب، به صورت پیش‌فرض روی آلمان ست کن
    echo -e "${CYAN}Setting default endpoint to Germany (188.114.98.10:2408)...${NC}"
    parham_warp_disconnect
    parham_warp_set_custom_endpoint "188.114.98.10:2408"
    echo "Germany-1|188.114.98.10:2408" > "$CURRENT_ENDPOINT_FILE"
    warp-cli connect
    sleep 5

    if ! parham_warp_is_connected; then
        echo -e "${YELLOW}Germany endpoint failed. Falling back to auto endpoint.${NC}"
        parham_warp_clear_custom_endpoint
        warp-cli connect
        sleep 5
    fi

    echo -e "${GREEN}WARP installation completed!${NC}"
    parham_warp_status
}

parham_warp_connect() {
    echo -e "${BLUE}Connecting to WARP Proxy...${NC}"

    if ! parham_warp_is_installed; then
        echo -e "${RED}warp-cli is not installed. Run Install first.${NC}"
        return 1
    fi

    if ! warp-cli registration show >/dev/null 2>&1; then
        yes | warp-cli registration new 2>/dev/null || warp-cli registration new || warp-cli register
    fi

    parham_warp_ensure_proxy_mode
    warp-cli connect
    sleep 3

    local attempts=0
    while [[ $attempts -lt 10 ]] && ! parham_warp_is_connected; do
        sleep 1
        attempts=$((attempts + 1))
    done

    if parham_warp_is_connected; then
        echo -e "${GREEN}Connected to WARP${NC}"
    else
        echo -e "${RED}Failed to connect to WARP${NC}"
        return 1
    fi
}

parham_warp_disconnect() {
    echo -e "${YELLOW}Disconnecting WARP...${NC}"
    warp-cli disconnect 2>/dev/null || true
    sleep 2
}

parham_warp_status() {
    echo -e "${CYAN}=== WARP Status ===${NC}"
    if parham_warp_is_installed; then
        warp-cli status 2>/dev/null || echo -e "${RED}warp-cli status failed${NC}"
    else
        echo -e "${RED}warp-cli not installed${NC}"
    fi
    echo

    if parham_warp_is_connected; then
        echo -e "${CYAN}=== Connection Details ===${NC}"

        local ip4 ip6
        ip4=$(parham_warp_get_out_ip 2>/dev/null || echo "")
        ip6=$(parham_warp_get_out_ipv6 2>/dev/null || echo "")

        if [[ -n "$ip4" ]]; then
            echo -e "  ${GREEN}IPv4 (WARP Out):${NC} $ip4"
        else
            echo -e "  ${YELLOW}IPv4 (WARP Out):${NC} N/A"
        fi

        if [[ -n "$ip6" ]]; then
            echo -e "  ${GREEN}IPv6 (WARP Out / Cloudflare):${NC} $ip6"
        else
            echo -e "  ${YELLOW}IPv6 (WARP Out):${NC} Not available"
        fi

        local geo
        geo=$(parham_warp_get_out_geo 2>/dev/null || echo "")
        if [[ -n "$geo" ]]; then
            IFS='|' read -r country country_code isp asn <<< "$geo"
            [[ -n "$country" ]] && echo -e "  ${GREEN}Country:${NC} $country (${country_code})"
            [[ -n "$isp" ]] && echo -e "  ${GREEN}ISP:${NC} $isp"
            [[ -n "$asn" ]] && echo -e "  ${GREEN}ASN:${NC} $asn"

            if [[ "$country_code" == "TR" ]]; then
                echo -e "\n  ${YELLOW}Warning:${NC} Current exit location is ${RED}Turkey (TR)${NC}"
                echo -e "  Use multi-location endpoints to switch to another country."
            fi
        fi

        local endpoint_info
        endpoint_info=$(warp-cli settings 2>/dev/null | grep -i "endpoint" || true)
        if [[ -n "$endpoint_info" ]]; then
            echo -e "\n  ${GREEN}Endpoint:${NC} $(echo "$endpoint_info" | grep -o '[0-9.:]\+' | head -1)"
        fi

        echo -e "\n${CYAN}=== Proxy Test ===${NC}"
        if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "  ${GREEN}Proxy is working (IPv4)${NC}"
        else
            echo -e "  ${RED}Proxy IPv4 is not responding${NC}"
        fi

        if timeout 8 curl -6 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "  ${GREEN}Proxy is working (IPv6)${NC}"
        else
            echo -e "  ${YELLOW}IPv6 proxy test failed (may be unsupported on this network)${NC}"
        fi
    else
        echo -e "${YELLOW}WARP is not connected${NC}"
    fi
    echo
}

parham_warp_test_proxy() {
    echo -e "${CYAN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}"

    if ! parham_warp_check_connection; then
        return 1
    fi

    local services=(
        "Cloudflare:https://www.cloudflare.com"
        "Google:https://www.google.com"
        "IP Check v4:https://api.ipify.org"
    )

    for service in "${services[@]}"; do
        local name="${service%%:*}"
        local url="${service#*:}"

        echo -ne "  Testing $name (IPv4)... "
        if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 "$url" > /dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAIL${NC}"
        fi
    done

    echo -ne "  Testing IP Check v6 (https://api64.ipify.org)... "
    if timeout 8 curl -6 -s --socks5 127.0.0.1:10808 https://api64.ipify.org > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}IPv6 FAIL (maybe not available)${NC}"
    fi

    local ip4 ip6
    ip4=$(parham_warp_get_out_ip)
    ip6=$(parham_warp_get_out_ipv6)

    if [[ -n "$ip4" ]]; then
        echo -e "\n  ${GREEN}Current IPv4 (WARP):${NC} $ip4"
    else
        echo -e "\n  ${RED}Could not get IPv4${NC}"
    fi

    if [[ -n "$ip6" ]]; then
        echo -e "  ${GREEN}Current IPv6 (WARP / Cloudflare):${NC} $ip6"
    else
        echo -e "  ${YELLOW}No IPv6 address detected${NC}"
    fi
}

parham_warp_remove() {
    echo -e "${RED}Removing WARP...${NC}"

    warp-cli disconnect 2>/dev/null || true
    sleep 2

    apt remove --purge -y cloudflare-warp 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true

    echo -e "${GREEN}WARP removed successfully${NC}"
}

# ========== Change IP Functions ==========
parham_warp_quick_change_ip() {
    if ! parham_warp_check_connection; then
        return 1
    fi

    echo -e "${CYAN}Quick IP change (reconnect)...${NC}"
    local old_ip new_ip

    old_ip=$(parham_warp_get_out_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..3}; do
        echo -e "\nAttempt ${attempt}/3:"
        parham_warp_disconnect
        sleep 2
        parham_warp_connect
        sleep 3

        new_ip=$(parham_warp_get_out_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}New IP: $new_ip${NC}"
            return 0
        fi
    done

    echo -e "${YELLOW}IP did not change. Try 'New Identity' option.${NC}"
    return 1
}

parham_warp_new_identity() {
    if ! parham_warp_check_connection; then
        return 1
    fi

    echo -e "${CYAN}New Identity (full reset)...${NC}"
    local old_ip new_ip

    old_ip=$(parham_warp_get_out_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    parham_warp_disconnect

    warp-cli registration delete 2>/dev/null || true
    warp-cli clear-custom-endpoint 2>/dev/null || true
    sleep 2

    parham_warp_restart_warp_service

    yes | warp-cli registration new 2>/dev/null || warp-cli registration new || warp-cli register
    parham_warp_ensure_proxy_mode
    warp-cli connect
    sleep 5

    new_ip=$(parham_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}New Identity IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}IP remained the same: $new_ip${NC}"
        fi
    else
        echo -e "${RED}Failed to get new IP${NC}"
        return 1
    fi
}

# ========== Scanning Functions ==========
parham_warp_scan_cloudflare_ips() {
    echo -e "${CYAN}Scanning Cloudflare IPs...${NC}"
    echo -e "${YELLOW}Note: This may take a few minutes${NC}\n"

    read -r -p "Use default range 162.159.192.[0-255]? [Y/n]: " use_default
    local base="162.159.192"
    local start=0
    local end=255

    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        read -r -p "Base IP (e.g. 162.159.192): " base_input
        [[ -n "$base_input" ]] && base="$base_input"
        read -r -p "Start host (0-255): " s
        read -r -p "End host (0-255): " e
        [[ -n "$s" ]] && start="$s"
        [[ -n "$e" ]] && end="$e"
    fi

    read -r -p "Max IPs to find (default 20): " max_ok
    [[ -z "$max_ok" ]] && max_ok=20

    echo -e "\n${CYAN}Scanning ${base}.${start}-${end} ...${NC}"
    echo "IP,RTT(ms)" > "$SCAN_RESULT_FILE"

    local ok_count=0
    local total=$((end - start + 1))
    local current=0

    for i in $(seq "$start" "$end"); do
        current=$((current + 1))
        local ip="${base}.${i}"
        local progress=$((current * 100 / total))

        echo -ne "\rScanning: ${progress}% (${current}/${total}) - Found: ${ok_count}"

        local rtt
        rtt=$(ping -c 2 -W 1 "$ip" 2>/dev/null | awk -F'/' 'END{print $5}')

        if [[ -n "$rtt" ]]; then
            echo "$ip,$rtt" >> "$SCAN_RESULT_FILE"
            ok_count=$((ok_count + 1))

            if [[ "$ok_count" -ge "$max_ok" ]]; then
                echo -e "\n${GREEN}Found ${max_ok} IPs, stopping scan.${NC}"
                break
            fi
        fi
    done

    echo -e "\n\n${CYAN}Scan completed. Found ${ok_count} responsive IPs.${NC}"

    if [[ "$ok_count" -gt 0 ]]; then
        echo -e "\n${GREEN}Top 10 fastest IPs:${NC}"
        sort -t',' -k2 -n "$SCAN_RESULT_FILE" | head -10 | column -t -s ','

        echo -e "\n${CYAN}Saving best endpoints...${NC}"
        : > "$BEST_ENDPOINTS_FILE"
        sort -t',' -k2 -n "$SCAN_RESULT_FILE" | head -5 | while IFS=',' read -r ip rtt; do
            echo "${ip}:2408|${rtt}ms" >> "$BEST_ENDPOINTS_FILE"
        done

        echo -e "${GREEN}Best endpoints saved to:${NC} $BEST_ENDPOINTS_FILE"
    fi
}

parham_warp_select_ip_from_scan() {
    if [[ ! -f "$SCAN_RESULT_FILE" ]]; then
        echo -e "${RED}No scan results. Run scan first.${NC}"
        return 1
    fi

    echo -e "${CYAN}Select IP from scan results:${NC}"
    echo -e "${YELLOW}No.  IP              RTT(ms)${NC}"
    echo "--------------------------------"

    local sorted
    sorted=$(sort -t',' -k2 -n "$SCAN_RESULT_FILE")
    local count=0

    while IFS=',' read -r ip rtt; do
        count=$((count + 1))
        printf " %2d. %-15s %6s\n" "$count" "$ip" "$rtt"
        [[ $count -eq 20 ]] && break
    done <<< "$sorted"

    echo -e "\n${CYAN}Select IP (1-${count}, 0 to cancel):${NC} "
    read -r idx

    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    if [[ "$idx" -gt 0 && "$idx" -le "$count" ]]; then
        local selected
        selected=$(echo "$sorted" | sed -n "${idx}p")
        local ip="${selected%%,*}"

        echo -e "\n${CYAN}Selected IP: ${GREEN}$ip${NC}"
        read -r -p "Port (default 2408): " port
        [[ -z "$port" ]] && port=2408

        local endpoint="${ip}:${port}"

        echo -e "\n${CYAN}Applying endpoint...${NC}"
        parham_warp_disconnect
        parham_warp_set_custom_endpoint "$endpoint"
        warp-cli connect
        sleep 5

        echo -e "\n${GREEN}Endpoint applied successfully!${NC}"
        parham_warp_status
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

parham_warp_test_endpoint_speed() {
    if ! parham_warp_check_connection; then
        return 1
    fi

    echo -e "${CYAN}Testing endpoint speed...${NC}"

    local endpoint_info
    endpoint_info=$(warp-cli settings 2>/dev/null | grep -i "endpoint" || true)
    local endpoint=""

    if [[ -n "$endpoint_info" ]]; then
        endpoint=$(echo "$endpoint_info" | grep -o '[0-9.:]\+' | head -1)
        echo -e "Current endpoint: ${YELLOW}$endpoint${NC}"
    fi

    echo -e "\n${CYAN}Running speed test via proxy...${NC}"

    echo -ne "  Download speed: "
    local start_time download_time speed_mbps

    start_time=$(date +%s.%N)
    if curl -4 -s --socks5 127.0.0.1:10808 http://speedtest.ftp.otenet.gr/files/test100k.db > /dev/null 2>&1; then
        download_time=$(echo "$(date +%s.%N) - $start_time" | bc)
        if (( $(echo "$download_time > 0" | bc -l) )); then
            speed_mbps=$(echo "scale=2; 0.8 / $download_time" | bc)
            echo -e "${GREEN}${speed_mbps} Mbps${NC}"
        else
            echo -e "${YELLOW}Too fast to measure${NC}"
        fi
    else
        echo -e "${RED}Failed${NC}"
    fi

    echo -ne "  Latency to Cloudflare: "
    local latency
    latency=$(curl -4 -s --socks5 127.0.0.1:10808 -w "%{time_connect}\n" -o /dev/null https://www.cloudflare.com 2>/dev/null || echo "0")
    if [[ "$latency" != "0" ]]; then
        local latency_ms
        latency_ms=$(echo "$latency * 1000" | bc | cut -d. -f1)
        echo -e "${GREEN}${latency_ms} ms${NC}"
    else
        echo -e "${RED}Failed${NC}"
    fi
}

# ========== Multi-location Functions ==========
parham_warp_list_saved_endpoints() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints.${NC}"
        return 0
    fi

    local current_endpoint=""
    [[ -f "$CURRENT_ENDPOINT_FILE" ]] && current_endpoint=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)

    echo -e "${CYAN}Saved endpoints:${NC}"
    echo "----------------------------------------"

    local i=1
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue

        local mark=" "
        if [[ "${name}|${endpoint}" == "$current_endpoint" ]]; then
            mark="*"
        fi

        printf " %2d. %-20s %s %s\n" "$i" "$name" "$endpoint" "$mark"
        i=$((i + 1))
    done < "$ENDPOINTS_FILE"

    [[ -n "$current_endpoint" ]] && echo -e "\n* Currently active endpoint"
}

parham_warp_add_saved_endpoint() {
    echo -e "${CYAN}Add new endpoint${NC}"
    echo -e "${YELLOW}Example: Germany-Frankfurt-1|188.114.98.10:2408${NC}"

    read -r -p "Name/Label: " name
    [[ -z "$name" ]] && {
        echo -e "${RED}Name is required.${NC}"
        return 1
    }

    read -r -p "Endpoint (IP:PORT): " endpoint
    [[ -z "$endpoint" ]] && {
        echo -e "${RED}Endpoint is required.${NC}"
        return 1
    }

    if ! [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}Invalid endpoint format. Use IP:PORT${NC}"
        return 1
    fi

    echo "${name}|${endpoint}" >> "$ENDPOINTS_FILE"
    echo -e "${GREEN}Endpoint added: ${name} -> ${endpoint}${NC}"
}

parham_warp_apply_saved_endpoint() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints.${NC}"
        return 1
    fi

    parham_warp_list_saved_endpoints
    echo

    local count
    count=$(wc -l < "$ENDPOINTS_FILE")

    read -r -p "Select endpoint (1-${count}, 0 to cancel): " idx

    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    if [[ "$idx" -gt 0 && "$idx" -le "$count" ]]; then
        local selected
        selected=$(sed -n "${idx}p" "$ENDPOINTS_FILE")
        local name="${selected%%|*}"
        local endpoint="${selected#*|}"

        echo -e "\n${CYAN}Applying endpoint: ${YELLOW}${name}${NC}"
        echo -e "Endpoint: ${GREEN}${endpoint}${NC}"

        log_message "Applying endpoint: $name -> $endpoint"

        parham_warp_disconnect
        parham_warp_set_custom_endpoint "$endpoint"

        echo "$name|$endpoint" > "$CURRENT_ENDPOINT_FILE"

        warp-cli connect
        sleep 5

        if parham_warp_is_connected; then
            echo -e "${GREEN}Successfully applied endpoint!${NC}"

            local new_ip
            new_ip=$(parham_warp_get_out_ip)
            if [[ -n "$new_ip" ]]; then
                echo -e "${GREEN}New IP: ${new_ip}${NC}"

                local geo
                geo=$(parham_warp_get_out_geo 2>/dev/null || true)
                if [[ -n "$geo" ]]; then
                    IFS='|' read -r country country_code isp asn <<< "$geo"
                    echo -e "${CYAN}Location: ${country} (${country_code})${NC}"
                fi
            fi
        else
            echo -e "${RED}Failed to connect with new endpoint${NC}"
        fi
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

parham_warp_rotate_endpoint() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints.${NC}"
        return 1
    fi

    local current=""
    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
        current=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
    fi

    local current_idx=0 idx=1
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        if [[ "$current" == "${name}|${endpoint}" ]]; then
            current_idx=$idx
            break
        fi
        idx=$((idx + 1))
    done < "$ENDPOINTS_FILE"

    local total
    total=$(grep -c '|' "$ENDPOINTS_FILE")

    local next_idx=$((current_idx % total + 1))

    local next_endpoint
    next_endpoint=$(sed -n "${next_idx}p" "$ENDPOINTS_FILE")
    local next_name="${next_endpoint%%|*}"
    local next_addr="${next_endpoint#*|}"

    echo -e "${CYAN}Rotating endpoint...${NC}"
    echo -e "Current: ${YELLOW}$(echo "$current" | cut -d'|' -f1)${NC}"
    echo -e "Next: ${GREEN}${next_name}${NC}"

    parham_warp_disconnect
    parham_warp_set_custom_endpoint "$next_addr"
    echo "$next_name|$next_addr" > "$CURRENT_ENDPOINT_FILE"
    warp-cli connect
    sleep 5

    if parham_warp_is_connected; then
        echo -e "${GREEN}Rotated to: ${next_name}${NC}"
        local new_ip
        new_ip=$(parham_warp_get_out_ip)
        [[ -n "$new_ip" ]] && echo -e "${GREEN}New IP: ${new_ip}${NC}"
    else
        echo -e "${RED}Rotation failed${NC}"
    fi
}

parham_warp_multilocation_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Multi-location Endpoints ===${NC}"
        echo -e "${YELLOW}Manage your WARP endpoints for different locations${NC}\n"

        parham_warp_list_saved_endpoints
        echo

        echo -e "${GREEN}Options:${NC}"
        echo " 1) Add new endpoint"
        echo " 2) Apply endpoint"
        echo " 3) Delete endpoint"
        echo " 4) Rotate to next endpoint"
        echo " 5) Test current endpoint speed"
        echo " 0) Back to main menu"
        echo

        read -r -p "Select option: " choice

        case $choice in
            1) parham_warp_add_saved_endpoint ;;
            2) parham_warp_apply_saved_endpoint ;;
            3)
                echo -e "${YELLOW}Deleting endpoints is not implemented yet.${NC}"
                echo -e "Edit this file manually if needed: $ENDPOINTS_FILE"
                sleep 2
                ;;
            4) parham_warp_rotate_endpoint ;;
            5) parham_warp_test_endpoint_speed ;;
            0) break ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac

        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
    done
}

# ========== Main Menu ==========
parham_warp_draw_menu() {
    clear

    local status_color status_text
    local current_ip="N/A"
    local location=""

    if parham_warp_is_connected; then
        status_color="$GREEN"
        status_text="CONNECTED"
        current_ip=$(parham_warp_get_out_ip 2>/dev/null || echo "N/A")

        local geo
        geo=$(parham_warp_get_out_geo 2>/dev/null || true)
        if [[ -n "$geo" ]]; then
            IFS='|' read -r country _ _ _ <<< "$geo"
            location="$country"
        fi
    else
        status_color="$RED"
        status_text="DISCONNECTED"
    fi

    local endpoint_info="Auto"
    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
        local current
        current=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
        if [[ -n "$current" ]]; then
            endpoint_info=$(echo "$current" | cut -d'|' -f1)
        fi
    fi

    cat << EOF
${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}
${CYAN}║         ${BOLD}WARP Manager v${VERSION} - Enhanced Edition${NC}           ${CYAN}║${NC}
${CYAN}║                    ${BOLD}by Parham Pahlevan${NC}                       ${CYAN}║${NC}
${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}

${GREEN}Status:${NC} ${status_color}${status_text}${NC}
${GREEN}Current IP (IPv4):${NC} ${YELLOW}${current_ip}${NC}
${GREEN}Location:${NC} ${CYAN}${location:-Unknown}${NC}
${GREEN}Endpoint:${NC} ${PURPLE}${endpoint_info}${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BOLD}Main Options:${NC}
 ${GREEN}1${NC}) Install WARP
 ${GREEN}2${NC}) Status & Info
 ${GREEN}3${NC}) Test Proxy
 ${GREEN}4${NC}) Remove WARP
 ${GREEN}5${NC}) Quick IP Change
 ${GREEN}6${NC}) New Identity

${BOLD}Advanced Options:${NC}
 ${GREEN}7${NC}) Scan Cloudflare IPs
 ${GREEN}8${NC}) Apply Scanned IP
 ${GREEN}9${NC}) Manual Endpoint
 ${GREEN}10${NC}) Multi-location Manager

${RED}0${NC}) Exit

${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
}

parham_warp_main_menu() {
    parham_warp_preload_endpoints

    while true; do
        parham_warp_draw_menu
        echo -ne "${YELLOW}Select option: ${NC}"
        read -r choice

        case $choice in
            1) parham_warp_install ;;
            2) parham_warp_status ;;
            3) parham_warp_test_proxy ;;
            4) parham_warp_remove ;;
            5) parham_warp_quick_change_ip ;;
            6) parham_warp_new_identity ;;
            7) parham_warp_scan_cloudflare_ips ;;
            8) parham_warp_select_ip_from_scan ;;
            9)
                echo -e "${CYAN}Manual endpoint setup${NC}"
                read -r -p "Enter IP:PORT (e.g. 188.114.98.10:2408): " manual_endpoint
                if [[ -n "$manual_endpoint" ]]; then
                    parham_warp_disconnect
                    parham_warp_set_custom_endpoint "$manual_endpoint"
                    echo "Manual|$manual_endpoint" > "$CURRENT_ENDPOINT_FILE"
                    warp-cli connect
                    sleep 5
                    parham_warp_status
                fi
                ;;
            10) parham_warp_multilocation_menu ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 2
                ;;
        esac

        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
    done
}

# ========== Start the script ==========
if [[ $# -eq 0 ]]; then
    parham_warp_main_menu
else
    case $1 in
        install) parham_warp_install ;;
        status) parham_warp_status ;;
        connect) parham_warp_connect ;;
        disconnect) parham_warp_disconnect ;;
        rotate) parham_warp_rotate_endpoint ;;
        scan) parham_warp_scan_cloudflare_ips ;;
        *) parham_warp_main_menu ;;
    esac
fi
