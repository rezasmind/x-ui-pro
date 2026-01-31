#!/bin/bash
# deploy-psiphon.sh
# Psiphon Multi-Instance Deployment Tool (PRD Implementation)
# Deploys 5 concurrent Psiphon instances: US, GB, FR, SG, NL
# Each instance runs both SOCKS5 and HTTP proxies

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration - PRD Specification
declare -A INSTANCES=(
    ["us"]="US:1080:8080"
    ["gb"]="GB:1081:8081"
    ["fr"]="FR:1082:8082"
    ["sg"]="SG:1083:8083"
    ["nl"]="NL:1084:8084"
)

declare -A COUNTRY_NAMES=(
    ["us"]="United States"
    ["gb"]="United Kingdom"
    ["fr"]="France"
    ["sg"]="Singapore"
    ["nl"]="Netherlands"
)

PSIPHON_DIR="/etc/psiphon-core"
BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BIN_PATH="${PSIPHON_DIR}/psiphon-tunnel-core"
CONFIG_DIR="${PSIPHON_DIR}/configs"
DATA_DIR="/var/cache/psiphon"
LOG_DIR="/var/log/psiphon"

# Logging Functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { 
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Banner
print_banner() {
    echo -e "${MAGENTA}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════╗
║     Psiphon Multi-Instance Deployment Tool v2.0          ║
║     5 Countries: US, GB, FR, SG, NL                      ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        echo "Usage: sudo $0 [install|monitor|logs|status|restart|stop|start|uninstall]"
        exit 1
    fi
}

install_dependencies() {
    log_info "Checking and installing dependencies..."
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
        log_info "Installing: ${install_list[*]}"
        if command -v apt &> /dev/null; then
            apt update -qq && apt install -y -qq "${install_list[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${install_list[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y -q "${install_list[@]}"
        else
            log_error "Unsupported package manager. Please install manually: ${install_list[*]}"
            exit 1
        fi
    fi
    log_success "Dependencies installed."
}

free_ports() {
    local instance="$1"
    IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
    
    log_debug "Freeing ports for $instance: SOCKS5=$socks_port, HTTP=$http_port"
    
    # Stop systemd service first
    systemctl stop "psiphon-${instance}" 2>/dev/null || true
    systemctl kill --kill-who=main --signal=KILL "psiphon-${instance}" 2>/dev/null || true
    
    # Free both ports
    for port in "$socks_port" "$http_port"; do
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
                sleep 0.5
                waited=$((waited + 1))
                if [[ $waited -ge 20 ]]; then
                    log_warn "Port $port still in use after 10s"
                    break
                fi
            done
        fi
    done
    
    sleep 1
}

install_psiphon_core() {
    log_info "Setting up Psiphon Core..."
    mkdir -p "$PSIPHON_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    
    if [[ ! -f "$BIN_PATH" ]]; then
        log_info "Downloading psiphon-tunnel-core binary..."
        wget -qO "$BIN_PATH" "$BIN_URL"
        chmod +x "$BIN_PATH"
        log_success "Psiphon Core binary installed at $BIN_PATH"
    else
        log_info "Psiphon Core already exists at $BIN_PATH"
        # Check if update available
        local current_md5=$(md5sum "$BIN_PATH" | awk '{print $1}')
        local temp_file="/tmp/psiphon-new"
        wget -qO "$temp_file" "$BIN_URL"
        local new_md5=$(md5sum "$temp_file" | awk '{print $1}')
        
        if [[ "$current_md5" != "$new_md5" ]]; then
            log_warn "New version available. Updating..."
            mv "$temp_file" "$BIN_PATH"
            chmod +x "$BIN_PATH"
            log_success "Psiphon Core updated."
        else
            log_info "Psiphon Core is up to date."
            rm -f "$temp_file"
        fi
    fi
}

create_config() {
    local instance="$1"
    IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
    
    local config_file="${CONFIG_DIR}/config-${instance}.json"
    local data_dir="${DATA_DIR}/instance-${instance}"
    
    mkdir -p "$data_dir"
    
    log_debug "Creating config for $instance: Country=$country, SOCKS=$socks_port, HTTP=$http_port"
    
    # PRD-compliant configuration with both SOCKS5 and HTTP proxies
    cat > "$config_file" << EOF
{
    "LocalSocksProxyPort": $socks_port,
    "LocalHttpProxyPort": $http_port,
    "EgressRegion": "$country",
    "DataRootDirectory": "$data_dir",
    "NetworkID": "PSIPHON-MULTI-${instance^^}",
    "PropagationChannelId": "FFFFFFFFFFFFFFFF",
    "RemoteServerListDownloadFilename": "remote_server_list",
    "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
    "SponsorId": "FFFFFFFFFFFFFFFF",
    "EstablishTunnelTimeoutSeconds": 300,
    "UseIndistinguishableTLS": true,
    "TunnelPoolSize": 4,
    "ConnectionWorkerPoolSize": 4,
    "DisableLocalHTTPProxySkipProxyCheckAddresses": false,
    "DisableLocalSocksProxySkipProxyCheckAddresses": false
}
EOF
    
    chmod 600 "$config_file"
}

