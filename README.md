# vpnsocksify

**Route any application's traffic through a VPN using a SOCKS5 proxy.**

A lightweight Docker container that connects to a VPN (OpenVPN or WireGuard), verifies the connection, and exposes a SOCKS5 proxy with optional username/password authentication. All proxy traffic is routed exclusively through the VPN tunnel.

```
┌─────────────┐     ┌──────────────────────────────────────┐     ┌──────────┐
│ Your App    │────▶│  vpnsocksify container               │────▶│ Internet │
│ (browser,   │     │  ┌─────────┐   ┌──────────────────┐  │     │ (via VPN │
│  curl, etc) │     │  │ SOCKS5  │──▶│ OpenVPN/WireGuard│──│────▶│  exit)   │
│             │     │  │ :1080   │   │ tun0/wg0         │  │     │          │
└─────────────┘     │  └─────────┘   └──────────────────┘  │     └──────────┘
                    │  iptables kill switch (no leaks)      │
                    └──────────────────────────────────────┘
```

## Features

- **Dual VPN support** — auto-detects OpenVPN (`.ovpn`) and WireGuard (`.conf`) configs
- **SOCKS5 proxy** with optional username/password authentication (Dante server)
- **Kill switch** — iptables rules prevent any traffic from leaking outside the VPN tunnel
- **DNS leak prevention** — IPv6 disabled, DNS forced through the tunnel
- **Health checks** — built-in Docker health check verifies the full proxy chain
- **Multi-instance** — run multiple containers on different ports with different VPN configs
- **Interactive launcher** — `launch.sh` prompts for config selection, port, and credentials
- **Tiny footprint** — Alpine Linux base, ~47MB image

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/faeton/vpnsocksify.git
cd vpnsocksify

# Copy your VPN config(s) into the config directory
cp /path/to/your-vpn.ovpn config/
# or for WireGuard:
cp /path/to/wg0.conf config/

# Create .env from example
cp .env.example .env
# Edit .env with your preferred settings (port, auth, etc.)
```

### 2. Build and run

```bash
docker compose build
docker compose up -d
```

### 3. Use the proxy

```bash
# Test it
curl --proxy socks5h://proxyuser:proxypass@localhost:1080 https://api.ipify.org

# Use with any SOCKS5-capable application
# Firefox: Settings → Network → SOCKS5 → localhost:1080
# Chrome: --proxy-server="socks5://localhost:1080"
```

## Interactive Launcher

For a guided setup experience, use the interactive launcher:

```bash
./launch.sh
```

It will prompt you to:
1. Select a VPN config from your `config/` directory
2. Choose a SOCKS5 port
3. Set bind address (public or local only)
4. Configure SOCKS5 authentication
5. Enter VPN credentials (if the config requires them)

```bash
# Or use CLI arguments:
./launch.sh --config ./config/us-server.ovpn --port 2080 --name vpn-us
./launch.sh --config ./config/uk-server.ovpn --port 3080 --name vpn-uk
```

## Multiple Instances

Run several VPN proxies simultaneously, each with a different VPN server and port:

```bash
# Instance 1: US VPN on port 1080
CONTAINER_NAME=vpn-us SOCKS_PORT=1080 VPN_CONFIG_PATH=./config/us \
  docker compose -p vpn-us up -d

# Instance 2: UK VPN on port 2080
CONTAINER_NAME=vpn-uk SOCKS_PORT=2080 VPN_CONFIG_PATH=./config/uk \
  docker compose -p vpn-uk up -d

# Instance 3: Local-only access on port 3080
CONTAINER_NAME=vpn-local SOCKS_PORT=3080 BIND_ADDR=127.0.0.1 \
  docker compose -p vpn-local up -d
