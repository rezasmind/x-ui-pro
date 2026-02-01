# Psiphon Multi-Instance Deployment Guide

## 🚨 CRITICAL: Read This First!

**IMPORTANT UPDATE (February 2026)**: The public Docker image `bigbugcc/warp-plus:latest` is **BROKEN** due to Go 1.25+ compatibility issues. This deployment uses a **custom-built image** with Go 1.24.3 to fix the TLS panic error.

**Error Symptoms:**
- Containers restart continuously
- Logs show: `panic: tls: ConnectionState is not equal to tls.ConnectionState: struct field count mismatch: 17 vs 16`
- Psiphon mode (`--cfon` flag) doesn't work

**Solution:** This guide includes building a custom Docker image with Go 1.24.3. See [PSIPHON-TLS-ERROR-FIX.md](./PSIPHON-TLS-ERROR-FIX.md) for detailed technical information.

---

## 📋 Overview

This guide walks you through deploying **6 concurrent Psiphon instances** on a single VPS, each exiting through a different country. This is the **WORKING SOLUTION** using Docker containers with a custom-built `warp-plus:fixed` image.

## 🎯 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      YOUR VPS SERVER                         │
│                                                              │
│  Docker Containers (network_mode: host)                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ psiphon-us   │  │ psiphon-de   │  │ psiphon-gb   │      │
│  │ Port: 10080  │  │ Port: 10081  │  │ Port: 10082  │      │
│  │ Exit: US 🇺🇸   │  │ Exit: DE 🇩🇪   │  │ Exit: GB 🇬🇧   │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ psiphon-fr   │  │ psiphon-nl   │  │ psiphon-sg   │      │
│  │ Port: 10083  │  │ Port: 10084  │  │ Port: 10085  │      │
│  │ Exit: FR 🇫🇷   │  │ Exit: NL 🇳🇱   │  │ Exit: SG 🇸🇬   │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  X-UI Panel (Routes users by email to different proxies)    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
                  Internet (6 Countries)
```

## 🚀 Quick Start

### Prerequisites

**System Requirements:**
- **OS**: Ubuntu 20.04+, Debian 11+, or CentOS 8+
- **RAM**: Minimum 2GB (recommended: 4GB)
- **Storage**: 20GB free space
- **Network**: Good internet connection
- **Access**: Root or sudo privileges

**Required Software:**
- Docker 20.10+
- Docker Compose 2.0+
- curl, jq (for testing)

### Step 1: Install Docker

If Docker is not installed:

```bash
# Install Docker
curl -fsSL https://get.docker.com | bash

# Start Docker service
systemctl start docker
systemctl enable docker

# Install Docker Compose plugin
apt-get install -y docker-compose-plugin

# Verify installation
docker --version
docker compose version
```

### Step 2: Download Deployment Files

```bash
# Create project directory
mkdir -p /opt/psiphon-fleet
cd /opt/psiphon-fleet

# Download all required files
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/docker-compose-psiphon.yml
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/psiphon-docker.sh
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/Dockerfile.warp-plus-fixed
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/PSIPHON-TLS-ERROR-FIX.md

# Make scripts executable
chmod +x psiphon-docker.sh
```

Or if you have the files locally:

```bash
# Upload to server
scp docker-compose-psiphon.yml psiphon-docker.sh Dockerfile.warp-plus-fixed root@YOUR_SERVER_IP:/opt/psiphon-fleet/

# SSH into server
ssh root@YOUR_SERVER_IP
cd /opt/psiphon-fleet
chmod +x psiphon-docker.sh
```

### Step 2.5: Build Custom Docker Image (CRITICAL!)

**This step is REQUIRED** to fix the TLS panic error:

```bash
cd /opt/psiphon-fleet

# Build custom image with Go 1.24.3 (takes 5-10 minutes)
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .

# Verify the build
docker images warp-plus:fixed

