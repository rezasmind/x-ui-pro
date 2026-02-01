# Psiphon Fleet Troubleshooting Guide

## 🔍 Quick Diagnostics

### Run All Diagnostic Commands

```bash
cd /opt/psiphon-fleet

echo "=== DOCKER STATUS ==="
docker --version
docker compose version
systemctl status docker

echo -e "\n=== CONTAINER STATUS ==="
docker ps -a --filter "name=psiphon-"

echo -e "\n=== PSIPHON FLEET STATUS ==="
./psiphon-docker.sh status

echo -e "\n=== CONNECTIVITY TEST ==="
./psiphon-docker.sh verify

echo -e "\n=== RECENT LOGS ==="
./psiphon-docker.sh logs | tail -50

echo -e "\n=== DISK SPACE ==="
df -h

echo -e "\n=== MEMORY USAGE ==="
free -h

echo -e "\n=== PORT LISTENERS ==="
ss -tulpn | grep -E ":(10080|10081|10082|10083|10084|10085)"
```

---

## 🐛 Common Issues & Solutions

### Issue 1: Container Shows "UP" But No Connection

**Symptoms:**
```bash
$ curl --socks5 127.0.0.1:10080 https://ipapi.co/json
curl: (7) Couldn't connect to server
```

**Diagnosis:**
```bash
./psiphon-docker.sh logs psiphon-us

docker inspect psiphon-us | grep -A 10 NetworkMode
```

**Solutions:**

**A. Wait for Tunnel Initialization**
Psiphon needs 1-3 minutes to establish secure tunnels on first start.

```bash
echo "Waiting for tunnel..."
sleep 120
./psiphon-docker.sh verify
```

**B. Check Network Mode**
Must be `host` mode, not `bridge`.

```bash
docker inspect psiphon-us --format '{{.HostConfig.NetworkMode}}'
```

Should show: `host`

If not, fix `docker-compose-psiphon.yml`:
```yaml
services:
  psiphon-us:
    network_mode: host
```

**C. Port Already in Use**
```bash
lsof -i :10080
netstat -tulpn | grep 10080
```

Kill conflicting process or change port in docker-compose file.

**D. Restart Container**
```bash
./psiphon-docker.sh restart psiphon-us
sleep 30
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```

---

### Issue 2: Wrong Exit Country

**Symptoms:**
```bash
$ curl --socks5 127.0.0.1:10080 https://ipapi.co/json | jq -r '.country_code'
DE  # Expected US, got DE
```

**Diagnosis:**
```bash
docker logs psiphon-us 2>&1 | grep -i country

docker inspect psiphon-us --format '{{.Config.Cmd}}'
```

**Solutions:**

**A. Verify docker-compose Configuration**
```bash
cat docker-compose-psiphon.yml | grep -A 5 "psiphon-us:"
```

Must have: `--country US`

**B. Clear Cached Data**
```bash
./psiphon-docker.sh stop psiphon-us
rm -rf ./warp-data/us/*
./psiphon-docker.sh start psiphon-us
sleep 60
./psiphon-docker.sh verify
```

**C. Recreate Container**
```bash
docker-compose -f docker-compose-psiphon.yml up -d --force-recreate psiphon-us
```

---

### Issue 3: All Containers Exited/Crashed

**Symptoms:**
```bash
$ docker ps -a --filter "name=psiphon-"
CONTAINER       STATUS
psiphon-us      Exited (1) 5 minutes ago
psiphon-de      Exited (137) 5 minutes ago
```

**Diagnosis:**
```bash
for container in psiphon-us psiphon-de psiphon-gb psiphon-fr psiphon-nl psiphon-sg; do
    echo "=== $container ==="
    docker logs $container --tail 30
    echo ""
done
```

**Common Causes & Solutions:**

**A. Out of Memory (Exit 137)**
```bash
free -h
docker stats --no-stream
```

