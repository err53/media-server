# Media Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a Real-Debrid-based media server stack on Hetzner CPX21 using Docker Compose with Caddy reverse proxy, Tailscale management, and OIDC auth.

**Architecture:** Single `docker-compose.yml` with 7 services on one bridge network (`medianet`). Caddy is the only public-facing service (ports 80/443). All other services bind to `127.0.0.1` or have no port bindings, accessible only via Tailscale on the host. Zurg provides RealDebrid content via WebDAV, rclone FUSE-mounts it, CineSync organizes via symlinks, Jellyfin streams, Jellyseerr + SeerrBridge handle requests.

**Tech Stack:** Docker Compose, Caddy (with caddy-dns/cloudflare), Zurg, rclone, Jellyfin, Jellyseerr, SeerrBridge, CineSync, Tailscale (host-level), Debian 13, ufw

**Spec:** `docs/superpowers/specs/2026-04-26-media-server-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `.gitignore` | Ignore `.env`, logs, data dirs |
| `.env.example` | Template for all required secrets |
| `docker-compose.yml` | All 7 services, volumes, network |
| `Caddyfile` | Reverse proxy routing + TLS config |
| `caddy/Dockerfile` | Custom Caddy build with cloudflare DNS module |
| `zurg.yaml` | Zurg RealDebrid configuration |
| `provision.sh` | Host provisioning script (users, Docker, Tailscale, firewall) |
| `docs/configuration.md` | Service configuration guide and env var reference |
| `docs/troubleshooting.md` | Common issues and debugging steps |
| `README.md` | Project overview, quickstart, architecture diagram |

---

### Task 1: Project Scaffolding (.gitignore, .env.example)

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Create .gitignore**

```gitignore
# Secrets
.env

# Logs
logs/
*.log

# Data directories
data/
db/

# OS
.DS_Store
Thumbs.db
```

- [ ] **Step 2: Create .env.example**

```bash
# RealDebrid API token — get from https://real-debrid.com/apitoken
RD_API_TOKEN=

# Cloudflare API token — needs Zone:DNS:Edit permission for huang67.com
CLOUDFLARE_API_TOKEN=

# PocketID OIDC credentials — create clients at https://idm.huang-auth.com
# (used for manual UI configuration in Jellyfin and Jellyseerr)
POCKETID_CLIENT_ID=
POCKETID_CLIENT_SECRET=
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add .gitignore and .env.example"
```

---

### Task 2: Caddy Dockerfile and Caddyfile

**Files:**
- Create: `caddy/Dockerfile`
- Create: `Caddyfile`

- [ ] **Step 1: Create caddy/Dockerfile**

This builds a custom Caddy binary with the Cloudflare DNS module for ACME DNS challenge.

```dockerfile
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

- [ ] **Step 2: Create Caddyfile**

```caddyfile
{
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

jellyfin.huang67.com {
	reverse_proxy jellyfin:8096
}

requests.huang67.com {
	reverse_proxy jellyseerr:5055
	request_header X-Real-IP {header.CF-Connecting-IP}
}
```

- [ ] **Step 3: Commit**

```bash
git add caddy/Dockerfile Caddyfile
git commit -m "feat: add Caddy reverse proxy with Cloudflare DNS challenge"
```

---

### Task 3: Zurg Configuration

**Files:**
- Create: `zurg.yaml`

- [ ] **Step 1: Create zurg.yaml**

Zurg natively supports `${ENV_VAR}` substitution in its config file. The `RD_API_TOKEN` is passed via Docker Compose environment and resolved at runtime:

```yaml
zurg: v1
token: ${RD_API_TOKEN}
host: "[::]"
port: 9999
check_for_changes_every_secs: 10
enable_repair: true
repair_every_mins: 60
rar_action: extract

directories:
  movies:
    group: media
    group_order: 10
    filters:
      - regex: /.*/
  shows:
    group: media
    group_order: 20
    filters:
      - regex: /.*/
```

- [ ] **Step 2: Commit**

```bash
git add zurg.yaml
git commit -m "feat: add Zurg RealDebrid configuration"
```

---

### Task 4: Docker Compose — Core Services (Caddy, Zurg, rclone)

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Create docker-compose.yml with core services**

Start with the foundational services that don't depend on media being available.