create_systemd_service() {
    local instance="$1"
    IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
    local country_name="${COUNTRY_NAMES[$instance]}"
    
    local service_name="psiphon-${instance}"
    local config_file="${CONFIG_DIR}/config-${instance}.json"
    local log_file="${LOG_DIR}/${service_name}.log"
    
    log_info "Creating systemd service: $service_name ($country_name)"
    
    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=Psiphon Client - ${country_name} (${country})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${PSIPHON_DIR}

# Pre-start: Free up ports
ExecStartPre=/bin/bash -c 'for port in $socks_port $http_port; do if command -v fuser >/dev/null 2>&1; then fuser -k "\${port}/tcp" 2>/dev/null || true; fi; if command -v ss >/dev/null 2>&1; then pids=\$(ss -ltnp "sport = :\${port}" 2>/dev/null | sed -n "s/.*pid=\\\\([0-9]\\\\+\\\\).*/\\\\1/p" | sort -u); for pid in \$pids; do kill -9 "\$pid" 2>/dev/null || true; done; waited=0; while ss -ltn "sport = :\${port}" 2>/dev/null | grep -q ":\${port}"; do sleep 0.5; waited=\$((waited+1)); if [ "\$waited" -ge 20 ]; then break; fi; done; fi; done; exit 0'

# Main process
ExecStart=${BIN_PATH} -config ${config_file} -formatNotices json

# Restart policy
Restart=always
RestartSec=10
StartLimitBurst=5
StartLimitInterval=60

# Resource limits
LimitNOFILE=65535

# Logging
StandardOutput=append:${log_file}
StandardError=append:${log_file}

# Security (optional hardening)
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "/etc/systemd/system/${service_name}.service"
}

deploy_instances() {
    log_info "Deploying 5 Psiphon instances (US, GB, FR, SG, NL)..."
    
    # Stop all existing services first
    for instance in "${!INSTANCES[@]}"; do
        systemctl stop "psiphon-${instance}" 2>/dev/null || true
        systemctl disable "psiphon-${instance}" 2>/dev/null || true
        free_ports "$instance"
    done
    
    # Create configs and services
    for instance in "${!INSTANCES[@]}"; do
        create_config "$instance"
        create_systemd_service "$instance"
    done
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start services
    log_info "Starting services..."
    for instance in "${!INSTANCES[@]}"; do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
        log_info "Starting psiphon-${instance} (${COUNTRY_NAMES[$instance]}) on SOCKS:$socks_port, HTTP:$http_port"
        systemctl enable "psiphon-${instance}"
        systemctl start "psiphon-${instance}"
        sleep 2
    done
    
    log_success "All instances deployed."
}

verify_deployment() {
    log_info "Verifying deployment (waiting 20s for tunnels to establish)..."
    sleep 20
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    printf "%-8s %-15s %-10s %-8s %-8s %-15s %-10s\n" "Instance" "Country" "Status" "SOCKS5" "HTTP" "Exit IP" "Location"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    
    for instance in us gb fr sg nl; do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
        local service_status="DOWN"
        local exit_ip="N/A"
        local exit_country="N/A"
        
        if systemctl is-active --quiet "psiphon-${instance}"; then
            service_status="${GREEN}UP${NC}"
            
            # Test SOCKS5 proxy
            local ip_info=$(timeout 10 curl --connect-timeout 5 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json 2>/dev/null || echo "")
            
            if [[ -n "$ip_info" ]]; then
                exit_ip=$(echo "$ip_info" | jq -r '.ip // "N/A"' 2>/dev/null)
                exit_country=$(echo "$ip_info" | jq -r '.country_code // "N/A"' 2>/dev/null)
                
                if [[ "$exit_country" == "$country" ]]; then
                    exit_country="${GREEN}${exit_country}${NC}"
                else
                    exit_country="${YELLOW}${exit_country}${NC}"
                fi
            else
                exit_ip="${RED}Timeout${NC}"
                exit_country="${RED}N/A${NC}"
            fi
        else
            service_status="${RED}DOWN${NC}"
        fi
        
        printf "%-8s %-15s %-18s %-8s %-8s %-15s %-18s\n" \
            "$instance" "${COUNTRY_NAMES[$instance]}" "$service_status" "$socks_port" "$http_port" "$exit_ip" "$exit_country"
    done
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

show_status() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                      Psiphon Instances Status                             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    for instance in us gb fr sg nl; do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
        local service_name="psiphon-${instance}"
        
        echo -e "${BLUE}Instance:${NC} ${instance^^} (${COUNTRY_NAMES[$instance]})"
        echo -e "${BLUE}Country:${NC} $country"
        echo -e "${BLUE}Ports:${NC} SOCKS5=$socks_port, HTTP=$http_port"
        
        if systemctl is-active --quiet "$service_name"; then
            echo -e "${BLUE}Status:${NC} ${GREEN}Running${NC}"
            echo -e "${BLUE}Uptime:${NC} $(systemctl show -p ActiveEnterTimestamp "$service_name" --value | cut -d' ' -f2-4)"
        else
            echo -e "${BLUE}Status:${NC} ${RED}Stopped${NC}"
        fi
        
        echo ""
    done
}

