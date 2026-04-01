#!/usr/bin/env bash
set -euo pipefail

SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
HEALTH_URL="${CONNECTION_TEST_URL:-https://api.ipify.org}"

proxy_url="socks5h://127.0.0.1:${SOCKS_PORT}"
if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
    proxy_url="socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}"
fi

ip=$(curl -sf --max-time 10 --proxy "$proxy_url" "$HEALTH_URL" 2>/dev/null)
if [[ -n "$ip" ]]; then
    exit 0
else
    exit 1
fi
