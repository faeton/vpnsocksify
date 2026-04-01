#!/usr/bin/env bash
set -euo pipefail

# =============================================
# vpnsocksifier entrypoint
# =============================================

# Default configuration
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
VPN_CONFIG_DIR="${VPN_CONFIG_DIR:-/config}"
VPN_CONFIG="${VPN_CONFIG:-}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1,8.8.8.8}"
KILL_SWITCH="${KILL_SWITCH:-true}"
VPN_LOG_LEVEL="${VPN_LOG_LEVEL:-3}"
VPN_USER="${VPN_USER:-}"
VPN_PASS="${VPN_PASS:-}"
CONNECTION_TEST_URL="${CONNECTION_TEST_URL:-https://api.ipify.org}"
CONNECTION_TEST_TIMEOUT="${CONNECTION_TEST_TIMEOUT:-60}"

# Global state
VPN_TYPE=""
WG_INTERFACE=""
VPN_CONFIG_FILE=""

# =============================================
# VPN type detection
# =============================================
detect_vpn_type() {
    # If a specific config is requested, detect type from that file only
    if [[ -n "$VPN_CONFIG" ]]; then
        local f="$VPN_CONFIG_DIR/$VPN_CONFIG"
        if [[ ! -f "$f" ]]; then
            echo "unknown"
            return
        fi
        case "$f" in
            *.ovpn) echo "openvpn"; return ;;
        esac
        if grep -q '^\[Interface\]' "$f" 2>/dev/null; then
            echo "wireguard"
            return
        fi
        if grep -qE '^(client|remote |proto |dev )' "$f" 2>/dev/null; then
            echo "openvpn"
            return
        fi
        echo "unknown"
        return
    fi

    # Check for WireGuard configs (wg*.conf with [Interface] section)
    for f in "$VPN_CONFIG_DIR"/wg*.conf; do
        if [[ -f "$f" ]] && grep -q '^\[Interface\]' "$f" 2>/dev/null; then
            echo "wireguard"
            return
        fi
    done

    # Check for .ovpn files
    for f in "$VPN_CONFIG_DIR"/*.ovpn; do
        if [[ -f "$f" ]]; then
            echo "openvpn"
            return
        fi
    done

    # Check remaining .conf files
    for f in "$VPN_CONFIG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -q '^\[Interface\]' "$f" 2>/dev/null; then
            echo "wireguard"
            return
        fi
        if grep -qE '^(client|remote |proto |dev )' "$f" 2>/dev/null; then
            echo "openvpn"
            return
        fi
    done

    echo "unknown"
}

# =============================================
# Parse VPN endpoints from config files
# =============================================
parse_vpn_endpoints() {
    # Returns lines of "ip port proto" for kill switch rules
    if [[ "$VPN_TYPE" == "openvpn" ]]; then
        local proto="udp"
        if grep -qE '^proto[[:space:]]+tcp' "$VPN_CONFIG_FILE" 2>/dev/null; then
            proto="tcp"
        fi
        grep -E '^remote[[:space:]]+' "$VPN_CONFIG_FILE" | while read -r _ host port _rest; do
            echo "$host ${port:-1194} $proto"
        done
    elif [[ "$VPN_TYPE" == "wireguard" ]]; then
        grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$VPN_CONFIG_FILE" | while read -r line; do
            local endpoint
            endpoint=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            local host="${endpoint%:*}"
            local port="${endpoint##*:}"
            echo "$host ${port:-51820} udp"
        done
    fi
}

# =============================================
# Kill switch (iptables)
# =============================================
setup_kill_switch() {
    local docker_subnet
    docker_subnet=$(ip route | grep 'dev eth0' | awk '{print $1}' | head -1 || echo "")

    echo "[killswitch] Setting up iptables kill switch..."
    echo "[killswitch] Docker subnet: ${docker_subnet:-unknown}"

    # Flush existing filter rules (preserve Docker's NAT rules for port forwarding)
    iptables -F
    iptables -X 2>/dev/null || true

    # Default policy: DROP
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow SOCKS5 connections inbound (from Docker network + port-mapped host)
    iptables -A INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT
    iptables -A OUTPUT -p tcp --sport "$SOCKS_PORT" -m conntrack --ctstate ESTABLISHED -j ACCEPT

    # Allow FORWARD for Docker port-mapped traffic to SOCKS port
    iptables -A FORWARD -p tcp --dport "$SOCKS_PORT" -j ACCEPT
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS on eth0 (needed for VPN server hostname resolution and connectivity tests)
    iptables -A OUTPUT -o eth0 -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -o eth0 -p tcp --dport 53 -j ACCEPT

    # Allow VPN endpoints parsed from config
    local has_endpoints=false
    while IFS=' ' read -r host port proto; do
        [[ -z "$host" ]] && continue
        has_endpoints=true

        # Resolve hostname to IP if needed
        local ip="$host"
        if ! echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            ip=$(dig +short "$host" A | head -1 || echo "$host")
        fi

        local iptables_proto="udp"
        [[ "$proto" == "tcp" ]] && iptables_proto="tcp"

        echo "[killswitch] Allowing VPN endpoint: $ip:$port/$iptables_proto"
        iptables -A OUTPUT -o eth0 -d "$ip" -p "$iptables_proto" --dport "$port" -j ACCEPT
    done < <(parse_vpn_endpoints)

    # Fallback: if no endpoints parsed, allow common VPN ports
    if [[ "$has_endpoints" == "false" ]]; then
        echo "[killswitch] No endpoints parsed, allowing common VPN ports"
        iptables -A OUTPUT -o eth0 -p udp --dport 1194 -j ACCEPT
        iptables -A OUTPUT -o eth0 -p tcp --dport 443 -j ACCEPT
        iptables -A OUTPUT -o eth0 -p tcp --dport 1194 -j ACCEPT
        iptables -A OUTPUT -o eth0 -p udp --dport 443 -j ACCEPT
        iptables -A OUTPUT -o eth0 -p udp --dport 51820 -j ACCEPT
    fi

    # Allow ALL traffic through VPN tunnel interfaces
    iptables -A INPUT -i tun+ -j ACCEPT
    iptables -A OUTPUT -o tun+ -j ACCEPT
    iptables -A INPUT -i wg+ -j ACCEPT
    iptables -A OUTPUT -o wg+ -j ACCEPT

    # Block IPv6 entirely to prevent leaks
    ip6tables -F 2>/dev/null || true
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

    echo "[killswitch] Kill switch active."
}

# =============================================
# DNS configuration
# =============================================
setup_dns() {
    echo "[dns] Configuring DNS servers: $DNS_SERVERS"
    : > /etc/resolv.conf
    IFS=',' read -ra servers <<< "$DNS_SERVERS"
    for server in "${servers[@]}"; do
        server=$(echo "$server" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "nameserver $server" >> /etc/resolv.conf
    done
}

# =============================================
# Find config file
# =============================================
find_openvpn_config() {
    for f in "$VPN_CONFIG_DIR"/*.ovpn; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return
        fi
    done
    for f in "$VPN_CONFIG_DIR"/*.conf; do
        if [[ -f "$f" ]] && ! grep -q '^\[Interface\]' "$f" 2>/dev/null; then
            echo "$f"
            return
        fi
    done
}

find_wireguard_config() {
    for f in "$VPN_CONFIG_DIR"/wg*.conf "$VPN_CONFIG_DIR"/*.conf; do
        if [[ -f "$f" ]] && grep -q '^\[Interface\]' "$f" 2>/dev/null; then
            echo "$f"
            return
        fi
    done
}

# =============================================
# OpenVPN
# =============================================
start_openvpn() {
    echo "[openvpn] Using config: $VPN_CONFIG_FILE"

    local auth_args=()
    if [[ -n "$VPN_USER" && -n "$VPN_PASS" ]]; then
        echo "[openvpn] Setting up authentication from environment variables"
        printf '%s\n%s\n' "$VPN_USER" "$VPN_PASS" > /tmp/vpn-auth.txt
        chmod 600 /tmp/vpn-auth.txt
        auth_args=(--auth-user-pass /tmp/vpn-auth.txt)
    fi

    openvpn \
        --config "$VPN_CONFIG_FILE" \
        --verb "$VPN_LOG_LEVEL" \
        --auth-nocache \
        --pull-filter ignore "ifconfig-ipv6" \
        --pull-filter ignore "route-ipv6" \
        "${auth_args[@]}" \
        --daemon --writepid /var/run/openvpn.pid \
        --log /var/log/openvpn.log \
        || {
            echo "[openvpn] ERROR: Failed to start OpenVPN"
            [[ -f /var/log/openvpn.log ]] && cat /var/log/openvpn.log
            exit 1
        }

    echo "[openvpn] Started, waiting for tunnel..."
}

# =============================================
# WireGuard
# =============================================
start_wireguard() {
    echo "[wireguard] Using config: $VPN_CONFIG_FILE"

    local iface_name
    iface_name=$(basename "$VPN_CONFIG_FILE" .conf)
    WG_INTERFACE="$iface_name"

    mkdir -p /etc/wireguard
    cp "$VPN_CONFIG_FILE" "/etc/wireguard/${iface_name}.conf"
    chmod 600 "/etc/wireguard/${iface_name}.conf"

    wg-quick up "$iface_name"
    echo "[wireguard] Interface $iface_name is up."
}

# =============================================
# Wait for VPN connection
# =============================================
wait_for_vpn() {
    local max_wait="$CONNECTION_TEST_TIMEOUT"
    local elapsed=0
    local interface

    if [[ "$VPN_TYPE" == "openvpn" ]]; then
        interface="tun0"
    else
        interface="${WG_INTERFACE:-wg0}"
    fi

    echo "[vpncheck] Waiting for interface $interface (max ${max_wait}s)..."

    while [[ $elapsed -lt $max_wait ]]; do
        if ip link show "$interface" &>/dev/null; then
            if [[ $elapsed -eq 0 ]] || (( elapsed % 10 == 0 )); then
                echo "[vpncheck] Interface $interface is up (${elapsed}s elapsed)"
            fi

            # Try connectivity test
            local public_ip
            public_ip=$(curl -sf --max-time 10 "$CONNECTION_TEST_URL" 2>/dev/null || echo "")

            if [[ -n "$public_ip" ]]; then
                echo "[vpncheck] VPN is working. Public IP: $public_ip"
                return 0
            fi
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    echo "[vpncheck] ERROR: VPN failed to establish within ${max_wait}s"
    if [[ "$VPN_TYPE" == "openvpn" && -f /var/log/openvpn.log ]]; then
        echo "[vpncheck] OpenVPN log (last 30 lines):"
        tail -30 /var/log/openvpn.log
    fi
    # Debug: show routing and DNS state
    echo "[vpncheck] Routes:"
    ip route 2>/dev/null || true
    echo "[vpncheck] DNS:"
    cat /etc/resolv.conf 2>/dev/null || true
    echo "[vpncheck] Interfaces:"
    ip -o link show 2>/dev/null || true
    exit 1
}

# =============================================
# SOCKS5 proxy (Dante)
# =============================================
generate_sockd_conf() {
    local auth_method

    if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
        echo "[socks] Authentication enabled for user: $SOCKS_USER"
        adduser -D -H -s /sbin/nologin "$SOCKS_USER" 2>/dev/null || true
        echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd 2>/dev/null
        auth_method="username"
    else
        echo "[socks] Authentication disabled (no SOCKS_USER/SOCKS_PASS set)"
        auth_method="none"
    fi

    # Detect the VPN tunnel interface
    local external_if
    external_if=$(ip -o link show | awk -F'[ :]+' '/tun[0-9]|wg[0-9]/{print $2; exit}')
    external_if="${external_if:-tun0}"

    export SOCKS_PORT
    export SOCKS_AUTH_METHOD="$auth_method"
    export EXTERNAL_INTERFACE="$external_if"

    envsubst '${SOCKS_PORT} ${SOCKS_AUTH_METHOD} ${EXTERNAL_INTERFACE}' \
        < /app/sockd.conf.template > /etc/sockd.conf

    echo "[socks] Dante config generated (external: $external_if, port: $SOCKS_PORT, auth: $auth_method)"
}

# =============================================
# Graceful shutdown
# =============================================
cleanup() {
    echo "[shutdown] Received shutdown signal, cleaning up..."

    # Stop dante
    if [[ -f /var/run/sockd.pid ]]; then
        kill "$(cat /var/run/sockd.pid)" 2>/dev/null || true
    fi
    killall sockd 2>/dev/null || true

    # Stop VPN
    if [[ "$VPN_TYPE" == "openvpn" ]]; then
        if [[ -f /var/run/openvpn.pid ]]; then
            kill "$(cat /var/run/openvpn.pid)" 2>/dev/null || true
        fi
    elif [[ "$VPN_TYPE" == "wireguard" && -n "$WG_INTERFACE" ]]; then
        wg-quick down "$WG_INTERFACE" 2>/dev/null || true
    fi

    rm -f /tmp/vpn-auth.txt

    echo "[shutdown] Cleanup complete."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# =============================================
# Main
# =============================================
main() {
    echo "=========================================="
    echo " vpnsocksifier - VPN + SOCKS5 Proxy"
    echo "=========================================="

    # Detect VPN type
    VPN_TYPE=$(detect_vpn_type)
    echo "[main] Detected VPN type: $VPN_TYPE"

    if [[ "$VPN_TYPE" == "unknown" ]]; then
        echo "[main] ERROR: No VPN config found in $VPN_CONFIG_DIR"
        echo "[main] Place .ovpn files (OpenVPN) or wg*.conf files (WireGuard) in the config directory."
        exit 1
    fi

    # Find config file
    if [[ -n "$VPN_CONFIG" ]]; then
        VPN_CONFIG_FILE="$VPN_CONFIG_DIR/$VPN_CONFIG"
        if [[ ! -f "$VPN_CONFIG_FILE" ]]; then
            echo "[main] ERROR: Specified config not found: $VPN_CONFIG_FILE"
            exit 1
        fi
    elif [[ "$VPN_TYPE" == "openvpn" ]]; then
        VPN_CONFIG_FILE=$(find_openvpn_config)
    else
        VPN_CONFIG_FILE=$(find_wireguard_config)
    fi

    if [[ -z "$VPN_CONFIG_FILE" ]]; then
        echo "[main] ERROR: Could not find VPN config file"
        exit 1
    fi

    echo "[main] Using config: $VPN_CONFIG_FILE"

    # Create /dev/net/tun if missing
    mkdir -p /dev/net
    if [[ ! -c /dev/net/tun ]]; then
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi

    # Setup DNS early so VPN hostname resolution and connectivity checks work
    setup_dns

    # Setup kill switch BEFORE starting VPN
    if [[ "$KILL_SWITCH" == "true" ]]; then
        setup_kill_switch
    fi

    # Start VPN
    if [[ "$VPN_TYPE" == "openvpn" ]]; then
        start_openvpn
    else
        start_wireguard
    fi

    # Wait for VPN connection
    wait_for_vpn

    # Generate dante config and start SOCKS5 proxy
    generate_sockd_conf

    echo "[main] Starting SOCKS5 proxy on port $SOCKS_PORT..."
    sockd -f /etc/sockd.conf &
    SOCKD_PID=$!

    echo "[main] SOCKS5 proxy started (PID: $SOCKD_PID)"
    echo "[main] Ready! Connect via socks5://host:$SOCKS_PORT"

    # Tail OpenVPN log for Docker logs visibility
    if [[ "$VPN_TYPE" == "openvpn" && -f /var/log/openvpn.log ]]; then
        tail -f /var/log/openvpn.log &
    fi

    # Wait for sockd to exit (keeps container alive)
    wait $SOCKD_PID
}

main "$@"
