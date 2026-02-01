#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  PSIPHON MANAGER v5.0 - Production-Ready Multi-Instance Deployment
#  Uses native psiphon-tunnel-core with proper configuration
#  Each instance has its own: config, data directory, process, and ports
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail
trap 'echo -e "\n\033[0;31m[ABORT]\033[0m Script interrupted."; exit 130' INT

# Root check
[[ $EUID -ne 0 ]] && { echo "Run as root!"; exec sudo "$0" "$@"; }

#───────────────────────────────────────────────────────────────────────────────
# Configuration & Constants
#───────────────────────────────────────────────────────────────────────────────
readonly VERSION="5.0"
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m' CYAN='\033[0;36m' MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m' NC='\033[0m' BOLD='\033[1m' DIM='\033[2m'

readonly BASE_DIR="/opt/psiphon"
readonly CONFIG_DIR="${BASE_DIR}/configs"
readonly DATA_DIR="${BASE_DIR}/data"
readonly LOG_DIR="/var/log/psiphon"
readonly STATE_FILE="${BASE_DIR}/instances.state"
readonly BIN_PATH="${BASE_DIR}/psiphon-tunnel-core"
readonly BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"

# Countries with Psiphon servers
declare -A COUNTRIES=(
    ["US"]="United States"    ["DE"]="Germany"        ["GB"]="United Kingdom"
    ["NL"]="Netherlands"      ["FR"]="France"         ["SG"]="Singapore"
    ["JP"]="Japan"            ["CA"]="Canada"         ["AU"]="Australia"
    ["CH"]="Switzerland"      ["SE"]="Sweden"         ["NO"]="Norway"
    ["AT"]="Austria"          ["BE"]="Belgium"        ["CZ"]="Czech Republic"
    ["DK"]="Denmark"          ["ES"]="Spain"          ["IT"]="Italy"
    ["PL"]="Poland"           ["IN"]="India"          ["IE"]="Ireland"
)

# Instance storage: instance_id => "country:socks_port:http_port"
declare -A INSTANCES=()

#───────────────────────────────────────────────────────────────────────────────
# Logging
#───────────────────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$1${NC}"; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║   ██████╗ ███████╗██╗██████╗ ██╗  ██╗ ██████╗ ███╗   ██╗                     ║
║   ██╔══██╗██╔════╝██║██╔══██╗██║  ██║██╔═══██╗████╗  ██║                     ║
║   ██████╔╝███████╗██║██████╔╝███████║██║   ██║██╔██╗ ██║                     ║
║   ██╔═══╝ ╚════██║██║██╔═══╝ ██╔══██║██║   ██║██║╚██╗██║                     ║
║   ██║     ███████║██║██║     ██║  ██║╚██████╔╝██║ ╚████║                     ║
║   ╚═╝     ╚══════╝╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝                     ║
║                        MANAGER v5.0 - Native Binary Mode                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

#───────────────────────────────────────────────────────────────────────────────
# State Management
#───────────────────────────────────────────────────────────────────────────────
save_state() {
    mkdir -p "$BASE_DIR"
    : > "$STATE_FILE"
    for key in "${!INSTANCES[@]}"; do
        echo "${key}=${INSTANCES[$key]}" >> "$STATE_FILE"
    done
    chmod 600 "$STATE_FILE"
}

load_state() {
    INSTANCES=()
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ -n "$key" && -n "$value" ]] && INSTANCES["$key"]="$value"
        done < "$STATE_FILE"
        return 0
    fi
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# Port Management
#───────────────────────────────────────────────────────────────────────────────
declare -A RESERVED_PORTS=()

is_port_available() {
    local port="$1"
    # Check if port is in use by any process
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    # Check if we already reserved it
    if [[ -n "${RESERVED_PORTS[$port]:-}" ]]; then
        return 1
    fi
    return 0
}

