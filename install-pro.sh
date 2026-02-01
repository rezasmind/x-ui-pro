#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════════════════════════
#  X-UI-PRO UNIFIED INSTALLER - Complete Multi-Country VPN Solution
#  Author: Engineered for x-ui-pro
#  Purpose: One-command deployment of Psiphon Fleet + X-UI + Telegram Bot + Auto-Routing
#═══════════════════════════════════════════════════════════════════════════════════════════════════

set -e
trap 'echo -e "\n\033[0;31m[ABORT]\033[0m Installation interrupted. Run again to resume."; exit 130' INT

# Must run as root
[[ $EUID -ne 0 ]] && { echo "Run as root!"; exec sudo "$0" "$@"; }

#───────────────────────────────────────────────────────────────────────────────────────────────────
# ANSI Colors & Styles
#───────────────────────────────────────────────────────────────────────────────────────────────────
declare -r RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m'
declare -r CYAN='\033[0;36m' MAGENTA='\033[0;35m' WHITE='\033[1;37m' NC='\033[0m'
declare -r BOLD='\033[1m' DIM='\033[2m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_step()    { echo -e "\n${MAGENTA}════════════════════════════════════════════════════════════════${NC}"; echo -e "${MAGENTA}  STEP: ${NC}${BOLD}$1${NC}"; echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}\n"; }

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/x-ui-pro"
CONFIG_DIR="/etc/x-ui-pro"
LOG_FILE="/var/log/x-ui-pro-install.log"

# Scripts to deploy
PSIPHON_FLEET_SCRIPT="${SCRIPT_DIR}/psiphon-fleet.sh"
XRAY_ROUTING_SCRIPT="${SCRIPT_DIR}/xray-routing.sh"
XUI_API_SCRIPT="${SCRIPT_DIR}/xui_api.py"
XUI_BOT_SCRIPT="${SCRIPT_DIR}/xui_bot.py"

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Banner
#───────────────────────────────────────────────────────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${MAGENTA}"
    cat << 'BANNER'
═══════════════════════════════════════════════════════════════════════════════════════════
                                                                                            
  ██╗  ██╗      ██╗   ██╗██╗      ██████╗ ██████╗  ██████╗                                  
  ╚██╗██╔╝      ██║   ██║██║      ██╔══██╗██╔══██╗██╔═══██╗                                 
   ╚███╔╝ █████╗██║   ██║██║█████╗██████╔╝██████╔╝██║   ██║                                 
   ██╔██╗ ╚════╝██║   ██║██║╚════╝██╔═══╝ ██╔══██╗██║   ██║                                 
  ██╔╝ ██╗      ╚██████╔╝██║      ██║     ██║  ██║╚██████╔╝                                 
  ╚═╝  ╚═╝       ╚═════╝ ╚═╝      ╚═╝     ╚═╝  ╚═╝ ╚═════╝                                  
                                                                                            
      UNIFIED INSTALLER - Multi-Country VPN with Smart Routing & Telegram Bot              
                                                                                            
═══════════════════════════════════════════════════════════════════════════════════════════
BANNER
    echo -e "${NC}"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Utility Functions
#───────────────────────────────────────────────────────────────────────────────────────────────────
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. Exiting."
        exit 1
    fi
    
    log_info "Detected: ${OS} ${VERSION}"
    
    case $OS in
        ubuntu|debian)
            PKG_MGR="apt"
            PKG_UPDATE="apt update -qq"
            PKG_INSTALL="apt install -y -qq"
            ;;
        centos|fedora|rhel|rocky|almalinux)
            PKG_MGR="dnf"
            PKG_UPDATE="dnf makecache -q"
            PKG_INSTALL="dnf install -y -q"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

