#!/bin/bash

set -euo pipefail

readonly VERSION="1.0"
readonly INSTALL_DIR="/opt/psiphon-fleet"
readonly REPO_URL="https://raw.githubusercontent.com/rezasmind/x-ui-pro/master"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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
║                        MULTI-INSTANCE INSTALLER v1.0                          ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

check_system() {
    log_info "Checking system requirements..."
    
    if ! command -v curl &>/dev/null; then
        log_warn "curl not found, installing..."
        apt-get update && apt-get install -y curl
    fi
    
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found, installing..."
        apt-get install -y jq
    fi
    
    local total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $total_ram -lt 2 ]]; then
        log_warn "Low RAM detected (${total_ram}GB). Recommended: 4GB+"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    local free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $free_space -lt 10 ]]; then
        log_warn "Low disk space (${free_space}GB free). Recommended: 20GB+"
    fi
    
    log_success "System check passed"
}

install_docker() {
    log_info "Checking Docker installation..."
    
    if command -v docker &>/dev/null; then
        log_success "Docker already installed: $(docker --version)"
        
        if ! docker ps &>/dev/null; then
            log_warn "Docker daemon not running, starting..."
            systemctl start docker
            systemctl enable docker
        fi
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com | bash
        systemctl start docker
        systemctl enable docker
        log_success "Docker installed successfully"
    fi
    
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        log_info "Installing Docker Compose..."
        apt-get update && apt-get install -y docker-compose-plugin
        log_success "Docker Compose installed successfully"
    fi
}

create_install_directory() {
    log_info "Creating installation directory..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    log_success "Directory created: $INSTALL_DIR"
}

