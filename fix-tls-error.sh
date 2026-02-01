#!/bin/bash

#######################################
# Quick Fix Script for TLS Panic Error
#######################################
#
# This script fixes the "tls: ConnectionState struct field count mismatch" 
# error by rebuilding Docker containers with Go 1.24.3 image.
#
# Error symptoms:
#   - Containers restart continuously
#   - panic: tls: ConnectionState is not equal to tls.ConnectionState: struct field count mismatch: 17 vs 16
#   - Psiphon mode doesn't work
#
# Usage:
#   bash fix-tls-error.sh
#   bash fix-tls-error.sh --force  (skip confirmations)
#

set -eo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly INSTALL_DIR="/opt/psiphon-fleet"
readonly FORCE_MODE="${1}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                  TLS PANIC ERROR FIX SCRIPT                    ║
║                                                                ║
║  Fixes: panic: tls: ConnectionState struct field mismatch     ║
║  Solution: Rebuild with Go 1.24.3                             ║
╚════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_docker() {
    log_info "Checking Docker installation..."
    
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed"
        log_info "Install Docker first: curl -fsSL https://get.docker.com | bash"
        exit 1
    fi
    
    if ! docker ps &>/dev/null; then
        log_error "Docker daemon is not running"
        log_info "Start Docker: systemctl start docker"
        exit 1
    fi
    
    log_success "Docker is running"
}

check_installation() {
    log_info "Checking Psiphon Fleet installation..."
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "Psiphon Fleet not found at $INSTALL_DIR"
        log_info "Install first using install-psiphon.sh"
        exit 1
    fi
    
    cd "$INSTALL_DIR"
    
    if [[ ! -f "docker-compose-psiphon.yml" ]]; then
        log_error "docker-compose-psiphon.yml not found"
        exit 1
    fi
    
    if [[ ! -f "psiphon-docker.sh" ]]; then
        log_error "psiphon-docker.sh not found"
        exit 1
    fi
    
    log_success "Installation found at $INSTALL_DIR"
}

detect_error() {
    log_info "Detecting TLS panic error..."
    
    local error_found=0
    
    for container in psiphon-us psiphon-de psiphon-gb psiphon-fr psiphon-nl psiphon-sg; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            if docker logs "$container" 2>&1 | grep -q "panic.*ConnectionState"; then
                log_warn "TLS panic error detected in $container"
                error_found=1
            fi
        fi
    done
    
    if [[ $error_found -eq 0 ]]; then
        log_warn "No TLS panic error detected in logs"
        log_info "This script rebuilds containers with Go 1.24.3 to prevent the error"
        
        if [[ "$FORCE_MODE" != "--force" ]]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
        fi
    else
        log_error "TLS panic error confirmed!"
    fi
}

download_dockerfile() {
    log_info "Checking for Dockerfile.warp-plus-fixed..."
    
    if [[ -f "Dockerfile.warp-plus-fixed" ]]; then
        log_success "Dockerfile found"
        return 0
    fi
    
    log_warn "Dockerfile not found, downloading..."
    
    if curl -fsSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/Dockerfile.warp-plus-fixed -o Dockerfile.warp-plus-fixed; then
        log_success "Dockerfile downloaded"
    else
        log_error "Failed to download Dockerfile"
        log_info "Manual fix: Create Dockerfile.warp-plus-fixed in $INSTALL_DIR"
        log_info "See: https://github.com/rezasmind/x-ui-pro/blob/master/Dockerfile.warp-plus-fixed"
        exit 1
    fi
}

build_fixed_image() {
    log_info "Building custom Docker image with Go 1.24.3..."
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}This will take 5-10 minutes to download and compile warp-plus${NC}"
    echo -e "${YELLOW}Go grab a coffee ☕ while the image builds...${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check if image already exists
    if docker images | grep -q "warp-plus.*fixed"; then
        log_warn "warp-plus:fixed image already exists"
        
        if [[ "$FORCE_MODE" != "--force" ]]; then
            read -p "Rebuild anyway? (y/N): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Using existing image"; return 0; }
        fi
        
        log_info "Removing old image..."
        docker rmi warp-plus:fixed 2>/dev/null || true
    fi
    
    log_info "Starting build..."
    
    if docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed . 2>&1 | tee /tmp/warp-build.log; then
        log_success "Docker image built successfully!"
        
        echo ""
        docker images warp-plus:fixed
        echo ""
        
        log_info "Verifying Go version..."
        local go_version=$(docker run --rm warp-plus:fixed sh -c "go version" 2>/dev/null | grep -o "go1\.[0-9]*\.[0-9]*" || echo "unknown")
        
        if [[ "$go_version" =~ ^go1\.24 ]]; then
            log_success "Go version verified: $go_version ✅"
        elif [[ "$go_version" == "unknown" ]]; then
            log_warn "Could not verify Go version (image may not have Go installed, this is OK)"
        else
            log_error "Wrong Go version: $go_version (expected 1.24.x)"
            exit 1
        fi
    else
        log_error "Docker build failed!"
        log_error "Build log saved to: /tmp/warp-build.log"
        echo ""
        echo -e "${RED}Common reasons for build failure:${NC}"
        echo "  1. Insufficient disk space (need ~2GB free)"
        echo "  2. No internet connection (needs to download Go modules)"
        echo "  3. GitHub rate limits (try again later)"
        echo ""
        exit 1
    fi
}

