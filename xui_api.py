#!/usr/bin/env python3
"""
═══════════════════════════════════════════════════════════════════════════════════════════════════
  X-UI API CLIENT - Unified Interface for Panel Management
  Author: Engineered for x-ui-pro
  Purpose: Complete API wrapper for 3x-ui panel with user/routing management
═══════════════════════════════════════════════════════════════════════════════════════════════════
"""

import os
import sys
import json
import time
import hashlib
import secrets
import sqlite3
import uuid
from datetime import datetime, timedelta
from typing import Optional, Dict, List, Any, Tuple
from dataclasses import dataclass, field, asdict
from pathlib import Path

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except ImportError:
    print("Installing requests...")
    os.system(f"{sys.executable} -m pip install requests -q")
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry


@dataclass
class XUIConfig:
    """X-UI Panel Configuration"""
    host: str = "127.0.0.1"
    port: int = 2053
    username: str = "admin"
    password: str = "admin"
    base_path: str = "/"
    use_ssl: bool = False
    verify_ssl: bool = False
    timeout: int = 30
    
    @property
    def base_url(self) -> str:
        protocol = "https" if self.use_ssl else "http"
        path = self.base_path.strip("/")
        path = f"/{path}" if path else ""
        return f"{protocol}://{self.host}:{self.port}{path}"


@dataclass
class Client:
    """X-UI Client/User Model"""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    email: str = ""
    enable: bool = True
    flow: str = ""
    total_gb: float = 0  # 0 = unlimited
    expiry_time: int = 0  # 0 = never expires (timestamp in ms)
    limit_ip: int = 0  # 0 = unlimited
    tg_id: str = ""
    sub_id: str = field(default_factory=lambda: secrets.token_hex(8))
    
    def to_dict(self) -> Dict:
        return {
            "id": self.id,
            "email": self.email,
            "enable": self.enable,
            "flow": self.flow,
            "totalGB": int(self.total_gb * 1024 * 1024 * 1024),  # Convert to bytes
            "expiryTime": self.expiry_time,
            "limitIp": self.limit_ip,
            "tgId": self.tg_id,
            "subId": self.sub_id,
        }
    
    @classmethod
    def from_dict(cls, data: Dict) -> "Client":
        return cls(
            id=data.get("id", str(uuid.uuid4())),
            email=data.get("email", ""),
            enable=data.get("enable", True),
            flow=data.get("flow", ""),
            total_gb=data.get("totalGB", 0) / (1024 * 1024 * 1024),
            expiry_time=data.get("expiryTime", 0),
            limit_ip=data.get("limitIp", 0),
            tg_id=data.get("tgId", ""),
            sub_id=data.get("subId", secrets.token_hex(8)),
        )


@dataclass
class Inbound:
    """X-UI Inbound Model"""
    id: int = 0
    remark: str = ""
    enable: bool = True
    protocol: str = "vless"
    port: int = 443
    listen: str = ""
    settings: Dict = field(default_factory=dict)
    stream_settings: Dict = field(default_factory=dict)
    sniffing: Dict = field(default_factory=dict)
    tag: str = ""
    clients: List[Client] = field(default_factory=list)