```

## Configuration

All settings are configured via environment variables. Set them in `.env` or pass them directly.

| Variable | Default | Description |
|----------|---------|-------------|
| `SOCKS_PORT` | `1080` | SOCKS5 proxy listen port |
| `SOCKS_USER` | _(empty)_ | SOCKS5 username (empty = no auth) |
| `SOCKS_PASS` | _(empty)_ | SOCKS5 password |
| `VPN_USER` | _(empty)_ | VPN username (for OpenVPN `auth-user-pass`) |
| `VPN_PASS` | _(empty)_ | VPN password |
| `VPN_CONFIG_PATH` | `./config` | Path to VPN config file or directory |
| `BIND_ADDR` | `0.0.0.0` | Bind address (`0.0.0.0` = all interfaces, `127.0.0.1` = local only) |
| `CONTAINER_NAME` | `vpnsocksifier` | Docker container name |
| `DNS_SERVERS` | `1.1.1.1,8.8.8.8` | DNS servers (comma-separated) |
| `KILL_SWITCH` | `true` | Enable iptables kill switch |
| `VPN_LOG_LEVEL` | `3` | OpenVPN log verbosity (0-11) |
| `CONNECTION_TEST_URL` | `https://api.ipify.org` | URL to verify VPN connectivity |
| `CONNECTION_TEST_TIMEOUT` | `60` | Max seconds to wait for VPN connection |

## VPN Config Auto-Detection

Place your VPN config files in the `config/` directory (or specify a path via `VPN_CONFIG_PATH`). The container auto-detects the VPN type:

| File Pattern | Detected As |
|-------------|-------------|
| `*.ovpn` | OpenVPN |
| `wg*.conf` with `[Interface]` section | WireGuard |
| `*.conf` with `[Interface]` section | WireGuard |
| `*.conf` with `client`/`remote` directives | OpenVPN |

**OpenVPN**: Supports inline certificates, external cert files, `auth-user-pass` via env vars, all protocols (UDP/TCP) and ports.

**WireGuard**: Supports standard `wg-quick` configs with `[Interface]`/`[Peer]` sections. Requires the WireGuard kernel module on the Docker host (Linux 5.6+).

## Security

### Kill Switch

When enabled (default), iptables rules are configured **before** the VPN starts:

- All outbound traffic is **blocked by default**
- Only the VPN server endpoint (parsed from your config) is allowed on the physical interface
- All traffic through `tun+`/`wg+` interfaces is allowed
- IPv6 is completely disabled to prevent leaks
- If the VPN tunnel drops, **no traffic leaks** to your real IP

### DNS Leak Prevention

- DNS servers are explicitly configured (default: 1.1.1.1, 8.8.8.8)
- After the VPN tunnel is established, all DNS queries route through the tunnel
- IPv6 is disabled at the kernel level to prevent IPv6 DNS leaks

### SOCKS5 Authentication

When `SOCKS_USER` and `SOCKS_PASS` are set, the proxy requires RFC 1929 username/password authentication. Connections without valid credentials are rejected.

## Docker Requirements

The container requires:

```yaml
cap_add:
  - NET_ADMIN          # Required for VPN tunnel management and iptables
devices:
  - /dev/net/tun       # Required for TUN device (OpenVPN)
sysctls:
  - net.ipv4.conf.all.src_valid_mark=1   # Required for WireGuard routing
  - net.ipv6.conf.all.disable_ipv6=1     # Prevent IPv6 leaks
```

## Health Checks

The container includes a built-in Docker health check that verifies the full chain:

```bash
# Check health status
docker inspect --format='{{.State.Health.Status}}' vpnsocksifier

# View health check logs
docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' vpnsocksifier
```

The health check curls an external URL through the SOCKS5 proxy every 30 seconds, confirming that the VPN tunnel, proxy server, and authentication are all functioning.

## Troubleshooting

```bash
# View container logs
docker logs vpnsocksifier

# Check if VPN is connected
docker exec vpnsocksifier curl -s https://api.ipify.org

# Check VPN interface
docker exec vpnsocksifier ip addr show tun0   # OpenVPN
docker exec vpnsocksifier wg show              # WireGuard

# Check iptables rules
docker exec vpnsocksifier iptables -L -n

# Check DNS
docker exec vpnsocksifier cat /etc/resolv.conf
```

