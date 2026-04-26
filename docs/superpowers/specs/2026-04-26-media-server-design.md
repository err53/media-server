# Media Server Design Spec

Real-Debrid-based media server stack on Hetzner CPX21, managed via Docker Compose with Caddy reverse proxy and Tailscale for management access.

## Host

- **Provider**: Hetzner CPX21 (3 vCPU, 4GB RAM, 80GB disk)
- **Region**: US-East
- **Public IP**: `SERVER_IP`
- **Hostname**: `media01`
- **OS**: Debian 13
- **Tailscale**: Installed on host (not containerized), Tailscale SSH enabled, advertised as `media01` on tailnet

## Users

| User | UID/GID | Purpose |
|------|---------|---------|
| `media` | 1000:1000 | Service account. Owns all config/data dirs. Member of `docker` group. All containers run as this user. |
| `jason` | auto | Personal account with sudo. SSH access via Tailscale only. |

## Firewall (ufw)

| Rule | Source | Ports |
|------|--------|-------|
| Allow | Anywhere | 80, 443 (Caddy) |
| Allow | Tailscale interface (`tailscale0`) | All (management) |
| Deny | Everything else | All |

SSH is only accessible over Tailscale (via Tailscale SSH).

## Provisioning Script (`provision.sh`)

Idempotent bash script, run as root on a fresh Debian 13 instance. Steps:

1. Update system packages, set hostname to `media01`, set timezone to UTC
2. Create `media` user (UID/GID 1000), create `jason` user with sudo
3. Install Docker Engine + Compose plugin via official Docker apt repository
4. Install Tailscale via official apt repository
5. Authenticate Tailscale using auth key passed as CLI argument (`./provision.sh --ts-authkey <key>`), enable Tailscale SSH, set hostname `media01`
6. Configure ufw: allow 80/443 from anywhere, allow all from `tailscale0`, enable ufw
7. Install `fuse3` package, ensure `/dev/fuse` is available
8. Clone repo to `/opt/media-server/`, set ownership to `media:media`
9. Copy `.env.example` to `.env`, prompt user to fill in secrets
10. Create `/mnt/media` for rclone FUSE mount point, owned by `media:media`

The script does NOT run `docker compose up` — that is a manual step after reviewing `.env`.

## Docker Compose Stack

### Location

`/opt/media-server/` — repo cloned here, owned by `media:media`.

### Network

Single bridge network: `medianet`. All services communicate over Docker DNS. Only Caddy binds to host ports.

### Services

#### Caddy (reverse proxy)
- **Image**: Custom Dockerfile building Caddy with `caddy-dns/cloudflare` module
- **Ports**: `0.0.0.0:80:80`, `0.0.0.0:443:443` (only public-facing service)
- **Volumes**: `caddy_data:/data`, `caddy_config:/config`, `./Caddyfile:/etc/caddy/Caddyfile:ro`
- **Env**: `CLOUDFLARE_API_TOKEN`
- **Restart**: `unless-stopped`

#### Zurg (RealDebrid gateway)
- **Image**: Zurg image
- **Ports**: None (internal only, exposes 9999 on `medianet`)
- **Volumes**: `./zurg.yaml:/app/config.yaml:ro`
- **Env**: `RD_API_TOKEN`
- **Restart**: `unless-stopped`

#### rclone (FUSE mount)
- **Image**: `rclone/rclone`
- **Ports**: None
- **Volumes**: `rclone_media:/media:rshared`
- **Capabilities**: `SYS_ADMIN`
- **Devices**: `/dev/fuse`
- **Command**: Mount Zurg's WebDAV endpoint (`zurg:9999`) to `/media`
- **Depends on**: `zurg`
- **Restart**: `unless-stopped`

#### Jellyfin (media server)
- **Image**: `jellyfin/jellyfin`
- **Ports**: `127.0.0.1:8096:8096` (accessible via Tailscale, not publicly)
- **Volumes**: `jellyfin_config:/config`, `rclone_media:/mnt/zurg:ro`, `cinesync_media:/media:ro`
- **Env**: `PUID=1000`, `PGID=1000`
- **Notes**: Software transcoding only (no GPU). OIDC via `jellyfin-plugin-sso`, configured post-deploy through Jellyfin UI against `idm.huang-auth.com`.
- **Depends on**: `rclone`
- **Restart**: `unless-stopped`

#### Jellyseerr (request management)
- **Image**: `fallenbagel/jellyseerr`
- **Ports**: `127.0.0.1:5055:5055` (accessible via Tailscale, not publicly)
- **Volumes**: `jellyseerr_config:/app/config`
- **Env**: `PUID=1000`, `PGID=1000`
- **Notes**: Built-in OIDC support, configured post-deploy via UI against `idm.huang-auth.com`. Connects to Jellyfin internally via `jellyfin:8096`.
- **Depends on**: `jellyfin`
- **Restart**: `unless-stopped`

