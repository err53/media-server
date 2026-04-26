# media-server

Real-Debrid media server stack for Hetzner CPX21 (`media01`).

## Architecture

```
Internet (ports 80/443)
       |
     Caddy ── jellyfin.huang67.com ──> Jellyfin
       |   ── requests.huang67.com ──> Jellyseerr
       |
   [medianet - Docker bridge]
       |
     Zurg (RD API) -> rclone (FUSE) -> CineSync (symlinks) -> Jellyfin
                                                                  |
     Jellyseerr -> SeerrBridge (DMM fulfillment)                  |
                                                           streams to user
```

## Services

| Service | Purpose | Access |
|---------|---------|--------|
| Caddy | Reverse proxy + TLS | Public (80/443) |
| Zurg | RealDebrid WebDAV gateway | Internal |
| rclone | FUSE mount | Internal |
| CineSync | Symlink organizer | Tailscale (:8082) |
| Jellyfin | Media streaming | Public + Tailscale (:8096) |
| Jellyseerr | Media requests | Public + Tailscale (:5055) |
| SeerrBridge | Request fulfillment | Tailscale (:3777) |

## Quick Start

### 1. Provision the server

```bash
ssh root@SERVER_IP
curl -fsSL https://raw.githubusercontent.com/err53/media-server/main/provision.sh | bash -s -- --ts-authkey tskey-auth-xxxxx
```

### 2. Configure secrets

```bash
ssh media01  # via Tailscale
cd /opt/media-server
nano .env    # fill in RD_API_TOKEN and CLOUDFLARE_API_TOKEN
```

### 2.5. Generate Zurg config

Zurg doesn't support env var substitution in its config file, so generate it from the template after filling in `.env`:

```bash
set -a && source .env && set +a && envsubst < zurg.yaml.tpl > zurg.yaml
```

### 3. Start the stack

```bash
sudo -u media docker compose up -d
```

### 4. Post-deploy setup

See [docs/configuration.md](docs/configuration.md) for detailed setup of each service.

## Docs

- [Configuration Guide](docs/configuration.md) — env vars, OIDC, Cloudflare DNS
- [Troubleshooting](docs/troubleshooting.md) — common issues and fixes
