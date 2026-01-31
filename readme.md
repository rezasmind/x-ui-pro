<p align="center">
  <img src="https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/media/XUI_Pro_Logo.png" alt="X-UI-PRO Logo" width="400">
</p>

<h1 align="center">🌐 X-UI-PRO: Multi-Country VPN Server</h1>

<p align="center">
  <b>Deploy a single VPS that connects through multiple countries simultaneously</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Version-2.0-blue?style=for-the-badge" alt="Version">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/Platform-Linux-orange?style=for-the-badge" alt="Platform">
</p>

---

## 🎯 What is X-UI-PRO?

X-UI-PRO transforms a **single VPS** into a **multi-country proxy server**. Using the power of Psiphon technology, you can create VPN configurations that exit through **5 different countries simultaneously** - all from one server.

### ✨ Key Features

| Feature                      | Description                                                                   |
| ---------------------------- | ----------------------------------------------------------------------------- |
| 🌍 **Multi-Country Exit**    | 5 concurrent Psiphon instances (ports 8080-8084), each in a different country |
| 🔒 **Full TLS Security**     | All traffic encrypted with Let's Encrypt SSL certificates                     |
| 🌐 **Cloudflare Compatible** | Works behind Cloudflare CDN for additional protection                         |
| 🎛️ **X-UI Panel**            | Beautiful web interface for managing VPN configurations                       |
| 🔄 **Auto-Recovery**         | Services auto-restart on failure with health monitoring                       |
| 📊 **Real-time Monitoring**  | Live dashboard showing all instance statuses                                  |

---

## 🏗️ Architecture Overview

```
                                    ┌─────────────────────────────────────────┐
                                    │           YOUR SINGLE VPS               │
                                    │                                         │
                                    │  ┌─────────────────────────────────┐   │
                                    │  │         X-UI Panel              │   │
                                    │  │    (Create VPN Configs)          │   │
┌──────────────┐                    │  └─────────────────────────────────┘   │
│   Client     │  ──── HTTPS ────▶ │                  │                      │
│ (Your Users) │     Port 443      │                  ▼                      │
└──────────────┘                    │  ┌─────────────────────────────────┐   │
                                    │  │         NGINX Reverse Proxy       │  │
                                    │  │    (SSL Termination + Routing)    │  │
                                    │  └─────────────────────────────────┘   │
                                    │                  │                      │
                                    │    ┌─────────────┼─────────────┐       │
                                    │    ▼             ▼             ▼       │
                                    │ ┌──────┐    ┌──────┐    ┌──────┐      │
                                    │ │:8080 │    │:8081 │    │:8082 │      │
                                    │ │  US  │    │  DE  │    │  GB  │      │
                                    │ └──┬───┘    └──┬───┘    └──┬───┘      │
                                    │    │           │           │           │
                                    │ ┌──────┐    ┌──────┐                   │
                                    │ │:8083 │    │:8084 │                   │
                                    │ │  NL  │    │  FR  │                   │
                                    │ └──┬───┘    └──┬───┘                   │
                                    └────┼───────────┼───────────────────────┘
                                         │           │
                                         ▼           ▼
                              ┌─────────────────────────────────────┐
                              │       INTERNET (Multiple Countries)  │
                              │   🇺🇸 US   🇩🇪 DE   🇬🇧 GB   🇳🇱 NL   🇫🇷 FR │
                              └─────────────────────────────────────┘
```

---

## 🚀 Quick Start Guide

### Prerequisites

- A VPS running **Ubuntu 20.04+** or **Debian 11+** or **CentOS 8+**
- A domain name pointed to your VPS IP
- Root/sudo access
- Minimum 1GB RAM, 10GB storage

### Step 1: Install X-UI-PRO

```bash
sudo su -c "bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -panel 0"
```

During installation, you'll be asked:

1. Enter your subdomain (e.g., `vpn.yourdomain.com`)
2. Choose SSL method (standalone or Cloudflare DNS)
3. **Answer `y` when asked about Multi-Port Psiphon**
4. Select a country for each port (8080-8084)

### Step 2: Verify Psiphon Deployment

After installation, check that all instances are running:

```bash
./check-psiphon.sh
```

Or use the detailed management tool:

```bash
./deploy-psiphon.sh status
```

### Step 3: Configure X-UI Panel

1. Access your panel at: `https://yourdomain.com/your-secret-path/`
2. Login with the credentials shown after installation
3. Create inbound configurations (see detailed guide below)