## VPN Provider Setup Guides

### AirVPN

[AirVPN](https://airvpn.org/?referred_by=684381) supports both OpenVPN and WireGuard with full config file downloads.

1. Log in at [airvpn.org/generator](https://airvpn.org/generator/)
2. Select **OpenVPN** or **WireGuard** protocol
3. Choose your servers/locations
4. Click **Generate** and download the config files
5. Place them in `config/`

> **Note:** AirVPN configs expire 30 minutes after generation. Activate the connection within that window or regenerate.

```bash
# OpenVPN (no auth-user-pass needed — certs are inline)
cp AirVPN_*.ovpn config/
docker compose up -d

# WireGuard
cp AirVPN_*.conf config/
docker compose up -d
```

### Mullvad

[Mullvad](https://mullvad.net) supports WireGuard (primary) and OpenVPN (being phased out).

1. Go to [mullvad.net/account](https://mullvad.net/en/account/) and log in with your account number
2. Navigate to **WireGuard configuration** or **OpenVPN configuration**
3. Generate and download config files

```bash
# WireGuard (recommended)
cp mullvad-wg0.conf config/
docker compose up -d

# OpenVPN
cp mullvad_*.ovpn config/
docker compose up -d
```

> **Note:** Mullvad is transitioning away from OpenVPN. Use WireGuard for best long-term support.

### NordVPN

[NordVPN](https://refer-nordvpn.com/CKtwPrhUroe) supports OpenVPN config files. WireGuard is available only via their proprietary NordLynx protocol (app-only).

1. Log in to [my.nordaccount.com](https://my.nordaccount.com/)
2. Go to **Settings** → **Manual setup** → **OpenVPN configuration files**
3. Download `.ovpn` files for your desired servers
4. Get your **Service credentials** (under Manual setup) — these are **different from your account password**

```bash
cp us1234.nordvpn.com.udp.ovpn config/

# NordVPN requires service credentials, NOT your account email/password
SOCKS_PORT=1080 \
SOCKS_USER=proxyuser \
SOCKS_PASS=proxypass \
VPN_USER=your-service-username \
VPN_PASS=your-service-password \
docker compose up -d
```

> **Important:** Since June 2023, NordVPN requires [service credentials](https://support.nordvpn.com/hc/en-us/articles/19685514639633) for third-party OpenVPN clients. Your regular account login will not work.

### ExpressVPN

[ExpressVPN](https://www.expressvpn.com) supports OpenVPN config files. Their WireGuard implementation is proprietary and app-only.

1. Log in to your ExpressVPN account
2. Go to **VPN Setup** → **Manual Config**
3. Download `.ovpn` files for your desired locations
4. Note the username and password shown on the Manual Config page

```bash
cp my_expressvpn_usa.ovpn config/

VPN_USER=your-expressvpn-username \
VPN_PASS=your-expressvpn-password \
docker compose up -d
```

### Provider Compatibility

| Provider | OpenVPN | WireGuard | Auth Required | Notes |
|----------|:-------:|:---------:|:-------------:|-------|
| [AirVPN](https://airvpn.org/?referred_by=684381) | ✅ | ✅ | No (inline certs) | Full config generator |
| [Mullvad](https://mullvad.net) | ✅ (deprecated) | ✅ | Account number | WireGuard preferred |
| [NordVPN](https://refer-nordvpn.com/CKtwPrhUroe) | ✅ | ❌ | Service credentials | NordLynx is app-only |
| [ExpressVPN](https://www.expressvpn.com) | ✅ | ❌ | Manual config creds | WireGuard is app-only |

> Any VPN provider that offers standard OpenVPN (`.ovpn`) or WireGuard (`wg-quick`) config files will work with vpnsocksify.

## License

MIT
