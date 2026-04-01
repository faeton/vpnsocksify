#!/usr/bin/env bash
set -euo pipefail

# =============================================
# vpnsocksifier interactive launcher
# =============================================
# Launches one or more VPN+SOCKS5 proxy instances.
# Can be used interactively (prompts for missing values)
# or non-interactively via environment variables / CLI args.
#
# Usage:
#   ./launch.sh                          # interactive mode
#   ./launch.sh --config ./my-vpn.ovpn   # use specific config
#   ./launch.sh --port 2080 --name vpn2  # custom port and name

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
CONFIG_PATH=""
SOCKS_PORT=""
SOCKS_USER=""
SOCKS_PASS=""
VPN_USER=""
VPN_PASS=""
BIND_ADDR=""
CONTAINER_NAME=""
DETACH=true

# =============================================
# Parse CLI arguments
# =============================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|-c)   CONFIG_PATH="$2"; shift 2 ;;
        --port|-p)     SOCKS_PORT="$2"; shift 2 ;;
        --user|-u)     SOCKS_USER="$2"; shift 2 ;;
        --pass)        SOCKS_PASS="$2"; shift 2 ;;
        --vpn-user)    VPN_USER="$2"; shift 2 ;;
        --vpn-pass)    VPN_PASS="$2"; shift 2 ;;
        --bind|-b)     BIND_ADDR="$2"; shift 2 ;;
        --name|-n)     CONTAINER_NAME="$2"; shift 2 ;;
        --foreground|-f) DETACH=false; shift ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -c, --config PATH    VPN config file or directory (default: ./config)"
            echo "  -p, --port PORT      SOCKS5 proxy port (default: 1080)"
            echo "  -u, --user USER      SOCKS5 proxy username"
            echo "      --pass PASS      SOCKS5 proxy password"
            echo "      --vpn-user USER  VPN username (OpenVPN auth-user-pass)"
            echo "      --vpn-pass PASS  VPN password"
            echo "  -b, --bind ADDR      Bind address (default: 0.0.0.0)"
            echo "  -n, --name NAME      Container name (default: vpnsocksifier)"
            echo "  -f, --foreground     Run in foreground (default: detached)"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Interactive mode: run without arguments to be prompted for each option."
            echo ""
            echo "Examples:"
            echo "  $0                                    # interactive"
            echo "  $0 -c ./my-vpn.ovpn -p 2080          # specific config on port 2080"
            echo "  $0 -c ./configs/us/ -p 3080 -n vpn-us  # US VPN on port 3080"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================
# Interactive prompts for missing values
# =============================================
prompt_if_empty() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    local is_secret="${4:-false}"

    eval "local current_val=\"\${$var_name:-}\""
    if [[ -n "$current_val" ]]; then
        return
    fi

    if [[ -n "$default_val" ]]; then
        prompt_text="$prompt_text [$default_val]"
    fi

    if [[ "$is_secret" == "true" ]]; then
        read -rsp "$prompt_text: " value
        echo ""
    else
        read -rp "$prompt_text: " value
    fi

    value="${value:-$default_val}"
    eval "$var_name=\"$value\""
}