# Expected output:
# REPOSITORY   TAG      IMAGE ID       CREATED         SIZE
# warp-plus    fixed    abc123def456   2 minutes ago   ~50MB
```

**Why is this needed?**
- Go 1.25+ broke Psiphon-TLS with struct field count mismatch
- Custom image uses Go 1.24.3 which works correctly
- Without this, all containers will crash with panic errors

**Build Tips:**
- Requires ~2GB free disk space
- Takes 5-10 minutes depending on internet speed
- If build fails, check `/tmp/warp-build.log` for errors
- See [PSIPHON-TLS-ERROR-FIX.md](./PSIPHON-TLS-ERROR-FIX.md) for troubleshooting

### Step 3: Deploy Psiphon Fleet

```bash
# Run setup (pulls images, creates containers, starts services)
./psiphon-docker.sh setup
```

This will:
1. ✅ Check Docker installation
2. ✅ Create data directories: `./warp-data/{us,de,gb,fr,nl,sg}`
3. ✅ Pull `bigbugcc/warp-plus:latest` image
4. ✅ Start all 6 containers
5. ✅ Wait 30 seconds for tunnels to establish
6. ✅ Show status of all instances

**Expected output:**
```
╔═══════════════════════════════════════════════════════════════════════════╗
║                          PSIPHON FLEET STATUS (Docker)                    ║
╚═══════════════════════════════════════════════════════════════════════════╝

CONTAINER       COUNTRY         PORT       EXIT IP            VERIFIED
─────────────────────────────────────────────────────────────────────────────
psiphon-us      US              10080      203.0.113.42       OK (US)
psiphon-de      DE              10081      198.51.100.88      OK (DE)
psiphon-gb      GB              10082      192.0.2.156        OK (GB)
psiphon-fr      FR              10083      203.0.113.77       OK (FR)
psiphon-nl      NL              10084      198.51.100.123     OK (NL)
psiphon-sg      SG              10085      192.0.2.201        OK (SG)
```

### Step 4: Verify Connections

```bash
# Test all instances
./psiphon-docker.sh verify

# Test individual proxy
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```

**Successful response:**
```json
{
  "ip": "203.0.113.42",
  "country": "US",
  "country_name": "United States",
  "region": "California",
  "city": "Los Angeles"
}
```

## 🎛️ Management Commands

### Status & Monitoring

```bash
# Show status of all containers
./psiphon-docker.sh status

# Verify all proxy connections work
./psiphon-docker.sh verify
```

### Start/Stop/Restart

```bash
# Restart all containers
./psiphon-docker.sh restart

# Restart specific container
./psiphon-docker.sh restart psiphon-us

# Stop all containers
./psiphon-docker.sh stop

# Start all containers
./psiphon-docker.sh start
```

### View Logs

```bash
# View logs from all containers (last 50 lines)
./psiphon-docker.sh logs

# View logs from specific container
./psiphon-docker.sh logs psiphon-us

# View more lines
./psiphon-docker.sh logs psiphon-de 200

# Follow logs in real-time
./psiphon-docker.sh follow psiphon-fr
```

### Maintenance

```bash
# Rebuild all containers (pulls latest image)
./psiphon-docker.sh rebuild

# Complete cleanup (removes containers and data)
./psiphon-docker.sh cleanup
```

## 🔗 X-UI Integration

### Step 1: Generate Configuration

```bash
./psiphon-docker.sh xui-config
```

This outputs ready-to-use SOCKS5 outbound configurations.

### Step 2: Add Outbounds to X-UI

1. Open X-UI Panel: `https://yourdomain.com/admin/`
2. Go to: **Xray Configs → Outbounds**
3. Click **Add Outbound**
4. For each country, create an outbound:

**Example for US:**
```json
{
  "tag": "psiphon-us",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": 10080
      }
    ]
  }
}
```

Repeat for all countries:
- `psiphon-de` → 127.0.0.1:10081
- `psiphon-gb` → 127.0.0.1:10082
- `psiphon-fr` → 127.0.0.1:10083
- `psiphon-nl` → 127.0.0.1:10084
- `psiphon-sg` → 127.0.0.1:10085

### Step 3: Configure Routing Rules

Go to: **Xray Configs → Routing Rules**

**Option A: Route by Email**

Create users with different emails:
- `user-us@x-ui` → routes to `psiphon-us` (exits via USA)
- `user-de@x-ui` → routes to `psiphon-de` (exits via Germany)
- `user-gb@x-ui` → routes to `psiphon-gb` (exits via UK)

**Option B: Route by Client IP**

Route specific client IPs to different countries:
- `192.168.1.10` → `psiphon-us`
- `192.168.1.20` → `psiphon-de`