#### SeerrBridge (request fulfillment)
- **Image**: SeerrBridge image
- **Ports**: `127.0.0.1:8282:8282` (accessible via Tailscale, not publicly)
- **Volumes**: `seerrbridge_config:/app/config`
- **Env**: `PUID=1000`, `PGID=1000`
- **Notes**: Fulfills Jellyseerr requests using DMM via RealDebrid.
- **Depends on**: `jellyseerr`
- **Restart**: `unless-stopped`

#### CineSync (symlink organizer)
- **Image**: CineSync image
- **Ports**: None
- **Volumes**: `rclone_media:/mnt/zurg:ro`, `cinesync_media:/media`
- **Env**: `PUID=1000`, `PGID=1000`
- **Notes**: Watches rclone mount, creates organized symlink structure under `/media/movies` and `/media/tv`.
- **Depends on**: `rclone`
- **Restart**: `unless-stopped`

### Volumes

| Volume | Purpose | Used by |
|--------|---------|---------|
| `rclone_media` | FUSE mount of RealDebrid content via Zurg | rclone (rw), CineSync (ro), Jellyfin (ro) |
| `cinesync_media` | Organized symlink structure | CineSync (rw), Jellyfin (ro) |
| `jellyfin_config` | Jellyfin config, metadata, plugins | Jellyfin |
| `jellyseerr_config` | Jellyseerr config and database | Jellyseerr |
| `seerrbridge_config` | SeerrBridge config | SeerrBridge |
| `caddy_data` | TLS certificates | Caddy |
| `caddy_config` | Caddy runtime config | Caddy |

### Data Flow

```
User Request Flow:
  User → Jellyseerr (request movie/show)
       → SeerrBridge (fulfill via DMM + RealDebrid)
       → Zurg (content appears in RD library)
       → rclone (FUSE mount updates)
       → CineSync (creates symlinks)
       → Jellyfin (media available to stream)

Streaming Flow:
  User → Cloudflare (requests.huang67.com proxied, jellyfin.huang67.com DNS-only)
       → Caddy (TLS termination)
       → Jellyfin (serves media from rclone mount via CineSync symlinks)
```

## Caddy Configuration (`Caddyfile`)

```
{
    acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

jellyfin.huang67.com {
    reverse_proxy jellyfin:8096
}

requests.huang67.com {
    reverse_proxy jellyseerr:5055
    header_up X-Real-IP {header.CF-Connecting-IP}
}
```

- Both domains use Cloudflare DNS challenge for TLS certificate issuance.
- `jellyfin.huang67.com` is DNS-only (grey cloud) in Cloudflare — direct TLS to Caddy, no real-IP header needed.
- `requests.huang67.com` is Cloudflare-proxied (orange cloud) — `CF-Connecting-IP` forwarded as real client IP.

## Zurg Configuration (`zurg.yaml`)

Minimal config pointing at RealDebrid API with the `RD_API_TOKEN`. Exposes WebDAV on port 9999. Specific config options to be determined from Zurg docs during implementation.

## OIDC Integration

Both are configured post-deploy through their respective UIs:

- **Jellyfin**: Install `jellyfin-plugin-sso` plugin from the plugin catalog. Configure OIDC provider pointing at `idm.huang-auth.com` with client ID/secret from PocketID.
- **Jellyseerr**: Settings → General → OIDC. Configure provider URL `idm.huang-auth.com` with client ID/secret from PocketID.

## Secrets (`.env`)

```
# RealDebrid
RD_API_TOKEN=

# Cloudflare (for Caddy DNS challenge)
CLOUDFLARE_API_TOKEN=

# PocketID OIDC (for manual UI configuration reference)
POCKETID_CLIENT_ID=
POCKETID_CLIENT_SECRET=

# Tailscale auth key is passed inline to provision.sh, not stored here
```

`.env` is git-ignored. `.env.example` is committed with empty values.

## Repository Structure

```
media-server/
├── docker-compose.yml
├── Caddyfile
├── caddy/
│   └── Dockerfile          # Custom Caddy build with cloudflare DNS module
├── zurg.yaml
├── .env.example
├── .gitignore
├── provision.sh
├── README.md
├── docs/
│   ├── configuration.md    # Service configuration guide and env var reference
│   ├── troubleshooting.md  # Common issues and debugging steps
│   └── superpowers/
│       └── specs/
│           └── 2026-04-26-media-server-design.md
└── ...
```

## Post-Deploy Steps (manual)

1. Fill in `.env` with all secrets
2. Run `docker compose up -d`
3. Access Jellyfin at `http://media01:8096` (via Tailscale) for initial setup
4. Install `jellyfin-plugin-sso` plugin, configure OIDC
5. Access Jellyseerr at `http://media01:5055` (via Tailscale), connect to Jellyfin, configure OIDC
6. Configure Jellyfin libraries to point at `/media/movies` and `/media/tv` (CineSync output)
7. Set up Cloudflare DNS records:
   - `jellyfin.huang67.com` → `SERVER_IP` (DNS-only / grey cloud)
   - `requests.huang67.com` → `SERVER_IP` (Proxied / orange cloud)
