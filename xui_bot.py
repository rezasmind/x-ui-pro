#!/usr/bin/env python3
"""
═══════════════════════════════════════════════════════════════════════════════════════════════════
  X-UI TELEGRAM BOT - Customer Management & Subscription System
  Author: Engineered for x-ui-pro
  Purpose: Complete Telegram bot for user management with country-based routing
═══════════════════════════════════════════════════════════════════════════════════════════════════
"""

import os
import sys
import json
import asyncio
import logging
import secrets
import sqlite3
from datetime import datetime, timedelta
from typing import Optional, Dict, List, Any, Tuple
from pathlib import Path
from dataclasses import dataclass, field
from enum import Enum

# Check and install dependencies
REQUIRED_PACKAGES = ["python-telegram-bot", "requests", "qrcode", "Pillow"]

def check_dependencies():
    missing = []
    try:
        import telegram
    except ImportError:
        missing.append("python-telegram-bot")
    try:
        import requests
    except ImportError:
        missing.append("requests")
    try:
        import qrcode
    except ImportError:
        missing.append("qrcode")
    try:
        from PIL import Image
    except ImportError:
        missing.append("Pillow")
    
    if missing:
        print(f"Installing missing packages: {missing}")
        os.system(f"{sys.executable} -m pip install {' '.join(missing)} -q")

check_dependencies()

from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup,
    ReplyKeyboardMarkup, KeyboardButton, InputFile
)
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, ConversationHandler, filters
)
from telegram.constants import ParseMode

import requests
import qrcode
from io import BytesIO

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

@dataclass
class BotConfig:
    """Bot Configuration"""
    token: str = ""
    admin_ids: List[int] = field(default_factory=list)
    xui_host: str = "127.0.0.1"
    xui_port: int = 2053
    xui_username: str = "admin"
    xui_password: str = "admin"
    xui_base_path: str = "/"
    domain: str = ""
    subscription_port: int = 443
    default_inbound_id: int = 1
    
    @classmethod
    def load(cls, config_file: str = "/etc/xui-bot/config.json") -> "BotConfig":
        if os.path.exists(config_file):
            with open(config_file, "r") as f:
                data = json.load(f)
                return cls(**data)
        return cls()
    
    def save(self, config_file: str = "/etc/xui-bot/config.json"):
        os.makedirs(os.path.dirname(config_file), exist_ok=True)
        with open(config_file, "w") as f:
            json.dump(self.__dict__, f, indent=2, default=list)


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# DATABASE
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

class BotDatabase:
    """SQLite database for bot data"""
    
    def __init__(self, db_path: str = "/etc/xui-bot/bot.db"):
        self.db_path = db_path
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._init_db()
    
    def _init_db(self):
        conn = sqlite3.connect(self.db_path)
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                telegram_id INTEGER PRIMARY KEY,
                username TEXT,
                first_name TEXT,
                is_admin INTEGER DEFAULT 0,
                is_banned INTEGER DEFAULT 0,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                telegram_id INTEGER,
                email TEXT UNIQUE,
                uuid TEXT,
                sub_id TEXT UNIQUE,
                country TEXT,
                inbound_id INTEGER,
                traffic_gb REAL DEFAULT 0,
                traffic_used REAL DEFAULT 0,
                expiry_date TEXT,
                is_active INTEGER DEFAULT 1,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (telegram_id) REFERENCES users(telegram_id)
            );
            
            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                telegram_id INTEGER,
                amount REAL,
                description TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (telegram_id) REFERENCES users(telegram_id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_subs_telegram ON subscriptions(telegram_id);
            CREATE INDEX IF NOT EXISTS idx_subs_email ON subscriptions(email);
        """)
        conn.commit()
        conn.close()
    
    def add_user(self, telegram_id: int, username: str = "", first_name: str = ""):
        conn = sqlite3.connect(self.db_path)
        conn.execute("""
            INSERT OR IGNORE INTO users (telegram_id, username, first_name)
            VALUES (?, ?, ?)
        """, (telegram_id, username, first_name))
        conn.commit()
        conn.close()
    
    def get_user(self, telegram_id: int) -> Optional[Dict]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute("SELECT * FROM users WHERE telegram_id = ?", (telegram_id,))
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None
    
    def add_subscription(
        self,
        telegram_id: int,
        email: str,
        uuid: str,
        sub_id: str,
        country: str,
        inbound_id: int,
        traffic_gb: float,
        expiry_days: int
    ):
        conn = sqlite3.connect(self.db_path)
        expiry_date = (datetime.now() + timedelta(days=expiry_days)).isoformat()
        conn.execute("""
            INSERT INTO subscriptions 
            (telegram_id, email, uuid, sub_id, country, inbound_id, traffic_gb, expiry_date)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (telegram_id, email, uuid, sub_id, country, inbound_id, traffic_gb, expiry_date))
        conn.commit()
        conn.close()
    
    def get_user_subscriptions(self, telegram_id: int) -> List[Dict]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            "SELECT * FROM subscriptions WHERE telegram_id = ? ORDER BY created_at DESC",
            (telegram_id,)
        )
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]
    
    def get_subscription_by_email(self, email: str) -> Optional[Dict]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute("SELECT * FROM subscriptions WHERE email = ?", (email,))
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None
    
    def update_subscription_traffic(self, email: str, used_gb: float):
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "UPDATE subscriptions SET traffic_used = ? WHERE email = ?",
            (used_gb, email)
        )
        conn.commit()
        conn.close()
    
    def extend_subscription(self, email: str, extra_days: int):
        conn = sqlite3.connect(self.db_path)
        conn.execute("""
            UPDATE subscriptions 
            SET expiry_date = datetime(expiry_date, '+' || ? || ' days')
            WHERE email = ?
        """, (extra_days, email))
        conn.commit()
        conn.close()
    
    def add_traffic(self, email: str, extra_gb: float):
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "UPDATE subscriptions SET traffic_gb = traffic_gb + ? WHERE email = ?",
            (extra_gb, email)
        )
        conn.commit()
        conn.close()


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# X-UI API CLIENT (Simplified for bot)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

