#!/bin/bash
# deploy-psiphon.sh
# Psiphon Multi-Instance Deployment Tool
# Implements requirements from PRD.md
# Deploys 5 concurrent Psiphon instances on specific ports/countries

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BASE_DIR="/opt/psiphon"
BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
USER="psiphon"

# Instance Definitions
# Format: "NAME|COUNTRY|HTTP_PORT|SOCKS_PORT"
INSTANCES=(
    "psiphon-us|US|8081|1081"
    "psiphon-gb|GB|8082|1082"
    "psiphon-fr|FR|8083|1083"
    "psiphon-sg|SG|8084|1084"
    "psiphon-nl|NL|8085|1085"
)

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
    local deps=(wget curl jq)
    local install_list=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            install_list+=("$dep")
        fi
    done

    if ! command -v fuser &> /dev/null; then
        install_list+=("psmisc")
    fi

    if ! command -v ss &> /dev/null; then
        if command -v apt &> /dev/null; then
            install_list+=("iproute2")
        elif command -v dnf &> /dev/null; then
            install_list+=("iproute")
        fi
    fi
    
    if [[ ${#install_list[@]} -gt 0 ]]; then
        log_info "Installing dependencies: ${install_list[*]}"
        if command -v apt &> /dev/null; then
            apt update -qq && apt install -y -qq "${install_list[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${install_list[@]}"
        fi
    fi
}

setup_user() {
    if ! id "$USER" &>/dev/null; then
        log_info "Creating user $USER..."
        useradd -r -s /bin/false "$USER"
    else
        log_info "User $USER already exists."
    fi
}

setup_instances() {
    log_info "Setting up instances..."
    
    # Download binary once
    local temp_bin="/tmp/psiphon-tunnel-core"
    log_info "Downloading Psiphon Core binary..."
    wget -qO "$temp_bin" "$BIN_URL"
    chmod +x "$temp_bin"

    for instance in "${INSTANCES[@]}"; do
        IFS='|' read -r name country http_port socks_port <<< "$instance"
        
        local instance_dir="${BASE_DIR}/${name}"
        local config_file="${instance_dir}/client.json"
        local bin_path="${instance_dir}/psiphon-client"
        
        log_info "Configuring $name (Region: $country, HTTP: $http_port, SOCKS: $socks_port)..."
        
        mkdir -p "$instance_dir"
        
        # Copy binary
        cp "$temp_bin" "$bin_path"
        chmod +x "$bin_path"
        
        # Create config
        cat > "$config_file" << EOF
{
    "LocalHttpProxyPort": $http_port,
    "LocalSocksProxyPort": $socks_port,
    "EgressRegion": "$country",
    "NetworkID": "X-UI-PRO-$name",
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "RemoteServerListDownloadFilename": "remote_server_list",
    "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
    "SponsorId": "1",
    "EstablishTunnelTimeoutSeconds": 31536000,
    "UseIndistinguishableTLS": true,
    "TunnelPoolSize": 4,
    "ConnectionWorkerPoolSize": 4
}
EOF
        # Set permissions
        chown -R "$USER:$USER" "$instance_dir"
    done
    
    rm -f "$temp_bin"
}

setup_systemd() {
    log_info "Creating systemd template..."
    
    cat > "/etc/systemd/system/psiphon@.service" <<EOF
[Unit]
Description=Psiphon Instance %i
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$BASE_DIR/%i
# Ensure ports are free before starting
ExecStartPre=/bin/bash -c 'config=$BASE_DIR/%i/client.json; if [[ -f "$config" ]]; then ports=$(grep -oE "ProxyPort\": [0-9]+" "$config" | awk "{print \$2}"); for port in $ports; do fuser -k -n tcp "$port" || true; done; fi'
ExecStart=$BASE_DIR/%i/psiphon-client -config client.json -formatNotices json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

start_instances() {
    log_info "Starting instances..."
    for instance in "${INSTANCES[@]}"; do
        IFS='|' read -r name country http_port socks_port <<< "$instance"
        
        log_info "Enabling and starting psiphon@$name"
        systemctl enable --now "psiphon@$name"
    done
}

verify_deployment() {
    log_info "Verifying deployment (waiting 15s for services to initialize)..."
    sleep 15
    
    for instance in "${INSTANCES[@]}"; do
        IFS='|' read -r name country http_port socks_port <<< "$instance"
        
        log_info "Checking $name..."
        
        if ! systemctl is-active --quiet "psiphon@$name"; then
            log_error "Service psiphon@$name is NOT active."
            continue
        fi

        # Check connectivity
        local ip_info=$(curl --connect-timeout 5 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json || echo "failed")
        
        if [[ "$ip_info" == "failed" ]]; then
            log_error "$name (Port $socks_port): Connection failed."
        else
            local ip=$(echo "$ip_info" | jq -r .ip 2>/dev/null || echo "Unknown")
            local actual_country=$(echo "$ip_info" | jq -r .country_code 2>/dev/null || echo "Unknown")
            
            if [[ "$actual_country" == "$country" ]]; then
                 log_success "$name: Online | IP: $ip | Country: $actual_country (MATCH)"
            else
                 log_warn "$name: Online | IP: $ip | Country: $actual_country (EXPECTED: $country)"
            fi
        fi
    done
}

monitor_mode() {
    while true; do
        clear
        echo "=== Psiphon Instances Monitor ==="
        date
        echo ""
        printf "%-15s %-10s %-10s %-10s %-15s %-10s\n" "Instance" "Status" "HTTP" "SOCKS" "IP" "Country"
        echo "----------------------------------------------------------------------------"
        
        for instance in "${INSTANCES[@]}"; do
            IFS='|' read -r name country http_port socks_port <<< "$instance"
            
            status="DOWN"
            if systemctl is-active --quiet "psiphon@$name"; then
                status="UP"
            fi
            
            if [[ "$status" == "UP" ]]; then
                ip_info=$(curl --connect-timeout 2 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json 2>/dev/null)
                if [[ -z "$ip_info" ]]; then
                     ip="Unreachable"
                     actual_country="-"
                else
                     ip=$(echo "$ip_info" | jq -r .ip 2>/dev/null || echo "-")
                     actual_country=$(echo "$ip_info" | jq -r .country_code 2>/dev/null || echo "-")
                fi
            else
                ip="-"
                actual_country="-"
            fi
            
            printf "%-15s %-10s %-10s %-10s %-15s %-10s\n" "$name" "$status" "$http_port" "$socks_port" "$ip" "$actual_country"
        done
        
        echo ""
        echo "Press Ctrl+C to exit monitor."
        sleep 10
    done
}

logs_mode() {
    local name="${1:-psiphon-us}"
    echo "Logs for $name:"
    journalctl -u "psiphon@$name" -n 50 -f
}

cleanup() {
    log_info "Cleaning up old instances..."
    # Stop all potential psiphon services
    systemctl stop "psiphon@*" 2>/dev/null || true
    
    # Try to clean up legacy services from previous version
    for i in {8080..8085}; do
        systemctl stop "psiphon-$i" 2>/dev/null || true
        systemctl disable "psiphon-$i" 2>/dev/null || true
        rm -f "/etc/systemd/system/psiphon-$i.service"
    done
    systemctl daemon-reload
}

main() {
    check_root
    
    if [[ "$1" == "monitor" ]]; then
        monitor_mode
        exit 0
    elif [[ "$1" == "logs" ]]; then
        logs_mode "$2"
        exit 0
    elif [[ "$1" == "cleanup" ]]; then
        cleanup
        exit 0
    fi

    install_dependencies
    cleanup # Stop old/conflicting services before starting new ones
    setup_user
    setup_instances
    setup_systemd
    start_instances
    verify_deployment
    
    log_success "Deployment complete."
    log_info "Run '$0 monitor' to start the monitoring dashboard."
    log_info "Run '$0 logs <instance_name>' to view logs (e.g., psiphon-us)."
}

main "$@"
