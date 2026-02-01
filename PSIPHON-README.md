# Psiphon Multi-Instance Fleet

**Deploy 6 concurrent Psiphon instances on a single VPS, each exiting through a different country.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Required-blue.svg)](https://www.docker.com/)
[![Version](https://img.shields.io/badge/Version-1.0-blue.svg)]()

---

## 🎯 What is This?

This project allows you to run **multiple Psiphon proxy instances** on a single VPS server, each configured to exit through different countries. Perfect for:

- **Multi-country VPN services** - Offer users different exit locations
- **Geo-restriction bypass** - Access content from multiple regions
- **Load balancing** - Distribute traffic across countries
- **X-UI Integration** - Route users by email/IP to different countries

### Key Features

✅ **6 concurrent instances** - US, DE, GB, FR, NL, SG (easily customizable)  
✅ **Docker-based** - Isolated, reliable, easy to manage  
✅ **Auto-recovery** - Health monitoring with automatic restart  
✅ **Production-ready** - Systemd integration, logging, backups  
✅ **X-UI compatible** - Works with SOCKS5 outbounds  

---

## 🚀 Quick Start

### One-Line Installation

```bash
curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/install-psiphon.sh | sudo bash
```

That's it! The script will:
1. ✅ Install Docker if needed
2. ✅ Download all required files
3. ✅ Set up 6 Psiphon instances
4. ✅ Enable auto-start on boot
5. ✅ Configure health monitoring

**Wait 2-3 minutes for tunnels to establish**, then test:

```bash
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```

---

## 📦 What You Get

### SOCKS5 Proxies

| Port  | Country        | Usage                                        |
|-------|---------------|----------------------------------------------|
| 10080 | United States | `curl --socks5 127.0.0.1:10080 URL`         |
| 10081 | Germany       | `curl --socks5 127.0.0.1:10081 URL`         |
| 10082 | United Kingdom| `curl --socks5 127.0.0.1:10082 URL`         |
| 10083 | France        | `curl --socks5 127.0.0.1:10083 URL`         |
| 10084 | Netherlands   | `curl --socks5 127.0.0.1:10084 URL`         |
| 10085 | Singapore     | `curl --socks5 127.0.0.1:10085 URL`         |

### Management Tools

```bash
cd /opt/psiphon-fleet

./psiphon-docker.sh status           # Check all containers
./psiphon-docker.sh verify           # Test all proxies
./psiphon-docker.sh restart          # Restart all
./psiphon-docker.sh logs psiphon-us  # View logs
```

---

## 🛠️ Manual Installation

### Prerequisites

- Ubuntu 20.04+, Debian 11+, or CentOS 8+
- 2GB RAM minimum (4GB recommended)
- 20GB disk space
- Root access

### Step 1: Install Docker

```bash
curl -fsSL https://get.docker.com | bash
systemctl start docker && systemctl enable docker
apt-get install -y docker-compose-plugin
```

### Step 2: Download Files

```bash
mkdir -p /opt/psiphon-fleet && cd /opt/psiphon-fleet

wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/docker-compose-psiphon.yml
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/psiphon-docker.sh
chmod +x psiphon-docker.sh
```

### Step 3: Deploy

```bash
./psiphon-docker.sh setup
```

Wait 2-3 minutes, then verify:

```bash
./psiphon-docker.sh verify
```

---

## 🔗 X-UI Integration

### Generate X-UI Configuration

```bash
./psiphon-docker.sh xui-config
```

This outputs SOCKS5 outbound configurations ready to paste into X-UI panel.

### Add to X-UI

1. Open X-UI Panel → **Xray Configs** → **Outbounds**
2. Click **Add Outbound**
3. Paste the generated JSON for each country

**Example:**
```json
{
  "tag": "psiphon-us",
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "127.0.0.1", "port": 10080}]
  }
}
```

### Route Users by Email

Go to **Routing Rules**, create rules like:
- `user-us@x-ui` → routes to `psiphon-us` (exits via USA)
- `user-de@x-ui` → routes to `psiphon-de` (exits via Germany)

---

## 📊 Monitoring

### Health Checks (Auto-Enabled)

Cron job runs every 5 minutes:
```bash
*/5 * * * * /opt/psiphon-fleet/psiphon-health-check.sh check
```

Automatically restarts failed containers. View log:
```bash
tail -f /var/log/psiphon-health-check.log
```

### Performance Monitoring

```bash
./psiphon-performance.sh monitor     # Real-time monitoring
./psiphon-performance.sh report      # Generate report
```

### Manual Status Check

```bash
./psiphon-docker.sh status
```

---

## 💾 Backup & Restore

### Create Backup

```bash
./psiphon-backup.sh backup
```

Backups saved to: `/var/backups/psiphon-fleet/`

### Restore from Backup

```bash
./psiphon-backup.sh list
./psiphon-backup.sh restore /var/backups/psiphon-fleet/psiphon-fleet-20250201_120000.tar.gz
```

### Automatic Daily Backups

Enabled during installation. Runs at 2 AM daily.

---

## 🔧 Advanced Configuration

### Change Countries

Edit `docker-compose-psiphon.yml`:

```yaml
services:
  psiphon-jp:  # Add Japan
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

Then: `./psiphon-docker.sh rebuild`

### Available Countries

AT, AU, BE, BG, BR, CA, CH, CZ, DE, DK, EE, ES, FI, FR, GB, HR, HU, IE, IN, IT, JP, LV, NL, NO, PL, PT, RO, RS, SE, SG, SK, UA, US

### Change Ports

Edit `docker-compose-psiphon.yml`, modify `--bind 0.0.0.0:PORT`

### Resource Limits

Add to any service in `docker-compose-psiphon.yml`:

```yaml
deploy:
  resources:
    limits:
      cpus: '0.5'
      memory: 512M
```

---

## 🐛 Troubleshooting

### Container Up But No Connection

**Wait 2-3 minutes** for tunnel initialization, then:

```bash
./psiphon-docker.sh logs psiphon-us
./psiphon-docker.sh restart psiphon-us
```

### Wrong Exit Country

```bash
./psiphon-docker.sh stop psiphon-us
rm -rf ./warp-data/us/*
./psiphon-docker.sh start psiphon-us
```

### All Containers Down After Reboot

Enable systemd auto-start:

```bash
cp psiphon-fleet.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable psiphon-fleet.service
systemctl start psiphon-fleet.service
```

### Port Already in Use

```bash
lsof -i :10080
kill -9 <PID>
```

**Full troubleshooting guide:** [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)

---

## 📁 Project Structure

```
/opt/psiphon-fleet/
├── docker-compose-psiphon.yml    # Docker Compose configuration
├── psiphon-docker.sh             # Main management script
├── psiphon-health-check.sh       # Health monitoring
├── psiphon-backup.sh             # Backup & restore
├── psiphon-performance.sh        # Performance monitoring
├── psiphon-fleet.service         # Systemd service
├── DEPLOYMENT.md                 # Full deployment guide
├── TROUBLESHOOTING.md            # Troubleshooting guide
└── warp-data/                    # Persistent data
    ├── us/
    ├── de/
    ├── gb/
    ├── fr/
    ├── nl/
    └── sg/
```

---

## 🔐 Security

### Firewall Configuration

```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (Let's Encrypt)
ufw allow 443/tcp   # HTTPS (X-UI Panel)
ufw enable

# DO NOT expose 10080-10085 publicly
# Access them only via X-UI routing
```

### Bind to Localhost Only

For local-only access, edit `docker-compose-psiphon.yml`:

```yaml
command: >
  -v
  --bind 127.0.0.1:10080  # Changed from 0.0.0.0
  --cfon
  --country US
  --scan
```

---

## 🆘 Getting Help

1. **Check status:** `./psiphon-docker.sh status`
2. **View logs:** `./psiphon-docker.sh logs`
3. **Read guides:** [DEPLOYMENT.md](./DEPLOYMENT.md), [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
4. **GitHub Issues:** https://github.com/rezasmind/x-ui-pro/issues

---

## 📚 Documentation

- **[DEPLOYMENT.md](./DEPLOYMENT.md)** - Complete deployment guide with X-UI integration
- **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** - Common issues and solutions
- **[X-UI-PRO Main README](./README.md)** - Full X-UI-PRO documentation

---

## 🤝 Contributing

Contributions welcome! Please open issues or pull requests.

---

## 📜 License

MIT License - See [LICENSE](./LICENSE)

---

## 🙏 Credits

- **[warp-plus](https://github.com/bepass-org/warp-plus)** - Psiphon+WARP implementation
- **[bigbugcc/warp-plus](https://hub.docker.com/r/bigbugcc/warp-plus)** - Docker image
- **[X-UI](https://github.com/alireza0/x-ui)** - Panel integration

---

## 📝 Quick Reference

### Common Commands

```bash
# Status & Monitoring
./psiphon-docker.sh status
./psiphon-docker.sh verify
./psiphon-docker.sh logs

# Start/Stop/Restart
./psiphon-docker.sh restart
./psiphon-docker.sh stop
./psiphon-docker.sh start

# Maintenance
./psiphon-docker.sh rebuild
./psiphon-backup.sh backup
./psiphon-health-check.sh report

# Troubleshooting
./psiphon-docker.sh logs psiphon-us 200
docker stats psiphon-us
```

### Test Proxies

```bash
# Test all
for port in {10080..10085}; do
  echo "Port $port:"
  curl --socks5 127.0.0.1:$port https://ipapi.co/json | jq -r '.country_name'
done

# Test one
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```

### Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/install-psiphon.sh | sudo bash -s uninstall
```

---

**⭐ Star this repo if you find it useful!**