class XUIClient:
    """Simplified X-UI API client for bot operations"""
    
    def __init__(self, config: BotConfig):
        self.config = config
        self.session = requests.Session()
        self._logged_in = False
    
    @property
    def base_url(self) -> str:
        path = self.config.xui_base_path.strip("/")
        path = f"/{path}" if path else ""
        return f"http://{self.config.xui_host}:{self.config.xui_port}{path}"
    
    def login(self) -> bool:
        try:
            response = self.session.post(
                f"{self.base_url}/login",
                data={
                    "username": self.config.xui_username,
                    "password": self.config.xui_password
                },
                timeout=10
            )
            data = response.json()
            self._logged_in = data.get("success", False)
            return self._logged_in
        except Exception as e:
            logging.error(f"Login failed: {e}")
            return False
    
    def ensure_logged_in(self):
        if not self._logged_in:
            if not self.login():
                raise Exception("X-UI authentication failed")
    
    def list_inbounds(self) -> List[Dict]:
        self.ensure_logged_in()
        response = self.session.post(f"{self.base_url}/panel/inbound/list", timeout=10)
        data = response.json()
        return data.get("obj", [])
    
    def get_inbound(self, inbound_id: int) -> Optional[Dict]:
        self.ensure_logged_in()
        response = self.session.get(f"{self.base_url}/panel/inbound/get/{inbound_id}", timeout=10)
        data = response.json()
        return data.get("obj")
    
    def add_client(
        self,
        inbound_id: int,
        email: str,
        uuid: str,
        traffic_gb: float = 0,
        expiry_days: int = 30,
        limit_ip: int = 2,
        telegram_id: str = "",
        sub_id: str = ""
    ) -> bool:
        self.ensure_logged_in()
        
        expiry_time = 0
        if expiry_days > 0:
            expiry_time = int((datetime.now() + timedelta(days=expiry_days)).timestamp() * 1000)
        
        client = {
            "id": uuid,
            "email": email,
            "enable": True,
            "flow": "",
            "totalGB": int(traffic_gb * 1024 * 1024 * 1024),
            "expiryTime": expiry_time,
            "limitIp": limit_ip,
            "tgId": telegram_id,
            "subId": sub_id
        }
        
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client]})
        }
        
        try:
            response = self.session.post(
                f"{self.base_url}/panel/inbound/addClient",
                data=payload,
                timeout=10
            )
            data = response.json()
            return data.get("success", False)
        except Exception as e:
            logging.error(f"Add client failed: {e}")
            return False
    
    def update_client_traffic(self, inbound_id: int, uuid: str, new_total_gb: float) -> bool:
        self.ensure_logged_in()
        
        # Get current client data
        inbound = self.get_inbound(inbound_id)
        if not inbound:
            return False
        
        settings = json.loads(inbound.get("settings", "{}"))
        clients = settings.get("clients", [])
        
        for client in clients:
            if client.get("id") == uuid:
                client["totalGB"] = int(new_total_gb * 1024 * 1024 * 1024)
                break
        else:
            return False
        
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client]})
        }
        
        try:
            response = self.session.post(
                f"{self.base_url}/panel/inbound/updateClient/{uuid}",
                data=payload,
                timeout=10
            )
            data = response.json()
            return data.get("success", False)
        except Exception as e:
            logging.error(f"Update client failed: {e}")
            return False
    
    def get_client_traffic(self, email: str) -> Optional[Dict]:
        self.ensure_logged_in()
        try:
            response = self.session.get(
                f"{self.base_url}/panel/inbound/getClientTraffics/{email}",
                timeout=10
            )
            data = response.json()
            return data.get("obj")
        except Exception as e:
            logging.error(f"Get traffic failed: {e}")
            return None
    
    def delete_client(self, inbound_id: int, uuid: str) -> bool:
        self.ensure_logged_in()
        try:
            response = self.session.post(
                f"{self.base_url}/panel/inbound/{inbound_id}/delClient/{uuid}",
                timeout=10
            )
            data = response.json()
            return data.get("success", False)
        except Exception as e:
            logging.error(f"Delete client failed: {e}")
            return False


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# COUNTRY MANAGER
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