---

## 📖 Detailed Configuration Guide

### Creating Multi-Country VPN Configs

#### Step 1: Add Psiphon Outbounds in X-UI

Go to: **X-UI Panel → Xray Configs → Outbounds → Add Outbound**

Create 5 SOCKS outbounds, one for each Psiphon instance:

| Outbound Name | Protocol | Address   | Port |
| ------------- | -------- | --------- | ---- |
| psiphon-US    | SOCKS    | 127.0.0.1 | 8080 |
| psiphon-DE    | SOCKS    | 127.0.0.1 | 8081 |
| psiphon-GB    | SOCKS    | 127.0.0.1 | 8082 |
| psiphon-NL    | SOCKS    | 127.0.0.1 | 8083 |
| psiphon-FR    | SOCKS    | 127.0.0.1 | 8084 |

Example configuration:

```json
{
  "tag": "psiphon-US",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": 8080
      }
    ]
  }
}
```

#### Step 2: Create Inbound Configurations

Go to: **X-UI Panel → Inbounds → Add Inbound**

Create an inbound for each country. Example for VLESS + WebSocket:

| Setting   | Value                          |
| --------- | ------------------------------ |
| Protocol  | VLESS                          |
| Port      | 443 (shared via nginx)         |
| Transport | WebSocket                      |
| Path      | /us-config (unique per config) |
| TLS       | Enabled                        |

#### Step 3: Route Inbounds to Outbounds

Go to: **X-UI Panel → Xray Configs → Routing Rules → Add Rule**

Create routing rules to connect specific inbounds to their Psiphon outbounds:

| Inbound Tag | Outbound Tag | Result                       |
| ----------- | ------------ | ---------------------------- |
| us-inbound  | psiphon-US   | Traffic exits via US IP      |
| de-inbound  | psiphon-DE   | Traffic exits via Germany IP |
| gb-inbound  | psiphon-GB   | Traffic exits via UK IP      |

---

## 🛠️ Management Commands

### Psiphon Instance Management

```bash
# Check status of all instances
./deploy-psiphon.sh status

# Live monitoring dashboard
./deploy-psiphon.sh monitor

# View logs for specific port
./deploy-psiphon.sh logs 8080

# Restart all instances
./deploy-psiphon.sh restart

# Restart specific instance
./deploy-psiphon.sh restart 8081

# Stop all instances
./deploy-psiphon.sh stop

# Reconfigure all instances (change countries)
./deploy-psiphon.sh

# Uninstall Psiphon instances
./deploy-psiphon.sh uninstall
```

### Quick Status Check

```bash
./check-psiphon.sh
```

### Change Country for Main WARP Instance

```bash
# Single country
bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -WarpCfonCountry US

# Random country
bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -WarpCfonCountry XX
```

### Tor Configuration

```bash
# Set Tor exit country
bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -TorCountry US

# Random Tor country
bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -TorCountry XX
```

---

## 🌍 Supported Countries

Use these 2-letter codes when configuring Psiphon instances:

| Code | Country     | Code | Country        | Code | Country       |
| ---- | ----------- | ---- | -------------- | ---- | ------------- |
| AT   | Austria     | HU   | Hungary        | PL   | Poland        |
| AU   | Australia   | IE   | Ireland        | PT   | Portugal      |
| BE   | Belgium     | IN   | India          | RO   | Romania       |
| BG   | Bulgaria    | IT   | Italy          | RS   | Serbia        |
| BR   | Brazil      | JP   | Japan          | SE   | Sweden        |
| CA   | Canada      | LV   | Latvia         | SG   | Singapore     |
| CH   | Switzerland | NL   | Netherlands    | SK   | Slovakia      |
| CZ   | Czechia     | NO   | Norway         | UA   | Ukraine       |
| DE   | Germany     | GB   | United Kingdom | US   | United States |
| DK   | Denmark     |      |                |      |               |
| EE   | Estonia     |      |                |      |               |
| ES   | Spain       |      |                |      |               |
| FI   | Finland     |      |                |      |               |
| FR   | France      |      |                |      |               |
| HR   | Croatia     |      |                |      |               |

---

## ⚙️ Installation Options

### Basic Installation

```bash
sudo su -c "bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -panel 0"
```

### With Cloudflare CDN Protection

```bash
sudo su -c "bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -panel 0 -cdn on"
```

### With Country Restriction

