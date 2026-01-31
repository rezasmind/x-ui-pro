#!/bin/bash

#############################################################################
#  Psiphon Multi-Instance Deployment Manager v2.0
#  Part of X-UI-PRO - Multi-Country VPN Configuration System
#  
#  Deploys 5 concurrent Psiphon instances on ports 8080-8084
#  Each instance connects through a different country for multi-geo configs
#############################################################################

set -euo pipefail

# Colors and Styling
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Configuration
readonly PORTS=(8080 8081 8082 8083 8084)
readonly WARP_DIR="/etc/warp-plus"
readonly WARP_BIN="$WARP_DIR/warp-plus"
readonly CACHE_BASE="/var/cache/psiphon"
readonly LOG_DIR="/var/log/psiphon"
readonly CONFIG_FILE="/etc/psiphon/config.json"
readonly VALID_COUNTRIES="AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US"

# Logging Functions
log_info()    { echo -e "${BLUE}${BOLD}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}${BOLD}[ERROR]${NC} $1"; }
log_step()    { echo -e "${MAGENTA}${BOLD}[STEP]${NC} $1"; }

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║           ____       _       __                   __  ___                 ║
║          / __ \_____(_)___  / /_  ____  ____     /  |/  /___ _____  ____ ║
║         / /_/ / ___/ / __ \/ __ \/ __ \/ __ \   / /|_/ / __ `/ __ \/ __ \║
║        / ____(__  ) / /_/ / / / / /_/ / / / /  / /  / / /_/ / / / / /_/ /║
║       /_/   /____/_/ .___/_/ /_/\____/_/ /_/  /_/  /_/\__,_/_/ /_/\__, / ║
║                   /_/                                            /____/  ║
║                                                                           ║
║              Multi-Country Psiphon Instance Manager v2.0                  ║
║                    Part of X-UI-PRO Project                               ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo $0"
        exit 1
    fi
}

validate_country() {
    local country="$1"
    if echo "$VALID_COUNTRIES" | grep -qw "$country"; then
        return 0
    else
        return 1
    fi
}

install_dependencies() {
    log_step "Checking and installing dependencies..."
    
    local deps_needed=()
    command -v wget &> /dev/null || deps_needed+=(wget)
    command -v unzip &> /dev/null || deps_needed+=(unzip)
    command -v curl &> /dev/null || deps_needed+=(curl)
    command -v jq &> /dev/null || deps_needed+=(jq)
    
    if [[ ${#deps_needed[@]} -gt 0 ]]; then
        log_info "Installing: ${deps_needed[*]}"
        if command -v apt &> /dev/null; then
            apt update -qq && apt install -y -qq "${deps_needed[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${deps_needed[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y -q "${deps_needed[@]}"
        fi
    else
        log_success "All dependencies are already installed"
    fi
}

install_warp_plus() {
    if [[ -f "$WARP_BIN" && -x "$WARP_BIN" ]]; then
        log_success "warp-plus is already installed at $WARP_BIN"
        return
    fi

    log_step "Downloading warp-plus (Psiphon engine)..."
    mkdir -p "$WARP_DIR"
    
    local ARCH=$(uname -m)
    local BASE_URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux"
    local ZIP_URL=""

    case "$ARCH" in
        x86_64|amd64)   ZIP_URL="${BASE_URL}-amd64.zip" ;;
        aarch64|arm64)  ZIP_URL="${BASE_URL}-arm64.zip" ;;
        armv7l|armv7)   ZIP_URL="${BASE_URL}-arm7.zip" ;;
        mips64)         ZIP_URL="${BASE_URL}-mips64.zip" ;;
        mips64le)       ZIP_URL="${BASE_URL}-mips64le.zip" ;;
        mipsle*)        ZIP_URL="${BASE_URL}-mipsle.zip" ;;
        mips)           ZIP_URL="${BASE_URL}-mips.zip" ;;
        riscv64)        ZIP_URL="${BASE_URL}-riscv64.zip" ;;
        *) 
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    log_info "Downloading for architecture: $ARCH"
    wget -q --show-progress -O "/tmp/warp-plus.zip" "$ZIP_URL" || {
        log_error "Failed to download warp-plus"
        exit 1
    }
    
    unzip -q -o "/tmp/warp-plus.zip" -d "$WARP_DIR"
    rm -f "/tmp/warp-plus.zip"
    chmod +x "$WARP_BIN"
    
    log_success "warp-plus installed successfully"
}

stop_existing_services() {
    log_step "Stopping existing Psiphon services..."
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            systemctl stop "$service_name" 2>/dev/null || true
            log_info "Stopped $service_name"
        fi
    done
    
    # Also stop main warp-plus service if running
    systemctl stop warp-plus 2>/dev/null || true
}

configure_instances() {
    log_step "Configuring Psiphon instances..."
    
    declare -A INSTANCE_COUNTRIES
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  Select a country for each Psiphon instance                   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Use 2-letter country codes (e.g., US, DE, GB, NL)            ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}Available Countries:${NC}                                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HR             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local default_countries=("US" "DE" "GB" "NL" "FR")
    local idx=0

    for port in "${PORTS[@]}"; do
        while true; do
            local default="${default_countries[$idx]}"
            read -rp "$(echo -e "${GREEN}►${NC} Enter country for Port ${BOLD}$port${NC} [default: ${YELLOW}$default${NC}]: ")" country
            country=${country:-$default}
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            
            if validate_country "$country"; then
                INSTANCE_COUNTRIES[$port]=$country
                echo -e "  ${GREEN}✓${NC} Port $port → $country"
                break
            else
                log_warn "Invalid country code '$country'. Please use a valid 2-letter code."
            fi
        done
        ((idx++))
    done

    echo ""
    log_step "Creating systemd services..."
    
    # Create directories
    mkdir -p "$LOG_DIR" "$(dirname "$CONFIG_FILE")"
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
{
    "version": "2.0",
    "created": "$(date -Iseconds)",
    "instances": {
EOF

    local first=true
    for port in "${PORTS[@]}"; do
        local country=${INSTANCE_COUNTRIES[$port]}
        local service_name="psiphon-${port}"
        local cache_dir="${CACHE_BASE}-${port}"
        local log_file="${LOG_DIR}/${service_name}.log"
        
        mkdir -p "$cache_dir"
        
        log_info "Creating service $service_name → Country: ${BOLD}$country${NC}"
        
        # Append to config file
        if $first; then
            first=false
        else
            echo "," >> "$CONFIG_FILE"
        fi
        cat >> "$CONFIG_FILE" << EOF
        "$port": {
            "country": "$country",
            "cache_dir": "$cache_dir",
            "log_file": "$log_file"
        }
EOF
        
        # Create enhanced systemd service with proper initialization
        cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=Psiphon Instance on Port $port ($country) - X-UI-PRO
Documentation=https://github.com/rezasmind/x-ui-pro
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WARP_DIR
Environment="HOME=/root"

# Pre-start: Clean old cache if connection issues
ExecStartPre=/bin/bash -c 'rm -rf $cache_dir/* 2>/dev/null || true'

# Main execution with scan for better endpoint discovery
ExecStart=$WARP_BIN --scan --cfon --country $country --bind 127.0.0.1:$port --cache-dir $cache_dir

# Graceful shutdown
ExecStop=/bin/kill -TERM \$MAINPID

# Restart configuration
Restart=always
RestartSec=10
StartLimitInterval=300
StartLimitBurst=5

# Resource limits
LimitNOFILE=65535
LimitNPROC=65535

# Logging
StandardOutput=append:$log_file
StandardError=append:$log_file

# Security hardening
NoNewPrivileges=false
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

    done
    
    # Close JSON config
    cat >> "$CONFIG_FILE" << EOF

    }
}
EOF

    # Reload and enable services
    systemctl daemon-reload
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        systemctl enable "$service_name" --quiet
    done
    
    log_success "All services configured and enabled"
}

start_services() {
    log_step "Starting Psiphon services..."
    echo ""
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        echo -ne "  Starting ${BOLD}$service_name${NC}... "
        
        systemctl start "$service_name" 2>/dev/null && \
            echo -e "${GREEN}✓${NC}" || \
            echo -e "${RED}✗${NC}"
        
        # Small delay between starts to prevent resource conflicts
        sleep 2
    done
}

wait_for_initialization() {
    local wait_time=${1:-30}
    
    echo ""
    log_step "Waiting for Psiphon instances to initialize (${wait_time}s)..."
    echo -e "  ${YELLOW}Note: Initial connection may take 20-60 seconds per instance${NC}"
    echo ""
    
    # Progress bar
    local progress=0
    local step=$((wait_time / 20))
    
    echo -n "  ["
    while [[ $progress -lt $wait_time ]]; do
        echo -n "▓"
        sleep $step
        progress=$((progress + step))
    done
    echo "] Done"
    echo ""
}

verify_deployment() {
    log_step "Verifying deployment..."
    echo ""
    
    printf "${CYAN}╔════════════╦════════════╦══════════════════╦══════════╦════════════╗${NC}\n"
    printf "${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-16s${NC} ${CYAN}║${NC} ${BOLD}%-8s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC}\n" \
           "Port" "Status" "External IP" "Country" "Latency"
    printf "${CYAN}╠════════════╬════════════╬══════════════════╬══════════╬════════════╣${NC}\n"
    
    local success_count=0
    local total_count=${#PORTS[@]}
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        local status="DOWN"
        local status_color="$RED"
        local ip="-"
        local country="-"
        local latency="-"
        local configured_country="-"
        
        # Get configured country
        if [[ -f "$CONFIG_FILE" ]]; then
            configured_country=$(jq -r ".instances.\"$port\".country // \"-\"" "$CONFIG_FILE" 2>/dev/null || echo "-")
        fi
        
        # Check service status
        if systemctl is-active --quiet "$service_name"; then
            status="ACTIVE"
            status_color="$YELLOW"
            
            # Test actual connectivity with timing
            local start_time=$(date +%s%N)
            local ip_info=$(curl --connect-timeout 10 --max-time 15 \
                           --socks5-hostname "127.0.0.1:$port" \
                           -s "https://ipapi.co/json" 2>/dev/null || echo "")
            local end_time=$(date +%s%N)
            
            if [[ -n "$ip_info" && "$ip_info" != *"error"* ]]; then
                status="ONLINE"
                status_color="$GREEN"
                ((success_count++))
                
                ip=$(echo "$ip_info" | jq -r '.ip // "-"' 2>/dev/null || echo "-")
                country=$(echo "$ip_info" | jq -r '.country_code // "-"' 2>/dev/null || echo "-")
                latency=$(( (end_time - start_time) / 1000000 ))"ms"
                
                # Truncate IP if too long
                [[ ${#ip} -gt 16 ]] && ip="${ip:0:13}..."
            else
                status="CONNECTING"
                status_color="$YELLOW"
            fi
        fi
        
        printf "${CYAN}║${NC} %-10s ${CYAN}║${NC} ${status_color}%-10s${NC} ${CYAN}║${NC} %-16s ${CYAN}║${NC} %-8s ${CYAN}║${NC} %-10s ${CYAN}║${NC}\n" \
               "$port" "$status" "$ip" "$country" "$latency"
    done
    
    printf "${CYAN}╚════════════╩════════════╩══════════════════╩══════════╩════════════╝${NC}\n"
    echo ""
    
    if [[ $success_count -eq $total_count ]]; then
        log_success "All $total_count instances are online and working!"
    elif [[ $success_count -gt 0 ]]; then
        log_warn "$success_count/$total_count instances are online. Others may still be connecting..."
        echo -e "  ${YELLOW}TIP: Run '$0 status' in 1-2 minutes to check again${NC}"
    else
        log_warn "Instances are still initializing. This is normal for first deployment."
        echo -e "  ${YELLOW}TIP: Wait 1-2 minutes, then run '$0 status' to check${NC}"
        echo -e "  ${YELLOW}TIP: Check logs with '$0 logs <port>' for details${NC}"
    fi
}

show_status() {
    show_banner
    log_info "Checking Psiphon instances status..."
    echo ""
    
    printf "${CYAN}╔════════════╦════════════╦══════════════════╦══════════╦════════════╦══════════════╗${NC}\n"
    printf "${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-16s${NC} ${CYAN}║${NC} ${BOLD}%-8s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-12s${NC} ${CYAN}║${NC}\n" \
           "Port" "Status" "External IP" "Country" "Config" "Uptime"
    printf "${CYAN}╠════════════╬════════════╬══════════════════╬══════════╬════════════╬══════════════╣${NC}\n"
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        local status="STOPPED"
        local status_color="$RED"
        local ip="-"
        local country="-"
        local configured_country="-"
        local uptime="-"
        
        # Get configured country from service file
        if [[ -f "/etc/systemd/system/${service_name}.service" ]]; then
            configured_country=$(grep -oP '(?<=--country )\w+' "/etc/systemd/system/${service_name}.service" 2>/dev/null || echo "-")
        fi
        
        # Check service status
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            status="ACTIVE"
            status_color="$YELLOW"
            
            # Get uptime
            uptime=$(systemctl show "$service_name" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +"%Hh%Mm" 2>/dev/null || echo "-")
            
            # Test connectivity
            local ip_info=$(curl --connect-timeout 5 --max-time 10 \
                           --socks5-hostname "127.0.0.1:$port" \
                           -s "https://ipapi.co/json" 2>/dev/null || echo "")
            
            if [[ -n "$ip_info" && "$ip_info" != *"error"* ]]; then
                status="ONLINE"
                status_color="$GREEN"
                ip=$(echo "$ip_info" | jq -r '.ip // "-"' 2>/dev/null || echo "-")
                country=$(echo "$ip_info" | jq -r '.country_code // "-"' 2>/dev/null || echo "-")
                [[ ${#ip} -gt 16 ]] && ip="${ip:0:13}..."
            fi
        fi
        
        printf "${CYAN}║${NC} %-10s ${CYAN}║${NC} ${status_color}%-10s${NC} ${CYAN}║${NC} %-16s ${CYAN}║${NC} %-8s ${CYAN}║${NC} %-10s ${CYAN}║${NC} %-12s ${CYAN}║${NC}\n" \
               "$port" "$status" "$ip" "$country" "$configured_country" "$uptime"
    done
    
    printf "${CYAN}╚════════════╩════════════╩══════════════════╩══════════╩════════════╩══════════════╝${NC}\n"
}

monitor_mode() {
    log_info "Starting real-time monitor (Ctrl+C to exit)..."
    echo ""
    
    while true; do
        clear
        show_banner
        echo -e "${BOLD}Real-Time Monitor${NC} - $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        show_status
        echo ""
        echo -e "${YELLOW}Refreshing in 10 seconds... (Ctrl+C to exit)${NC}"
        sleep 10
    done
}

show_logs() {
    local port=${1:-8080}
    local log_file="${LOG_DIR}/psiphon-${port}.log"
    
    if [[ -f "$log_file" ]]; then
        log_info "Showing logs for port $port (last 50 lines):"
        echo ""
        tail -50 "$log_file"
    else
        log_warn "No log file found for port $port"
        echo "Try: journalctl -u psiphon-${port} -f"
    fi
}

restart_instance() {
    local port=${1:-all}
    
    if [[ "$port" == "all" ]]; then
        log_step "Restarting all Psiphon instances..."
        for p in "${PORTS[@]}"; do
            echo -ne "  Restarting psiphon-${p}... "
            systemctl restart "psiphon-${p}" && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
        done
    else
        log_step "Restarting Psiphon instance on port $port..."
        systemctl restart "psiphon-${port}"
        log_success "psiphon-${port} restarted"
    fi
}

stop_all() {
    log_step "Stopping all Psiphon instances..."
    for port in "${PORTS[@]}"; do
        systemctl stop "psiphon-${port}" 2>/dev/null || true
        systemctl disable "psiphon-${port}" 2>/dev/null || true
    done
    log_success "All instances stopped"
}

uninstall() {
    log_warn "This will remove all Psiphon instances and data."
    read -rp "Are you sure? (y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
        stop_all
        
        for port in "${PORTS[@]}"; do
            rm -f "/etc/systemd/system/psiphon-${port}.service"
            rm -rf "${CACHE_BASE}-${port}"
        done
        
        rm -rf "$LOG_DIR" "$(dirname "$CONFIG_FILE")"
        systemctl daemon-reload
        
        log_success "Psiphon instances uninstalled"
    else
        log_info "Uninstall cancelled"
    fi
}

show_help() {
    show_banner
    echo -e "${BOLD}Usage:${NC} $0 [command]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${GREEN}(none)${NC}      - Deploy/reconfigure Psiphon instances"
    echo -e "  ${GREEN}status${NC}      - Show status of all instances"
    echo -e "  ${GREEN}monitor${NC}     - Start real-time monitoring dashboard"
    echo -e "  ${GREEN}restart${NC}     - Restart all instances"
    echo -e "  ${GREEN}restart${NC} N   - Restart instance on port N"
    echo -e "  ${GREEN}logs${NC} N      - Show logs for port N"
    echo -e "  ${GREEN}stop${NC}        - Stop all instances"
    echo -e "  ${GREEN}uninstall${NC}   - Remove all instances and data"
    echo -e "  ${GREEN}help${NC}        - Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  $0                    # Interactive deployment"
    echo -e "  $0 status             # Check all instances"
    echo -e "  $0 monitor            # Live monitoring dashboard"
    echo -e "  $0 logs 8080          # View logs for port 8080"
    echo -e "  $0 restart 8081       # Restart specific instance"
    echo ""
}

main() {
    check_root
    
    case "${1:-deploy}" in
        status)
            show_banner
            show_status
            ;;
        monitor)
            monitor_mode
            ;;
        logs)
            show_logs "${2:-8080}"
            ;;
        restart)
            show_banner
            restart_instance "${2:-all}"
            ;;
        stop)
            show_banner
            stop_all
            ;;
        uninstall)
            show_banner
            uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        deploy|*)
            show_banner
            install_dependencies
            install_warp_plus
            stop_existing_services
            configure_instances
            start_services
            wait_for_initialization 30
            verify_deployment
            
            echo ""
            log_success "Deployment complete!"
            echo ""
            echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║${NC}  ${BOLD}Quick Reference:${NC}                                             ${CYAN}║${NC}"
            echo -e "${CYAN}║${NC}  • Status:   $0 status                           ${CYAN}║${NC}"
            echo -e "${CYAN}║${NC}  • Monitor:  $0 monitor                          ${CYAN}║${NC}"
            echo -e "${CYAN}║${NC}  • Logs:     $0 logs 8080                        ${CYAN}║${NC}"
            echo -e "${CYAN}║${NC}  • Restart:  $0 restart                          ${CYAN}║${NC}"
            echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${CYAN}║${NC}  ${YELLOW}Use in X-UI: Create SOCKS5 outbound to 127.0.0.1:PORT${NC}        ${CYAN}║${NC}"
            echo -e "${CYAN}║${NC}  ${YELLOW}Then route specific inbounds through each outbound${NC}          ${CYAN}║${NC}"
            echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            ;;
    esac
}

main "$@"
