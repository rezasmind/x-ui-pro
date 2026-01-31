#!/bin/bash

# Psiphon Manager - Multi-Instance Deployment Tool
# Deploys 5 concurrent Psiphon instances on ports 8080-8084
# Each instance can be configured with a specific country.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PORTS=(8080 8081 8082 8083 8084)
WARP_DIR="/etc/warp-plus"
WARP_BIN="$WARP_DIR/warp-plus"
CACHE_BASE="/var/cache/psiphon"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

install_dependencies() {
    log_info "Checking dependencies..."
    if ! command -v wget &> /dev/null || ! command -v unzip &> /dev/null || ! command -v curl &> /dev/null; then
        log_info "Installing dependencies..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y wget unzip curl
        elif command -v dnf &> /dev/null; then
            dnf install -y wget unzip curl
        fi
    fi
}

install_warp_plus() {
    if [[ -f "$WARP_BIN" ]]; then
        log_info "warp-plus is already installed at $WARP_BIN"
        return
    fi

    log_info "Downloading warp-plus..."
    mkdir -p "$WARP_DIR"
    
    local ARCH=$(uname -m)
    local URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux"
    local ZIP_NAME=""

    case "$ARCH" in
        x86_64) ZIP_NAME="${URL}-amd64.zip" ;;
        aarch64) ZIP_NAME="${URL}-arm64.zip" ;;
        armv7l) ZIP_NAME="${URL}-arm7.zip" ;;
        *) 
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    wget -qO "/tmp/warp-plus.zip" "$ZIP_NAME"
    unzip -o "/tmp/warp-plus.zip" -d "$WARP_DIR"
    rm -f "/tmp/warp-plus.zip"
    chmod +x "$WARP_BIN"
    
    log_success "warp-plus installed successfully."
}

configure_instances() {
    log_info "Configuring Psiphon instances..."
    
    # Valid countries list for reference
    # AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US
    
    declare -A INSTANCE_COUNTRIES
    
    echo "Please select a country for each instance (2-letter code, e.g., US, DE, GB)."
    echo "Available: AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US"
    echo ""

    for port in "${PORTS[@]}"; do
        while true; do
            read -p "Enter country for Port $port (default: US): " country
            country=${country:-US}
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            
            if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
                INSTANCE_COUNTRIES[$port]=$country
                break
            else
                log_warn "Invalid country code. Please use 2 letters."
            fi
        done
    done

    # Generate Systemd Services
    for port in "${PORTS[@]}"; do
        country=${INSTANCE_COUNTRIES[$port]}
        service_name="psiphon-${port}"
        cache_dir="${CACHE_BASE}-${port}"
        
        mkdir -p "$cache_dir"
        
        log_info "Creating service $service_name for Country: $country on Port: $port"
        
        cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=Psiphon Instance on Port $port ($country)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WARP_DIR
ExecStart=$WARP_BIN --cfon --country $country --bind 127.0.0.1:$port --cache-dir $cache_dir
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "$service_name"
        systemctl restart "$service_name"
    done
}

verify_deployment() {
    log_info "Verifying deployment (waiting 10s for services to initialize)..."
    sleep 10
    
    for port in "${PORTS[@]}"; do
        log_info "Checking instance on port $port..."
        
        if ! systemctl is-active --quiet "psiphon-${port}"; then
            log_error "Service psiphon-${port} is NOT active."
            continue
        fi

        # Check connectivity
        local ip_info=$(curl --connect-timeout 5 --socks5 127.0.0.1:$port -s https://ipapi.co/json || echo "failed")
        
        if [[ "$ip_info" == "failed" ]]; then
            log_error "Port $port: Connection failed."
        else
            if command -v jq &> /dev/null; then
                local ip=$(echo "$ip_info" | jq -r .ip)
                local country=$(echo "$ip_info" | jq -r .country_code)
            else
                local ip=$(echo "$ip_info" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
                local country=$(echo "$ip_info" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
            fi
            log_success "Port $port: Online | IP: $ip | Country: $country"
        fi
    done
}

monitor_mode() {
    while true; do
        clear
        echo "=== Psiphon Instances Monitor ==="
        date
        echo ""
        printf "%-10s %-10s %-15s %-10s\n" "Port" "Status" "IP" "Country"
        echo "------------------------------------------------"
        
        for port in "${PORTS[@]}"; do
            status="DOWN"
            if systemctl is-active --quiet "psiphon-${port}"; then
                status="UP"
            fi
            
            if [[ "$status" == "UP" ]]; then
                ip_info=$(curl --connect-timeout 2 --socks5 127.0.0.1:$port -s https://ipapi.co/json 2>/dev/null)
                if [[ -z "$ip_info" ]]; then
                     ip="Unreachable"
                     country="-"
                else
                     if command -v jq &> /dev/null; then
                         ip=$(echo "$ip_info" | jq -r .ip)
                         country=$(echo "$ip_info" | jq -r .country_code)
                     else
                         ip=$(echo "$ip_info" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
                         country=$(echo "$ip_info" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
                     fi
                fi
            else
                ip="-"
                country="-"
            fi
            
            printf "%-10s %-10s %-15s %-10s\n" "$port" "$status" "$ip" "$country"
        done
        
        echo ""
        echo "Press Ctrl+C to exit monitor."
        sleep 10
    done
}

main() {
    check_root
    
    if [[ "$1" == "monitor" ]]; then
        monitor_mode
        exit 0
    fi

    install_dependencies
    install_warp_plus
    configure_instances
    verify_deployment
    
    log_success "Deployment complete."
    log_info "Run '$0 monitor' to start the monitoring dashboard."
}

main "$@"