find_available_port() {
    local start="${1:-10000}"
    local end="${2:-20000}"
    local port
    
    for ((port = start; port <= end; port++)); do
        if is_port_available "$port"; then
            RESERVED_PORTS[$port]=1
            echo "$port"
            return 0
        fi
    done
    
    log_error "No available port found in range ${start}-${end}"
    return 1
}

kill_port() {
    local port="$1"
    if command -v fuser &>/dev/null; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    fi
    # Also kill by searching ss output
    local pids
    pids=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u)
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
}

#───────────────────────────────────────────────────────────────────────────────
# Dependencies
#───────────────────────────────────────────────────────────────────────────────
install_dependencies() {
    log_step "Installing dependencies..."
    
    local deps=(curl wget jq)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Check for ss (iproute2)
    if ! command -v ss &>/dev/null; then
        missing+=("iproute2")
    fi
    
    # Check for fuser (psmisc)
    if ! command -v fuser &>/dev/null; then
        missing+=("psmisc")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing: ${missing[*]}"
        if command -v apt &>/dev/null; then
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}"
        fi
    fi
    
    log_success "Dependencies installed"
}

#───────────────────────────────────────────────────────────────────────────────
# Psiphon Binary Management
#───────────────────────────────────────────────────────────────────────────────
download_psiphon() {
    log_step "Setting up Psiphon binary..."
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    
    if [[ -f "$BIN_PATH" ]] && [[ -x "$BIN_PATH" ]]; then
        log_info "Psiphon binary already exists, checking for updates..."
        local current_size
        current_size=$(stat -c%s "$BIN_PATH" 2>/dev/null || echo 0)
        
        # Download to temp and compare
        local temp_bin="${BIN_PATH}.new"
        if wget -q -O "$temp_bin" "$BIN_URL" 2>/dev/null; then
            local new_size
            new_size=$(stat -c%s "$temp_bin" 2>/dev/null || echo 0)
            
            if [[ "$new_size" -gt 1000000 ]] && [[ "$new_size" != "$current_size" ]]; then
                log_info "New version available, updating..."
                mv "$temp_bin" "$BIN_PATH"
                chmod +x "$BIN_PATH"
                log_success "Psiphon binary updated"
            else
                rm -f "$temp_bin"
                log_success "Psiphon binary is up to date"
            fi
        else
            rm -f "$temp_bin"
            log_warn "Could not check for updates, using existing binary"
        fi
    else
        log_info "Downloading Psiphon binary..."
        wget -q -O "$BIN_PATH" "$BIN_URL"
        chmod +x "$BIN_PATH"
        log_success "Psiphon binary downloaded: $BIN_PATH"
    fi
    
    # Verify binary works
    if ! "$BIN_PATH" --help &>/dev/null; then
        log_error "Psiphon binary verification failed!"
        return 1
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Configuration Generation
#───────────────────────────────────────────────────────────────────────────────
create_config() {
    local instance_id="$1"
    local country="$2"
    local socks_port="$3"
    local http_port="$4"
    
    local config_file="${CONFIG_DIR}/${instance_id}.json"
    local data_path="${DATA_DIR}/${instance_id}"
    
    mkdir -p "$data_path"
    
    # Create a unique network ID for each instance to prevent conflicts
    local network_id="PSIPHON-${instance_id}-$(date +%s%N)"
    
    cat > "$config_file" << JSONEOF
{
    "LocalSocksProxyPort": ${socks_port},
    "LocalHttpProxyPort": ${http_port},
    "EgressRegion": "${country}",
    "DataRootDirectory": "${data_path}",
    "MigrateDataStoreDirectory": "${data_path}",
    "NetworkID": "${network_id}",
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "SponsorId": "FFFFFFFFFFFFFFFF",
    "RemoteServerListDownloadFilename": "server_list_${instance_id}",
    "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
    "EstablishTunnelTimeoutSeconds": 120,
    "UseIndistinguishableTLS": true,
    "TunnelPoolSize": 1,
    "ConnectionWorkerPoolSize": 5,
    "LimitTunnelProtocols": ["OSSH", "SSH", "UNFRONTED-MEEK-OSSH", "UNFRONTED-MEEK-HTTPS-OSSH"],
    "EmitDiagnosticNotices": true,
    "EmitBytesTransferred": false,
    "DisableLocalSocksProxy": false,
    "DisableLocalHTTPProxy": false
}
JSONEOF

    chmod 600 "$config_file"
    log_success "Config created: $config_file"
}

#───────────────────────────────────────────────────────────────────────────────
# Systemd Service Creation
#───────────────────────────────────────────────────────────────────────────────
create_systemd_service() {
    local instance_id="$1"
    local country="$2"
    local socks_port="$3"
    local http_port="$4"
    
    local service_name="psiphon-${instance_id}"
    local config_file="${CONFIG_DIR}/${instance_id}.json"
    local log_file="${LOG_DIR}/${instance_id}.log"
    local data_path="${DATA_DIR}/${instance_id}"
    local country_name="${COUNTRIES[$country]:-$country}"
    
    cat > "/etc/systemd/system/${service_name}.service" << SVCEOF
[Unit]
Description=Psiphon Proxy - ${country_name} (${country}) SOCKS:${socks_port} HTTP:${http_port}
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/Psiphon-Labs/psiphon-tunnel-core

[Service]
Type=simple
User=root

# Working directory for this instance
WorkingDirectory=${data_path}

# Pre-start: ensure clean port state
ExecStartPre=/bin/bash -c 'for p in ${socks_port} ${http_port}; do fuser -k \${p}/tcp 2>/dev/null || true; done; sleep 1'

# Main command - pass config file directly
ExecStart=${BIN_PATH} -config ${config_file}

# Restart behavior
Restart=always
RestartSec=10
StartLimitBurst=5
StartLimitIntervalSec=300

# Process limits
LimitNOFILE=65535
TasksMax=256

# Logging
StandardOutput=append:${log_file}
StandardError=append:${log_file}

# Security
PrivateTmp=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
SVCEOF

    chmod 644 "/etc/systemd/system/${service_name}.service"
}

#───────────────────────────────────────────────────────────────────────────────
# Instance Management
#───────────────────────────────────────────────────────────────────────────────
create_instance() {
    local country="$1"
    country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    
    if [[ -z "${COUNTRIES[$country]:-}" ]]; then
        log_error "Unknown country code: $country"
        echo "Available: ${!COUNTRIES[*]}"
        return 1
    fi
    
    # Find available ports
    local socks_port http_port
    socks_port=$(find_available_port 10000 15000) || return 1
    http_port=$(find_available_port 15001 20000) || return 1
    
    local instance_id="${country,,}-${socks_port}"
    
    log_info "Creating instance: ${instance_id} [${COUNTRIES[$country]}]"
    log_info "  SOCKS5: 127.0.0.1:${socks_port}"
    log_info "  HTTP:   127.0.0.1:${http_port}"
    
    # Store instance
    INSTANCES["$instance_id"]="${country}:${socks_port}:${http_port}"
    
    # Create config and service
    create_config "$instance_id" "$country" "$socks_port" "$http_port"
    create_systemd_service "$instance_id" "$country" "$socks_port" "$http_port"
    
    return 0
}

start_instance() {
    local instance_id="$1"
    local service_name="psiphon-${instance_id}"
    
    log_info "Starting ${instance_id}..."
    
    systemctl daemon-reload
    systemctl enable "$service_name" 2>/dev/null || true
    systemctl start "$service_name"
    
    # Wait briefly and check status
    sleep 2
    if systemctl is-active --quiet "$service_name"; then
        log_success "${instance_id} started successfully"
        return 0
    else
        log_error "${instance_id} failed to start"
        journalctl -u "$service_name" --no-pager -n 5
        return 1
    fi
}

stop_instance() {
    local instance_id="$1"
    local service_name="psiphon-${instance_id}"
    
    log_info "Stopping ${instance_id}..."
    systemctl stop "$service_name" 2>/dev/null || true
    
    # Also kill any orphaned processes on the ports
    if [[ -n "${INSTANCES[$instance_id]:-}" ]]; then
        IFS=':' read -r _ socks_port http_port <<< "${INSTANCES[$instance_id]}"
        kill_port "$socks_port"
        kill_port "$http_port"
    fi
    
    log_success "${instance_id} stopped"
}

remove_instance() {
    local instance_id="$1"
    local service_name="psiphon-${instance_id}"
    
    stop_instance "$instance_id"
    
    systemctl disable "$service_name" 2>/dev/null || true
    rm -f "/etc/systemd/system/${service_name}.service"
    rm -f "${CONFIG_DIR}/${instance_id}.json"
    rm -rf "${DATA_DIR}/${instance_id}"
    rm -f "${LOG_DIR}/${instance_id}.log"
    
    unset "INSTANCES[$instance_id]"
    save_state
    
    systemctl daemon-reload
    log_success "${instance_id} removed"
}

#───────────────────────────────────────────────────────────────────────────────
# Fleet Operations
#───────────────────────────────────────────────────────────────────────────────
stop_all() {
    log_step "Stopping all instances..."
    
    # Stop via systemd
    for instance_id in "${!INSTANCES[@]}"; do
        stop_instance "$instance_id"
    done
    
    # Also kill any stray psiphon processes
    pkill -f psiphon-tunnel-core 2>/dev/null || true
    
    log_success "All instances stopped"
}

start_all() {
    log_step "Starting all instances with staggered delays..."
    
    local count=0
    for instance_id in "${!INSTANCES[@]}"; do
        ((count++)) || true
        log_info "[$count/${#INSTANCES[@]}] Starting ${instance_id}..."
        start_instance "$instance_id"
        sleep 5  # Stagger start to avoid conflicts
    done
    
    log_success "All instances started"
}

restart_all() {
    stop_all
    sleep 3
    start_all
}

#───────────────────────────────────────────────────────────────────────────────
# Interactive Setup
#───────────────────────────────────────────────────────────────────────────────
interactive_setup() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                        PSIPHON FLEET SETUP WIZARD                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Show available countries
    echo -e "${WHITE}Available Countries:${NC}"
    echo ""
    local cols=0
    for code in $(echo "${!COUNTRIES[@]}" | tr ' ' '\n' | sort); do
        printf "  ${GREEN}%-3s${NC} %-18s" "$code" "${COUNTRIES[$code]}"
        ((cols++)) || true
        if [[ $cols -ge 4 ]]; then
            echo ""
            cols=0
        fi
    done
    [[ $cols -gt 0 ]] && echo ""
    echo ""
    
    # Get number of instances
    local num_instances
    while true; do
        echo -ne "${GREEN}How many Psiphon instances? (1-10) [5]: ${NC}"
        read -r num_instances
        num_instances="${num_instances:-5}"
        if [[ "$num_instances" =~ ^[0-9]+$ ]] && [[ "$num_instances" -ge 1 ]] && [[ "$num_instances" -le 10 ]]; then
            break
        fi
        echo -e "${RED}Please enter a number between 1 and 10${NC}"
    done
    
    echo ""
    
    # Clear existing instances
    INSTANCES=()
    
    # Configure each instance
    for ((i = 1; i <= num_instances; i++)); do
        local country
        while true; do
            echo -ne "${YELLOW}Instance $i - Country code: ${NC}"
            read -r country
            country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
            
            if [[ -n "${COUNTRIES[$country]:-}" ]]; then
                break
            fi
            echo -e "${RED}Invalid code. Use: ${!COUNTRIES[*]}${NC}"
        done
        
        create_instance "$country"
        echo ""
    done
    
    save_state
    log_success "Configuration complete! ${#INSTANCES[@]} instances configured."
}