```yaml
networks:
  medianet:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
  rclone_media:

services:
  caddy:
    build: ./caddy
    container_name: caddy
    restart: unless-stopped
    ports:
      - "0.0.0.0:80:80"
      - "0.0.0.0:443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
    networks:
      - medianet

  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    container_name: zurg
    restart: unless-stopped
    volumes:
      - ./zurg.yaml:/app/config.yaml:ro
    environment:
      - RD_API_TOKEN=${RD_API_TOKEN}
    networks:
      - medianet

  rclone:
    image: rclone/rclone:latest
    container_name: rclone
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
    command: >
      mount zurg: /media
      --config /dev/null
      --vfs-cache-mode off
      --allow-other
      --allow-non-empty
      --dir-cache-time 10s
      --rc
      --rc-no-auth
      --rc-addr=:5572
    environment:
      - RCLONE_CONFIG_ZURG_TYPE=webdav
      - RCLONE_CONFIG_ZURG_URL=http://zurg:9999
      - RCLONE_CONFIG_ZURG_VENDOR=other
    volumes:
      - rclone_media:/media:rshared
    depends_on:
      - zurg
    networks:
      - medianet
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose with Caddy, Zurg, and rclone"
```

---

### Task 5: Docker Compose — Media Services (CineSync, Jellyfin)

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add CineSync and Jellyfin volumes**

Add to the `volumes:` section:

```yaml
  cinesync_db:
  jellyfin_config:
```

- [ ] **Step 2: Add CineSync service**

Add to the `services:` section:

```yaml
  cinesync:
    image: sureshfizzy/cinesync:latest
    container_name: cinesync
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - rclone_media:/mnt/zurg:ro
      - rclone_media:/mnt/media:rshared
      - cinesync_db:/app/db
    ports:
      - "127.0.0.1:8082:8082"
    depends_on:
      - rclone
    networks:
      - medianet
```

- [ ] **Step 3: Add Jellyfin service**

Add to the `services:` section:

```yaml
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    user: "1000:1000"
    ports:
      - "127.0.0.1:8096:8096"
    environment:
      - JELLYFIN_PublishedServerUrl=https://jellyfin.huang67.com
    volumes:
      - jellyfin_config:/config
      - rclone_media:/mnt/zurg:ro
    depends_on:
      - rclone
    networks:
      - medianet
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add CineSync and Jellyfin services"
```

---

### Task 6: Docker Compose — Request Services (Jellyseerr, SeerrBridge)

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add Jellyseerr and SeerrBridge volumes**

Add to the `volumes:` section:

```yaml
  jellyseerr_config:
  seerrbridge_data:
  seerrbridge_mysql:
  seerrbridge_logs:
```

- [ ] **Step 2: Add Jellyseerr service**

Add to the `services:` section:

```yaml
  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    environment:
      - TZ=UTC
    ports:
      - "127.0.0.1:5055:5055"
    volumes:
      - jellyseerr_config:/app/config
    depends_on:
      - jellyfin
    networks:
      - medianet
```

- [ ] **Step 3: Add SeerrBridge service**

Add to the `services:` section:

```yaml
  seerrbridge:
    image: ghcr.io/woahai321/seerrbridge:latest
    container_name: seerrbridge
    restart: unless-stopped
    environment:
      - PYTHONUNBUFFERED=1
      - PYTHONDONTWRITEBYTECODE=1
      - NODE_ENV=production
      - NUXT_HOST=0.0.0.0
      - NUXT_PORT=3777
      - DB_HOST=localhost
      - DB_PORT=3306
      - DB_NAME=seerrbridge
      - DB_USER=seerrbridge
      - DB_PASSWORD=seerrbridge
      - MYSQL_ROOT_PASSWORD=seerrbridge_root
      - USE_DATABASE=true
      - SEERRBRIDGE_URL=http://localhost:8777
      - SETUP_API_URL=http://localhost:8778
      - SEERRBRIDGE_SETUP_URL=http://localhost:8778
    ports:
      - "127.0.0.1:3777:3777"
      - "127.0.0.1:8777:8777"
      - "127.0.0.1:8778:8778"
    volumes:
      - seerrbridge_mysql:/var/lib/mysql
      - seerrbridge_logs:/app/logs
      - seerrbridge_data:/app/data
    depends_on:
      - jellyseerr
    networks:
      - medianet
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Jellyseerr and SeerrBridge services"
```

---

### Task 7: Provisioning Script

**Files:**
- Create: `provision.sh`

- [ ] **Step 1: Create provision.sh**