Solution: Increase RAM or add swap:
```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

**B. Docker Daemon Stopped**
```bash
systemctl status docker
systemctl start docker
systemctl enable docker
```

**C. Disk Full**
```bash
df -h
docker system prune -af
```

**D. Corrupted Image**
```bash
docker-compose -f docker-compose-psiphon.yml down
docker rmi bigbugcc/warp-plus:latest
docker pull bigbugcc/warp-plus:latest
./psiphon-docker.sh setup
```

---

### Issue 4: Intermittent Connection Drops

**Symptoms:**
- Works for a while, then stops
- Some requests succeed, others fail

**Diagnosis:**
```bash
./psiphon-docker.sh follow psiphon-us

dmesg | tail -50

journalctl -u psiphon-fleet.service -n 100
```

**Solutions:**

**A. Network Instability**
Check VPS network:
```bash
ping -c 10 8.8.8.8
mtr -r cloudflare.com
```

**B. Enable Auto-Recovery**
```bash
chmod +x psiphon-health-check.sh

(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/psiphon-fleet/psiphon-health-check.sh check") | crontab -
```

**C. Increase Restart Policy**
Edit `docker-compose-psiphon.yml`:
```yaml
services:
  psiphon-us:
    restart: always
```

**D. Add Resource Limits**
Prevent containers from starving each other:
```yaml
services:
  psiphon-us:
    deploy:
      resources:
        limits:
          cpus: '0.75'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
```

---

### Issue 5: Slow Connection Speed

**Symptoms:**
- High latency
- Low bandwidth
- Timeouts

**Diagnosis:**
```bash
time curl --socks5 127.0.0.1:10080 -o /dev/null -s https://speed.cloudflare.com/__down?bytes=10000000

docker stats --no-stream psiphon-us
```

**Solutions:**

**A. Try Different Country**
Some regions have better Cloudflare connectivity.

```bash
for port in {10080..10085}; do
    echo "Testing port $port..."
    time curl --socks5 127.0.0.1:$port -o /dev/null -s https://speed.cloudflare.com/__down?bytes=1000000
done
```

**B. Remove --scan Flag (May Help)**
Edit `docker-compose-psiphon.yml`, remove `--scan` from slow instances:
```yaml
command: >
  -v
  --bind 0.0.0.0:10080
  --cfon
  --country US
```

**C. Check VPS Network**
```bash
speedtest-cli
iperf3 -c speed.cloudflare.com
```

**D. Optimize System Network Stack**
```bash
cat >> /etc/sysctl.conf << EOF
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p
```

---

### Issue 6: Containers Not Starting After Reboot

**Symptoms:**
- VPS restarted
- All Psiphon containers down
- Manual start required

**Diagnosis:**
```bash
systemctl status psiphon-fleet.service

docker ps -a --filter "name=psiphon-"
```

**Solutions:**

**A. Enable Systemd Service**
```bash
cp psiphon-fleet.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable psiphon-fleet.service
systemctl start psiphon-fleet.service
systemctl status psiphon-fleet.service
```

**B. Verify Docker Auto-Start**
```bash
systemctl enable docker
systemctl is-enabled docker
```

**C. Test Service**
```bash
systemctl restart psiphon-fleet.service
sleep 30
./psiphon-docker.sh status
```

---

### Issue 7: Docker Compose Command Not Found

**Symptoms:**
```bash
$ docker-compose
bash: docker-compose: command not found
```

**Solutions:**

**A. Install Docker Compose Plugin (Recommended)**
```bash
apt-get update
apt-get install -y docker-compose-plugin

docker compose version
```

**B. Install Standalone Docker Compose**
```bash
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

docker-compose --version
```

**C. Update Scripts to Use Plugin**
Edit `psiphon-docker.sh`, replace `docker-compose` with `docker compose`.

---

### Issue 8: Permission Denied Errors

**Symptoms:**
```bash
$ ./psiphon-docker.sh status
permission denied while trying to connect to the Docker daemon socket
```

**Solutions:**

**A. Run as Root**
```bash
sudo su
cd /opt/psiphon-fleet
./psiphon-docker.sh status
```

**B. Add User to Docker Group**
```bash
usermod -aG docker $USER
newgrp docker

docker ps
```

**C. Fix Docker Socket Permissions**
```bash
chmod 666 /var/run/docker.sock
```

---

### Issue 9: Port Conflicts

**Symptoms:**
```bash
Error: bind: address already in use
```

**Diagnosis:**
```bash
ss -tulpn | grep -E ":(10080|10081|10082|10083|10084|10085)"

lsof -i :10080
```

**Solutions:**

**A. Kill Conflicting Process**
```bash
lsof -ti :10080 | xargs kill -9
```

**B. Change Ports**
Edit `docker-compose-psiphon.yml`:
```yaml
command: >
  -v
  --bind 0.0.0.0:11080
  --cfon
  --country US
  --scan
```

Update X-UI outbound configs to match new ports.

---

### Issue 10: High CPU Usage

**Symptoms:**
```bash
$ docker stats
psiphon-us    95.3%
```

**Diagnosis:**
```bash
docker stats --no-stream
top -p $(pgrep -f warp-plus)
```

**Solutions:**

**A. Limit CPU Usage**
```yaml
services:
  psiphon-us:
    deploy:
      resources:
        limits:
          cpus: '0.5'
```

**B. Check for Excessive Scanning**
Remove `--scan` if causing high CPU:
```yaml
command: >
  -v
  --bind 0.0.0.0:10080
  --cfon
  --country US
```

**C. Reduce Instance Count**
If VPS is underpowered, run fewer instances:
```bash
docker-compose -f docker-compose-psiphon.yml stop psiphon-sg psiphon-nl
```

---

## 🔧 Advanced Debugging

### Enable Verbose Logging

Already enabled with `-v` flag. To see more:
```bash
./psiphon-docker.sh follow psiphon-us
```

### Inspect Container Details

```bash
docker inspect psiphon-us

docker inspect psiphon-us --format '{{.State.Status}}'
docker inspect psiphon-us --format '{{.State.Health}}'
docker inspect psiphon-us --format '{{.NetworkSettings.Networks}}'
```

### Test SOCKS5 Manually

```bash
nc -zv 127.0.0.1 10080

timeout 10 curl -v --socks5 127.0.0.1:10080 https://ipapi.co/json
```

### Check Cloudflare Connectivity

```bash
curl --socks5 127.0.0.1:10080 https://1.1.1.1/cdn-cgi/trace

curl --socks5 127.0.0.1:10080 https://speed.cloudflare.com/__down?bytes=1000
```

### Strace Container Process

```bash
docker exec -it psiphon-us sh

ps aux | grep warp
strace -p <PID>
```

---

## 📋 Diagnostic Checklist

When reporting issues, provide:

- [ ] Output of `./psiphon-docker.sh status`
- [ ] Output of `./psiphon-docker.sh verify`
- [ ] Logs: `./psiphon-docker.sh logs > logs.txt`
- [ ] Docker version: `docker --version`
- [ ] OS info: `cat /etc/os-release`
- [ ] VPS specs: RAM, CPU, disk
- [ ] Network test: `curl https://ipapi.co/json`

---

## 🆘 Still Not Working?

### Complete Reset

```bash
cd /opt/psiphon-fleet

./psiphon-docker.sh cleanup

docker system prune -af

docker pull bigbugcc/warp-plus:latest

./psiphon-docker.sh setup

sleep 120

./psiphon-docker.sh verify
```

### Contact Support

1. Save diagnostic info:
```bash
./psiphon-docker.sh status > diagnostic.txt
./psiphon-docker.sh logs >> diagnostic.txt
docker ps -a >> diagnostic.txt
docker inspect psiphon-us >> diagnostic.txt
```

2. Open issue on GitHub with `diagnostic.txt`

---

## 📚 Additional Resources

- [Deployment Guide](./DEPLOYMENT.md)
- [warp-plus Documentation](https://github.com/bepass-org/warp-plus)
- [Docker Documentation](https://docs.docker.com/)
- [X-UI Panel Guide](https://github.com/alireza0/x-ui)
