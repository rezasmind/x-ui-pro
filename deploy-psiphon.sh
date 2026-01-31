#!/bin/bash

#############################################################################
#  Psiphon Multi-Instance Deployment Manager v2.1
#  Part of X-UI-PRO - Multi-Country VPN Configuration System
#  
#  Deploys up to 10 concurrent Psiphon instances on ports 8080-8089
#  Each instance connects through a different country for multi-geo configs
#  
#  IMPORTANT: Services are started with delays to avoid WARP API rate limits
#############################################################################

set -eo pipefail

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
readonly WARP_DIR="/etc/warp-plus"
readonly WARP_BIN="$WARP_DIR/warp-plus"
readonly CACHE_BASE="/var/cache/psiphon"
readonly LOG_DIR="/var/log/psiphon"
readonly CONFIG_FILE="/etc/psiphon/config.json"
readonly VALID_COUNTRIES="AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US"

# Default: 10 ports (8080-8089)
DEFAULT_INSTANCE_COUNT=10
INSTANCE_COUNT=${INSTANCE_COUNT:-$DEFAULT_INSTANCE_COUNT}

# Delay between starting each service (in seconds) to avoid API rate limits
readonly START_DELAY=35

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
║              Multi-Country Psiphon Instance Manager v2.1                  ║
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

