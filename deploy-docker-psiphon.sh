#!/bin/bash
# deploy-docker-psiphon-v2.sh
# Fixes "No such file or directory" error by using correct container path
# Deploys 5 concurrent instances on ports 8080-8084

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PORTS=(8080 8081 8082 8083 8084)
DOCKER_IMAGE="thepsiphonguys/psiphon"
CONTAINER_PREFIX="psiphon-docker"

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
    log_info "Checking system dependencies..."
    local pkgs=""
    
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        systemctl enable docker
        systemctl start docker
    fi

    # Check for utilities used in cleanup and monitoring
    if ! command -v jq &> /dev/null; then pkgs="$pkgs jq"; fi
    if ! command -v fuser &> /dev/null; then pkgs="$pkgs psmisc"; fi
    if ! command -v lsof &> /dev/null; then pkgs="$pkgs lsof"; fi
    if ! command -v netstat &> /dev/null; then pkgs="$pkgs net-tools"; fi

    if [[ -n "$pkgs" ]]; then
        log_info "Installing missing packages:$pkgs..."
        apt-get update -qq && apt-get install -y $pkgs -qq
    fi
}

clean_old_instances() {
    log_info "Cleaning up old instances..."
    
    for port in "${PORTS[@]}"; do
        # 1. Stop Native Services
        systemctl stop "psiphon-${port}" 2>/dev/null || true
        
        # 2. Stop ANY Docker container using this port
        local conflicting_container=$(docker ps -a --format '{{.ID}}' --filter "publish=$port")
        if [[ -n "$conflicting_container" ]]; then
            log_warn "Freeing port $port (Container: $conflicting_container)..."
            docker rm -f $conflicting_container >/dev/null
        fi

        # 3. Stop named containers
        local named_container="${CONTAINER_PREFIX}-${port}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${named_container}$"; then
            docker rm -f "$named_container" >/dev/null
        fi
    done
    
    # Prune networks
    docker network prune -f >/dev/null 2>&1 || true
    
    # 4. Aggressive Process Kill (Host level)
    for port in "${PORTS[@]}"; do
        if command -v fuser &> /dev/null; then
            fuser -k -9 "${port}/tcp" 2>/dev/null || true
        fi
    done
    
    sleep 2
}

deploy_containers() {
    log_info "Deploying Psiphon containers..."
    
    declare -A INSTANCE_COUNTRIES
    
    # Defaulting to US to skip manual entry for automated runs, 
    # or you can uncomment the loop below to ask for input.
    for port in "${PORTS[@]}"; do
        INSTANCE_COUNTRIES[$port]="US"
    done

    # If you want to ask for countries manually, uncomment these lines:
    # echo "Enter country codes (e.g., US, DE, GB). Press Enter for default [US]."
    # for port in "${PORTS[@]}"; do
    #     read -p "Port $port: " country
    #     country=${country:-US}
    #     INSTANCE_COUNTRIES[$port]=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    # done

    log_info "Pulling Docker image (this may take a moment)..."
    docker pull "$DOCKER_IMAGE" >/dev/null

    for port in "${PORTS[@]}"; do
        country=${INSTANCE_COUNTRIES[$port]}
        container_name="${CONTAINER_PREFIX}-${port}"
        
        # Double check port is free
        if netstat -tuln | grep -q ":$port "; then
            log_error "Port $port is still occupied. Skipping."
            continue
        fi

        log_info "Starting $container_name (Port: $port, Country: $country)..."
        
        # --- FIXED COMMAND HERE ---
        # We use 'sh -c' to navigate to /root/psiphon before running the python script
        docker run -d \
            --name "$container_name" \
            --restart always \
            -p "${port}:1080" \
            "$DOCKER_IMAGE" \
            sh -c "cd /root/psiphon && python psi_client.py -r $country -e"
            
        if [ $? -eq 0 ]; then
            log_success "Started $container_name"
        else
            log_error "Failed to start $container_name"
        fi
    done
}

monitor_mode() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required. Run script again to install it."
        exit 1
    fi

    while true; do
        clear
        echo "=== Psiphon Docker Monitor ==="
        date
        echo "--------------------------------------------------------------------------------"
        printf "%-8s %-25s %-10s %-18s %-5s\n" "Port" "Container Name" "Status" "Public IP" "Loc"
        echo "--------------------------------------------------------------------------------"
        
        for port in "${PORTS[@]}"; do
            container_name="${CONTAINER_PREFIX}-${port}"
            status="DOWN"
            ip="-"
            loc="-"
            
            if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
                status="UP"
            fi
            
            if [[ "$status" == "UP" ]]; then
                # Checking connectivity through the proxy
                ip_json=$(curl --connect-timeout 2 --socks5 127.0.0.1:$port -s https://ipapi.co/json || echo "")
                
                if [[ -n "$ip_json" ]]; then
                    ip=$(echo "$ip_json" | jq -r .ip 2>/dev/null || echo "Err")
                    loc=$(echo "$ip_json" | jq -r .country_code 2>/dev/null || echo "?")
                else
                    ip="Connecting..."
                fi
                status_disp="${GREEN}${status}${NC}"
            else
                status_disp="${RED}${status}${NC}"
            fi

            printf "%-8s %-25s %-19s %-18s %-5s\n" "$port" "$container_name" "$status_disp" "$ip" "$loc"
        done
        
        echo ""
        echo "Press Ctrl+C to exit."
        sleep 5
    done
}

main() {
    check_root
    
    if [[ "$1" == "monitor" ]]; then
        monitor_mode
        exit 0
    fi

    install_dependencies
    clean_old_instances
    deploy_containers
    
    echo ""
    log_success "Deployment complete."
    log_info "Run: './deploy-docker-psiphon-v2.sh monitor' to see status."
}

main "$@"