#───────────────────────────────────────────────────────────────────────────────
# Status & Verification
#───────────────────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                               PSIPHON FLEET STATUS                                             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        echo -e "  ${DIM}No instances configured. Run: $0 install${NC}"
        echo ""
        return
    fi
    
    printf "${WHITE}%-15s %-18s %-10s %-10s %-8s %-18s %-10s${NC}\n" \
        "INSTANCE" "COUNTRY" "SOCKS" "HTTP" "STATUS" "EXIT IP" "VERIFIED"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────────"
    
    for instance_id in $(echo "${!INSTANCES[@]}" | tr ' ' '\n' | sort); do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance_id]}"
        
        local service_name="psiphon-${instance_id}"
        local status="DOWN"
        local status_color="${RED}"
        local exit_ip="N/A"
        local verified="${RED}N/A${NC}"
        
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            status="UP"
            status_color="${GREEN}"
            
            # Test SOCKS proxy
            local result
            result=$(timeout 15 curl --connect-timeout 10 --socks5 "127.0.0.1:${socks_port}" \
                     -s "https://ipapi.co/json" 2>/dev/null || echo "")
            
            if [[ -n "$result" && "$result" != *"error"* && "$result" != *"limit"* ]]; then
                exit_ip=$(echo "$result" | jq -r '.ip // "N/A"' 2>/dev/null | head -c 15)
                local exit_country
                exit_country=$(echo "$result" | jq -r '.country_code // "N/A"' 2>/dev/null)
                
                if [[ "$exit_country" == "$country" ]]; then
                    verified="${GREEN}OK (${exit_country})${NC}"
                else
                    verified="${YELLOW}DIFF (${exit_country})${NC}"
                fi
            else
                exit_ip="Connecting..."
                verified="${YELLOW}...${NC}"
            fi
        fi
        
        printf "%-15s %-18s %-10s %-10s ${status_color}%-8s${NC} %-18s %-10b\n" \
            "$instance_id" "${COUNTRIES[$country]:-$country}" "$socks_port" "$http_port" "$status" "$exit_ip" "$verified"
    done
    
    echo ""
}

