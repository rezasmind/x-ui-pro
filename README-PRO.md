# X-UI-PRO: Multi-Country VPN with Smart Routing

A complete solution for deploying a multi-country VPN service with:
- **Psiphon Fleet**: Multiple isolated SOCKS proxies for different countries
- **Smart Routing**: Single inbound port, multiple country exits based on user email
- **Telegram Bot**: Customer management with subscription creation and traffic monitoring
- **X-UI API**: Full API integration for programmatic control

## 🚀 Quick Start

```bash
# One-command installation
bash install-pro.sh
```

## 📋 What's Included

| Component | File | Purpose |
|-----------|------|---------|
| Psiphon Fleet | `psiphon-fleet.sh` | Deploy 5+ isolated Psiphon proxies with different country exits |
| X-UI API | `xui_api.py` | Python API client for X-UI panel management |
| Telegram Bot | `xui_bot.py` | Customer-facing bot for subscription management |
| Xray Routing | `xray-routing.sh` | Auto-generate user-based routing configurations |
| Unified Installer | `install-pro.sh` | One-command deployment of everything |

## 🌍 How Multi-Country Routing Works

### The Magic: User Email = Country Exit

```
One Inbound Port (2083) → Multiple Users → Different Country Exits

user-us-john    ───► Psiphon US ───► 🇺🇸 USA Exit
user-de-mary    ───► Psiphon DE ───► 🇩🇪 Germany Exit
user-gb-peter   ───► Psiphon GB ───► 🇬🇧 UK Exit
user-nl-alice   ───► Psiphon NL ───► 🇳🇱 Netherlands Exit
```

### Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           YOUR SERVER                                     │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌─────────────────┐    ┌──────────────────────────────────────────────┐ │
│  │   X-UI Panel    │    │              PSIPHON FLEET                   │ │
│  │  (Port 2053)    │    │                                              │ │
│  │                 │    │  ┌──────────┐ ┌──────────┐ ┌──────────┐     │ │
│  │  Inbound:2083   │────│  │ US:40123 │ │ DE:40456 │ │ GB:40789 │ ... │ │
│  │  - user-us-*    │    │  └────┬─────┘ └────┬─────┘ └────┬─────┘     │ │
│  │  - user-de-*    │    │       │            │            │           │ │
│  │  - user-gb-*    │    └───────┼────────────┼────────────┼───────────┘ │
│  └─────────────────┘            │            │            │             │
│                                 ▼            ▼            ▼             │
│                            🇺🇸 USA      🇩🇪 Germany   🇬🇧 UK            │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## 📦 Psiphon Fleet

Deploy completely isolated Psiphon instances for different countries.

### Installation

```bash
./psiphon-fleet.sh install
```

### Commands

```bash
psiphon-fleet install       # Interactive setup
psiphon-fleet status        # Show all instances
psiphon-fleet add US        # Add new US instance
psiphon-fleet restart       # Restart all
psiphon-fleet logs us       # View logs
psiphon-fleet generate-xui  # Generate X-UI configs
```

### Features
- ✅ Complete instance isolation (no cross-contamination)
- ✅ Random port assignment
- ✅ Systemd integration with auto-restart
- ✅ 20+ countries supported
- ✅ Health monitoring

## 🔄 Xray Routing Configuration

Auto-generate routing rules for user-based country routing.

### Generate Configuration

```bash
./xray-routing.sh generate
```

### Output Files

| File | Purpose |
|------|---------|
| `/etc/xui-routing/outbounds.json` | Add to X-UI Xray config |
| `/etc/xui-routing/routing.json` | Add to X-UI routing rules |
| `/etc/xui-routing/user-emails.txt` | Email patterns reference |

### How to Apply

1. Go to X-UI Panel → **Panel Settings** → **Xray Configuration**
2. Add outbounds from `outbounds.json`
3. Add routing rules from `routing.json`
4. Save and restart Xray

## 🤖 Telegram Bot

Full-featured customer management bot.

### Setup

```bash
python3 xui_bot.py setup
```

### Features

**For Users:**
- `/new` - Create new subscription with country selection
- `/mysubs` - View all subscriptions
- `/status` - Check traffic usage
- QR code generation for easy import

**For Admins:**
- `/admin` - Admin panel
- Server statistics
- User management
- Country availability

### Bot Configuration