# Get server's country code to exclude from selection
get_server_country() {
    local country=""
    country=$(curl -s --connect-timeout 5 https://ipapi.co/country_code 2>/dev/null) || \
    country=$(curl -s --connect-timeout 5 https://ipinfo.io/country 2>/dev/null) || \
    country=""
    echo "${country:-XX}"
}

# Get array of available countries (excluding server's country)
get_available_countries() {
    local server_country="${1:-XX}"
    local countries=()
    
    for c in $VALID_COUNTRIES; do
        if [[ "$c" != "$server_country" ]]; then
            countries+=("$c")
        fi
    done
    
    echo "${countries[@]}"
}

# Select N random countries from the available list
select_random_countries() {
    local count="$1"
    local server_country="$2"
    local available
    available=($(get_available_countries "$server_country"))
    
    # Shuffle and pick first N countries
    local selected=()
    local shuffled
    shuffled=($(printf '%s\n' "${available[@]}" | shuf))
    
    for ((i=0; i<count && i<${#shuffled[@]}; i++)); do
        selected+=("${shuffled[$i]}")
    done
    
    echo "${selected[@]}"
}

validate_country() {
    local country="${1:-}"
    [[ -z "$country" ]] && return 1
    if echo " $VALID_COUNTRIES " | grep -q " $country "; then
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
    command -v shuf &> /dev/null || deps_needed+=(coreutils)
    
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
    
    # Stop all possible psiphon services (8080-8089)
    for port in $(seq 8080 8089); do
        local service_name="psiphon-${port}"
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            systemctl stop "$service_name" 2>/dev/null || true
            log_info "Stopped $service_name"
        fi
        # Disable and remove old service files
        systemctl disable "$service_name" 2>/dev/null || true
    done
    
    # Also stop main warp-plus service if running
    systemctl stop warp-plus 2>/dev/null || true
    
    # Clean all cache directories to force fresh identity creation
    log_info "Cleaning cache directories..."
    rm -rf /var/cache/psiphon-*/primary 2>/dev/null || true
    
    # Wait for services to fully stop
    sleep 3
}

generate_ports_array() {
    local count="$1"
    local ports=()
    for ((i=0; i<count; i++)); do
        ports+=($((8080 + i)))
    done
    echo "${ports[@]}"
}

configure_instances() {
    log_step "Detecting server location..."
    local server_country
    server_country=$(get_server_country)
    log_info "Server country detected: ${BOLD}$server_country${NC}"
    log_info "This country will be excluded from Psiphon instances."
    
    echo ""
    read -rp "$(echo -e "${GREEN}►${NC} How many Psiphon instances? [1-10, default: 10]: ")" instance_count
    instance_count=${instance_count:-10}
    
    # Validate instance count
    if ! [[ "$instance_count" =~ ^[0-9]+$ ]] || [[ "$instance_count" -lt 1 ]] || [[ "$instance_count" -gt 10 ]]; then
        log_warn "Invalid count. Using default: 10"
        instance_count=10
    fi
    
    INSTANCE_COUNT=$instance_count
    local PORTS
    PORTS=($(generate_ports_array "$INSTANCE_COUNT"))
    
    log_step "Configuring $INSTANCE_COUNT Psiphon instances..."
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  Country Selection Mode                                        ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}1)${NC} Auto-select random countries (recommended)               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}2)${NC} Manually select country for each port                    ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    read -rp "$(echo -e "${GREEN}►${NC} Select mode [1/2, default: 1]: ")" selection_mode
    selection_mode=${selection_mode:-1}
    
    declare -A INSTANCE_COUNTRIES
    
    if [[ "$selection_mode" == "1" ]]; then
        # Auto-select random countries
        log_info "Auto-selecting $INSTANCE_COUNT random countries (excluding $server_country)..."
        local selected_countries
        selected_countries=($(select_random_countries "$INSTANCE_COUNT" "$server_country"))
        
        local idx=0
        for port in "${PORTS[@]}"; do
            INSTANCE_COUNTRIES[$port]="${selected_countries[$idx]}"
            echo -e "  ${GREEN}✓${NC} Port $port → ${selected_countries[$idx]}"
            idx=$((idx + 1))
        done
    else
        # Manual selection
        echo ""
        echo -e "${CYAN}Available Countries (excluding $server_country):${NC}"
        echo -e "AT AU BE BG BR CA CH CZ DE DK EE ES FI FR GB HR"
        echo -e "HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US"
        echo ""
        
        for port in "${PORTS[@]}"; do
            while true; do
                read -rp "$(echo -e "${GREEN}►${NC} Enter country for Port ${BOLD}$port${NC}: ")" country
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
                
                if [[ -z "$country" ]]; then
                    log_warn "Country cannot be empty."
                elif [[ "$country" == "$server_country" ]]; then
                    log_warn "Cannot use server's country ($server_country). Choose another."
                elif validate_country "$country"; then
                    INSTANCE_COUNTRIES[$port]=$country
                    echo -e "  ${GREEN}✓${NC} Port $port → $country"
                    break
                else
                    log_warn "Invalid country code '$country'."
                fi
            done
        done
    fi

    echo ""
    log_step "Creating systemd services..."
    
    # Create directories
    mkdir -p "$LOG_DIR" "$(dirname "$CONFIG_FILE")"
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
{
    "version": "2.1",
    "created": "$(date -Iseconds)",
    "server_country": "$server_country",
    "instance_count": $INSTANCE_COUNT,
    "start_delay_seconds": $START_DELAY,
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
        
        # Create systemd service - Pure Psiphon (cfon) mode configuration
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

# Pure Psiphon (cfon) mode without WARP scanning or chaining
# --cfon: Enable Psiphon mode with specific country
# --bind: SOCKS5 proxy address
# --cache-dir: Unique profile storage per instance
ExecStart=$WARP_BIN --cfon --country $country --bind 127.0.0.1:$port --cache-dir $cache_dir

# Graceful shutdown
ExecStop=/bin/kill -TERM \$MAINPID

# Restart configuration with backoff
Restart=always
RestartSec=60
StartLimitInterval=600
StartLimitBurst=3

# Resource limits
LimitNOFILE=65535
LimitNPROC=65535

# Logging
StandardOutput=append:$log_file
StandardError=append:$log_file

[Install]
WantedBy=multi-user.target
EOF

    done
    
    # Close JSON config
    cat >> "$CONFIG_FILE" << EOF

    }
}
EOF

    # Reload systemd
    systemctl daemon-reload
    
    # Enable all services
    for port in "${PORTS[@]}"; do
        systemctl enable "psiphon-${port}" --quiet 2>/dev/null || true
    done
    
    log_success "All $INSTANCE_COUNT services configured"
    
    # Store PORTS globally for other functions
    echo "${PORTS[@]}" > /tmp/psiphon_ports
}