class CountryManager:
    """Manages available countries from Psiphon fleet"""
    
    FLEET_STATE_FILE = "/etc/psiphon-fleet/fleet.state"
    
    COUNTRY_FLAGS = {
        "US": "🇺🇸", "DE": "🇩🇪", "GB": "🇬🇧", "NL": "🇳🇱", "FR": "🇫🇷",
        "SG": "🇸🇬", "JP": "🇯🇵", "CA": "🇨🇦", "AU": "🇦🇺", "CH": "🇨🇭",
        "SE": "🇸🇪", "NO": "🇳🇴", "AT": "🇦🇹", "BE": "🇧🇪", "CZ": "🇨🇿",
        "DK": "🇩🇰", "ES": "🇪🇸", "FI": "🇫🇮", "HU": "🇭🇺", "IE": "🇮🇪",
        "IT": "🇮🇹", "PL": "🇵🇱", "PT": "🇵🇹", "RO": "🇷🇴", "SK": "🇸🇰",
        "IN": "🇮🇳", "BR": "🇧🇷"
    }
    
    COUNTRY_NAMES = {
        "US": "United States", "DE": "Germany", "GB": "United Kingdom",
        "NL": "Netherlands", "FR": "France", "SG": "Singapore",
        "JP": "Japan", "CA": "Canada", "AU": "Australia",
        "CH": "Switzerland", "SE": "Sweden", "NO": "Norway",
        "AT": "Austria", "BE": "Belgium", "CZ": "Czech Republic",
        "DK": "Denmark", "ES": "Spain", "FI": "Finland",
        "HU": "Hungary", "IE": "Ireland", "IT": "Italy",
        "PL": "Poland", "PT": "Portugal", "RO": "Romania",
        "SK": "Slovakia", "IN": "India", "BR": "Brazil"
    }
    
    def __init__(self):
        self.countries = self._load_countries()
    
    def _load_countries(self) -> Dict[str, int]:
        """Load available countries from Psiphon fleet state"""
        countries = {}
        
        if os.path.exists(self.FLEET_STATE_FILE):
            try:
                with open(self.FLEET_STATE_FILE, "r") as f:
                    for line in f:
                        if "=" in line:
                            instance_id, config = line.strip().split("=", 1)
                            country, port = config.split(":")
                            countries[country] = int(port)
            except Exception as e:
                logging.error(f"Failed to load fleet state: {e}")
        
        return countries
    
    def get_available(self) -> List[str]:
        """Get list of available country codes"""
        return list(self.countries.keys())
    
    def get_display_name(self, code: str) -> str:
        """Get display name with flag"""
        flag = self.COUNTRY_FLAGS.get(code, "🌍")
        name = self.COUNTRY_NAMES.get(code, code)
        return f"{flag} {name}"
    
    def is_available(self, code: str) -> bool:
        """Check if country is available"""
        return code.upper() in self.countries


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# SUBSCRIPTION LINK GENERATOR
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

