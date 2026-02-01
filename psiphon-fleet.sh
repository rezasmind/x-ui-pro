#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════════════════════════
#  PSIPHON FLEET COMMANDER v3.0 - Multi-Instance Isolated Proxy Deployment
#  Author: Engineered for x-ui-pro
#  Purpose: Deploy N isolated Psiphon instances with zero cross-contamination
#  Each instance runs in its own namespace with dedicated ports and country routing
#═══════════════════════════════════════════════════════════════════════════════════════════════════
set -e
trap 'echo -e "\n\033[0;31m[ABORT]\033[0m Script interrupted."; exit 130' INT

# Root check
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
log_step()    { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────────────────────────
declare -r PSIPHON_DIR="/etc/psiphon-fleet"
declare -r BIN_PATH="${PSIPHON_DIR}/psiphon-core"
declare -r CONFIG_DIR="${PSIPHON_DIR}/instances"
declare -r DATA_DIR="/var/lib/psiphon-fleet"
declare -r LOG_DIR="/var/log/psiphon-fleet"
declare -r STATE_FILE="${PSIPHON_DIR}/fleet.state"
declare -r BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"

# Available countries for Psiphon
declare -A COUNTRY_NAMES=(
    ["US"]="United States"    ["DE"]="Germany"        ["GB"]="United Kingdom"
    ["NL"]="Netherlands"      ["FR"]="France"         ["SG"]="Singapore"
    ["JP"]="Japan"            ["CA"]="Canada"         ["AU"]="Australia"
    ["CH"]="Switzerland"      ["SE"]="Sweden"         ["NO"]="Norway"
    ["AT"]="Austria"          ["BE"]="Belgium"        ["CZ"]="Czech Republic"
    ["DK"]="Denmark"          ["ES"]="Spain"          ["FI"]="Finland"
    ["HU"]="Hungary"          ["IE"]="Ireland"        ["IT"]="Italy"
    ["PL"]="Poland"           ["PT"]="Portugal"       ["RO"]="Romania"
    ["SK"]="Slovakia"         ["IN"]="India"          ["BR"]="Brazil"
)

# Fleet instances - will be populated from state or interactively
declare -A FLEET_INSTANCES=()

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Banner
#───────────────────────────────────────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${MAGENTA}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════════════╗
║   ██████╗ ███████╗██╗██████╗ ██╗  ██╗ ██████╗ ███╗   ██╗                     ║
║   ██╔══██╗██╔════╝██║██╔══██╗██║  ██║██╔═══██╗████╗  ██║                     ║
║   ██████╔╝███████╗██║██████╔╝███████║██║   ██║██╔██╗ ██║                     ║
║   ██╔═══╝ ╚════██║██║██╔═══╝ ██╔══██║██║   ██║██║╚██╗██║                     ║
║   ██║     ███████║██║██║     ██║  ██║╚██████╔╝██║ ╚████║                     ║
║   ╚═╝     ╚══════╝╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝                     ║
║                     FLEET COMMANDER v3.0                                      ║
║            Multi-Instance Isolated Proxy Deployment System                    ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# State Management
#───────────────────────────────────────────────────────────────────────────────────────────────────
save_state() {
    mkdir -p "$PSIPHON_DIR"
    : > "$STATE_FILE"
    for key in "${!FLEET_INSTANCES[@]}"; do
        echo "${key}=${FLEET_INSTANCES[$key]}" >> "$STATE_FILE"
    done
    log_success "Fleet state saved to $STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ -n "$key" && -n "$value" ]] && FLEET_INSTANCES["$key"]="$value"
        done < "$STATE_FILE"
        return 0
    fi
    return 1
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Port Generator - Ensures unique random ports
#───────────────────────────────────────────────────────────────────────────────────────────────────
declare -A USED_PORTS=()

get_random_port() {
    local port
    local max_attempts=100
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        port=$((RANDOM % 10000 + 40000))  # Range: 40000-50000
        
        # Check if port is in use by system
        if ! ss -tuln | grep -q ":${port} " && [[ -z "${USED_PORTS[$port]}" ]]; then
            USED_PORTS[$port]=1
            echo "$port"
            return 0
        fi
        ((attempt++))
    done
    
    log_error "Failed to find available port after $max_attempts attempts"
    return 1
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Dependencies
#───────────────────────────────────────────────────────────────────────────────────────────────────
install_dependencies() {
    log_step "Checking dependencies..."
    local deps=(wget curl jq psmisc iproute2)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null && ! dpkg -l "$dep" &>/dev/null 2>&1 && ! rpm -q "$dep" &>/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing: ${missing[*]}"
        if command -v apt &>/dev/null; then
            apt update -qq && apt install -y -qq "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}"
        fi
    fi
    log_success "Dependencies ready"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Binary Installation
#───────────────────────────────────────────────────────────────────────────────────────────────────
install_binary() {
    log_step "Installing Psiphon Core binary..."
    mkdir -p "$PSIPHON_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    
    if [[ ! -f "$BIN_PATH" ]]; then
        log_info "Downloading psiphon-tunnel-core..."
        wget -qO "$BIN_PATH" "$BIN_URL" || curl -sSL -o "$BIN_PATH" "$BIN_URL"
        chmod +x "$BIN_PATH"
        log_success "Psiphon Core installed"
    else
        log_info "Psiphon Core already exists, checking for updates..."
        local current_md5=$(md5sum "$BIN_PATH" 2>/dev/null | awk '{print $1}')
        local temp_file=$(mktemp)
        wget -qO "$temp_file" "$BIN_URL" 2>/dev/null || curl -sSL -o "$temp_file" "$BIN_URL" 2>/dev/null
        local new_md5=$(md5sum "$temp_file" 2>/dev/null | awk '{print $1}')
        
        if [[ "$current_md5" != "$new_md5" && -s "$temp_file" ]]; then
            mv "$temp_file" "$BIN_PATH"
            chmod +x "$BIN_PATH"
            log_success "Psiphon Core updated"
        else
            rm -f "$temp_file"
            log_info "Psiphon Core is up to date"
        fi
    fi
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Instance Configuration Generator
#───────────────────────────────────────────────────────────────────────────────────────────────────
create_instance_config() {
    local instance_id="$1"
    local socks_port="$2"
    local country="$3"
    
    local config_file="${CONFIG_DIR}/${instance_id}.json"
    local data_dir="${DATA_DIR}/${instance_id}"
    local instance_dir="${PSIPHON_DIR}/runtime/${instance_id}"
    
    mkdir -p "$data_dir" "$instance_dir"
    
    # Generate unique network ID to ensure complete isolation
    local network_id="FLEET-${instance_id}-$(date +%s)-${RANDOM}"
    
    cat > "$config_file" << ENDCONFIG
{
    "LocalSocksProxyPort": ${socks_port},
    "LocalHttpProxyPort": 0,
    "LocalSocksProxyInterface": "127.0.0.1",
    "LocalHttpProxyInterface": "127.0.0.1",
    "EgressRegion": "${country}",
    "DataRootDirectory": "${data_dir}",
    "MigrateDataStoreDirectory": "${data_dir}/migrate",
    "NetworkID": "${network_id}",
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "SponsorId": "FFFFFFFFFFFFFFFF",
    "RemoteServerListDownloadFilename": "server_list_${instance_id}",
    "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
    "ObfuscatedServerListRootURLs": ["https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"],
    "EstablishTunnelTimeoutSeconds": 300,
    "UseIndistinguishableTLS": true,
    "TunnelPoolSize": 2,
    "ConnectionWorkerPoolSize": 4,
    "LimitTunnelProtocols": ["OSSH", "SSH", "UNFRONTED-MEEK-OSSH", "UNFRONTED-MEEK-HTTPS-OSSH", "FRONTED-MEEK-OSSH"],
    "DisableLocalHTTPProxy": true,
    "DisableRemoteServerListFetcher": false,
    "EmitDiagnosticNotices": true,
    "EmitBytesTransferred": true
}
ENDCONFIG
    
    chmod 600 "$config_file"
    log_success "Config created: ${instance_id} -> ${country}:${socks_port}"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Systemd Service Generator - Complete Isolation
#───────────────────────────────────────────────────────────────────────────────────────────────────
create_systemd_service() {
    local instance_id="$1"
    local socks_port="$2"
    local country="$3"
    
    local service_name="psiphon-fleet@${instance_id}"
    local config_file="${CONFIG_DIR}/${instance_id}.json"
    local log_file="${LOG_DIR}/${instance_id}.log"
    local instance_dir="${PSIPHON_DIR}/runtime/${instance_id}"
    local country_name="${COUNTRY_NAMES[$country]:-$country}"
    
    mkdir -p "$instance_dir"
    
    cat > "/etc/systemd/system/psiphon-fleet@${instance_id}.service" << ENDSERVICE
[Unit]
Description=Psiphon Fleet Instance: ${instance_id} [${country_name}] Port ${socks_port}
Documentation=https://github.com/Psiphon-Labs/psiphon-tunnel-core
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
Group=root

# Isolated working directory
WorkingDirectory=${instance_dir}

# Aggressive port cleanup before start
ExecStartPre=/bin/bash -c '\
    PORT=${socks_port}; \
    fuser -k \${PORT}/tcp 2>/dev/null || true; \
    sleep 1; \
    if command -v ss >/dev/null 2>&1; then \
        for pid in \$(ss -ltnp "sport = :\${PORT}" 2>/dev/null | sed -n "s/.*pid=\\([0-9]\\+\\).*/\\1/p" | sort -u); do \
            kill -9 "\$pid" 2>/dev/null || true; \
        done; \
        waited=0; \
        while ss -ltn "sport = :\${PORT}" 2>/dev/null | grep -q ":\${PORT}"; do \
            sleep 0.5; \
            waited=\$((waited + 1)); \
            [[ \$waited -ge 20 ]] && break; \
        done; \
    fi; \
    sleep 1; \
    exit 0'

# Main process with JSON notices for parsing
ExecStart=${BIN_PATH} -config ${config_file} -formatNotices json

# Graceful stop with timeout
ExecStop=/bin/bash -c 'kill -TERM \$MAINPID 2>/dev/null; sleep 3; kill -9 \$MAINPID 2>/dev/null || true'

# Restart policy
Restart=always
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=30

# Resource limits
LimitNOFILE=65535
LimitNPROC=4096
TasksMax=256
MemoryMax=512M

# Logging
StandardOutput=append:${log_file}
StandardError=append:${log_file}

# Security hardening
PrivateTmp=true
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}/${instance_id} ${LOG_DIR} ${instance_dir}

# Prevent OOM killer
OOMScoreAdjust=-500

# Environment
Environment="PSIPHON_INSTANCE_ID=${instance_id}"
Environment="PSIPHON_COUNTRY=${country}"
Environment="PSIPHON_PORT=${socks_port}"

[Install]
WantedBy=multi-user.target
ENDSERVICE

    chmod 644 "/etc/systemd/system/psiphon-fleet@${instance_id}.service"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Interactive Fleet Setup
#───────────────────────────────────────────────────────────────────────────────────────────────────
interactive_setup() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                        FLEET CONFIGURATION WIZARD                            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Show available countries in a clean grid format
    echo -e "${WHITE}Available Countries:${NC}"
    echo ""
    echo -e "  ${GREEN}US${NC}  United States     ${GREEN}DE${NC}  Germany          ${GREEN}GB${NC}  United Kingdom   ${GREEN}NL${NC}  Netherlands"
    echo -e "  ${GREEN}FR${NC}  France            ${GREEN}SG${NC}  Singapore        ${GREEN}JP${NC}  Japan            ${GREEN}CA${NC}  Canada"
    echo -e "  ${GREEN}AU${NC}  Australia         ${GREEN}CH${NC}  Switzerland      ${GREEN}SE${NC}  Sweden           ${GREEN}NO${NC}  Norway"
    echo -e "  ${GREEN}AT${NC}  Austria           ${GREEN}BE${NC}  Belgium          ${GREEN}CZ${NC}  Czech Republic   ${GREEN}DK${NC}  Denmark"
    echo -e "  ${GREEN}ES${NC}  Spain             ${GREEN}FI${NC}  Finland          ${GREEN}HU${NC}  Hungary          ${GREEN}IE${NC}  Ireland"
    echo -e "  ${GREEN}IT${NC}  Italy             ${GREEN}PL${NC}  Poland           ${GREEN}PT${NC}  Portugal         ${GREEN}RO${NC}  Romania"
    echo -e "  ${GREEN}SK${NC}  Slovakia          ${GREEN}IN${NC}  India            ${GREEN}BR${NC}  Brazil"
    echo ""
    
    # Get number of instances
    local num_instances=""
    while [[ -z "$num_instances" ]] || ! [[ "$num_instances" =~ ^[0-9]+$ ]] || [[ "$num_instances" -lt 1 ]] || [[ "$num_instances" -gt 20 ]]; do
        echo -ne "${GREEN}How many Psiphon instances do you want? (1-20) [5]: ${NC}"
        read -r num_instances
        num_instances="${num_instances:-5}"
        if ! [[ "$num_instances" =~ ^[0-9]+$ ]] || [[ "$num_instances" -lt 1 ]] || [[ "$num_instances" -gt 20 ]]; then
            echo -e "${RED}Please enter a number between 1 and 20${NC}"
            num_instances=""
        fi
    done
    
    echo ""
    log_info "Configuring $num_instances instance(s)..."
    echo ""
    
    # Valid country codes
    local valid_countries="US DE GB NL FR SG JP CA AU CH SE NO AT BE CZ DK ES FI HU IE IT PL PT RO SK IN BR"
    
    # Configure each instance
    for ((i=1; i<=num_instances; i++)); do
        local country=""
        while [[ -z "$country" ]]; do
            echo -ne "${YELLOW}Instance $i - Enter country code (e.g., US, DE, GB): ${NC}"
            read -r country
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            
            # Validate country code
            if [[ ! " $valid_countries " =~ " $country " ]]; then
                echo -e "${RED}Invalid country code '$country'. Use one from the list above.${NC}"
                country=""
            fi
        done
        
        local port
        port=$(get_random_port)
        local instance_id="psiphon-${country,,}-${port}"
        
        # Store in fleet
        FLEET_INSTANCES["$instance_id"]="${country}:${port}"
        
        echo -e "  ${GREEN}✓${NC} Instance #${i}: ${CYAN}${instance_id}${NC} -> ${country} on port ${YELLOW}${port}${NC}"
    done
    
    echo ""
    save_state
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Deploy All Instances
#───────────────────────────────────────────────────────────────────────────────────────────────────
deploy_fleet() {
    log_step "Deploying Fleet with ${#FLEET_INSTANCES[@]} instances..."
    
    # Stop existing instances
    log_info "Stopping any existing fleet instances..."
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        systemctl stop "psiphon-fleet@${instance_id}" 2>/dev/null || true
        systemctl disable "psiphon-fleet@${instance_id}" 2>/dev/null || true
    done
    sleep 2
    
    # Create all configs and services
    log_info "Creating configurations and services..."
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        create_instance_config "$instance_id" "$port" "$country"
        create_systemd_service "$instance_id" "$port" "$country"
    done
    
    # Reload systemd
    systemctl daemon-reload
    sleep 1
    
    # Enable all services
    log_info "Enabling services..."
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        systemctl enable "psiphon-fleet@${instance_id}" >/dev/null 2>&1
    done
    
    # Start services with staggered delays for isolation
    log_info "Starting fleet with staggered delays for complete isolation..."
    local count=0
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        ((count++))
        echo -ne "  [${count}/${#FLEET_INSTANCES[@]}] Starting ${CYAN}${instance_id}${NC}..."
        systemctl start "psiphon-fleet@${instance_id}"
        
        if systemctl is-active --quiet "psiphon-fleet@${instance_id}"; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${YELLOW}initializing...${NC}"
        fi
        
        # Stagger starts to prevent port conflicts
        sleep 5
    done
    
    log_success "Fleet deployed successfully!"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Verification & Status
#───────────────────────────────────────────────────────────────────────────────────────────────────
verify_fleet() {
    echo ""
    log_step "Verifying Fleet Status (waiting 30s for tunnel establishment)..."
    
    for i in {30..1}; do
        echo -ne "\r  Waiting for tunnels... ${YELLOW}${i}s${NC}  "
        sleep 1
    done
    echo -e "\r  Waiting for tunnels... ${GREEN}Done!${NC}    "
    echo ""
    
    show_status
}

show_status() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                               PSIPHON FLEET STATUS                                       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    printf "${WHITE}%-28s %-12s %-10s %-8s %-18s %-10s${NC}\n" "INSTANCE ID" "COUNTRY" "STATUS" "PORT" "EXIT IP" "VERIFIED"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────"
    
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        local status="DOWN"
        local status_color="${RED}"
        local exit_ip="N/A"
        local exit_country="N/A"
        local verified="${RED}✗${NC}"
        
        if systemctl is-active --quiet "psiphon-fleet@${instance_id}"; then
            status="UP"
            status_color="${GREEN}"
            
            # Test SOCKS5 proxy
            local ip_info=$(timeout 10 curl --connect-timeout 5 --socks5 127.0.0.1:${port} -s https://ipapi.co/json 2>/dev/null || echo "")
            
            if [[ -n "$ip_info" && "$ip_info" != *"error"* ]]; then
                exit_ip=$(echo "$ip_info" | jq -r '.ip // "N/A"' 2>/dev/null | head -c 15)
                exit_country=$(echo "$ip_info" | jq -r '.country_code // "N/A"' 2>/dev/null)
                
                if [[ "$exit_country" == "$country" ]]; then
                    verified="${GREEN}✓ Match${NC}"
                else
                    verified="${YELLOW}≈ ${exit_country}${NC}"
                fi
            else
                exit_ip="Connecting..."
                verified="${YELLOW}...${NC}"
            fi
        fi
        
        printf "%-28s %-12s ${status_color}%-10s${NC} %-8s %-18s %-10b\n" \
            "$instance_id" "${COUNTRY_NAMES[$country]:-$country}" "$status" "$port" "$exit_ip" "$verified"
    done
    
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Generate X-UI Outbound Configuration
#───────────────────────────────────────────────────────────────────────────────────────────────────
generate_xui_outbounds() {
    echo ""
    log_step "Generating X-UI Outbound Configurations"
    echo ""
    
    local outbounds_file="${PSIPHON_DIR}/xray-outbounds.json"
    
    cat > "$outbounds_file" << 'HEADER'
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
HEADER

    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        local tag="out-${country,,}"
        
        cat >> "$outbounds_file" << OUTBOUND
    ,{
      "tag": "${tag}",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "127.0.0.1",
          "port": ${port}
        }]
      }
    }
OUTBOUND
    done
    
    echo "  ]" >> "$outbounds_file"
    echo "}" >> "$outbounds_file"
    
    log_success "Outbounds config saved to: $outbounds_file"
    echo ""
    echo -e "${WHITE}Add these outbounds to your X-UI Xray configuration:${NC}"
    echo ""
    cat "$outbounds_file" | jq .
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Generate Routing Rules for User-based Routing
#───────────────────────────────────────────────────────────────────────────────────────────────────
generate_routing_rules() {
    echo ""
    log_step "Generating X-UI Routing Rules (User-based)"
    echo ""
    
    local routing_file="${PSIPHON_DIR}/xray-routing.json"
    
    cat > "$routing_file" << 'HEADER'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
HEADER

    local first=true
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        local user_email="user-${country,,}"
        local outbound_tag="out-${country,,}"
        
        [[ "$first" != "true" ]] && echo "      ," >> "$routing_file"
        first=false
        
        cat >> "$routing_file" << RULE
      {
        "type": "field",
        "user": ["${user_email}"],
        "outboundTag": "${outbound_tag}"
      }
RULE
    done
    
    cat >> "$routing_file" << 'FOOTER'
      ,{
        "type": "field",
        "outboundTag": "direct",
        "network": "udp,tcp"
      }
    ]
  }
}
FOOTER
    
    log_success "Routing config saved to: $routing_file"
    echo ""
    echo -e "${WHITE}Add these routing rules to your X-UI Xray configuration:${NC}"
    echo ""
    cat "$routing_file" | jq .
    echo ""
    
    echo -e "${YELLOW}Instructions:${NC}"
    echo -e "1. Create ONE inbound on port 2083 (VLESS/VMess with WebSocket)"
    echo -e "2. Add clients with these emails:"
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        echo -e "   - ${GREEN}user-${country,,}${NC} → exits via ${COUNTRY_NAMES[$country]:-$country}"
    done
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Control Functions
#───────────────────────────────────────────────────────────────────────────────────────────────────
control_fleet() {
    local action="$1"
    local target="$2"
    
    if [[ -n "$target" ]]; then
        # Single instance
        if [[ -z "${FLEET_INSTANCES[$target]}" ]]; then
            log_error "Instance '$target' not found in fleet"
            return 1
        fi
        
        log_info "${action^}ing $target..."
        systemctl "$action" "psiphon-fleet@${target}"
        log_success "$target ${action}ed"
    else
        # All instances
        log_info "${action^}ing all fleet instances..."
        for instance_id in "${!FLEET_INSTANCES[@]}"; do
            systemctl "$action" "psiphon-fleet@${instance_id}" 2>/dev/null || true
            [[ "$action" == "start" ]] && sleep 3
        done
        log_success "All instances ${action}ed"
    fi
}

show_logs() {
    local instance="${1:-}"
    local lines="${2:-50}"
    
    if [[ -z "$instance" ]]; then
        # Show combined logs
        log_info "Showing last $lines lines from all instances..."
        tail -n "$lines" ${LOG_DIR}/*.log 2>/dev/null | head -200
    else
        if [[ -z "${FLEET_INSTANCES[$instance]}" ]]; then
            log_error "Instance '$instance' not found"
            return 1
        fi
        log_info "Showing last $lines lines from $instance..."
        tail -n "$lines" "${LOG_DIR}/${instance}.log" 2>/dev/null
    fi
}

uninstall_fleet() {
    log_warn "Uninstalling Psiphon Fleet..."
    read -rp "Are you sure? This removes ALL instances and data (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log_info "Cancelled."; return; }
    
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        systemctl stop "psiphon-fleet@${instance_id}" 2>/dev/null || true
        systemctl disable "psiphon-fleet@${instance_id}" 2>/dev/null || true
        rm -f "/etc/systemd/system/psiphon-fleet@${instance_id}.service"
    done
    
    systemctl daemon-reload
    rm -rf "$PSIPHON_DIR" "$DATA_DIR" "$LOG_DIR"
    
    log_success "Fleet uninstalled completely"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Usage
#───────────────────────────────────────────────────────────────────────────────────────────────────
show_usage() {
    cat << USAGE
${CYAN}PSIPHON FLEET COMMANDER v3.0${NC}

${WHITE}Usage:${NC}
  $0 install              - Interactive setup and deploy fleet
  $0 status               - Show status of all instances
  $0 start [instance]     - Start instance(s)
  $0 stop [instance]      - Stop instance(s)  
  $0 restart [instance]   - Restart instance(s)
  $0 logs [instance] [n]  - Show logs (default: all, 50 lines)
  $0 generate-xui         - Generate X-UI outbounds and routing
  $0 add <country>        - Add new instance for country
  $0 uninstall            - Remove all fleet instances

${WHITE}Examples:${NC}
  $0 install
  $0 status
  $0 logs psiphon-us-42156 100
  $0 restart psiphon-de-45892
  $0 generate-xui
  $0 add FR

${WHITE}Current Fleet:${NC}
USAGE

    if load_state && [[ ${#FLEET_INSTANCES[@]} -gt 0 ]]; then
        for instance_id in "${!FLEET_INSTANCES[@]}"; do
            IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
            echo -e "  ${GREEN}•${NC} $instance_id → ${country}:${port}"
        done
    else
        echo -e "  ${DIM}No instances configured${NC}"
    fi
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Add Instance
#───────────────────────────────────────────────────────────────────────────────────────────────────
add_instance() {
    local country="$1"
    country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    
    if [[ -z "${COUNTRY_NAMES[$country]}" ]]; then
        log_error "Invalid country code: $country"
        return 1
    fi
    
    load_state
    
    local port=$(get_random_port)
    local instance_id="psiphon-${country,,}-${port}"
    
    FLEET_INSTANCES["$instance_id"]="${country}:${port}"
    save_state
    
    create_instance_config "$instance_id" "$port" "$country"
    create_systemd_service "$instance_id" "$port" "$country"
    
    systemctl daemon-reload
    systemctl enable "psiphon-fleet@${instance_id}"
    systemctl start "psiphon-fleet@${instance_id}"
    
    log_success "Added and started: $instance_id (${COUNTRY_NAMES[$country]} on port $port)"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Main Entry Point
#───────────────────────────────────────────────────────────────────────────────────────────────────
main() {
    print_banner
    load_state 2>/dev/null || true
    
    case "${1:-}" in
        install)
            install_dependencies
            install_binary
            interactive_setup
            deploy_fleet
            verify_fleet
            generate_xui_outbounds
            generate_routing_rules
            log_success "Installation complete!"
            ;;
        status)
            show_status
            ;;
        start|stop|restart)
            control_fleet "$1" "$2"
            ;;
        logs)
            show_logs "$2" "${3:-50}"
            ;;
        generate-xui)
            generate_xui_outbounds
            generate_routing_rules
            ;;
        add)
            [[ -z "$2" ]] && { log_error "Usage: $0 add <country_code>"; exit 1; }
            install_dependencies
            install_binary
            add_instance "$2"
            ;;
        uninstall)
            uninstall_fleet
            ;;
        *)
            show_usage
            ;;
    esac
}

main "$@"
