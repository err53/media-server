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
