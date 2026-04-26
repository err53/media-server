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
echo "[1/10] System setup..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq gettext-base

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
echo "  1. Edit $INSTALL_DIR/.env with your secrets:"
echo "       nano $INSTALL_DIR/.env"
echo "  2. Generate Zurg config from template:"
echo "       cd $INSTALL_DIR && set -a && source .env && set +a && envsubst < zurg.yaml.tpl > zurg.yaml"
echo "  3. Start the stack:"
echo "       sudo -u media docker compose up -d"
echo "  4. Access Jellyfin at http://media01:8096 (via Tailscale)"
echo "  5. Access Jellyseerr at http://media01:5055 (via Tailscale)"
echo "  6. Set up Cloudflare DNS records:"
echo "     - jellyfin.huang67.com -> SERVER_IP (DNS-only)"
echo "     - requests.huang67.com -> SERVER_IP (Proxied)"