download_files() {
    log_info "Downloading Psiphon Fleet files..."
    
    local files=(
        "docker-compose-psiphon.yml"
        "psiphon-docker.sh"
        "psiphon-health-check.sh"
        "psiphon-backup.sh"
        "psiphon-performance.sh"
        "psiphon-fleet.service"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            log_warn "$file already exists, backing up..."
            mv "$file" "${file}.bak.$(date +%s)"
        fi
        
        log_info "Downloading $file..."
        if curl -fsSL "${REPO_URL}/${file}" -o "$file"; then
            chmod +x "$file" 2>/dev/null || true
            log_success "$file downloaded"
        else
            log_error "Failed to download $file"
            return 1
        fi
    done
    
    log_success "All files downloaded successfully"
}

configure_countries() {
    log_info "Country configuration..."
    echo ""
    echo -e "${CYAN}Available countries:${NC}"
    echo "  US=USA, DE=Germany, GB=UK, FR=France, NL=Netherlands"
    echo "  SG=Singapore, CA=Canada, AU=Australia, JP=Japan, etc."
    echo ""
    echo "Default configuration: US, DE, GB, FR, NL, SG"
    echo ""
    
    read -p "Do you want to customize countries? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local countries=()
        local ports=(10080 10081 10082 10083 10084 10085)
        
        for i in {0..5}; do
            read -p "Country ${i} (port ${ports[$i]}): " country
            countries+=("${country^^}")
        done
        
        log_info "Customizing docker-compose.yml..."
    else
        log_info "Using default countries"
    fi
}

setup_systemd() {
    log_info "Setting up systemd service..."
    
    if [[ -f "psiphon-fleet.service" ]]; then
        cp psiphon-fleet.service /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable psiphon-fleet.service
        log_success "Systemd service enabled (auto-start on boot)"
    else
        log_warn "psiphon-fleet.service not found, skipping systemd setup"
    fi
}

setup_health_monitoring() {
    log_info "Setting up health monitoring..."
    echo ""
    read -p "Enable automatic health checks? (Y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        (crontab -l 2>/dev/null | grep -v psiphon-health-check; \
         echo "*/5 * * * * $INSTALL_DIR/psiphon-health-check.sh check") | crontab -
        log_success "Health monitoring enabled (checks every 5 minutes)"
    else
        log_info "Health monitoring skipped"
    fi
}

setup_backups() {
    log_info "Setting up automatic backups..."
    echo ""
    read -p "Enable daily backups? (Y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        mkdir -p /var/backups/psiphon-fleet
        (crontab -l 2>/dev/null | grep -v psiphon-backup; \
         echo "0 2 * * * $INSTALL_DIR/psiphon-backup.sh backup") | crontab -
        log_success "Daily backups enabled (2 AM daily)"
    else
        log_info "Automatic backups skipped"
    fi
}

start_fleet() {
    log_info "Starting Psiphon Fleet..."
    
    ./psiphon-docker.sh setup
    
    log_success "Psiphon Fleet started successfully!"
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                         INSTALLATION COMPLETE                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Installation Directory:${NC} $INSTALL_DIR"
    echo ""
    echo -e "${CYAN}Management Commands:${NC}"
    echo "  cd $INSTALL_DIR"
    echo "  ./psiphon-docker.sh status       - Check all containers"
    echo "  ./psiphon-docker.sh verify       - Test connectivity"
    echo "  ./psiphon-docker.sh logs         - View logs"
    echo "  ./psiphon-docker.sh restart      - Restart all"
    echo ""
    echo -e "${CYAN}SOCKS5 Proxies Available:${NC}"
    echo "  127.0.0.1:10080 - United States"
    echo "  127.0.0.1:10081 - Germany"
    echo "  127.0.0.1:10082 - United Kingdom"
    echo "  127.0.0.1:10083 - France"
    echo "  127.0.0.1:10084 - Netherlands"
    echo "  127.0.0.1:10085 - Singapore"
    echo ""
    echo -e "${CYAN}Test Connection:${NC}"
    echo "  curl --socks5 127.0.0.1:10080 https://ipapi.co/json"
    echo ""
    echo -e "${CYAN}X-UI Integration:${NC}"
    echo "  ./psiphon-docker.sh xui-config"
    echo ""
    echo -e "${CYAN}Documentation:${NC}"
    echo "  cat $INSTALL_DIR/DEPLOYMENT.md"
    echo "  cat $INSTALL_DIR/TROUBLESHOOTING.md"
    echo ""
    echo -e "${YELLOW}Note: Tunnels need 1-3 minutes to establish. Please wait before testing.${NC}"
    echo ""
}

uninstall() {
    log_warn "Starting uninstallation..."
    echo ""
    read -p "This will remove all Psiphon containers and data. Continue? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
    
    cd "$INSTALL_DIR" 2>/dev/null || true
    
    if [[ -f "psiphon-docker.sh" ]]; then
        ./psiphon-docker.sh cleanup || true
    fi
    
    systemctl stop psiphon-fleet.service 2>/dev/null || true
    systemctl disable psiphon-fleet.service 2>/dev/null || true
    rm -f /etc/systemd/system/psiphon-fleet.service
    systemctl daemon-reload
    
    crontab -l 2>/dev/null | grep -v psiphon | crontab - || true
    
    rm -rf "$INSTALL_DIR"
    
    log_success "Uninstallation complete"
}

show_usage() {
    cat << EOF
Psiphon Fleet Installer v${VERSION}

Usage: $0 [COMMAND]

Commands:
  install      Install Psiphon Fleet (default)
  uninstall    Remove Psiphon Fleet completely
  update       Update to latest version
  help         Show this help

Examples:
  curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/install-psiphon.sh | bash
  bash install-psiphon.sh install
  bash install-psiphon.sh uninstall

Documentation:
  https://github.com/rezasmind/x-ui-pro
EOF
}

main() {
    case "${1:-install}" in
        install)
            print_banner
            check_root
            check_system
            install_docker
            create_install_directory
            download_files
            configure_countries
            setup_systemd
            setup_health_monitoring
            setup_backups
            start_fleet
            print_summary
            ;;
        uninstall)
            print_banner
            check_root
            uninstall
            ;;
        update)
            print_banner
            check_root
            cd "$INSTALL_DIR"
            download_files
            ./psiphon-docker.sh rebuild
            log_success "Update complete"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
