#!/bin/bash

#############################################################################
#  Psiphon Multi-Instance Deployment Manager v3.0
#  Based on SpherionOS/PsiphonLinux & Psiphon-Labs Core
#  
#  Deploys concurrent Psiphon instances using official psiphon-tunnel-core
#  Configures unique ports and countries for each instance.
#############################################################################

set -eo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Configuration
readonly PSIPHON_DIR="/etc/psiphon-core"
readonly BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
readonly BIN_PATH="${PSIPHON_DIR}/psiphon-tunnel-core"
readonly CONFIG_DIR="${PSIPHON_DIR}/configs"
readonly DATA_DIR="/var/cache/psiphon"
readonly LOG_DIR="/var/log/psiphon"
readonly SYSTEMD_DIR="/etc/systemd/system"

# Valid countries from SpherionOS documentation
readonly VALID_COUNTRIES="AT BE BG CA CH CZ DE DK EE ES FI FR GB HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US"

# Dependencies
check_dependencies() {
    local deps=(wget curl jq shuf)
    local install_list=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            install_list+=("$dep")
        fi
    done
    
    if [[ ${#install_list[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Installing missing dependencies: ${install_list[*]}${NC}"
        if command -v apt &> /dev/null; then
            apt update -qq && apt install -y -qq "${install_list[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${install_list[@]}"
        fi
    fi
}

# Install Psiphon Core
install_psiphon() {
    mkdir -p "$PSIPHON_DIR"
    
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${BLUE}Downloading psiphon-tunnel-core...${NC}"
        wget -qO "$BIN_PATH" "$BIN_URL"
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}Psiphon Core installed.${NC}"
    else
        echo -e "${GREEN}Psiphon Core already installed.${NC}"
    fi
}

# Detect Server Country
get_server_country() {
    curl -s --connect-timeout 5 https://ipapi.co/country_code 2>/dev/null || echo "XX"
}

# Generate Config File
create_config() {
    local port="$1"
    local country="$2"
    local config_file="${CONFIG_DIR}/config-${port}.json"
    local data_dir="${DATA_DIR}/instance-${port}"
    
    mkdir -p "$CONFIG_DIR" "$data_dir"
    
    # Psiphon JSON Configuration
    cat > "$config_file" << EOF
{
    "LocalHttpProxyPort": 0,
    "LocalSocksProxyPort": $port,
    "EgressRegion": "$country",
    "DataRootDirectory": "$data_dir",
    "NetworkID": "X-UI-PRO-$port"
}
EOF
}

# Create Systemd Service
create_service() {
    local port="$1"
    local service_name="psiphon-${port}"
    local config_file="${CONFIG_DIR}/config-${port}.json"
    local log_file="${LOG_DIR}/${service_name}.log"
    
    cat > "${SYSTEMD_DIR}/${service_name}.service" << EOF
[Unit]
Description=Psiphon Proxy Service - Port $port ($country)
Documentation=https://github.com/SpherionOS/PsiphonLinux
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$PSIPHON_DIR
ExecStart=$BIN_PATH -config $config_file -formatNotices json

# Restart policies
Restart=always
RestartSec=30
StartLimitInterval=300
StartLimitBurst=5

# Logging
StandardOutput=append:$log_file
StandardError=append:$log_file

# Limits
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# Deploy Function
deploy() {
    check_dependencies
    install_psiphon
    
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR"
    
    SERVER_COUNTRY=$(get_server_country)
    echo -e "${BLUE}Server Country: $SERVER_COUNTRY (will exclude from selection)${NC}"
    
    read -rp "Number of instances (1-10) [Default: 10]: " count
    count=${count:-10}
    [[ ! "$count" =~ ^[0-9]+$ ]] && count=10
    
    # Process Countries
    AVAILABLE_COUNTRIES=$(echo "$VALID_COUNTRIES" | tr ' ' '\n' | grep -v "^${SERVER_COUNTRY}$" | tr '\n' ' ')
    RANDOM_COUNTRIES=($(echo "$AVAILABLE_COUNTRIES" | tr ' ' '\n' | shuf | head -n $count))
    
    echo -e "${GREEN}Deploying $count Psiphon instances...${NC}"
    
    # Stop existing services
    for i in {8080..8089}; do
        systemctl stop "psiphon-$i" 2>/dev/null || true
        systemctl disable "psiphon-$i" --quiet 2>/dev/null || true
    done
    
    for ((i=0; i<count; i++)); do
        port=$((8080 + i))
        country="${RANDOM_COUNTRIES[$i]}"
        
        echo -e "  [Port $port] Country: ${BOLD}$country${NC}"
        
        create_config "$port" "$country"
        create_service "$port"
        
        systemctl daemon-reload
        systemctl enable "psiphon-${port}" --quiet
    done
    
    # Staggered Start
    echo ""
    echo -e "${YELLOW}Starting services (staggered delay: 5s)...${NC}"
    for ((i=0; i<count; i++)); do
        port=$((8080 + i))
        echo -ne "  Starting psiphon-${port}... "
        systemctl start "psiphon-${port}"
        echo -e "${GREEN}✓${NC}"
        
        if ((i < count - 1)); then
            sleep 5
        fi
    done
    
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo -e "Check configuration at: $CONFIG_DIR"
}

# Status Function
status() {
    echo ""
    printf "%-10s %-10s %-15s %-10s\n" "PORT" "STATUS" "IP" "COUNTRY"
    echo "------------------------------------------------"
    
    for config in "${CONFIG_DIR}"/config-*.json; do
        [[ ! -f "$config" ]] && continue
        
        # Parse config for details
        PORT=$(jq -r .LocalSocksProxyPort "$config")
        CFG_COUNTRY=$(jq -r .EgressRegion "$config")
        
        svc_status="STOPPED"
        if systemctl is-active --quiet "psiphon-${PORT}"; then
            svc_status="ACTIVE"
            ip_info=$(curl -s --connect-timeout 3 --socks5 127.0.0.1:$PORT https://ipapi.co/json 2>/dev/null)
            if [[ -n "$ip_info" ]]; then
                ip=$(echo "$ip_info" | jq -r .ip 2>/dev/null)
                real_country=$(echo "$ip_info" | jq -r .country_code 2>/dev/null)
                if [[ "$ip" != "null" ]]; then
                    svc_status="ONLINE"
                fi
            fi
        fi
        
        printf "%-10s %-10s %-15s %-10s\n" "$PORT" "$svc_status" "${ip:- -}" "${real_country:- -}"
    done
    echo ""
}

# Logs Function
logs() {
    local port="${1:-8080}"
    local log_file="${LOG_DIR}/psiphon-${port}.log"
    echo -e "${BLUE}Logs for Port $port:${NC}"
    if [[ -f "$log_file" ]]; then
        tail -n 20 "$log_file"
    else
        echo "Log file not found."
    fi
}

# Restart Function
restart() {
    local port="$1"
    if [[ -z "$port" ]]; then
        echo -e "${YELLOW}Restarting all services...${NC}"
        for config in "${CONFIG_DIR}"/config-*.json; do
            [[ ! -f "$config" ]] && continue
            PORT=$(jq -r .LocalSocksProxyPort "$config")
            systemctl restart "psiphon-${PORT}"
            echo "  psiphon-${PORT} restarted."
            sleep 2
        done
    else
        systemctl restart "psiphon-${port}"
        echo "  psiphon-${port} restarted."
    fi
}

# Wrapper
case "$1" in
    status) status ;;
    restart) restart "$2" ;;
    logs) logs "$2" ;;
    *) deploy ;;
esac