class XUIAPIClient:
    """
    Complete X-UI Panel API Client
    Supports: 3x-ui, x-ui, alireza-x-ui
    """
    
    def __init__(self, config: XUIConfig):
        self.config = config
        self.session = self._create_session()
        self._logged_in = False
        
    def _create_session(self) -> requests.Session:
        """Create session with retry logic"""
        session = requests.Session()
        retry = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[500, 502, 503, 504]
        )
        adapter = HTTPAdapter(max_retries=retry)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        session.verify = self.config.verify_ssl
        return session
    
    def _url(self, endpoint: str) -> str:
        """Build full URL for endpoint"""
        endpoint = endpoint.lstrip("/")
        return f"{self.config.base_url}/{endpoint}"
    
    def _request(self, method: str, endpoint: str, **kwargs) -> Dict:
        """Make API request with error handling"""
        url = self._url(endpoint)
        kwargs.setdefault("timeout", self.config.timeout)
        
        try:
            response = self.session.request(method, url, **kwargs)
            response.raise_for_status()
            
            data = response.json()
            if not data.get("success", True):
                raise Exception(data.get("msg", "Unknown API error"))
            
            return data
        except requests.exceptions.RequestException as e:
            raise Exception(f"API request failed: {e}")
    
    def login(self) -> bool:
        """Authenticate with panel"""
        try:
            response = self._request(
                "POST",
                "/login",
                data={
                    "username": self.config.username,
                    "password": self.config.password
                }
            )
            self._logged_in = response.get("success", False)
            return self._logged_in
        except Exception as e:
            print(f"Login failed: {e}")
            return False
    
    def ensure_logged_in(self):
        """Ensure we're logged in"""
        if not self._logged_in:
            if not self.login():
                raise Exception("Authentication failed")
    
    # ─────────────────────────────────────────────────────────────────────────
    # INBOUND OPERATIONS
    # ─────────────────────────────────────────────────────────────────────────
    
    def list_inbounds(self) -> List[Dict]:
        """Get all inbounds"""
        self.ensure_logged_in()
        response = self._request("POST", "/panel/inbound/list")
        return response.get("obj", [])
    
    def get_inbound(self, inbound_id: int) -> Optional[Dict]:
        """Get single inbound by ID"""
        self.ensure_logged_in()
        response = self._request("GET", f"/panel/inbound/get/{inbound_id}")
        return response.get("obj")
    
    def create_inbound(
        self,
        remark: str,
        port: int,
        protocol: str = "vless",
        network: str = "ws",
        path: str = "/graphql",
        security: str = "tls",
        clients: List[Client] = None,
        **kwargs
    ) -> Dict:
        """Create new inbound with smart defaults"""
        self.ensure_logged_in()
        
        clients = clients or []
        client_list = [c.to_dict() for c in clients]
        
        # Build settings based on protocol
        settings = {
            "clients": client_list,
            "decryption": "none",
            "fallbacks": []
        }
        
        # Stream settings
        stream_settings = {
            "network": network,
            "security": security,
        }
        
        if network == "ws":
            stream_settings["wsSettings"] = {
                "path": path,
                "headers": {"Host": kwargs.get("host", "")}
            }
        elif network == "grpc":
            stream_settings["grpcSettings"] = {
                "serviceName": path.lstrip("/"),
                "multiMode": True
            }
        
        if security == "tls":
            stream_settings["tlsSettings"] = {
                "serverName": kwargs.get("sni", ""),
                "certificates": [{
                    "certificateFile": kwargs.get("cert_file", ""),
                    "keyFile": kwargs.get("key_file", "")
                }]
            }
        
        # Sniffing
        sniffing = {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"]
        }
        
        payload = {
            "remark": remark,
            "enable": True,
            "listen": "",
            "port": port,
            "protocol": protocol,
            "settings": json.dumps(settings),
            "streamSettings": json.dumps(stream_settings),
            "sniffing": json.dumps(sniffing),
            "expiryTime": 0
        }
        
        response = self._request("POST", "/panel/inbound/add", data=payload)
        return response.get("obj", {})
    
    def update_inbound(self, inbound_id: int, **updates) -> Dict:
        """Update inbound configuration"""
        self.ensure_logged_in()
        
        # Get current inbound
        current = self.get_inbound(inbound_id)
        if not current:
            raise Exception(f"Inbound {inbound_id} not found")
        
        # Merge updates
        for key, value in updates.items():
            if key in ["settings", "streamSettings", "sniffing"]:
                current[key] = json.dumps(value) if isinstance(value, dict) else value
            else:
                current[key] = value
        
        response = self._request(
            "POST",
            f"/panel/inbound/update/{inbound_id}",
            data=current
        )
        return response.get("obj", {})
    
    def delete_inbound(self, inbound_id: int) -> bool:
        """Delete inbound"""
        self.ensure_logged_in()
        response = self._request("POST", f"/panel/inbound/del/{inbound_id}")
        return response.get("success", False)
    
    # ─────────────────────────────────────────────────────────────────────────
    # CLIENT OPERATIONS
    # ─────────────────────────────────────────────────────────────────────────
    
    def add_client(self, inbound_id: int, client: Client) -> bool:
        """Add client to inbound"""
        self.ensure_logged_in()
        
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client.to_dict()]})
        }
        
        response = self._request("POST", "/panel/inbound/addClient", data=payload)
        return response.get("success", False)
    
    def update_client(self, inbound_id: int, client_id: str, client: Client) -> bool:
        """Update existing client"""
        self.ensure_logged_in()
        
        payload = {
            "id": inbound_id,
            "settings": json.dumps({"clients": [client.to_dict()]})
        }
        
        response = self._request(
            "POST",
            f"/panel/inbound/updateClient/{client_id}",
            data=payload
        )
        return response.get("success", False)
    
    def delete_client(self, inbound_id: int, client_id: str) -> bool:
        """Delete client from inbound"""
        self.ensure_logged_in()
        response = self._request(
            "POST",
            f"/panel/inbound/{inbound_id}/delClient/{client_id}"
        )
        return response.get("success", False)
    
    def get_client_traffic(self, email: str) -> Dict:
        """Get client traffic stats"""
        self.ensure_logged_in()
        response = self._request("GET", f"/panel/inbound/getClientTraffics/{email}")
        return response.get("obj", {})
    
    def reset_client_traffic(self, inbound_id: int, email: str) -> bool:
        """Reset client traffic counter"""
        self.ensure_logged_in()
        response = self._request(
            "POST",
            f"/panel/inbound/{inbound_id}/resetClientTraffic/{email}"
        )
        return response.get("success", False)
    
    # ─────────────────────────────────────────────────────────────────────────
    # TRAFFIC & STATS
    # ─────────────────────────────────────────────────────────────────────────
    
    def get_stats(self) -> Dict:
        """Get server statistics"""
        self.ensure_logged_in()
        response = self._request("POST", "/server/status")
        return response.get("obj", {})
    
    def get_online_clients(self) -> List[str]:
        """Get list of online client emails"""
        self.ensure_logged_in()
        response = self._request("POST", "/panel/inbound/onlines")
        return response.get("obj", [])
    
    # ─────────────────────────────────────────────────────────────────────────
    # XRAY CONFIGURATION (Advanced)
    # ─────────────────────────────────────────────────────────────────────────
    
    def get_xray_config(self) -> Dict:
        """Get current Xray configuration"""
        self.ensure_logged_in()
        # This reads directly from panel settings
        response = self._request("POST", "/panel/setting/all")
        return response.get("obj", {})
    
    def restart_xray(self) -> bool:
        """Restart Xray service"""
        self.ensure_logged_in()
        response = self._request("POST", "/server/restartXray")
        return response.get("success", False)