# Check if we're in interactive mode (terminal attached)
if [[ -t 0 ]]; then
    echo "=========================================="
    echo " vpnsocksifier - Interactive Launcher"
    echo "=========================================="
    echo ""

    # Config selection
    if [[ -z "$CONFIG_PATH" ]]; then
        echo "Available VPN configs:"
        configs=()
        i=1

        # List .ovpn files
        for f in "$SCRIPT_DIR"/config/*.ovpn "$SCRIPT_DIR"/config/*.conf; do
            if [[ -f "$f" ]]; then
                configs+=("$f")
                echo "  $i) $(basename "$f")"
                i=$((i + 1))
            fi
        done

        if [[ ${#configs[@]} -eq 0 ]]; then
            echo "  No configs found in $SCRIPT_DIR/config/"
            read -rp "Enter path to VPN config file or directory: " CONFIG_PATH
        elif [[ ${#configs[@]} -eq 1 ]]; then
            echo ""
            echo "Only one config found, using it."
            CONFIG_PATH="${configs[0]}"
        else
            echo ""
            read -rp "Select config number (or enter path) [1]: " selection
            selection="${selection:-1}"
            if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#configs[@]} ]]; then
                CONFIG_PATH="${configs[$((selection - 1))]}"
            else
                CONFIG_PATH="$selection"
            fi
        fi
        echo "Using: $(basename "$CONFIG_PATH")"
        echo ""
    fi

    prompt_if_empty SOCKS_PORT "SOCKS5 port" "1080"
    prompt_if_empty BIND_ADDR "Bind address (0.0.0.0 = all, 127.0.0.1 = local only)" "0.0.0.0"
    prompt_if_empty CONTAINER_NAME "Container name" "vpnsocksifier-${SOCKS_PORT}"

    echo ""
    echo "SOCKS5 Authentication (leave empty for no auth):"
    prompt_if_empty SOCKS_USER "  Username" ""
    if [[ -n "$SOCKS_USER" ]]; then
        prompt_if_empty SOCKS_PASS "  Password" "" true
    fi

    # Check if the config might need VPN auth
    if [[ -f "$CONFIG_PATH" ]] && grep -q 'auth-user-pass' "$CONFIG_PATH" 2>/dev/null; then
        echo ""
        echo "VPN config requires authentication:"
        prompt_if_empty VPN_USER "  VPN Username" ""
        if [[ -n "$VPN_USER" ]]; then
            prompt_if_empty VPN_PASS "  VPN Password" "" true
        fi
    fi

    echo ""
fi

# =============================================
# Apply defaults
# =============================================
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
CONTAINER_NAME="${CONTAINER_NAME:-vpnsocksifier-${SOCKS_PORT}}"

# If config is a single file, mount its parent directory and pass filename via VPN_CONFIG
VPN_CONFIG_MOUNT="$CONFIG_PATH"
VPN_CONFIG_NAME=""
if [[ -f "$CONFIG_PATH" ]]; then
    VPN_CONFIG_NAME="$(basename "$CONFIG_PATH")"
    VPN_CONFIG_MOUNT="$(dirname "$CONFIG_PATH")"
fi

# =============================================
# Build if needed
# =============================================
echo "[launcher] Building image..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" build --quiet 2>&1

# =============================================
# Check if container already exists
# =============================================
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[launcher] Container '$CONTAINER_NAME' already exists."
    read -rp "Remove and recreate? [Y/n]: " yn
    yn="${yn:-Y}"
    if [[ "$yn" =~ ^[Yy] ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    else
        echo "Aborted."
        exit 0
    fi
fi

# =============================================
# Launch
# =============================================
echo "[launcher] Starting $CONTAINER_NAME (port $SOCKS_PORT, bind $BIND_ADDR)..."

DETACH_FLAG=""
if [[ "$DETACH" == "true" ]]; then
    DETACH_FLAG="-d"
fi

CONTAINER_NAME="$CONTAINER_NAME" \
SOCKS_PORT="$SOCKS_PORT" \
SOCKS_USER="$SOCKS_USER" \
SOCKS_PASS="$SOCKS_PASS" \
VPN_CONFIG="$VPN_CONFIG_NAME" \
VPN_USER="$VPN_USER" \
VPN_PASS="$VPN_PASS" \
BIND_ADDR="$BIND_ADDR" \
VPN_CONFIG_PATH="$VPN_CONFIG_MOUNT" \
docker compose -f "$SCRIPT_DIR/docker-compose.yml" -p "$CONTAINER_NAME" up $DETACH_FLAG 2>&1

if [[ "$DETACH" == "true" ]]; then
    echo ""
    echo "[launcher] Container started. Waiting for VPN connection..."
    sleep 10

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[launcher] Checking proxy..."
        local_test=$(curl -sf --max-time 10 --proxy "socks5h://${SOCKS_USER:+$SOCKS_USER:$SOCKS_PASS@}localhost:$SOCKS_PORT" https://api.ipify.org 2>/dev/null || echo "FAILED")
        if [[ "$local_test" != "FAILED" ]]; then
            echo "[launcher] SOCKS5 proxy is working! VPN IP: $local_test"
            echo ""
            echo "Connect via: socks5h://${SOCKS_USER:+$SOCKS_USER:$SOCKS_PASS@}${BIND_ADDR}:$SOCKS_PORT"
        else
            echo "[launcher] Proxy not ready yet. Check logs: docker logs $CONTAINER_NAME"
        fi
    else
        echo "[launcher] Container failed to start. Check logs: docker logs $CONTAINER_NAME"
    fi
fi