class LinkGenerator:
    """Generate subscription links and QR codes"""
    
    def __init__(self, config: BotConfig):
        self.config = config
    
    def generate_vless_link(
        self,
        uuid: str,
        address: str,
        port: int,
        path: str,
        sni: str,
        name: str = "xui-config"
    ) -> str:
        """Generate VLESS WebSocket link"""
        # vless://uuid@address:port?type=ws&security=tls&path=path&host=sni&sni=sni#name
        from urllib.parse import quote
        
        params = f"type=ws&security=tls&path={quote(path)}&host={sni}&sni={sni}"
        link = f"vless://{uuid}@{address}:{port}?{params}#{quote(name)}"
        return link
    
    def generate_subscription_url(self, sub_id: str) -> str:
        """Generate subscription URL"""
        domain = self.config.domain
        port = self.config.subscription_port
        
        if port == 443:
            return f"https://{domain}/sub/{sub_id}"
        else:
            return f"https://{domain}:{port}/sub/{sub_id}"
    
    def generate_qr_code(self, content: str) -> BytesIO:
        """Generate QR code image"""
        qr = qrcode.QRCode(
            version=1,
            error_correction=qrcode.constants.ERROR_CORRECT_L,
            box_size=10,
            border=4,
        )
        qr.add_data(content)
        qr.make(fit=True)
        
        img = qr.make_image(fill_color="black", back_color="white")
        buffer = BytesIO()
        img.save(buffer, format="PNG")
        buffer.seek(0)
        return buffer


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# BOT HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

# Conversation states
(
    STATE_WAITING_COUNTRY,
    STATE_WAITING_TRAFFIC,
    STATE_WAITING_DAYS,
    STATE_WAITING_CONFIRM,
    STATE_ADMIN_MANAGE,
    STATE_EXTEND_DAYS,
    STATE_ADD_TRAFFIC,
) = range(7)