class XUIDirectDB:
    """
    Direct SQLite database access for X-UI
    Use when API is not available or for bulk operations
    """
    
    DB_PATH = "/etc/x-ui/x-ui.db"
    
    def __init__(self, db_path: str = None):
        self.db_path = db_path or self.DB_PATH
        self._check_db()
    
    def _check_db(self):
        if not os.path.exists(self.db_path):
            raise FileNotFoundError(f"X-UI database not found: {self.db_path}")
    
    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.db_path)
    
    def get_settings(self) -> Dict[str, str]:
        """Get all panel settings"""
        conn = self._connect()
        cursor = conn.execute("SELECT key, value FROM settings")
        settings = {row[0]: row[1] for row in cursor.fetchall()}
        conn.close()
        return settings
    
    def set_setting(self, key: str, value: str):
        """Update a panel setting"""
        conn = self._connect()
        conn.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, value)
        )
        conn.commit()
        conn.close()
    
    def get_inbounds_raw(self) -> List[Dict]:
        """Get all inbounds as raw data"""
        conn = self._connect()
        conn.row_factory = sqlite3.Row
        cursor = conn.execute("SELECT * FROM inbounds")
        inbounds = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return inbounds
    
    def get_client_traffics(self) -> List[Dict]:
        """Get all client traffic records"""
        conn = self._connect()
        conn.row_factory = sqlite3.Row
        cursor = conn.execute("SELECT * FROM client_traffics")
        traffics = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return traffics
    
    def update_client_traffic_limit(self, email: str, total_bytes: int):
        """Update client's total traffic limit"""
        conn = self._connect()
        conn.execute(
            "UPDATE client_traffics SET total = ? WHERE email = ?",
            (total_bytes, email)
        )
        conn.commit()
        conn.close()
    
    def update_client_expiry(self, email: str, expiry_timestamp_ms: int):
        """Update client's expiry time in inbound settings"""
        conn = self._connect()
        inbounds = self.get_inbounds_raw()
        
        for inbound in inbounds:
            settings = json.loads(inbound.get("settings", "{}"))
            clients = settings.get("clients", [])
            
            for client in clients:
                if client.get("email") == email:
                    client["expiryTime"] = expiry_timestamp_ms
                    
                    conn.execute(
                        "UPDATE inbounds SET settings = ? WHERE id = ?",
                        (json.dumps(settings), inbound["id"])
                    )
                    break
        
        conn.commit()
        conn.close()