```json
{
    "token": "YOUR_BOT_TOKEN",
    "admin_ids": [123456789],
    "xui_host": "127.0.0.1",
    "xui_port": 2053,
    "xui_username": "admin",
    "xui_password": "admin",
    "domain": "vpn.example.com",
    "default_inbound_id": 1
}
```

## 🔌 X-UI API Client

Python library for programmatic X-UI control.

### Usage

```python
from xui_api import XUIAPIClient, XUIConfig, Client

# Connect
config = XUIConfig(
    host="127.0.0.1",
    port=2053,
    username="admin",
    password="admin"
)
client = XUIAPIClient(config)
client.login()

# List inbounds
inbounds = client.list_inbounds()

# Add client
new_client = Client(
    email="user-us-customer1",
    total_gb=50,
    expiry_time=int((datetime.now() + timedelta(days=30)).timestamp() * 1000)
)
client.add_client(inbound_id=1, client=new_client)

# Get traffic stats
traffic = client.get_client_traffic("user-us-customer1")
```

## 📐 Complete Setup Example

### Step 1: Install Psiphon Fleet

```bash
./psiphon-fleet.sh install

# Select countries:
# 1. US (United States)
# 2. DE (Germany)
# 3. GB (United Kingdom)
# 4. NL (Netherlands)
# 5. FR (France)
```

### Step 2: Generate Routing

```bash
./xray-routing.sh generate
```

### Step 3: Configure X-UI

1. Create inbound on port **2083**
   - Protocol: VLESS
   - Network: WebSocket
   - Security: TLS
   - Path: `/graphql`

2. Add outbounds (from generated config):
```json
{
  "tag": "out-us",
  "protocol": "socks",
  "settings": {"servers": [{"address": "127.0.0.1", "port": 40123}]}
}
```

3. Add routing rules:
```json
{
  "type": "field",
  "user": ["user-us"],
  "outboundTag": "out-us"
}
```

### Step 4: Add Clients

In X-UI, add clients with these email patterns:

| Email | Exit Country |
|-------|--------------|
| `user-us-john` | 🇺🇸 USA |
| `user-de-mary` | 🇩🇪 Germany |
| `user-gb-peter` | 🇬🇧 UK |

### Step 5: Start Telegram Bot

```bash
python3 xui_bot.py setup
systemctl start xui-bot
```

## 🔧 Troubleshooting

### Psiphon not connecting

```bash
# Check status
psiphon-fleet status

# View logs
psiphon-fleet logs us

# Restart specific instance
psiphon-fleet restart psiphon-us-40123

# Test manually
curl --socks5 127.0.0.1:40123 https://ipapi.co/json
```

### Routing not working

1. Verify email pattern matches: `user-XX-*`
2. Check outbound tag matches routing rule
3. Ensure Psiphon instance is running on correct port
4. Restart Xray after config changes

### Bot not responding

```bash
# Check status
systemctl status xui-bot

# View logs
journalctl -u xui-bot -f

# Test X-UI connection
python3 xui_api.py --action list
```

## 📁 File Structure

```
x-ui-pro/
├── install-pro.sh      # Unified installer
├── psiphon-fleet.sh    # Psiphon multi-instance manager
├── xray-routing.sh     # Routing configuration generator
├── xui_api.py          # X-UI API Python client
├── xui_bot.py          # Telegram bot
├── dp-ps.sh            # Legacy Psiphon script
├── x-ui-pro.sh         # Original X-UI installer
└── README-PRO.md       # This file
```

## 🌐 Supported Countries

| Code | Country | Code | Country |
|------|---------|------|---------|
| US | United States | NL | Netherlands |
| DE | Germany | FR | France |
| GB | United Kingdom | SG | Singapore |
| JP | Japan | CA | Canada |
| AU | Australia | CH | Switzerland |
| SE | Sweden | NO | Norway |
| AT | Austria | BE | Belgium |
| IT | Italy | ES | Spain |
| PL | Poland | PT | Portugal |

## 📊 Monitoring

### Psiphon Fleet Dashboard

```bash
psiphon-fleet status
```

### Traffic Monitoring

```bash
# Via API
python3 xui_api.py --action clients

# Via Telegram bot
/status
```

## 🔐 Security Notes

1. All Psiphon instances bind to `127.0.0.1` only
2. X-UI panel should be behind nginx with SSL
3. Use strong passwords for X-UI
4. Keep bot token secret
5. Regularly backup X-UI database

## 📝 License

MIT License - Use freely, contribute back!

---

Built with ❤️ for the x-ui-pro community