**Option C: Route by Domain**

Route specific domains to different exits:
- `*.netflix.com` → `psiphon-us`
- `*.bbc.co.uk` → `psiphon-gb`

## 🔧 Advanced Configuration

### Change Country Codes

Edit `docker-compose-psiphon.yml`:

```yaml
services:
  psiphon-jp:  # Add Japan instance
    image: bigbugcc/warp-plus:latest
    container_name: psiphon-jp
    restart: unless-stopped
    network_mode: host
    command: >
      -v
      --bind 0.0.0.0:10086
      --cfon
      --country JP
      --scan
    volumes:
      - ./warp-data/jp:/etc/warp
```

Then restart:
```bash
./psiphon-docker.sh rebuild
```

### Available Country Codes

| Code | Country        | Code | Country       | Code | Country     |
|------|---------------|------|---------------|------|-------------|
| AT   | Austria       | GB   | UK            | NL   | Netherlands |
| AU   | Australia     | HU   | Hungary       | NO   | Norway      |
| BE   | Belgium       | IE   | Ireland       | PL   | Poland      |
| BR   | Brazil        | IN   | India         | RO   | Romania     |
| CA   | Canada        | IT   | Italy         | SE   | Sweden      |
| CH   | Switzerland   | JP   | Japan         | SG   | Singapore   |
| DE   | Germany       | FR   | France        | US   | USA         |

### Bind to Localhost Only (More Secure)

If you only need local access (not remote), change `0.0.0.0` to `127.0.0.1` in `docker-compose-psiphon.yml`:

```yaml
command: >
  -v
  --bind 127.0.0.1:10080  # Changed from 0.0.0.0
  --cfon
  --country US
  --scan
```

### Adjust Resource Limits

Add resource constraints to prevent any single instance from consuming too much:

```yaml
services:
  psiphon-us:
    # ... existing config ...
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
```

## 🔒 Security Best Practices

### Firewall Configuration

Only expose necessary ports:

```bash
# Allow SSH
ufw allow 22/tcp

# Allow HTTPS (for X-UI panel)
ufw allow 443/tcp

# Allow HTTP (for Let's Encrypt)
ufw allow 80/tcp

# Enable firewall
ufw --force enable

# DO NOT expose 10080-10085 publicly
# They should only be accessed via X-UI routing
```

### Secure Docker Socket

Ensure Docker socket has proper permissions:

```bash
chmod 660 /var/run/docker.sock
```

### Regular Updates

```bash
# Update system packages
apt-get update && apt-get upgrade -y

# Update Docker images
./psiphon-docker.sh rebuild
```

## 📊 Monitoring & Health Checks

### Manual Health Check

```bash
# Check all instances
./psiphon-docker.sh status

# Verify connectivity
./psiphon-docker.sh verify
```

### Automated Monitoring (Cron)

Create a monitoring script:

```bash
cat > /opt/psiphon-fleet/monitor.sh << 'EOF'
#!/bin/bash
cd /opt/psiphon-fleet

# Check if any container is down
DOWN=$(docker ps -a --filter "name=psiphon-" --format "{{.Status}}" | grep -c "Exited")

if [[ $DOWN -gt 0 ]]; then
    echo "[$(date)] $DOWN Psiphon containers are down. Restarting..." | tee -a /var/log/psiphon-monitor.log
    ./psiphon-docker.sh restart
fi
EOF

chmod +x /opt/psiphon-fleet/monitor.sh

# Add to crontab (check every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/psiphon-fleet/monitor.sh") | crontab -
```

### View Container Resource Usage

```bash
docker stats psiphon-us psiphon-de psiphon-gb psiphon-fr psiphon-nl psiphon-sg
```

## 🐛 Troubleshooting

### Issue: Container Shows "UP" But No Connection

**Symptoms:**
```bash
$ curl --socks5 127.0.0.1:10080 https://ipapi.co/json
curl: (7) Couldn't connect to server
```

**Solution:**
1. Wait 2-3 minutes - tunnels need time to establish
2. Check logs: `./psiphon-docker.sh logs psiphon-us`
3. Restart container: `./psiphon-docker.sh restart psiphon-us`

### Issue: Wrong Exit Country

**Symptoms:**
```
Expected: US
Got: DE
```