verify_all() {
    log_step "Verifying all instances (this may take a minute)..."
    echo ""
    
    local success=0
    local failed=0
    
    for instance_id in "${!INSTANCES[@]}"; do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance_id]}"
        
        echo -ne "  Testing ${instance_id} (SOCKS:${socks_port})... "
        
        local result
        result=$(timeout 20 curl --connect-timeout 10 --socks5 "127.0.0.1:${socks_port}" \
                 -s "https://ipapi.co/json" 2>/dev/null || echo "")
        
        if [[ -n "$result" && "$result" != *"error"* ]]; then
            local exit_ip exit_country
            exit_ip=$(echo "$result" | jq -r '.ip' 2>/dev/null)
            exit_country=$(echo "$result" | jq -r '.country_code' 2>/dev/null)
            echo -e "${GREEN}OK${NC} - Exit IP: ${exit_ip}, Country: ${exit_country}"
            ((success++)) || true
        else
            echo -e "${RED}FAILED${NC}"
            ((failed++)) || true
        fi
    done
    
    echo ""
    log_info "Results: ${success} working, ${failed} failed"
}

#───────────────────────────────────────────────────────────────────────────────
# Log Viewing
#───────────────────────────────────────────────────────────────────────────────
show_logs() {
    local instance_id="${1:-}"
    local lines="${2:-50}"
    
    if [[ -z "$instance_id" ]]; then
        log_error "Usage: $0 logs <instance_id> [lines]"
        echo "Available instances:"
        for id in "${!INSTANCES[@]}"; do
            echo "  - $id"
        done
        return 1
    fi
    
    local log_file="${LOG_DIR}/${instance_id}.log"
    
    if [[ -f "$log_file" ]]; then
        echo -e "${CYAN}=== Last $lines lines from ${instance_id} ===${NC}"
        tail -n "$lines" "$log_file"
    else
        log_warn "No log file found, checking journald..."
        journalctl -u "psiphon-${instance_id}" --no-pager -n "$lines"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# X-UI Integration
#───────────────────────────────────────────────────────────────────────────────
generate_xui_config() {
    echo ""
    log_step "Generating X-UI Configuration"
    echo ""
    
    local outbounds_file="${BASE_DIR}/xray-outbounds.json"
    local routing_file="${BASE_DIR}/xray-routing.json"
    
    # Generate outbounds
    {
        echo '{"outbounds": ['
        echo '  {"tag": "direct", "protocol": "freedom", "settings": {}},'
        echo '  {"tag": "blocked", "protocol": "blackhole", "settings": {}}'
        
        for instance_id in "${!INSTANCES[@]}"; do
            IFS=':' read -r country socks_port _ <<< "${INSTANCES[$instance_id]}"
            cat << EOF
  ,{
    "tag": "psiphon-${country,,}",
    "protocol": "socks",
    "settings": {
      "servers": [{"address": "127.0.0.1", "port": ${socks_port}}]
    }
  }
EOF
        done
        echo ']}'
    } > "$outbounds_file"
    
    log_success "Outbounds saved: $outbounds_file"
    
    # Generate routing rules
    {
        echo '{"routing": {"domainStrategy": "AsIs", "rules": ['
        
        local first=true
        for instance_id in "${!INSTANCES[@]}"; do
            IFS=':' read -r country _ _ <<< "${INSTANCES[$instance_id]}"
            [[ "$first" != "true" ]] && echo ","
            first=false
            cat << EOF
  {"type": "field", "user": ["user-${country,,}@x-ui"], "outboundTag": "psiphon-${country,,}"}
EOF
        done
        
        echo ','
        echo '  {"type": "field", "outboundTag": "direct", "network": "udp,tcp"}'
        echo ']}}'
    } > "$routing_file"
    
    log_success "Routing saved: $routing_file"
    
    echo ""
    echo -e "${WHITE}X-UI Setup Instructions:${NC}"
    echo ""
    echo "1. Add these SOCKS outbounds to your Xray config:"
    for instance_id in "${!INSTANCES[@]}"; do
        IFS=':' read -r country socks_port _ <<< "${INSTANCES[$instance_id]}"
        echo -e "   ${GREEN}psiphon-${country,,}${NC} -> 127.0.0.1:${socks_port}"
    done
    echo ""
    echo "2. Create users with emails matching the routing rules:"
    for instance_id in "${!INSTANCES[@]}"; do
        IFS=':' read -r country _ _ <<< "${INSTANCES[$instance_id]}"
        echo -e "   ${YELLOW}user-${country,,}@x-ui${NC} -> exits via ${COUNTRIES[$country]}"
    done
    echo ""
    echo "3. View full configs:"
    echo "   cat $outbounds_file | jq ."
    echo "   cat $routing_file | jq ."
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# Cleanup / Uninstall
#───────────────────────────────────────────────────────────────────────────────
cleanup_all() {
    log_warn "Cleaning up all Psiphon instances..."
    
    # Stop all services
    for instance_id in "${!INSTANCES[@]}"; do
        local service_name="psiphon-${instance_id}"
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service_name}.service"
    done
    
    # Kill any remaining processes
    pkill -9 -f psiphon-tunnel-core 2>/dev/null || true
    
    # Clear state
    INSTANCES=()
    save_state
    
    systemctl daemon-reload
    log_success "Cleanup complete"
}

uninstall() {
    echo ""
    read -rp "Uninstall Psiphon Manager and remove ALL data? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        return
    fi
    
    cleanup_all
    
    log_info "Removing all files..."
    rm -rf "$BASE_DIR"
    rm -rf "$LOG_DIR"
    
    log_success "Psiphon Manager uninstalled"
}

#───────────────────────────────────────────────────────────────────────────────
# Quick Add
#───────────────────────────────────────────────────────────────────────────────
quick_add() {
    local country="$1"
    
    if create_instance "$country"; then
        save_state
        
        local instance_id
        # Get the last added instance
        for id in "${!INSTANCES[@]}"; do
            instance_id="$id"
        done
        
        start_instance "$instance_id"
        
        echo ""
        IFS=':' read -r _ socks_port http_port <<< "${INSTANCES[$instance_id]}"
        echo -e "${GREEN}Instance ready!${NC}"
        echo -e "  SOCKS5: curl --socks5 127.0.0.1:${socks_port} https://ipapi.co/json"
        echo -e "  HTTP:   curl -x http://127.0.0.1:${http_port} https://ipapi.co/json"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Usage
#───────────────────────────────────────────────────────────────────────────────
show_usage() {
    cat << USAGE
${CYAN}PSIPHON MANAGER v${VERSION}${NC}

${WHITE}Usage:${NC}
  $0 install              - Full interactive setup
  $0 status               - Show all instance statuses
  $0 verify               - Test all proxy connections
  $0 start [id]           - Start instance(s)
  $0 stop [id]            - Stop instance(s)
  $0 restart [id]         - Restart instance(s)
  $0 add <country>        - Add new instance (e.g., add US)
  $0 remove <id>          - Remove an instance
  $0 logs <id> [lines]    - View instance logs
  $0 xui-config           - Generate X-UI configuration
  $0 cleanup              - Stop and remove all instances
  $0 uninstall            - Complete removal

${WHITE}Examples:${NC}
  $0 install              # Interactive setup wizard
  $0 add DE               # Add Germany instance
  $0 status               # Check all statuses
  $0 logs us-10001 100    # View logs
  $0 restart              # Restart all

${WHITE}Current Instances:${NC}
USAGE

    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        echo -e "  ${DIM}None configured${NC}"
    else
        for instance_id in $(echo "${!INSTANCES[@]}" | tr ' ' '\n' | sort); do
            IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance_id]}"
            echo -e "  ${GREEN}${instance_id}${NC} - ${COUNTRIES[$country]:-$country} (SOCKS:${socks_port}, HTTP:${http_port})"
        done
    fi
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# Main
#───────────────────────────────────────────────────────────────────────────────
main() {
    print_banner
    load_state 2>/dev/null || true
    
    case "${1:-}" in
        install)
            install_dependencies
            download_psiphon
            cleanup_all  # Clean start
            interactive_setup
            start_all
            echo ""
            log_info "Waiting 30s for tunnels to establish..."
            sleep 30
            show_status
            generate_xui_config
            ;;
        status)
            show_status
            ;;
        verify)
            verify_all
            ;;
        start)
            if [[ -n "${2:-}" ]]; then
                start_instance "$2"
            else
                start_all
            fi
            ;;
        stop)
            if [[ -n "${2:-}" ]]; then
                stop_instance "$2"
            else
                stop_all
            fi
            ;;
        restart)
            if [[ -n "${2:-}" ]]; then
                stop_instance "$2"
                sleep 2
                start_instance "$2"
            else
                restart_all
            fi
            ;;
        add)
            [[ -z "${2:-}" ]] && { log_error "Usage: $0 add <country_code>"; exit 1; }
            download_psiphon
            quick_add "$2"
            ;;
        remove)
            [[ -z "${2:-}" ]] && { log_error "Usage: $0 remove <instance_id>"; exit 1; }
            remove_instance "$2"
            ;;
        logs)
            show_logs "${2:-}" "${3:-50}"
            ;;
        xui-config|generate-xui)
            generate_xui_config
            ;;
        cleanup|clean)
            cleanup_all
            ;;
        uninstall)
            uninstall
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            show_usage
            ;;
    esac
}

main "$@"