```bash
#!/usr/bin/env bash
#
# provision.sh — Idempotent provisioning for media01 (Hetzner CPX21, Debian 13)
# Usage: ./provision.sh --ts-authkey <tailscale-auth-key>
#
# Run as root on a fresh Debian 13 instance.
set -euo pipefail

# --- Parse arguments ---
TS_AUTHKEY=""
REPO_URL="https://github.com/err53/media-server.git"
INSTALL_DIR="/opt/media-server"

while [[ $# -gt 0 ]]; do
    case $1 in
        --ts-authkey)
            TS_AUTHKEY="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 --ts-authkey <tailscale-auth-key>"
            exit 1
            ;;
    esac
done

if [[ -z "$TS_AUTHKEY" ]]; then
    echo "Error: --ts-authkey is required"
    echo "Usage: $0 --ts-authkey <tailscale-auth-key>"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

echo "=== Provisioning media01 ==="

# --- 1. System basics ---
echo "[1/10] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "[1/10] Setting hostname and timezone..."
hostnamectl set-hostname media01
timedatectl set-timezone UTC

# --- 2. Users ---
echo "[2/10] Creating users..."
if ! id media &>/dev/null; then
    groupadd --gid 1000 media
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash media
    echo "Created user: media (1000:1000)"
else
    echo "User media already exists, skipping"
fi

if ! id jason &>/dev/null; then
    useradd --create-home --shell /bin/bash --groups sudo jason
    echo "Created user: jason (with sudo)"
    echo "NOTE: Set a password for jason with: passwd jason"
else
    echo "User jason already exists, skipping"
fi

# --- 3. Docker ---
echo "[3/10] Installing Docker..."
if ! command -v docker &>/dev/null; then
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker installed"
else
    echo "Docker already installed, skipping"
fi

usermod -aG docker media 2>/dev/null || true
echo "User media added to docker group"

# --- 4. Tailscale ---
echo "[4/10] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed"
else
    echo "Tailscale already installed, skipping"
fi

# --- 5. Tailscale auth ---
echo "[5/10] Authenticating Tailscale..."
tailscale up --authkey="$TS_AUTHKEY" --hostname=media01 --ssh
echo "Tailscale authenticated as media01 with SSH enabled"

# --- 6. Firewall ---
echo "[6/10] Configuring firewall..."
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow in on tailscale0
ufw --force enable
echo "Firewall configured: 80/443 open, tailscale0 allowed, rest denied"

# --- 7. FUSE ---
echo "[7/10] Installing FUSE..."
apt-get install -y -qq fuse3
echo "FUSE installed"

# --- 8. Clone repo ---
echo "[8/10] Setting up project directory..."
if [[ ! -d "$INSTALL_DIR" ]]; then
    apt-get install -y -qq git
    git clone "$REPO_URL" "$INSTALL_DIR"
    chown -R media:media "$INSTALL_DIR"
    echo "Repo cloned to $INSTALL_DIR"
else
    echo "$INSTALL_DIR already exists, skipping clone"
fi

# --- 9. Environment file ---
echo "[9/10] Setting up .env..."
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    chown media:media "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    echo ".env created from .env.example — fill in your secrets!"
else
    echo ".env already exists, skipping"
fi

# --- 10. Media mount point ---
echo "[10/10] Creating mount point..."
mkdir -p /mnt/media
chown media:media /mnt/media
echo "Mount point /mnt/media created"

echo ""
echo "=== Provisioning complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/.env with your secrets"
echo "  2. cd $INSTALL_DIR && sudo -u media docker compose up -d"
echo "  3. Access Jellyfin at http://media01:8096 (via Tailscale)"
echo "  4. Access Jellyseerr at http://media01:5055 (via Tailscale)"
echo "  5. Set up Cloudflare DNS records:"
echo "     - jellyfin.huang67.com -> SERVER_IP (DNS-only)"
echo "     - requests.huang67.com -> SERVER_IP (Proxied)"
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x provision.sh
git add provision.sh
git commit -m "feat: add host provisioning script for Debian 13"
```

---

### Task 8: Configuration Guide

**Files:**
- Create: `docs/configuration.md`

- [ ] **Step 1: Create docs/configuration.md**

```markdown
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

### Optional Variables (reference only)

These are configured through the service UIs, not Docker env vars:

| Variable | Purpose |
|----------|---------|
| `POCKETID_CLIENT_ID` | OIDC client ID from PocketID at `idm.huang-auth.com` |
| `POCKETID_CLIENT_SECRET` | OIDC client secret from PocketID |

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
- Add a Movies library pointing to `/mnt/zurg` (or CineSync output path)
- Add a TV Shows library pointing to `/mnt/zurg` (or CineSync output path)

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
```

- [ ] **Step 2: Commit**

```bash
git add docs/configuration.md
git commit -m "docs: add service configuration guide"
```

---

### Task 9: Troubleshooting Guide

**Files:**
- Create: `docs/troubleshooting.md`

- [ ] **Step 1: Create docs/troubleshooting.md**

```markdown
# Troubleshooting Guide

## Quick Diagnostics

Check all service status:
```bash
docker compose ps
```

View logs for a specific service:
```bash
docker compose logs -f <service-name>
```

Restart a specific service:
```bash
docker compose restart <service-name>
```

## Common Issues

### Zurg: "token invalid" or no content appearing

**Symptoms:** Zurg logs show authentication errors, rclone mount is empty.

**Fix:**
1. Verify your RD token: `curl -H "Authorization: Bearer $RD_API_TOKEN" https://api.real-debrid.com/rest/1.0/user`
2. Check if token is correctly set in `.env`
3. Restart Zurg: `docker compose restart zurg`