class CountryRoutingManager:
    """
    Manages user-to-country routing configuration
    Creates clients with specific emails that route through Psiphon proxies
    """
    
    PSIPHON_STATE_FILE = "/etc/psiphon-fleet/fleet.state"
    
    def __init__(self, xui_client: XUIAPIClient):
        self.xui = xui_client
        self.countries = self._load_psiphon_countries()
    
    def _load_psiphon_countries(self) -> Dict[str, int]:
        """Load available countries from Psiphon fleet"""
        countries = {}
        
        if os.path.exists(self.PSIPHON_STATE_FILE):
            with open(self.PSIPHON_STATE_FILE, "r") as f:
                for line in f:
                    if "=" in line:
                        instance_id, config = line.strip().split("=", 1)
                        country, port = config.split(":")
                        countries[country] = int(port)
        
        return countries
    
    def get_available_countries(self) -> List[str]:
        """Get list of available country codes"""
        return list(self.countries.keys())
    
    def create_country_user(
        self,
        inbound_id: int,
        country: str,
        traffic_gb: float = 0,
        days: int = 30,
        max_ips: int = 2,
        telegram_id: str = ""
    ) -> Tuple[Client, str]:
        """
        Create a user that routes through specific country
        Returns (Client, subscription_link)
        """
        country = country.upper()
        
        if country not in self.countries:
            raise ValueError(f"Country {country} not available. Available: {list(self.countries.keys())}")
        
        # Create client with country-specific email
        email = f"user-{country.lower()}-{secrets.token_hex(4)}"
        
        expiry = 0
        if days > 0:
            expiry = int((datetime.now() + timedelta(days=days)).timestamp() * 1000)
        
        client = Client(
            email=email,
            total_gb=traffic_gb,
            expiry_time=expiry,
            limit_ip=max_ips,
            tg_id=telegram_id
        )
        
        # Add to inbound
        success = self.xui.add_client(inbound_id, client)
        if not success:
            raise Exception("Failed to add client")
        
        return client, f"sub/{client.sub_id}"
    
    def generate_routing_rules(self) -> Dict:
        """
        Generate Xray routing rules for user-based country routing
        """
        rules = []
        
        for country, port in self.countries.items():
            rules.append({
                "type": "field",
                "user": [f"user-{country.lower()}"],
                "outboundTag": f"out-{country.lower()}"
            })
        
        # Default direct rule
        rules.append({
            "type": "field",
            "outboundTag": "direct",
            "network": "udp,tcp"
        })
        
        return {
            "routing": {
                "domainStrategy": "AsIs",
                "rules": rules
            }
        }
    
    def generate_outbounds(self) -> Dict:
        """
        Generate Xray outbound configurations for Psiphon proxies
        """
        outbounds = [
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "blocked", "protocol": "blackhole", "settings": {}}
        ]
        
        for country, port in self.countries.items():
            outbounds.append({
                "tag": f"out-{country.lower()}",
                "protocol": "socks",
                "settings": {
                    "servers": [{
                        "address": "127.0.0.1",
                        "port": port
                    }]
                }
            })
        
        return {"outbounds": outbounds}


# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# CLI Interface
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

def main():
    """CLI interface for testing"""
    import argparse
    
    parser = argparse.ArgumentParser(description="X-UI API Client")
    parser.add_argument("--host", default="127.0.0.1", help="Panel host")
    parser.add_argument("--port", type=int, default=2053, help="Panel port")
    parser.add_argument("--user", default="admin", help="Username")
    parser.add_argument("--pass", dest="password", default="admin", help="Password")
    parser.add_argument("--action", choices=["list", "stats", "clients", "routing"], default="list")
    
    args = parser.parse_args()
    
    config = XUIConfig(
        host=args.host,
        port=args.port,
        username=args.user,
        password=args.password
    )
    
    client = XUIAPIClient(config)
    
    if client.login():
        print("✓ Login successful")
        
        if args.action == "list":
            inbounds = client.list_inbounds()
            print(f"\nFound {len(inbounds)} inbound(s):")
            for ib in inbounds:
                print(f"  [{ib['id']}] {ib['remark']} - Port {ib['port']} ({ib['protocol']})")
        
        elif args.action == "stats":
            stats = client.get_stats()
            print(f"\nServer Stats:")
            print(json.dumps(stats, indent=2))
        
        elif args.action == "clients":
            online = client.get_online_clients()
            print(f"\nOnline clients: {len(online)}")
            for email in online:
                print(f"  • {email}")
        
        elif args.action == "routing":
            rm = CountryRoutingManager(client)
            print(f"\nAvailable countries: {rm.get_available_countries()}")
            print("\nRouting rules:")
            print(json.dumps(rm.generate_routing_rules(), indent=2))
            print("\nOutbounds:")
            print(json.dumps(rm.generate_outbounds(), indent=2))
    else:
        print("✗ Login failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
