#!/bin/bash
set -euo pipefail

readonly VERSION="6.0-DOCKER"
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m' CYAN='\033[0;36m' MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m' NC='\033[0m' BOLD='\033[1m'

readonly COMPOSE_FILE="docker-compose-psiphon.yml"
readonly DATA_DIR="./warp-data"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

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
║                        DOCKER MANAGER v6.0 - WORKING SOLUTION                 ║
║                        Uses: bepass-org/warp-plus (Docker)                    ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker not installed!"
        echo ""
        echo "Install Docker:"
        echo "  curl -fsSL https://get.docker.com | bash"
        exit 1
    fi
    
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        log_error "Docker Compose not installed!"
        echo ""
        echo "Install Docker Compose:"
        echo "  apt-get install docker-compose-plugin"
        exit 1
    fi
    
    if ! docker ps &>/dev/null; then
        log_error "Docker daemon not running or permission denied"
        echo "Try: sudo systemctl start docker"
        exit 1
    fi
}

setup() {
    log_info "Setting up Psiphon Fleet with Docker..."
    
    check_docker
    
    mkdir -p "$DATA_DIR"/{us,de,gb,fr,nl,sg}
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "docker-compose-psiphon.yml not found!"
        exit 1
    fi
    
    log_info "Pulling latest warp-plus Docker image..."
    docker pull bigbugcc/warp-plus:latest
    
    log_info "Starting all containers..."
    docker-compose -f "$COMPOSE_FILE" up -d
    
    log_success "Setup complete!"
    echo ""
    log_info "Waiting 30s for tunnels to establish..."
    sleep 30
    
    show_status
}

show_status() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                          PSIPHON FLEET STATUS (Docker)                                        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    printf "${WHITE}%-15s %-15s %-10s %-18s %-10s${NC}\n" \
        "CONTAINER" "COUNTRY" "PORT" "EXIT IP" "VERIFIED"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────────"
    
    local containers=("psiphon-us:US:10080" "psiphon-de:DE:10081" "psiphon-gb:GB:10082" 
                      "psiphon-fr:FR:10083" "psiphon-nl:NL:10084" "psiphon-sg:SG:10085")
    
    for entry in "${containers[@]}"; do
        IFS=':' read -r container country port <<< "$entry"
        
        local status="DOWN"
        local status_color="${RED}"
        local exit_ip="N/A"
        local verified="${RED}N/A${NC}"
        
        if docker ps --filter "name=^${container}$" --format "{{.Names}}" | grep -q "^${container}$"; then
            status="UP"
            status_color="${GREEN}"
            
            local result
            result=$(timeout 15 curl --connect-timeout 10 --socks5 "127.0.0.1:${port}" \
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
        
        printf "%-15s %-15s ${status_color}%-10s${NC} %-18s %-10b\n" \
            "$container" "$country" "$port" "$exit_ip" "$verified"
    done
    
    echo ""
    
    local server_ip=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Network Access:${NC}"
    echo -e "  ${GREEN}Local:${NC}  curl --socks5 127.0.0.1:10080 https://ipapi.co/json"
    echo -e "  ${GREEN}Remote:${NC} curl --socks5 ${server_ip}:10080 https://ipapi.co/json"
    echo ""
}

start_all() {
    log_info "Starting all containers..."
    docker-compose -f "$COMPOSE_FILE" up -d
    log_success "All containers started"
}

stop_all() {
    log_info "Stopping all containers..."
    docker-compose -f "$COMPOSE_FILE" down
    log_success "All containers stopped"
}

restart_all() {
    log_info "Restarting all containers..."
    docker-compose -f "$COMPOSE_FILE" restart
    log_success "All containers restarted"
}

start_one() {
    local container="$1"
    log_info "Starting ${container}..."
    docker-compose -f "$COMPOSE_FILE" start "$container"
    log_success "${container} started"
}

stop_one() {
    local container="$1"
    log_info "Stopping ${container}..."
    docker-compose -f "$COMPOSE_FILE" stop "$container"
    log_success "${container} stopped"
}

restart_one() {
    local container="$1"
    log_info "Restarting ${container}..."
    docker-compose -f "$COMPOSE_FILE" restart "$container"
    log_success "${container} restarted"
}

show_logs() {
    local container="${1:-}"
    local lines="${2:-50}"
    
    if [[ -z "$container" ]]; then
        log_info "Showing logs from all containers..."
        docker-compose -f "$COMPOSE_FILE" logs --tail="$lines"
    else
        log_info "Showing logs from ${container}..."
        docker-compose -f "$COMPOSE_FILE" logs --tail="$lines" "$container"
    fi
}

follow_logs() {
    local container="${1:-}"
    
    if [[ -z "$container" ]]; then
        docker-compose -f "$COMPOSE_FILE" logs -f
    else
        docker-compose -f "$COMPOSE_FILE" logs -f "$container"
    fi
}