### rclone: mount fails or "permission denied"

**Symptoms:** rclone container exits immediately, logs show FUSE errors.

**Fix:**
1. Verify FUSE is available on the host: `ls -la /dev/fuse`
2. If missing, install: `sudo apt-get install fuse3`
3. Check that the container has SYS_ADMIN capability (already set in compose)
4. Restart: `docker compose restart rclone`

### Caddy: TLS certificate errors

**Symptoms:** HTTPS not working, Caddy logs show ACME errors.

**Fix:**
1. Verify Cloudflare API token has Zone:DNS:Edit permission for `huang67.com`
2. Check token is set in `.env`: `grep CLOUDFLARE .env`
3. Test DNS resolution: `dig jellyfin.huang67.com` and `dig requests.huang67.com`
4. Check Caddy logs: `docker compose logs caddy`
5. If certs are stuck, clear and retry: `docker compose down caddy && docker volume rm media-server_caddy_data && docker compose up -d caddy`

### Jellyfin: "unable to connect" from browser

**Symptoms:** `https://jellyfin.huang67.com` returns connection refused or timeout.

**Fix:**
1. Check Jellyfin is running: `docker compose ps jellyfin`
2. Check Caddy is routing correctly: `docker compose logs caddy`
3. Verify DNS points to `SERVER_IP`: `dig jellyfin.huang67.com`
4. Verify Jellyfin is listening: `curl -s http://localhost:8096/health` (from the host via Tailscale)
5. Check firewall: `sudo ufw status`

### Jellyseerr: can't connect to Jellyfin

**Symptoms:** Jellyseerr setup wizard fails to find Jellyfin.

**Fix:** Use `http://jellyfin:8096` as the Jellyfin URL (Docker DNS name, not localhost).

### SeerrBridge: webhook not triggering

**Symptoms:** Requests approved in Jellyseerr but SeerrBridge doesn't process them.

**Fix:**
1. Verify webhook URL in Jellyseerr: should be `http://seerrbridge:8777/jellyseer-webhook/`
2. Check SeerrBridge is running: `docker compose ps seerrbridge`
3. Check SeerrBridge logs: `docker compose logs seerrbridge`
4. Verify the webhook trigger is set to "Request Automatically Approved"

### Tailscale: can't SSH to media01

**Symptoms:** `ssh media01` times out or refuses connection.

**Fix:**
1. Check Tailscale status on the server: `sudo tailscale status`
2. Verify Tailscale SSH is enabled: `sudo tailscale set --ssh`
3. On your local machine, check `tailscale status` shows `media01`
4. Try with IP: `ssh <tailscale-ip-of-media01>`

### General: service won't start

**Symptoms:** Container keeps restarting or exits immediately.

**Fix:**
1. Check logs: `docker compose logs <service>`
2. Check resource usage: `docker stats` (CPX21 has 3 vCPU, 4GB RAM)
3. Check disk space: `df -h` (80GB total)
4. Try recreating: `docker compose up -d --force-recreate <service>`

## Useful Commands

```bash
# Full stack restart
docker compose down && docker compose up -d

# Check what ports are bound
ss -tlnp

# Check Docker network connectivity
docker compose exec caddy ping jellyfin

# Inspect rclone mount contents
docker compose exec rclone ls /media

# Check Zurg WebDAV from inside the network
docker compose exec caddy curl -s http://zurg:9999/

# View real-time logs for all services
docker compose logs -f --tail=50
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/troubleshooting.md
git commit -m "docs: add troubleshooting guide"
```

---

### Task 10: README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README.md**

```markdown
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

### 3. Start the stack

```bash
sudo -u media docker compose up -d
```

### 4. Post-deploy setup

See [docs/configuration.md](docs/configuration.md) for detailed setup of each service.

## Docs

- [Configuration Guide](docs/configuration.md) — env vars, OIDC, Cloudflare DNS
- [Troubleshooting](docs/troubleshooting.md) — common issues and fixes
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README with architecture and quickstart"
```

---

### Task 11: Validate Docker Compose Syntax

**Files:**
- None (validation only)

- [ ] **Step 1: Validate compose file syntax**

Run from the repo root:

```bash
docker compose config --quiet
```

Expected: No output (success). If there are syntax errors, fix them in `docker-compose.yml`.

- [ ] **Step 2: Verify Caddy Dockerfile builds**

```bash
docker compose build caddy
```

Expected: Successful build of custom Caddy image with cloudflare module.

- [ ] **Step 3: Verify all images can be pulled**

```bash
docker compose pull --ignore-buildable
```

Expected: All images pulled successfully.

- [ ] **Step 4: Commit any fixes**

If any fixes were needed, commit them:

```bash
git add -A
git commit -m "fix: resolve docker compose validation issues"
```
