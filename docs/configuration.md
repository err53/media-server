# Configuration Guide

## Environment Variables

All secrets are stored in `.env` (never committed). Copy from `.env.example`:

```bash
cp .env.example .env
chmod 600 .env
```

### Required Variables

| Variable | Where to get it | Used by |
|----------|----------------|---------|
| `RD_API_TOKEN` | [real-debrid.com/apitoken](https://real-debrid.com/apitoken) | Zurg |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard > API Tokens > Create Token > Zone:DNS:Edit for `huang67.com` | Caddy |

## Service Configuration

### Zurg (`zurg.yaml`)

The RealDebrid token is read from the `RD_API_TOKEN` environment variable via `${RD_API_TOKEN}` substitution in the config file.

Key settings:
- `check_for_changes_every_secs`: How often Zurg polls RealDebrid for new content (default: 10)
- `enable_repair`: Automatically repair broken torrents (default: true)
- `rar_action`: Set to `extract` to auto-extract RAR archives

### Caddy (`Caddyfile`)

Routes:
- `jellyfin.huang67.com` -> Jellyfin (port 8096)
- `requests.huang67.com` -> Jellyseerr (port 5055)

TLS certificates are obtained automatically via Cloudflare DNS challenge. No manual cert management needed.

### Jellyfin

Access the admin UI at `http://media01:8096` via Tailscale for initial setup.

**OIDC Setup (PocketID):**
1. Go to Dashboard > Plugins > Catalog
2. Install "SSO Authentication" plugin
3. Restart Jellyfin
4. Go to Dashboard > Plugins > SSO Authentication
5. Add provider with:
   - OID Provider Name: PocketID
   - OID Discovery URL: `https://idm.huang-auth.com/.well-known/openid-configuration`
   - OID Client ID: your client ID from PocketID
   - OID Client Secret: your client secret from PocketID

**Library Setup:**
- Add a Movies library pointing to `/mnt/zurg`
- Add a TV Shows library pointing to `/mnt/zurg`

### Jellyseerr

Access the admin UI at `http://media01:5055` via Tailscale for initial setup.

**Initial Setup:**
1. Connect to Jellyfin using URL `http://jellyfin:8096`
2. Sign in with your Jellyfin admin account

**OIDC Setup (PocketID):**
1. Go to Settings > General
2. Enable OIDC
3. Set Discovery URL: `https://idm.huang-auth.com/.well-known/openid-configuration`
4. Set Client ID and Client Secret from PocketID

**Webhook for SeerrBridge:**
1. Go to Settings > Notifications > Webhook
2. Add webhook URL: `http://seerrbridge:8777/jellyseer-webhook/`
3. Enable trigger: "Request Automatically Approved"

### SeerrBridge

Access the dashboard at `http://media01:3777` via Tailscale.

**Initial Setup:**
1. Open the setup page at `http://media01:8778`
2. Configure Real-Debrid credentials
3. Configure Overseerr/Jellyseerr API key
4. Configure Trakt Client ID (required for search)

### CineSync

Access the web UI at `http://media01:8082` via Tailscale.

Configure source and destination paths through the web interface:
- Source: `/mnt/zurg` (rclone mount)
- Destination: `/mnt/media` (organized symlinks)

## Cloudflare DNS Records

| Record | Type | Value | Proxy Status |
|--------|------|-------|-------------|
| `jellyfin.huang67.com` | A | `SERVER_IP` | DNS only (grey cloud) |
| `requests.huang67.com` | A | `SERVER_IP` | Proxied (orange cloud) |

Jellyfin uses DNS-only to avoid Cloudflare's video streaming restrictions on the free tier.