update_docker_compose() {
    log_info "Updating docker-compose.yml..."
    
    if grep -q "image: warp-plus:fixed" docker-compose-psiphon.yml; then
        log_success "docker-compose.yml already uses warp-plus:fixed"
        return 0
    fi
    
    if grep -q "image: bigbugcc/warp-plus:latest" docker-compose-psiphon.yml; then
        log_info "Replacing bigbugcc/warp-plus:latest with warp-plus:fixed..."
        
        # Backup original
        cp docker-compose-psiphon.yml docker-compose-psiphon.yml.bak.$(date +%s)
        
        # Replace image
        sed -i 's|image: bigbugcc/warp-plus:latest|image: warp-plus:fixed|g' docker-compose-psiphon.yml
        
        if grep -q "image: warp-plus:fixed" docker-compose-psiphon.yml; then
            log_success "docker-compose.yml updated successfully"
        else
            log_error "Failed to update docker-compose.yml"
            exit 1
        fi
    else
        log_warn "Unknown image in docker-compose.yml"
        log_info "Manually edit: image: warp-plus:fixed"
    fi
}

rebuild_containers() {
    log_info "Rebuilding containers..."
    echo ""
    
    if [[ "$FORCE_MODE" != "--force" ]]; then
        read -p "This will stop all Psiphon containers and restart them. Continue? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; exit 0; }
    fi
    
    log_info "Stopping containers..."
    ./psiphon-docker.sh stop || true
    
    log_info "Removing old containers..."
    docker-compose -f docker-compose-psiphon.yml down 2>/dev/null || true
    
    log_info "Starting new containers with fixed image..."
    ./psiphon-docker.sh setup
    
    log_success "Containers rebuilt successfully!"
}

wait_for_tunnels() {
    log_info "Waiting for Psiphon tunnels to establish (2-3 minutes)..."
    echo ""
    
    for i in {1..36}; do
        echo -ne "${CYAN}[${i}/36]${NC} Waiting... (${i}0s elapsed)\r"
        sleep 5
    done
    
    echo ""
    log_success "Wait period complete"
}

verify_fix() {
    log_info "Verifying fix..."
    echo ""
    
    local all_healthy=1
    
    for container in psiphon-us psiphon-de psiphon-gb psiphon-fr psiphon-nl psiphon-sg; do
        if ! docker ps --filter "name=${container}" --format '{{.Names}}' | grep -q "^${container}$"; then
            log_error "$container is not running"
            all_healthy=0
            continue
        fi
        
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
        if [[ "$status" != "running" ]]; then
            log_error "$container status: $status"
            all_healthy=0
            continue
        fi
        
        if docker logs "$container" 2>&1 | grep -q "panic.*ConnectionState"; then
            log_error "$container still has TLS panic error"
            all_healthy=0
        else
            log_success "$container is healthy ✅"
        fi
    done
    
    echo ""
    
    if [[ $all_healthy -eq 1 ]]; then
        log_success "All containers are healthy! 🎉"
        echo ""
        log_info "Testing connectivity..."
        ./psiphon-docker.sh verify
    else
        log_error "Some containers have issues"
        echo ""
        log_info "Check logs with: ./psiphon-docker.sh logs"
        log_info "For detailed help: cat PSIPHON-TLS-ERROR-FIX.md"
        exit 1
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                      FIX APPLIED SUCCESSFULLY                  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}What was fixed:${NC}"
    echo "  ✅ Built custom Docker image with Go 1.24.3"
    echo "  ✅ Updated docker-compose.yml to use warp-plus:fixed"
    echo "  ✅ Rebuilt all containers with new image"
    echo "  ✅ Verified all containers are running without panic errors"
    echo ""
    echo -e "${CYAN}Management commands:${NC}"
    echo "  cd $INSTALL_DIR"
    echo "  ./psiphon-docker.sh status    - Check status"
    echo "  ./psiphon-docker.sh verify    - Test connectivity"
    echo "  ./psiphon-docker.sh logs      - View logs"
    echo ""
    echo -e "${CYAN}SOCKS5 Proxies:${NC}"
    echo "  127.0.0.1:10080 - United States"
    echo "  127.0.0.1:10081 - Germany"
    echo "  127.0.0.1:10082 - United Kingdom"
    echo "  127.0.0.1:10083 - France"
    echo "  127.0.0.1:10084 - Netherlands"
    echo "  127.0.0.1:10085 - Singapore"
    echo ""
    echo -e "${YELLOW}Note: If you still see issues, check PSIPHON-TLS-ERROR-FIX.md${NC}"
    echo ""
}

main() {
    print_banner
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
    
    check_docker
    check_installation
    detect_error
    download_dockerfile
    build_fixed_image
    update_docker_compose
    rebuild_containers
    wait_for_tunnels
    verify_fix
    print_summary
}

main "$@"