install_base_packages() {
    log_info "Installing base packages..."
    
    $PKG_UPDATE &>> "$LOG_FILE"
    
    local packages="curl wget jq sqlite3 python3 python3-pip git psmisc"
    
    for pkg in $packages; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -l "$pkg" &>/dev/null 2>&1; then
            $PKG_INSTALL "$pkg" &>> "$LOG_FILE" || true
        fi
    done
    
    # Install Python packages
    pip3 install --quiet requests python-telegram-bot qrcode Pillow 2>> "$LOG_FILE" || true
    
    log_success "Base packages installed"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Component Installation
#───────────────────────────────────────────────────────────────────────────────────────────────────
install_psiphon_fleet() {
    log_step "Installing Psiphon Fleet"
    
    if [[ ! -f "$PSIPHON_FLEET_SCRIPT" ]]; then
        log_error "Psiphon Fleet script not found: $PSIPHON_FLEET_SCRIPT"
        exit 1
    fi
    
    chmod +x "$PSIPHON_FLEET_SCRIPT"
    
    echo ""
    echo -e "${YELLOW}How many Psiphon proxy instances do you want?${NC}"
    echo -e "${DIM}Each instance provides a different country exit point.${NC}"
    echo ""
    
    read -rp "Enter number of instances (1-10) [5]: " num_instances
    num_instances=${num_instances:-5}
    
    if [[ ! "$num_instances" =~ ^[0-9]+$ ]] || [[ "$num_instances" -lt 1 ]] || [[ "$num_instances" -gt 10 ]]; then
        num_instances=5
    fi
    
    echo ""
    echo -e "${CYAN}Available Countries:${NC}"
    echo "  US (USA)        DE (Germany)    GB (UK)         NL (Netherlands)"
    echo "  FR (France)     SG (Singapore)  JP (Japan)      CA (Canada)"
    echo "  AU (Australia)  CH (Switzerland) SE (Sweden)    IT (Italy)"
    echo ""
    
    declare -A COUNTRIES_TO_INSTALL=()
    
    for ((i=1; i<=num_instances; i++)); do
        while true; do
            read -rp "Country #${i} (2-letter code): " country
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
                COUNTRIES_TO_INSTALL["country_$i"]="$country"
                break
            fi
            echo -e "${RED}Invalid country code. Use 2 letters (e.g., US, DE, GB)${NC}"
        done
    done
    
    # Deploy Psiphon Fleet
    mkdir -p /etc/psiphon-fleet
    
    # Create fleet state file with random ports
    : > /etc/psiphon-fleet/fleet.state
    
    for key in "${!COUNTRIES_TO_INSTALL[@]}"; do
        country="${COUNTRIES_TO_INSTALL[$key]}"
        port=$((40000 + RANDOM % 10000))
        instance_id="psiphon-${country,,}-${port}"
        echo "${instance_id}=${country}:${port}" >> /etc/psiphon-fleet/fleet.state
    done
    
    # Now run the fleet installer
    bash "$PSIPHON_FLEET_SCRIPT" install 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Psiphon Fleet installed"
}

configure_routing() {
    log_step "Configuring Xray Routing"
    
    if [[ ! -f "$XRAY_ROUTING_SCRIPT" ]]; then
        log_error "Routing script not found: $XRAY_ROUTING_SCRIPT"
        exit 1
    fi
    
    chmod +x "$XRAY_ROUTING_SCRIPT"
    bash "$XRAY_ROUTING_SCRIPT" generate 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Routing configuration generated"
}

setup_telegram_bot() {
    log_step "Setting up Telegram Bot"
    
    echo ""
    echo -e "${YELLOW}Telegram Bot Setup${NC}"
    echo -e "${DIM}You need a bot token from @BotFather on Telegram${NC}"
    echo ""
    
    read -rp "Do you want to set up the Telegram bot now? (y/n) [n]: " setup_bot
    
    if [[ "${setup_bot,,}" != "y" ]]; then
        log_info "Skipping Telegram bot setup. Run 'python3 xui_bot.py setup' later."
        return
    fi
    
    read -rp "Enter Telegram Bot Token: " bot_token
    
    if [[ -z "$bot_token" ]]; then
        log_warn "No token provided. Skipping bot setup."
        return
    fi
    
    read -rp "Enter your Telegram ID (for admin access): " admin_id
    
    if [[ ! "$admin_id" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid Telegram ID. Skipping bot setup."
        return
    fi
    
    # Get X-UI credentials from database
    local xui_port="2053"
    local xui_path="/"
    local xui_user="admin"
    local xui_pass="admin"
    
    if [[ -f "/etc/x-ui/x-ui.db" ]]; then
        xui_port=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "2053")
        xui_path=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    fi
    
    read -rp "X-UI Username [$xui_user]: " input_user
    xui_user=${input_user:-$xui_user}
    
    read -rp "X-UI Password [$xui_pass]: " input_pass
    xui_pass=${input_pass:-$xui_pass}
    
    read -rp "Your domain (for subscription links): " domain
    
    read -rp "Default inbound ID for new users [1]: " inbound_id
    inbound_id=${inbound_id:-1}
    
    # Create config
    mkdir -p /etc/xui-bot
    cat > /etc/xui-bot/config.json << EOF
{
    "token": "$bot_token",
    "admin_ids": [$admin_id],
    "xui_host": "127.0.0.1",
    "xui_port": $xui_port,
    "xui_username": "$xui_user",
    "xui_password": "$xui_pass",
    "xui_base_path": "$xui_path",
    "domain": "$domain",
    "subscription_port": 443,
    "default_inbound_id": $inbound_id
}
EOF
    
    log_success "Bot configuration saved to /etc/xui-bot/config.json"
    
    # Copy bot script
    cp "$XUI_BOT_SCRIPT" /usr/local/bin/xui-bot.py
    chmod +x /usr/local/bin/xui-bot.py
    
    # Create systemd service
    cat > /etc/systemd/system/xui-bot.service << 'EOF'
[Unit]
Description=X-UI Telegram Bot
After=network.target x-ui.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/xui-bot.py run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xui-bot
    systemctl start xui-bot
    
    log_success "Telegram bot installed and started"
}

deploy_scripts() {
    log_step "Deploying Scripts"
    
    mkdir -p "$INSTALL_DIR"
    
    # Copy all scripts
    cp "$PSIPHON_FLEET_SCRIPT" "$INSTALL_DIR/"
    cp "$XRAY_ROUTING_SCRIPT" "$INSTALL_DIR/"
    cp "$XUI_API_SCRIPT" "$INSTALL_DIR/"
    cp "$XUI_BOT_SCRIPT" "$INSTALL_DIR/"
    
    chmod +x "$INSTALL_DIR"/*.sh
    chmod +x "$INSTALL_DIR"/*.py
    
    # Create symlinks
    ln -sf "$INSTALL_DIR/psiphon-fleet.sh" /usr/local/bin/psiphon-fleet
    ln -sf "$INSTALL_DIR/xray-routing.sh" /usr/local/bin/xray-routing
    
    log_success "Scripts deployed to $INSTALL_DIR"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Final Summary
#───────────────────────────────────────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                         INSTALLATION COMPLETE!                                 ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${GREEN}✓ Psiphon Fleet${NC} - Multi-country SOCKS proxies"
    echo -e "  Command: ${WHITE}psiphon-fleet status${NC}"
    echo ""
    
    echo -e "${GREEN}✓ Xray Routing${NC} - User-based country routing"
    echo -e "  Command: ${WHITE}xray-routing show${NC}"
    echo -e "  Config:  ${WHITE}/etc/xui-routing/${NC}"
    echo ""
    
    if systemctl is-active --quiet xui-bot 2>/dev/null; then
        echo -e "${GREEN}✓ Telegram Bot${NC} - Running"
        echo -e "  Command: ${WHITE}systemctl status xui-bot${NC}"
        echo ""
    else
        echo -e "${YELLOW}○ Telegram Bot${NC} - Not configured"
        echo -e "  Setup:   ${WHITE}python3 /opt/x-ui-pro/xui_bot.py setup${NC}"
        echo ""
    fi
    
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "1. ${WHITE}Configure X-UI Routing:${NC}"
    echo "   - Go to X-UI Panel → Xray Settings"
    echo "   - Add outbounds from /etc/xui-routing/outbounds.json"
    echo "   - Add routing rules from /etc/xui-routing/routing.json"
    echo ""
    
    echo "2. ${WHITE}Create Inbound:${NC}"
    echo "   - Create ONE inbound on port 2083 (VLESS + WebSocket + TLS)"
    echo "   - Add clients with email patterns: user-XX-name"
    echo "   - Example: user-us-john, user-de-mary"
    echo ""
    
    echo "3. ${WHITE}Test Routing:${NC}"
    echo "   - Run: xray-routing test"
    echo ""
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Show Psiphon status
    echo -e "${YELLOW}Psiphon Fleet Status:${NC}"
    psiphon-fleet status 2>/dev/null || echo "  Run 'psiphon-fleet status' to check"
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Main Installation Flow
#───────────────────────────────────────────────────────────────────────────────────────────────────
main() {
    print_banner
    
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "Installation started: $(date)" > "$LOG_FILE"
    
    echo -e "${YELLOW}This will install:${NC}"
    echo "  • Psiphon Fleet (multi-country SOCKS proxies)"
    echo "  • Xray Routing (user-based country routing)"
    echo "  • X-UI API Library (Python)"
    echo "  • Telegram Bot (optional)"
    echo ""
    
    read -rp "Continue? (y/n) [y]: " confirm
    [[ "${confirm,,}" == "n" ]] && exit 0
    
    log_step "Detecting System"
    check_os
    
    log_step "Installing Base Packages"
    install_base_packages
    
    # Check if Psiphon Fleet already exists
    if [[ -f "/etc/psiphon-fleet/fleet.state" ]] && systemctl is-active --quiet psiphon-fleet@* 2>/dev/null; then
        log_info "Psiphon Fleet already installed"
        read -rp "Reinstall Psiphon Fleet? (y/n) [n]: " reinstall
        if [[ "${reinstall,,}" == "y" ]]; then
            install_psiphon_fleet
        fi
    else
        install_psiphon_fleet
    fi
    
    configure_routing
    deploy_scripts
    setup_telegram_bot
    
    print_summary
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# CLI Entry
#───────────────────────────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --help|-h|help)
        cat << EOF
X-UI-PRO Unified Installer

Usage: $0 [command]

Commands:
  install       Full installation (default)
  psiphon       Install only Psiphon Fleet
  routing       Configure only Xray routing
  bot           Setup only Telegram bot
  status        Show status of all components
  help          Show this help

Examples:
  $0            # Full installation
  $0 psiphon    # Only Psiphon Fleet
  $0 status     # Check all components

EOF
        ;;
    status)
        print_banner
        echo -e "${YELLOW}Component Status:${NC}"
        echo ""
        
        echo -n "Psiphon Fleet: "
        if [[ -f "/etc/psiphon-fleet/fleet.state" ]]; then
            echo -e "${GREEN}Installed${NC}"
            psiphon-fleet status 2>/dev/null || true
        else
            echo -e "${RED}Not installed${NC}"
        fi
        echo ""
        
        echo -n "Routing Config: "
        if [[ -f "/etc/xui-routing/outbounds.json" ]]; then
            echo -e "${GREEN}Generated${NC}"
        else
            echo -e "${RED}Not generated${NC}"
        fi
        echo ""
        
        echo -n "Telegram Bot: "
        if systemctl is-active --quiet xui-bot 2>/dev/null; then
            echo -e "${GREEN}Running${NC}"
        elif [[ -f "/etc/xui-bot/config.json" ]]; then
            echo -e "${YELLOW}Configured but stopped${NC}"
        else
            echo -e "${RED}Not configured${NC}"
        fi
        ;;
    psiphon)
        print_banner
        check_os
        install_base_packages
        install_psiphon_fleet
        ;;
    routing)
        print_banner
        configure_routing
        ;;
    bot)
        print_banner
        setup_telegram_bot
        ;;
    install|"")
        main
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