class XUIBot:
    """Main Telegram Bot Class"""
    
    def __init__(self, config: BotConfig):
        self.config = config
        self.db = BotDatabase()
        self.xui = XUIClient(config)
        self.countries = CountryManager()
        self.links = LinkGenerator(config)
        self.app: Optional[Application] = None
    
    def is_admin(self, user_id: int) -> bool:
        """Check if user is admin"""
        return user_id in self.config.admin_ids
    
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Command Handlers
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    
    async def cmd_start(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle /start command"""
        user = update.effective_user
        self.db.add_user(user.id, user.username or "", user.first_name or "")
        
        welcome_text = f"""
🌐 *Welcome to X-UI VPN Bot!*

Hello {user.first_name}! 👋

Use this bot to manage your VPN subscriptions.

*Available Commands:*
• /new - Create new subscription
• /mysubs - View your subscriptions
• /status - Check subscription status
• /help - Show help message
"""
        
        if self.is_admin(user.id):
            welcome_text += """
*Admin Commands:*
• /admin - Admin panel
• /stats - Server statistics
• /users - List all users
"""
        
        keyboard = [
            [KeyboardButton("🆕 New Subscription"), KeyboardButton("📋 My Subscriptions")],
            [KeyboardButton("📊 Status"), KeyboardButton("❓ Help")]
        ]
        
        await update.message.reply_text(
            welcome_text,
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=ReplyKeyboardMarkup(keyboard, resize_keyboard=True)
        )
    
    async def cmd_new(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Start new subscription flow"""
        available = self.countries.get_available()
        
        if not available:
            await update.message.reply_text(
                "❌ No countries available at the moment. Please contact admin."
            )
            return ConversationHandler.END
        
        # Build country selection keyboard
        buttons = []
        row = []
        for code in available:
            display = self.countries.get_display_name(code)
            row.append(InlineKeyboardButton(display, callback_data=f"country_{code}"))
            if len(row) == 2:
                buttons.append(row)
                row = []
        if row:
            buttons.append(row)
        
        buttons.append([InlineKeyboardButton("❌ Cancel", callback_data="cancel")])
        
        await update.message.reply_text(
            "🌍 *Select Country*\n\n"
            "Choose the exit country for your VPN connection:",
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons)
        )
        
        return STATE_WAITING_COUNTRY
    
    async def callback_country(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle country selection"""
        query = update.callback_query
        await query.answer()
        
        if query.data == "cancel":
            await query.edit_message_text("❌ Subscription cancelled.")
            return ConversationHandler.END
        
        country = query.data.replace("country_", "")
        context.user_data["country"] = country
        
        # Traffic selection
        buttons = [
            [
                InlineKeyboardButton("10 GB", callback_data="traffic_10"),
                InlineKeyboardButton("30 GB", callback_data="traffic_30"),
                InlineKeyboardButton("50 GB", callback_data="traffic_50")
            ],
            [
                InlineKeyboardButton("100 GB", callback_data="traffic_100"),
                InlineKeyboardButton("∞ Unlimited", callback_data="traffic_0")
            ],
            [InlineKeyboardButton("❌ Cancel", callback_data="cancel")]
        ]
        
        await query.edit_message_text(
            f"📦 *Select Traffic Limit*\n\n"
            f"Country: {self.countries.get_display_name(country)}\n\n"
            "Choose your data limit:",
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons)
        )
        
        return STATE_WAITING_TRAFFIC
    
    async def callback_traffic(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle traffic selection"""
        query = update.callback_query
        await query.answer()
        
        if query.data == "cancel":
            await query.edit_message_text("❌ Subscription cancelled.")
            return ConversationHandler.END
        
        traffic = int(query.data.replace("traffic_", ""))
        context.user_data["traffic"] = traffic
        
        # Duration selection
        buttons = [
            [
                InlineKeyboardButton("7 Days", callback_data="days_7"),
                InlineKeyboardButton("15 Days", callback_data="days_15"),
                InlineKeyboardButton("30 Days", callback_data="days_30")
            ],
            [
                InlineKeyboardButton("60 Days", callback_data="days_60"),
                InlineKeyboardButton("90 Days", callback_data="days_90")
            ],
            [InlineKeyboardButton("❌ Cancel", callback_data="cancel")]
        ]
        
        traffic_display = f"{traffic} GB" if traffic > 0 else "Unlimited"
        
        await query.edit_message_text(
            f"📅 *Select Duration*\n\n"
            f"Country: {self.countries.get_display_name(context.user_data['country'])}\n"
            f"Traffic: {traffic_display}\n\n"
            "Choose subscription duration:",
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons)
        )
        
        return STATE_WAITING_DAYS
    
    async def callback_days(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle days selection and create subscription"""
        query = update.callback_query
        await query.answer()
        
        if query.data == "cancel":
            await query.edit_message_text("❌ Subscription cancelled.")
            return ConversationHandler.END
        
        days = int(query.data.replace("days_", ""))
        context.user_data["days"] = days
        
        # Show confirmation
        country = context.user_data["country"]
        traffic = context.user_data["traffic"]
        traffic_display = f"{traffic} GB" if traffic > 0 else "Unlimited"
        
        buttons = [
            [
                InlineKeyboardButton("✅ Confirm", callback_data="confirm_yes"),
                InlineKeyboardButton("❌ Cancel", callback_data="cancel")
            ]
        ]
        
        await query.edit_message_text(
            f"📝 *Confirm Subscription*\n\n"
            f"Country: {self.countries.get_display_name(country)}\n"
            f"Traffic: {traffic_display}\n"
            f"Duration: {days} days\n\n"
            "Confirm to create subscription?",
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons)
        )
        
        return STATE_WAITING_CONFIRM
    
    async def callback_confirm(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Confirm and create subscription"""
        query = update.callback_query
        await query.answer()
        
        if query.data == "cancel":
            await query.edit_message_text("❌ Subscription cancelled.")
            return ConversationHandler.END
        
        user = update.effective_user
        country = context.user_data["country"]
        traffic = context.user_data["traffic"]
        days = context.user_data["days"]
        
        await query.edit_message_text("⏳ Creating subscription...")
        
        try:
            # Generate unique identifiers
            client_uuid = str(__import__("uuid").uuid4())
            sub_id = secrets.token_hex(8)
            email = f"user-{country.lower()}-{secrets.token_hex(4)}"
            
            # Add client to X-UI
            success = self.xui.add_client(
                inbound_id=self.config.default_inbound_id,
                email=email,
                uuid=client_uuid,
                traffic_gb=float(traffic),
                expiry_days=days,
                limit_ip=2,
                telegram_id=str(user.id),
                sub_id=sub_id
            )
            
            if not success:
                await query.edit_message_text(
                    "❌ Failed to create subscription. Please contact admin."
                )
                return ConversationHandler.END
            
            # Save to local database
            self.db.add_subscription(
                telegram_id=user.id,
                email=email,
                uuid=client_uuid,
                sub_id=sub_id,
                country=country,
                inbound_id=self.config.default_inbound_id,
                traffic_gb=float(traffic),
                expiry_days=days
            )
            
            # Generate subscription URL
            sub_url = self.links.generate_subscription_url(sub_id)
            
            # Generate QR code
            qr_buffer = self.links.generate_qr_code(sub_url)
            
            traffic_display = f"{traffic} GB" if traffic > 0 else "Unlimited"
            expiry_date = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
            
            success_text = f"""
✅ *Subscription Created Successfully!*

{self.countries.get_display_name(country)}

📧 *Config Name:* `{email}`
📦 *Traffic:* {traffic_display}
📅 *Expires:* {expiry_date}

🔗 *Subscription Link:*
`{sub_url}`

Scan the QR code or use the subscription link in your VPN app.

*Recommended Apps:*
• iOS: Streisand, V2Box, Shadowrocket
• Android: V2rayNG, NekoBox
• Windows: V2rayN, Nekoray
• macOS: V2rayU, ClashX
"""
            
            await query.delete_message()
            await context.bot.send_photo(
                chat_id=user.id,
                photo=InputFile(qr_buffer, filename="subscription_qr.png"),
                caption=success_text,
                parse_mode=ParseMode.MARKDOWN
            )
            
        except Exception as e:
            logging.error(f"Failed to create subscription: {e}")
            await query.edit_message_text(
                f"❌ Error: {str(e)}\n\nPlease contact admin."
            )
        
        return ConversationHandler.END
    
    async def cmd_mysubs(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Show user's subscriptions"""
        user = update.effective_user
        subs = self.db.get_user_subscriptions(user.id)
        
        if not subs:
            await update.message.reply_text(
                "📋 You don't have any subscriptions yet.\n\n"
                "Use /new to create one!"
            )
            return
        
        text = "📋 *Your Subscriptions:*\n\n"
        
        for i, sub in enumerate(subs, 1):
            country = sub["country"]
            traffic = sub["traffic_gb"]
            traffic_used = sub.get("traffic_used", 0)
            expiry = sub["expiry_date"][:10] if sub["expiry_date"] else "Never"
            is_active = "✅" if sub["is_active"] else "❌"
            
            traffic_text = f"{traffic_used:.1f}/{traffic:.0f} GB" if traffic > 0 else "Unlimited"
            
            text += f"{i}. {self.countries.get_display_name(country)}\n"
            text += f"   {is_active} `{sub['email']}`\n"
            text += f"   📦 {traffic_text} | 📅 {expiry}\n\n"
        
        buttons = []
        for sub in subs[:5]:  # Limit to 5 buttons
            buttons.append([
                InlineKeyboardButton(
                    f"📎 Get Link: {sub['email'][:15]}...",
                    callback_data=f"getlink_{sub['email']}"
                )
            ])
        
        await update.message.reply_text(
            text,
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons) if buttons else None
        )
    
    async def callback_getlink(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Get subscription link for specific config"""
        query = update.callback_query
        await query.answer()
        
        email = query.data.replace("getlink_", "")
        sub = self.db.get_subscription_by_email(email)
        
        if not sub:
            await query.answer("❌ Subscription not found", show_alert=True)
            return
        
        sub_url = self.links.generate_subscription_url(sub["sub_id"])
        qr_buffer = self.links.generate_qr_code(sub_url)
        
        text = f"""
🔗 *Subscription Link*

`{sub_url}`

Scan QR or copy the link above.
"""
        
        await context.bot.send_photo(
            chat_id=query.from_user.id,
            photo=InputFile(qr_buffer, filename="qr.png"),
            caption=text,
            parse_mode=ParseMode.MARKDOWN
        )
    
    async def cmd_status(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Check subscription status"""
        user = update.effective_user
        subs = self.db.get_user_subscriptions(user.id)
        
        if not subs:
            await update.message.reply_text("❌ No subscriptions found.")
            return
        
        text = "📊 *Subscription Status:*\n\n"
        
        for sub in subs:
            email = sub["email"]
            country = sub["country"]
            
            # Get real-time traffic from X-UI
            traffic_info = self.xui.get_client_traffic(email)
            
            if traffic_info:
                up = traffic_info.get("up", 0) / (1024**3)
                down = traffic_info.get("down", 0) / (1024**3)
                total = traffic_info.get("total", 0) / (1024**3)
                
                used = up + down
                remaining = total - used if total > 0 else float("inf")
                
                text += f"{self.countries.get_display_name(country)}\n"
                text += f"⬆️ Upload: {up:.2f} GB\n"
                text += f"⬇️ Download: {down:.2f} GB\n"
                text += f"📊 Used: {used:.2f} GB"
                
                if total > 0:
                    text += f" / {total:.0f} GB\n"
                    percent = (used / total) * 100 if total > 0 else 0
                    bar_len = 10
                    filled = int(bar_len * percent / 100)
                    bar = "█" * filled + "░" * (bar_len - filled)
                    text += f"[{bar}] {percent:.1f}%\n"
                else:
                    text += " (Unlimited)\n"
                
                text += "\n"
            else:
                text += f"{self.countries.get_display_name(country)}: ❌ Unable to fetch\n\n"
        
        await update.message.reply_text(text, parse_mode=ParseMode.MARKDOWN)
    
    async def cmd_help(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Show help message"""
        text = """
❓ *Help & Support*

*Available Commands:*
• /new - Create new subscription
• /mysubs - View your subscriptions
• /status - Check traffic usage
• /help - Show this message

*How it works:*
1. Use /new to create a subscription
2. Select your preferred exit country
3. Choose traffic limit and duration
4. Get your subscription link & QR code
5. Import into your VPN app

*Supported Apps:*
📱 *iOS:* Streisand, V2Box, Shadowrocket
📱 *Android:* V2rayNG, NekoBox, Clash
💻 *Windows:* V2rayN, Nekoray, Clash
💻 *macOS:* V2rayU, ClashX

Need help? Contact admin.
"""
        await update.message.reply_text(text, parse_mode=ParseMode.MARKDOWN)
    
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Admin Handlers
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    
    async def cmd_admin(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Admin panel"""
        if not self.is_admin(update.effective_user.id):
            await update.message.reply_text("❌ Unauthorized")
            return
        
        buttons = [
            [
                InlineKeyboardButton("📊 Stats", callback_data="admin_stats"),
                InlineKeyboardButton("👥 Users", callback_data="admin_users")
            ],
            [
                InlineKeyboardButton("📋 All Subs", callback_data="admin_subs"),
                InlineKeyboardButton("🌍 Countries", callback_data="admin_countries")
            ],
            [
                InlineKeyboardButton("➕ Create User", callback_data="admin_create"),
                InlineKeyboardButton("⚙️ Settings", callback_data="admin_settings")
            ]
        ]
        
        await update.message.reply_text(
            "🔧 *Admin Panel*\n\nSelect an option:",
            parse_mode=ParseMode.MARKDOWN,
            reply_markup=InlineKeyboardMarkup(buttons)
        )
    
    async def callback_admin(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle admin callbacks"""
        query = update.callback_query
        
        if not self.is_admin(query.from_user.id):
            await query.answer("❌ Unauthorized", show_alert=True)
            return
        
        await query.answer()
        action = query.data.replace("admin_", "")
        
        if action == "stats":
            try:
                inbounds = self.xui.list_inbounds()
                total_clients = 0
                total_traffic = 0
                
                for ib in inbounds:
                    settings = json.loads(ib.get("settings", "{}"))
                    clients = settings.get("clients", [])
                    total_clients += len(clients)
                    total_traffic += ib.get("down", 0) + ib.get("up", 0)
                
                traffic_gb = total_traffic / (1024**3)
                
                text = f"""
📊 *Server Statistics*

📡 Inbounds: {len(inbounds)}
👥 Total Clients: {total_clients}
📦 Total Traffic: {traffic_gb:.2f} GB
🌍 Countries: {len(self.countries.get_available())}
"""
                await query.edit_message_text(text, parse_mode=ParseMode.MARKDOWN)
            except Exception as e:
                await query.edit_message_text(f"❌ Error: {e}")
        
        elif action == "countries":
            available = self.countries.get_available()
            text = "🌍 *Available Countries:*\n\n"
            
            for code in available:
                text += f"• {self.countries.get_display_name(code)}\n"
            
            if not available:
                text += "No countries configured.\nRun `psiphon-fleet.sh install`"
            
            await query.edit_message_text(text, parse_mode=ParseMode.MARKDOWN)
    
    async def cancel(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Cancel current operation"""
        await update.message.reply_text("❌ Operation cancelled.")
        return ConversationHandler.END
    
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Message Handler
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    
    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Handle text messages (keyboard buttons)"""
        text = update.message.text
        
        if text == "🆕 New Subscription":
            return await self.cmd_new(update, context)
        elif text == "📋 My Subscriptions":
            return await self.cmd_mysubs(update, context)
        elif text == "📊 Status":
            return await self.cmd_status(update, context)
        elif text == "❓ Help":
            return await self.cmd_help(update, context)
    
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Bot Setup
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    
    def setup_handlers(self):
        """Setup all bot handlers"""
        
        # Conversation handler for new subscription
        conv_handler = ConversationHandler(
            entry_points=[
                CommandHandler("new", self.cmd_new),
                MessageHandler(filters.Regex("^🆕 New Subscription$"), self.cmd_new)
            ],
            states={
                STATE_WAITING_COUNTRY: [
                    CallbackQueryHandler(self.callback_country, pattern="^country_|^cancel$")
                ],
                STATE_WAITING_TRAFFIC: [
                    CallbackQueryHandler(self.callback_traffic, pattern="^traffic_|^cancel$")
                ],
                STATE_WAITING_DAYS: [
                    CallbackQueryHandler(self.callback_days, pattern="^days_|^cancel$")
                ],
                STATE_WAITING_CONFIRM: [
                    CallbackQueryHandler(self.callback_confirm, pattern="^confirm_|^cancel$")
                ]
            },
            fallbacks=[CommandHandler("cancel", self.cancel)]
        )
        
        self.app.add_handler(conv_handler)
        
        # Command handlers
        self.app.add_handler(CommandHandler("start", self.cmd_start))
        self.app.add_handler(CommandHandler("mysubs", self.cmd_mysubs))
        self.app.add_handler(CommandHandler("status", self.cmd_status))
        self.app.add_handler(CommandHandler("help", self.cmd_help))
        self.app.add_handler(CommandHandler("admin", self.cmd_admin))
        
        # Callback handlers
        self.app.add_handler(CallbackQueryHandler(self.callback_getlink, pattern="^getlink_"))
        self.app.add_handler(CallbackQueryHandler(self.callback_admin, pattern="^admin_"))
        
        # Message handler for keyboard buttons
        self.app.add_handler(MessageHandler(
            filters.TEXT & ~filters.COMMAND,
            self.handle_message
        ))
    
    def run(self):
        """Start the bot"""
        if not self.config.token:
            print("❌ Bot token not configured!")
            print("Please set the token in /etc/xui-bot/config.json")
            return
        
        self.app = Application.builder().token(self.config.token).build()
        self.setup_handlers()
        
        print("🤖 X-UI Telegram Bot starting...")
        print(f"📡 X-UI: {self.config.xui_host}:{self.config.xui_port}")
        print(f"🌍 Countries available: {len(self.countries.get_available())}")
        print(f"👤 Admins: {self.config.admin_ids}")
        
        self.app.run_polling(allowed_updates=Update.ALL_TYPES)


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# CLI & SETUP
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

def setup_wizard():
    """Interactive setup wizard"""
    print("\n" + "=" * 60)
    print("  X-UI Telegram Bot Setup Wizard")
    print("=" * 60 + "\n")
    
    config = BotConfig()
    
    config.token = input("Enter Telegram Bot Token: ").strip()
    
    admin_input = input("Enter Admin Telegram IDs (comma separated): ").strip()
    config.admin_ids = [int(x.strip()) for x in admin_input.split(",") if x.strip().isdigit()]
    
    config.xui_host = input("X-UI Panel Host [127.0.0.1]: ").strip() or "127.0.0.1"
    config.xui_port = int(input("X-UI Panel Port [2053]: ").strip() or "2053")
    config.xui_username = input("X-UI Username [admin]: ").strip() or "admin"
    config.xui_password = input("X-UI Password [admin]: ").strip() or "admin"
    config.xui_base_path = input("X-UI Base Path [/]: ").strip() or "/"
    
    config.domain = input("Your Domain (for subscription links): ").strip()
    config.subscription_port = int(input("Subscription Port [443]: ").strip() or "443")
    config.default_inbound_id = int(input("Default Inbound ID [1]: ").strip() or "1")
    
    config.save()
    print(f"\n✓ Configuration saved to /etc/xui-bot/config.json")
    print("\nStart the bot with: python3 xui_bot.py run")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="X-UI Telegram Bot")
    parser.add_argument("command", choices=["run", "setup", "test"], nargs="?", default="run")
    args = parser.parse_args()
    
    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=logging.INFO
    )
    
    if args.command == "setup":
        setup_wizard()
    elif args.command == "test":
        config = BotConfig.load()
        xui = XUIClient(config)
        if xui.login():
            print("✓ X-UI connection successful")
            inbounds = xui.list_inbounds()
            print(f"✓ Found {len(inbounds)} inbound(s)")
        else:
            print("✗ X-UI connection failed")
    else:
        config = BotConfig.load()
        if not config.token:
            print("❌ Bot not configured. Run: python3 xui_bot.py setup")
            sys.exit(1)
        
        bot = XUIBot(config)
        bot.run()


if __name__ == "__main__":
    main()