**Solution:**
1. Check docker-compose config: `--country` flag must be correct
2. Clear data directory: `rm -rf ./warp-data/us/*`
3. Restart: `./psiphon-docker.sh restart psiphon-us`

### Issue: Port Already in Use

**Symptoms:**
```
Error: bind: address already in use
```

**Solution:**
```bash
# Find process using port
lsof -i :10080

# Kill process
kill -9 <PID>

# Or change port in docker-compose-psiphon.yml
```

### Issue: Docker Compose Command Not Found

**Solution:**
```bash
# Install docker-compose-plugin
apt-get install -y docker-compose-plugin

# Or install standalone docker-compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

### Issue: Slow Connection or Timeouts

**Solution:**
1. The `--scan` flag helps find best endpoints
2. Try removing `--scan` if it causes delays
3. Check VPS network performance: `speedtest-cli`
4. Restart problematic instance

### Issue: All Containers Stopped After Reboot

**Solution:**

Enable auto-start on boot:

```bash
# Create systemd service
cat > /etc/systemd/system/psiphon-fleet.service << 'EOF'
[Unit]
Description=Psiphon Multi-Instance Fleet
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/psiphon-fleet
ExecStart=/usr/bin/docker compose -f docker-compose-psiphon.yml up -d
ExecStop=/usr/bin/docker compose -f docker-compose-psiphon.yml down

[Install]
WantedBy=multi-user.target
EOF

# Enable service
systemctl daemon-reload
systemctl enable psiphon-fleet.service
systemctl start psiphon-fleet.service
```

## 📁 File Structure

```
/opt/psiphon-fleet/
├── docker-compose-psiphon.yml    # Main Docker Compose config
├── psiphon-docker.sh             # Management script
├── monitor.sh                    # Health monitoring (optional)
└── warp-data/                    # Persistent data
    ├── us/                       # US instance data
    ├── de/                       # Germany instance data
    ├── gb/                       # UK instance data
    ├── fr/                       # France instance data
    ├── nl/                       # Netherlands instance data
    └── sg/                       # Singapore instance data
```

## 🔄 Backup & Restore

### Backup Configuration

```bash
# Backup entire fleet
tar -czf psiphon-fleet-backup-$(date +%Y%m%d).tar.gz \
    docker-compose-psiphon.yml \
    psiphon-docker.sh \
    warp-data/

# Copy to safe location
scp psiphon-fleet-backup-*.tar.gz user@backup-server:/backups/
```

### Restore Configuration

```bash
# Extract backup
tar -xzf psiphon-fleet-backup-20250201.tar.gz

# Restart services
./psiphon-docker.sh rebuild
```

## 📈 Performance Tuning

### Increase Connection Limits

Edit `/etc/sysctl.conf`:

```bash
# Network tuning
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1

# Apply changes
sysctl -p
```

### Docker Performance

```bash
# Increase container limits
docker update --cpus="1.0" --memory="1g" psiphon-us
```

## 🆘 Getting Help

**Check logs first:**
```bash
./psiphon-docker.sh logs psiphon-us 200
```

**Test connectivity:**
```bash
./psiphon-docker.sh verify
```

**Check Docker:**
```bash
docker ps -a
docker logs psiphon-us --tail 100
```

**Community Support:**
- GitHub Issues: https://github.com/rezasmind/x-ui-pro/issues
- Documentation: https://github.com/rezasmind/x-ui-pro

## ✅ Checklist

Before going live, ensure:

- [ ] All 6 containers show "UP" status
- [ ] All containers pass verification test
- [ ] Firewall configured (only 80, 443, SSH exposed)
- [ ] X-UI outbounds configured correctly
- [ ] Routing rules set up for user distribution
- [ ] Monitoring script enabled
- [ ] Auto-start on boot configured
- [ ] Backups scheduled
- [ ] Performance tuned for your VPS specs

## 📝 Next Steps

1. **Test from clients**: Create VPN configs in X-UI and test from actual client devices
2. **Set up monitoring**: Enable the health check cron job
3. **Document for users**: Create client configuration guides
4. **Optimize routes**: Fine-tune routing rules based on usage patterns
5. **Scale as needed**: Add more country instances if required

---

**Congratulations!** 🎉 Your multi-country Psiphon fleet is now operational.