monitor_mode() {
    log_info "Starting real-time monitoring (Press Ctrl+C to exit)..."
    echo ""
    
    while true; do
        clear
        echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║              Psiphon Multi-Instance Monitor - $(date +'%Y-%m-%d %H:%M:%S')              ║${NC}"
        echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        printf "%-8s %-15s %-10s %-8s %-8s %-15s %-12s\n" \
            "Instance" "Country" "Status" "SOCKS5" "HTTP" "Exit IP" "Location"
        echo "─────────────────────────────────────────────────────────────────────────────────"
        
        for instance in us gb fr sg nl; do
            IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
            local status="DOWN"
            local status_color="${RED}"
            local exit_ip="-"
            local exit_country="-"
            
            if systemctl is-active --quiet "psiphon-${instance}"; then
                status="UP"
                status_color="${GREEN}"
                
                # Quick check with timeout
                local ip_info=$(timeout 5 curl --connect-timeout 3 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json 2>/dev/null || echo "")
                
                if [[ -n "$ip_info" ]]; then
                    exit_ip=$(echo "$ip_info" | jq -r '.ip // "-"' 2>/dev/null)
                    exit_country=$(echo "$ip_info" | jq -r '.country_code // "-"' 2>/dev/null)
                else
                    exit_ip="Checking..."
                    exit_country="-"
                fi
            fi
            
            echo -e "$(printf "%-8s %-15s ${status_color}%-10s${NC} %-8s %-8s %-15s %-12s" \
                "$instance" "${COUNTRY_NAMES[$instance]}" "$status" "$socks_port" "$http_port" "$exit_ip" "$exit_country")"
        done
        
        echo ""
        echo -e "${CYAN}Commands: ${NC}./deploy-psiphon.sh [status|logs <instance>|restart|stop|start]"
        echo -e "${CYAN}Refreshing in 10 seconds...${NC}"
        
        sleep 10
    done
}

show_logs() {
    local instance="${1:-us}"
    local lines="${2:-50}"
    
    if [[ ! " ${!INSTANCES[@]} " =~ " ${instance} " ]]; then
        log_error "Invalid instance. Choose from: us, gb, fr, sg, nl"
        exit 1
    fi
    
    local log_file="${LOG_DIR}/psiphon-${instance}.log"
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Logs for psiphon-${instance} (${COUNTRY_NAMES[$instance]}) - Last $lines lines${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ -f "$log_file" ]]; then
        tail -n "$lines" "$log_file" | jq -r 'select(.noticeType) | "\(.timestamp // .data.timestamp) [\(.noticeType)] \(.data.message // .data)"' 2>/dev/null || tail -n "$lines" "$log_file"
    else
        log_error "Log file not found: $log_file"
    fi
    
    echo ""
    echo -e "${CYAN}Follow logs in real-time: tail -f $log_file${NC}"
}

control_services() {
    local action="$1"
    local instance="$2"
    
    case "$action" in
        start|stop|restart)
            if [[ -n "$instance" ]]; then
                if [[ ! " ${!INSTANCES[@]} " =~ " ${instance} " ]]; then
                    log_error "Invalid instance. Choose from: us, gb, fr, sg, nl"
                    exit 1
                fi
                log_info "${action^}ing psiphon-${instance}..."
                systemctl "$action" "psiphon-${instance}"
                log_success "psiphon-${instance} ${action}ed."
            else
                log_info "${action^}ing all instances..."
                for inst in us gb fr sg nl; do
                    systemctl "$action" "psiphon-${inst}"
                done
                log_success "All instances ${action}ed."
            fi
            ;;
        *)
            log_error "Invalid action. Use: start, stop, or restart"
            exit 1
            ;;
    esac
}

