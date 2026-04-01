# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

vpnsocksify is a Docker container that connects to a VPN (OpenVPN or WireGuard), then exposes a SOCKS5 proxy (Dante server) that routes all traffic through the VPN tunnel. It includes an iptables kill switch to prevent leaks.

Published image: `ghcr.io/faeton/vpnsocksify:latest`

## Build and run commands

```bash
# Build
docker compose build

# Run (needs VPN configs in ./config/)
docker compose up -d

# Run with overrides (multi-instance)
CONTAINER_NAME=vpn-us SOCKS_PORT=2080 VPN_CONFIG_PATH=./config/us docker compose -p vpn-us up -d

# Test proxy
curl --proxy socks5h://user:pass@localhost:1080 https://api.ipify.org

# View logs
docker logs vpnsocksifier

# Check health
docker inspect --format='{{.State.Health.Status}}' vpnsocksifier

# Debug inside container
docker exec vpnsocksifier ip addr show tun0
docker exec vpnsocksifier iptables -L -n
docker exec vpnsocksifier cat /etc/resolv.conf
```

## Architecture

The container runs two long-lived processes orchestrated by `entrypoint.sh`:

1. **VPN client** (OpenVPN daemon or WireGuard via wg-quick)
2. **Dante SOCKS5 server** (sockd, runs in foreground to keep container alive)

### Startup flow in `entrypoint.sh`

`detect_vpn_type()` → `setup_dns()` → `setup_kill_switch()` → `start_openvpn()`/`start_wireguard()` → `wait_for_vpn()` → `generate_sockd_conf()` → `sockd` (foreground)

Key design: DNS is set **before** the kill switch, and the kill switch is set **before** the VPN starts. This ensures no traffic leaks during startup.

### Config auto-detection priority

1. `wg*.conf` with `[Interface]` → WireGuard
2. `*.ovpn` → OpenVPN
3. `*.conf` with `[Interface]` → WireGuard
4. `*.conf` with `client`/`remote` → OpenVPN

### Kill switch (`setup_kill_switch`)

Parses actual VPN endpoints from the config via `parse_vpn_endpoints()` and only allows those specific IP:port combinations on eth0. Falls back to common VPN ports if parsing fails. All tun+/wg+ traffic is allowed. IPv6 is blocked entirely.

### SOCKS5 auth

When `SOCKS_USER`/`SOCKS_PASS` are set, a Linux system user is created via `adduser`/`chpasswd`. Dante uses PAM (`username` method) against this system user. Requires `linux-pam` package.

### Template processing

`sockd.conf.template` uses `envsubst` with three variables: `${SOCKS_PORT}`, `${SOCKS_AUTH_METHOD}`, `${EXTERNAL_INTERFACE}`. The interface name is detected at runtime from `ip -o link show`.

## Shell scripting constraints

The container runs Alpine Linux (BusyBox). `grep -P` (Perl regex) is **not available**. Use POSIX character classes (`[[:space:]]`) and `awk`/`sed` instead. Bash is installed but many coreutils are BusyBox symlinks.

## CI/CD

GitHub Actions (`.github/workflows/docker-publish.yml`) builds multi-arch images (amd64 + arm64) on every push to main and publishes to `ghcr.io/faeton/vpnsocksify`. Semver tags (`v*`) produce versioned image tags.

## GitHub Pages

`docs/index.html` is a standalone landing page served at `faeton.github.io/vpnsocksify`. Source configured as `/docs` on `main` branch.
