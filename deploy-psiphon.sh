#!/bin/bash
# deploy-psiphon.sh
# Psiphon Multi-Instance Deployment Tool (Using official psiphon-tunnel-core)
# Based on SpherionOS/PsiphonLinux
# Deploys 5 concurrent Psiphon instances on ports 8080-8084

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PORTS=(8080 8081 8082 8083 8084)
PSIPHON_DIR="/etc/psiphon-core"
BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BIN_PATH="${PSIPHON_DIR}/psiphon-tunnel-core"
CONFIG_DIR="${PSIPHON_DIR}/configs"
DATA_DIR="/var/cache/psiphon"
LOG_DIR="/var/log/psiphon"

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

    if ! command -v ss &> /dev/null; then
        if command -v apt &> /dev/null; then
            install_list+=("iproute2")
        elif command -v dnf &> /dev/null; then
            install_list+=("iproute")
        fi
    fi

    if ! command -v fuser &> /dev/null; then
        install_list+=("psmisc")
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

free_port() {
    local port="$1"

    systemctl stop "psiphon-${port}" 2>/dev/null || true
    systemctl kill --kill-who=main --signal=KILL "psiphon-${port}" 2>/dev/null || true

    if command -v fuser &> /dev/null; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    fi

    if command -v ss &> /dev/null; then
        local pids
        pids=$(ss -ltnp "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u | tr '\n' ' ')
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done

        local waited=0
        while ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"; do
            sleep 1
            waited=$((waited + 1))
            if [[ $waited -ge 30 ]]; then
                return 1
            fi
        done
    fi

    return 0
}

install_psiphon_core() {
    mkdir -p "$PSIPHON_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    
    if [[ ! -f "$BIN_PATH" ]]; then
        log_info "Downloading psiphon-tunnel-core..."
        wget -qO "$BIN_PATH" "$BIN_URL"
        chmod +x "$BIN_PATH"
        log_success "Psiphon Core installed."
    else
        log_info "Psiphon Core already installed."
    fi
}

# Generate Config File (Based on SpherionOS/PsiphonLinux template)
create_config() {
    local port="$1"
    local country="$2"
    local config_file="${CONFIG_DIR}/config-${port}.json"
    local data_dir="${DATA_DIR}/instance-${port}"
    
    mkdir -p "$data_dir"
    
    # Standard Psiphon Config JSON
    cat > "$config_file" << EOF
{
    "LocalHttpProxyPort": 0,
    "LocalSocksProxyPort": $port,
    "EgressRegion": "$country",
    "DataRootDirectory": "$data_dir",
    "NetworkID": "X-UI-PRO-$port",
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "RemoteServerListDownloadFilename": "remote_server_list",
    "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
    "SponsorId": "1",
    "EstablishTunnelTimeoutSeconds": 0,
    "UseIndistinguishableTLS": true
}
EOF
}

configure_instances() {
    log_info "Configuring Psiphon instances..."
    
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

    # Remove old warp-plus services if they exist
    for port in "${PORTS[@]}"; do
        systemctl stop "psiphon-${port}" 2>/dev/null || true
        systemctl disable "psiphon-${port}" 2>/dev/null || true
        free_port "$port" || true
    done

    # Generate Systemd Services
    for port in "${PORTS[@]}"; do
        country=${INSTANCE_COUNTRIES[$port]}
        service_name="psiphon-${port}"
        config_file="${CONFIG_DIR}/config-${port}.json"
        log_file="${LOG_DIR}/${service_name}.log"
        
        create_config "$port" "$country"
        
        log_info "Creating service $service_name for Country: $country on Port: $port"
        
        cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=Psiphon Instance on Port $port ($country)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PSIPHON_DIR
ExecStartPre=/bin/bash -c 'port=$port; if command -v fuser >/dev/null 2>&1; then fuser -k "${port}/tcp" 2>/dev/null || true; fi; if command -v ss >/dev/null 2>&1; then pids=$(ss -ltnp "sport = :${port}" 2>/dev/null | sed -n "s/.*pid=\\([0-9]\\+\\).*/\\1/p" | sort -u); for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done; waited=0; while ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"; do sleep 1; waited=$((waited+1)); if [ "$waited" -ge 30 ]; then exit 1; fi; done; fi; exit 0'
ExecStart=$BIN_PATH -config $config_file -formatNotices json
Restart=always
RestartSec=10
LimitNOFILE=65535
StandardOutput=append:$log_file
StandardError=append:$log_file

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "$service_name"
        systemctl restart "$service_name"
    done
}

verify_deployment() {
    log_info "Verifying deployment (waiting 15s for services to initialize)..."
    sleep 15
    
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
            local ip=$(echo "$ip_info" | jq -r .ip 2>/dev/null || echo "Unknown")
            local country=$(echo "$ip_info" | jq -r .country_code 2>/dev/null || echo "Unknown")
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
                     ip=$(echo "$ip_info" | jq -r .ip 2>/dev/null || echo "-")
                     country=$(echo "$ip_info" | jq -r .country_code 2>/dev/null || echo "-")
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

logs_mode() {
    local port="${1:-8080}"
    local log_file="${LOG_DIR}/psiphon-${port}.log"
    echo "Logs for Port $port:"
    if [[ -f "$log_file" ]]; then
        tail -n 20 "$log_file"
    else
        echo "Log file not found at $log_file"
    fi
}

main() {
    check_root
    
    if [[ "$1" == "monitor" ]]; then
        monitor_mode
        exit 0
    elif [[ "$1" == "logs" ]]; then
        logs_mode "$2"
        exit 0
    fi

    install_dependencies
    install_psiphon_core
    configure_instances
    verify_deployment
    
    log_success "Deployment complete."
    log_info "Run '$0 monitor' to start the monitoring dashboard."
    log_info "Run '$0 logs <port>' to view logs."
}

main "$@"