```bash
# Only allow connections from specific countries
sudo su -c "bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -panel 0 -cdn on -country us,de,gb"
```

### Secure Mode (Advanced)

```bash
sudo su -c "bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -panel 0 -cdn on -secure yes"
```

### All Available Arguments

| Argument           | Values       | Description                                                         |
| ------------------ | ------------ | ------------------------------------------------------------------- |
| `-panel`           | 0, 1, 2, 3   | X-UI variant (0=Alireza, 1=MHSanaei, 2=FranzKafkaYu, 3=AghayeCoder) |
| `-xuiver`          | version/last | X-UI version to install                                             |
| `-subdomain`       | domain       | Your subdomain                                                      |
| `-cdn`             | on/off       | Cloudflare CDN mode                                                 |
| `-secure`          | yes/no       | Enhanced security mode                                              |
| `-country`         | XX/codes     | Country restrictions                                                |
| `-ufw`             | on           | Enable UFW firewall                                                 |
| `-WarpCfonCountry` | code         | WARP+Psiphon country                                                |
| `-WarpLicKey`      | key          | WARP+ license key                                                   |
| `-TorCountry`      | code         | Tor exit node country                                               |
| `-RandomTemplate`  | yes          | Random fake website template                                        |
| `-Uninstall`       | yes          | Uninstall X-UI-PRO                                                  |

---

## 🔧 Troubleshooting

### Psiphon Instances Not Connecting

1. **Wait for initialization**: First startup can take 1-3 minutes

   ```bash
   # Watch the status in real-time
   ./deploy-psiphon.sh monitor
   ```

2. **Check service logs**:

   ```bash
   ./deploy-psiphon.sh logs 8080
   # or
   journalctl -u psiphon-8080 -f
   ```

3. **Restart specific instance**:

   ```bash
   ./deploy-psiphon.sh restart 8080
   ```

4. **Restart all instances**:
   ```bash
   ./deploy-psiphon.sh restart
   ```

### SSL Certificate Issues

```bash
# Force renewal
certbot renew --force-renewal

# Check certificate status
certbot certificates
```

### Nginx Issues

```bash
# Test configuration
nginx -t

# Restart nginx
systemctl restart nginx
```

### Check All Services

```bash
# X-UI Panel
systemctl status x-ui

# Nginx
systemctl status nginx

# Psiphon instances
./check-psiphon.sh
```

---

## 📊 Ports Reference

| Port  | Service | Description                                       |
| ----- | ------- | ------------------------------------------------- |
| 80    | Nginx   | HTTP (redirects to HTTPS)                         |
| 443   | Nginx   | HTTPS (main entry point)                          |
| 2017  | v2rayA  | v2rayA Web Panel                                  |
| 2053+ | X-UI    | X-UI Panel (internal)                             |
| 8080  | Psiphon | Instance #1 (Country 1)                           |
| 8081  | Psiphon | Instance #2 (Country 2)                           |
| 8082  | Psiphon | Instance #3 (Country 3)                           |
| 8083  | Psiphon | Instance #4 (Country 4)                           |
| 8084  | Psiphon | Instance #5 (Country 5)                           |
| 8086  | WARP    | Single WARP instance (if not using multi-Psiphon) |
| 9050  | Tor     | Tor SOCKS proxy                                   |

---

## 🔐 Security Best Practices

1. **Always use HTTPS** (port 443) for client connections
2. **Enable UFW firewall**:
   ```bash
   bash <(wget -qO- raw.githubusercontent.com/rezasmind/x-ui-pro/master/x-ui-pro.sh) -ufw on
   ```
3. **Change default SSH port**:
   ```bash
   sudo bash -c 'read -p "Enter new SSH port: " port && sed -i "s/^#Port 22/Port $port/" /etc/ssh/sshd_config && ufw allow ${port}/tcp && systemctl restart sshd'
   ```
4. **Use Cloudflare CDN** for additional protection
5. **Regularly update** your VPS and X-UI panel

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## 📜 License

This project is licensed under the MIT License.

---

## 🙏 Credits

- [x-ui panels](https://github.com/alireza0/x-ui) - Original X-UI developers
- [warp-plus](https://github.com/bepass-org/warp-plus) - WARP/Psiphon implementation
- [v2rayA](https://github.com/v2rayA/v2rayA) - v2rayA project

---

<p align="center">
  <b>⭐ Star this repo if you find it useful! ⭐</b>
</p>
