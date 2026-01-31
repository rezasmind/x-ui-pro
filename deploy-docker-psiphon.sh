#!/bin/bash
# deploy-docker-psiphon.sh
# Alternative Psiphon Deployment using Docker
# Deploys 5 concurrent instances on ports 8080-8084 using 'thepsiphonguys/psiphon' image

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

install_docker() {
    if ! command -v docker &> /dev/null; then
        log_info "Docker not found. Installing..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        systemctl enable docker
        systemctl start docker
        log_success "Docker installed."
    else
        log_info "Docker is already installed."
    fi
}

clean_old_instances() {
    log_info "Cleaning up old containers and processes..."
    
    # Stop native services if running
    for port in "${PORTS[@]}"; do
        systemctl stop "psiphon-${port}" 2>/dev/null || true
        systemctl disable "psiphon-${port}" 2>/dev/null || true
    done
    
    # Stop docker containers more aggressively
    log_info "Stopping and removing Docker containers with prefix $CONTAINER_PREFIX..."
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read container_name; do
            log_info "Removing container $container_name..."
            docker rm -f "$container_name" 2>/dev/null || true
        done
    fi
    
    # Clean up Docker networks to release port bindings
    log_info "Cleaning up Docker networks..."
    docker network prune -f 2>/dev/null || true
    
    # Wait for ports to be released
    sleep 2
    
    # Kill any lingering processes on ports (Aggressive Cleanup)
    log_info "Force-killing processes on ports ${PORTS[*]}..."
    if command -v fuser &> /dev/null; then
        for port in "${PORTS[@]}"; do
            fuser -k "${port}/tcp" 2>/dev/null || true
        done
    fi
    # Also use ss/lsof logic if fuser fails or is missing
    for port in "${PORTS[@]}"; do
        # Kill via lsof if available
        if command -v lsof &> /dev/null; then
            lsof -ti :$port | xargs kill -9 2>/dev/null || true
        fi
         # Kill via netstat/ss
         if command -v ss &> /dev/null; then
              pid=$(ss -lptn "sport = :$port" | grep -oP 'pid=\K\d+' || true)
              if [[ -n "$pid" ]]; then kill -9 $pid 2>/dev/null || true; fi
         fi
     done
}

verify_ports_free() {
    log_info "Verifying ports are free..."
    local all_free=true
    
    for port in "${PORTS[@]}"; do
        # Check if port is in use
        if ss -lnt "sport = :$port" | grep -q ":$port"; then
            log_warn "Port $port is still in use!"
            all_free=false
            
            # Try to find and kill what's using it
            log_info "Attempting to free port $port..."
            
            # Kill via fuser
            fuser -k "${port}/tcp" 2>/dev/null || true
            
            # Kill via lsof
            if command -v lsof &> /dev/null; then
                pids=$(lsof -ti :$port 2>/dev/null || true)
                if [[ -n "$pids" ]]; then
                    echo "$pids" | xargs -r kill -9 2>/dev/null || true
                fi
            fi
            
            # Kill via ss
            pid=$(ss -lptn "sport = :$port" 2>/dev/null | grep -oP 'pid=\K\d+' | head -1 || true)
            if [[ -n "$pid" ]]; then
                kill -9 "$pid" 2>/dev/null || true
            fi
            
            # Wait a moment
            sleep 1
        fi
    done
    
    if [[ "$all_free" == "false" ]]; then
        log_warn "Some ports were in use. Retrying cleanup..."
        sleep 2
        
        # Final check
        for port in "${PORTS[@]}"; do
            if ss -lnt "sport = :$port" | grep -q ":$port"; then
                log_error "Port $port is STILL in use after cleanup!"
                log_info "Processes on port $port:"
                ss -lptn "sport = :$port" 2>/dev/null || true
                lsof -i :$port 2>/dev/null || true
            fi
        done
    else
        log_success "All ports are free."
    fi
}

deploy_containers() {
    log_info "Deploying Psiphon containers..."
    
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

    # Pull image once
    log_info "Pulling Docker image: $DOCKER_IMAGE..."
    docker pull "$DOCKER_IMAGE"

    for port in "${PORTS[@]}"; do
        country=${INSTANCE_COUNTRIES[$port]}
        container_name="${CONTAINER_PREFIX}-${port}"
        
        log_info "Starting $container_name (Port: $port, Country: $country)..."
        
        # We map host port $port to container port 1080 (default internal SOCKS port)
        # We must invoke python explicitly as the image likely has no entrypoint for flags
        docker run -d \
            --name "$container_name" \
            --restart always \
            -p "${port}:1080" \
            "$DOCKER_IMAGE" \
            python psi_client.py -r "$country" -e
            
        if [ $? -eq 0 ]; then
            log_success "Container $container_name started."
        else
            log_error "Failed to start $container_name."
        fi
    done
}

verify_deployment() {
    log_info "Verifying deployment (waiting 15s for initialization)..."
    sleep 15
    
    for port in "${PORTS[@]}"; do
        log_info "Checking port $port..."
        
        container_name="${CONTAINER_PREFIX}-${port}"
        if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
             log_error "Container $container_name is NOT running."
             continue
        fi

        # Test connectivity
        local ip_info=$(curl --connect-timeout 5 --socks5 127.0.0.1:$port -s https://ipapi.co/json || echo "failed")
        
        if [[ "$ip_info" == "failed" ]]; then
            log_error "Port $port: Connection failed."
            # Check container logs
            echo "--- Container Logs ($container_name) ---"
            docker logs --tail 5 "$container_name"
            echo "----------------------------------------"
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
        echo "=== Psiphon Docker Monitor ==="
        date
        echo ""
        printf "%-10s %-20s %-10s %-15s %-10s\n" "Port" "Container" "Status" "IP" "Country"
        echo "----------------------------------------------------------------------"
        
        for port in "${PORTS[@]}"; do
            container_name="${CONTAINER_PREFIX}-${port}"
            status="DOWN"
            
            if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
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
            
            printf "%-10s %-20s %-10s %-15s %-10s\n" "$port" "$container_name" "$status" "$ip" "$country"
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

    install_docker
    clean_old_instances
    verify_ports_free
    deploy_containers
    verify_deployment
    
    log_success "Docker deployment complete."
    log_info "Run '$0 monitor' to view status."
}

main "$@"