rebuild() {
    log_warn "Rebuilding all containers..."
    docker-compose -f "$COMPOSE_FILE" down
    docker-compose -f "$COMPOSE_FILE" pull
    docker-compose -f "$COMPOSE_FILE" up -d
    log_success "Rebuild complete"
}

cleanup() {
    log_warn "Cleaning up all containers and data..."
    read -rp "This will remove all Psiphon containers and data. Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log_info "Cancelled"; return; }
    
    docker-compose -f "$COMPOSE_FILE" down -v
    rm -rf "$DATA_DIR"
    log_success "Cleanup complete"
}

verify_all() {
    log_info "Verifying all instances..."
    echo ""
    
    local containers=("psiphon-us:US:10080" "psiphon-de:DE:10081" "psiphon-gb:GB:10082" 
                      "psiphon-fr:FR:10083" "psiphon-nl:NL:10084" "psiphon-sg:SG:10085")
    
    local success=0 failed=0
    
    for entry in "${containers[@]}"; do
        IFS=':' read -r container country port <<< "$entry"
        
        echo -ne "  Testing ${container} (port ${port})... "
        
        local result
        result=$(timeout 20 curl --connect-timeout 10 --socks5 "127.0.0.1:${port}" \
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

generate_xui_config() {
    echo ""
    log_info "Generating X-UI Configuration..."
    echo ""
    
    echo -e "${WHITE}X-UI Outbound Configuration:${NC}"
    echo ""
    echo "Add these SOCKS5 outbounds to your Xray config:"
    echo ""
    
    local containers=("us:10080" "de:10081" "gb:10082" "fr:10083" "nl:10084" "sg:10085")
    
    for entry in "${containers[@]}"; do
        IFS=':' read -r country port <<< "$entry"
        echo -e "${GREEN}psiphon-${country}${NC} -> 127.0.0.1:${port}"
        cat << EOF
{
  "tag": "psiphon-${country}",
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "127.0.0.1", "port": ${port}}]
  }
}
EOF
        echo ""
    done
    
    echo -e "${WHITE}X-UI Routing Rules:${NC}"
    echo ""
    echo "Route users by email to different countries:"
    for entry in "${containers[@]}"; do
        IFS=':' read -r country port <<< "$entry"
        echo -e "  ${YELLOW}user-${country}@x-ui${NC} -> exits via ${country^^}"
    done
    echo ""
}

show_usage() {
    cat << USAGE
${CYAN}PSIPHON DOCKER MANAGER v${VERSION}${NC}

${WHITE}Usage:${NC}
  $0 setup                - Initial setup and start all containers
  $0 status               - Show all container statuses
  $0 verify               - Test all proxy connections
  $0 start [container]    - Start container(s)
  $0 stop [container]     - Stop container(s)
  $0 restart [container]  - Restart container(s)
  $0 logs [container] [n] - Show logs (default: all, 50 lines)
  $0 follow [container]   - Follow logs in real-time
  $0 rebuild              - Rebuild all containers
  $0 xui-config           - Generate X-UI configuration
  $0 cleanup              - Remove all containers and data

${WHITE}Available Containers:${NC}
  psiphon-us  - United States (Port 10080)
  psiphon-de  - Germany       (Port 10081)
  psiphon-gb  - United Kingdom(Port 10082)
  psiphon-fr  - France        (Port 10083)
  psiphon-nl  - Netherlands   (Port 10084)
  psiphon-sg  - Singapore     (Port 10085)

${WHITE}Examples:${NC}
  $0 setup                      # Initial setup
  $0 status                     # Check all containers
  $0 restart psiphon-us         # Restart US instance
  $0 logs psiphon-de 100        # View Germany logs
  $0 follow psiphon-fr          # Follow France logs
  $0 verify                     # Test all connections

${WHITE}Test Connection:${NC}
  curl --socks5 127.0.0.1:10080 https://ipapi.co/json
USAGE
}

main() {
    print_banner
    
    case "${1:-}" in
        setup|install)
            setup
            ;;
        status)
            show_status
            ;;
        verify|test)
            verify_all
            ;;
        start)
            if [[ -n "${2:-}" ]]; then
                start_one "$2"
            else
                start_all
            fi
            ;;
        stop)
            if [[ -n "${2:-}" ]]; then
                stop_one "$2"
            else
                stop_all
            fi
            ;;
        restart)
            if [[ -n "${2:-}" ]]; then
                restart_one "$2"
            else
                restart_all
            fi
            ;;
        logs)
            show_logs "${2:-}" "${3:-50}"
            ;;
        follow)
            follow_logs "${2:-}"
            ;;
        rebuild)
            rebuild
            ;;
        xui-config|generate-xui)
            generate_xui_config
            ;;
        cleanup|clean)
            cleanup
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