uninstall() {
    log_warn "Uninstalling Psiphon instances..."
    read -p "Are you sure? This will remove all configurations and data (y/N): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
    
    for instance in "${!INSTANCES[@]}"; do
        log_info "Stopping and removing psiphon-${instance}..."
        systemctl stop "psiphon-${instance}" 2>/dev/null || true
        systemctl disable "psiphon-${instance}" 2>/dev/null || true
        rm -f "/etc/systemd/system/psiphon-${instance}.service"
    done
    
    systemctl daemon-reload
    
    log_info "Removing directories..."
    rm -rf "$PSIPHON_DIR" "$DATA_DIR" "$LOG_DIR"
    
    log_success "Uninstall complete."
}

show_usage() {
    cat << EOF
${CYAN}Psiphon Multi-Instance Deployment Tool${NC}

${YELLOW}Usage:${NC}
  $0 install          - Install and deploy all 5 instances
  $0 status           - Show status of all instances
  $0 monitor          - Real-time monitoring dashboard
  $0 logs [instance] [lines] - View logs (default: us, 50 lines)
  $0 start [instance] - Start instance(s) (all if not specified)
  $0 stop [instance]  - Stop instance(s) (all if not specified)
  $0 restart [instance] - Restart instance(s) (all if not specified)
  $0 uninstall        - Remove all instances and data
  $0 test             - Test all proxy connections

${YELLOW}Instances:${NC} us, gb, fr, sg, nl

${YELLOW}Examples:${NC}
  $0 install
  $0 logs us 100
  $0 restart gb
  $0 monitor

${YELLOW}Port Assignments:${NC}
  US: SOCKS5=1080, HTTP=8080
  GB: SOCKS5=1081, HTTP=8081
  FR: SOCKS5=1082, HTTP=8082
  SG: SOCKS5=1083, HTTP=8083
  NL: SOCKS5=1084, HTTP=8084
EOF
}

test_connections() {
    log_info "Testing all proxy connections..."
    echo ""
    
    for instance in us gb fr sg nl; do
        IFS=':' read -r country socks_port http_port <<< "${INSTANCES[$instance]}"
        
        echo -e "${BLUE}Testing ${instance^^} (${COUNTRY_NAMES[$instance]})...${NC}"
        
        # Test SOCKS5
        echo -n "  SOCKS5 ($socks_port): "
        local socks_result=$(timeout 10 curl --connect-timeout 5 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json 2>/dev/null || echo "")
        if [[ -n "$socks_result" ]]; then
            local socks_ip=$(echo "$socks_result" | jq -r '.ip' 2>/dev/null)
            local socks_country=$(echo "$socks_result" | jq -r '.country_code' 2>/dev/null)
            echo -e "${GREEN}✓ Working${NC} - IP: $socks_ip, Country: $socks_country"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
        
        # Test HTTP
        echo -n "  HTTP ($http_port): "
        local http_result=$(timeout 10 curl --connect-timeout 5 -x http://127.0.0.1:$http_port -s https://ipapi.co/json 2>/dev/null || echo "")
        if [[ -n "$http_result" ]]; then
            local http_ip=$(echo "$http_result" | jq -r '.ip' 2>/dev/null)
            local http_country=$(echo "$http_result" | jq -r '.country_code' 2>/dev/null)
            echo -e "${GREEN}✓ Working${NC} - IP: $http_ip, Country: $http_country"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
        
        echo ""
    done
}

main() {
    print_banner
    check_root
    
    case "${1:-}" in
        install)
            install_dependencies
            install_psiphon_core
            deploy_instances
            verify_deployment
            log_success "Installation complete!"
            echo ""
            echo -e "${CYAN}Next steps:${NC}"
            echo "  - Run '$0 monitor' to watch instances in real-time"
            echo "  - Run '$0 test' to test all proxy connections"
            echo "  - Run '$0 logs <instance>' to view logs"
            ;;
        status)
            show_status
            ;;
        monitor)
            monitor_mode
            ;;
        logs)
            show_logs "$2" "${3:-50}"
            ;;
        start|stop|restart)
            control_services "$1" "$2"
            ;;
        test)
            test_connections
            ;;
        uninstall)
            uninstall
            ;;
        help|--help|-h|"")
            show_usage
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"