start_services_staggered() {
    log_step "Starting Psiphon services with staggered delays..."
    echo ""
    log_warn "IMPORTANT: Each service needs ${START_DELAY}s delay to avoid API rate limits!"
    log_warn "Total estimated time: $((INSTANCE_COUNT * START_DELAY / 60)) minutes"
    echo ""
    
    local PORTS
    if [[ -f /tmp/psiphon_ports ]]; then
        PORTS=($(cat /tmp/psiphon_ports))
    else
        PORTS=($(generate_ports_array "$INSTANCE_COUNT"))
    fi
    
    local current=1
    local total=${#PORTS[@]}
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        
        echo -ne "${CYAN}[$current/$total]${NC} Starting ${BOLD}$service_name${NC}... "
        
        # Clean cache for fresh start
        rm -rf "/var/cache/psiphon-${port}/primary" 2>/dev/null || true
        
        systemctl start "$service_name" 2>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
        
        if [[ $current -lt $total ]]; then
            echo -e "       ${YELLOW}Waiting ${START_DELAY}s before next service (to avoid rate limits)...${NC}"
            
            # Progress bar for wait
            for ((i=0; i<START_DELAY; i++)); do
                echo -ne "\r       [${GREEN}"
                for ((j=0; j<=i; j++)); do echo -ne "▓"; done
                for ((j=i; j<START_DELAY-1; j++)); do echo -ne "░"; done
                echo -ne "${NC}] $((i+1))/${START_DELAY}s"
                sleep 1
            done
            echo ""
        fi
        
        current=$((current + 1))
    done
    
    echo ""
    log_success "All services started!"
}

verify_deployment() {
    log_step "Verifying deployment..."
    echo ""
    
    local PORTS
    if [[ -f /tmp/psiphon_ports ]]; then
        PORTS=($(cat /tmp/psiphon_ports))
    else
        PORTS=($(generate_ports_array "$INSTANCE_COUNT"))
    fi
    
    printf "${CYAN}╔════════════╦════════════╦══════════════════╦══════════╦════════════╗${NC}\n"
    printf "${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-16s${NC} ${CYAN}║${NC} ${BOLD}%-8s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC}\n" \
           "Port" "Status" "External IP" "Country" "Config"
    printf "${CYAN}╠════════════╬════════════╬══════════════════╬══════════╬════════════╣${NC}\n"
    
    local success_count=0
    local total_count=${#PORTS[@]}
    
    for port in "${PORTS[@]}"; do
        local service_name="psiphon-${port}"
        local status="DOWN"
        local status_color="$RED"
        local ip="-"
        local country="-"
        local configured_country="-"
        
        # Get configured country from config file
        if [[ -f "$CONFIG_FILE" ]]; then
            configured_country=$(jq -r ".instances.\"$port\".country // \"-\"" "$CONFIG_FILE" 2>/dev/null || echo "-")
        fi
        
        # Check service status
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            status="ACTIVE"
            status_color="$YELLOW"
            
            # Test actual connectivity
            local ip_info
            ip_info=$(curl --connect-timeout 10 --max-time 15 \
                     --socks5-hostname "127.0.0.1:$port" \
                     -s "https://ipapi.co/json" 2>/dev/null || echo "")
            
            if [[ -n "$ip_info" && "$ip_info" != *"error"* && "$ip_info" != *"limit"* ]]; then
                status="ONLINE"
                status_color="$GREEN"
                ((success_count++)) || true
                
                ip=$(echo "$ip_info" | jq -r '.ip // "-"' 2>/dev/null || echo "-")
                country=$(echo "$ip_info" | jq -r '.country_code // "-"' 2>/dev/null || echo "-")
                
                # Truncate IP if too long
                [[ ${#ip} -gt 16 ]] && ip="${ip:0:13}..."
            fi
        fi
        
        printf "${CYAN}║${NC} %-10s ${CYAN}║${NC} ${status_color}%-10s${NC} ${CYAN}║${NC} %-16s ${CYAN}║${NC} %-8s ${CYAN}║${NC} %-10s ${CYAN}║${NC}\n" \
               "$port" "$status" "$ip" "$country" "$configured_country"
    done
    
    printf "${CYAN}╚════════════╩════════════╩══════════════════╩══════════╩════════════╝${NC}\n"
    echo ""
    
    if [[ $success_count -eq $total_count ]]; then
        log_success "All $total_count instances are online and working!"
    elif [[ $success_count -gt 0 ]]; then
        log_warn "$success_count/$total_count instances are online."
        echo -e "  ${YELLOW}TIP: Others may still be connecting. Run '$0 status' to check.${NC}"
    else
        log_warn "Instances may still be initializing (this is normal)."
        echo -e "  ${YELLOW}TIP: Wait 1-2 minutes, then run '$0 status'${NC}"
    fi
}

show_status() {
    show_banner
    log_info "Checking Psiphon instances status..."
    echo ""
    
    # Detect which ports have services
    local PORTS=()
    for port in $(seq 8080 8089); do
        if [[ -f "/etc/systemd/system/psiphon-${port}.service" ]]; then
            PORTS+=($port)
        fi
    done
    
    if [[ ${#PORTS[@]} -eq 0 ]]; then
        log_error "No Psiphon services found. Run '$0' to deploy."
        exit 1
    fi
    
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
            local start_time
            start_time=$(systemctl show "$service_name" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
            if [[ -n "$start_time" ]]; then
                uptime=$(date -d "$start_time" +"%H:%M" 2>/dev/null || echo "-")
            fi
            
            # Test connectivity
            local ip_info
            ip_info=$(curl --connect-timeout 5 --max-time 10 \
                     --socks5-hostname "127.0.0.1:$port" \
                     -s "https://ipapi.co/json" 2>/dev/null || echo "")
            
            if [[ -n "$ip_info" && "$ip_info" != *"error"* && "$ip_info" != *"limit"* ]]; then
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
    
    while true; do
        clear
        show_status
        echo ""
        echo -e "${YELLOW}Refreshing in 15 seconds... (Ctrl+C to exit)${NC}"
        sleep 15
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
        log_warn "No log file found. Using journalctl..."
        journalctl -u "psiphon-${port}" -n 50 --no-pager
    fi
}

restart_instance() {
    local port=${1:-all}
    
    if [[ "$port" == "all" ]]; then
        log_step "Restarting all Psiphon instances with staggered delays..."
        
        local PORTS=()
        for p in $(seq 8080 8089); do
            if [[ -f "/etc/systemd/system/psiphon-${p}.service" ]]; then
                PORTS+=($p)
            fi
        done
        
        local current=1
        local total=${#PORTS[@]}
        
        for p in "${PORTS[@]}"; do
            echo -ne "${CYAN}[$current/$total]${NC} Restarting psiphon-${p}... "
            rm -rf "/var/cache/psiphon-${p}/primary" 2>/dev/null || true
            systemctl restart "psiphon-${p}" && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
            
            if [[ $current -lt $total ]]; then
                echo -e "       ${YELLOW}Waiting ${START_DELAY}s...${NC}"
                sleep "$START_DELAY"
            fi
            current=$((current + 1))
        done
    else
        log_step "Restarting Psiphon instance on port $port..."
        rm -rf "/var/cache/psiphon-${port}/primary" 2>/dev/null || true
        systemctl restart "psiphon-${port}"
        log_success "psiphon-${port} restarted"
    fi
}

stop_all() {
    log_step "Stopping all Psiphon instances..."
    for port in $(seq 8080 8089); do
        systemctl stop "psiphon-${port}" 2>/dev/null || true
    done
    log_success "All instances stopped"
}

uninstall() {
    log_warn "This will remove all Psiphon instances and data."
    read -rp "Are you sure? (y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
        stop_all
        
        for port in $(seq 8080 8089); do
            systemctl disable "psiphon-${port}" 2>/dev/null || true
            rm -f "/etc/systemd/system/psiphon-${port}.service"
            rm -rf "/var/cache/psiphon-${port}"
        done
        
        rm -rf "$LOG_DIR" "$(dirname "$CONFIG_FILE")" /tmp/psiphon_ports
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
    echo -e "  ${GREEN}restart${NC}     - Restart all instances (with delays)"
    echo -e "  ${GREEN}restart${NC} N   - Restart instance on port N"
    echo -e "  ${GREEN}logs${NC} N      - Show logs for port N"
    echo -e "  ${GREEN}stop${NC}        - Stop all instances"
    echo -e "  ${GREEN}uninstall${NC}   - Remove all instances and data"
    echo -e "  ${GREEN}help${NC}        - Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  $0                    # Interactive deployment (10 instances)"
    echo -e "  $0 status             # Check all instances"
    echo -e "  $0 monitor            # Live monitoring dashboard"
    echo -e "  $0 logs 8080          # View logs for port 8080"
    echo -e "  $0 restart 8081       # Restart specific instance"
    echo ""
    echo -e "${BOLD}Notes:${NC}"
    echo -e "  • Services are started with ${START_DELAY}s delays to avoid API rate limits"
    echo -e "  • Server's country is auto-detected and excluded from selection"
    echo -e "  • Ports: 8080-8089 (up to 10 instances)"
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
            start_services_staggered
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
            echo -e "${CYAN}║${NC}  ${YELLOW}X-UI Config: Add SOCKS5 outbound to 127.0.0.1:PORT${NC}           ${CYAN}║${NC}"
            echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            ;;
    esac
}

main "$@"
