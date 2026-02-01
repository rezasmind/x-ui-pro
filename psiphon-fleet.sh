#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════════════════════════
#  PSIPHON FLEET COMMANDER v4.0 - Docker-Based Multi-Instance Proxy Deployment
#  Author: Engineered for x-ui-pro
#  Purpose: Deploy N isolated Psiphon instances using Docker containers
#  Each instance runs in its own isolated container with zero cross-contamination
#  Docker Image: swarupsengupta2007/psiphon
#═══════════════════════════════════════════════════════════════════════════════════════════════════
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
declare -r CONFIG_DIR="${PSIPHON_DIR}/instances"
declare -r STATE_FILE="${PSIPHON_DIR}/fleet.state"
declare -r DOCKER_IMAGE="swarupsengupta2007/psiphon:latest"
declare -r CONTAINER_PREFIX="psiphon-fleet"

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
║                     FLEET COMMANDER v4.0 (Docker)                             ║
║          Containerized Multi-Instance Proxy Deployment System                 ║
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
# Dependencies & Docker Setup
#───────────────────────────────────────────────────────────────────────────────────────────────────
install_dependencies() {
    log_step "Checking dependencies..."
    local deps=(curl jq)
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
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

check_docker() {
    log_step "Checking Docker installation..."
    
    if ! command -v docker &>/dev/null; then
        log_warn "Docker not found. Installing Docker..."
        
        if command -v apt &>/dev/null; then
            # Debian/Ubuntu
            apt update -qq
            apt install -y -qq ca-certificates gnupg lsb-release
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt update -qq
            apt install -y -qq docker-ce docker-ce-cli containerd.io
        elif command -v yum &>/dev/null; then
            # CentOS/RHEL
            yum install -y -q yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y -q docker-ce docker-ce-cli containerd.io
        fi
        
        systemctl enable docker
        systemctl start docker
        log_success "Docker installed successfully"
    else
        log_success "Docker is already installed"
    fi
    
    # Verify Docker is running
    if ! docker ps >/dev/null 2>&1; then
        log_warn "Docker is not running. Starting Docker..."
        systemctl start docker
        sleep 3
    fi
    
    log_success "Docker is ready"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Setup Directories
#───────────────────────────────────────────────────────────────────────────────────────────────────
setup_directories() {
    log_step "Setting up directories..."
    mkdir -p "$PSIPHON_DIR" "$CONFIG_DIR"
    log_success "Directories created"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
# Docker Container Deployment
#───────────────────────────────────────────────────────────────────────────────────────────────────
create_docker_container() {
    local instance_id="$1"
    local socks_port="$2"
    local country="$3"
    local container_name="${CONTAINER_PREFIX}-${instance_id}"
    local country_name="${COUNTRY_NAMES[$country]:-$country}"
    
    log_info "Creating container: ${container_name} [${country_name}:${socks_port}]"
    
    # Stop and remove existing container if exists
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Create and start the container with country routing
    docker run -d \
        --name "$container_name" \
        --restart=always \
        --memory="512m" \
        --cpus="1.0" \
        --network host \
        -e COUNTRY="$country" \
        -e SOCKS_PORT="$socks_port" \
        --label "psiphon-fleet=true" \
        --label "country=$country" \
        --label "port=$socks_port" \
        "$DOCKER_IMAGE" >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        log_success "Container deployed: ${container_name}"
        return 0
    else
        log_error "Failed to deploy container: ${container_name}"
        return 1
    fi
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
# Deploy All Docker Containers
#───────────────────────────────────────────────────────────────────────────────────────────────────
deploy_fleet() {
    log_step "Deploying Fleet with ${#FLEET_INSTANCES[@]} Docker containers..."
    
    # Ensure Docker image is available
    log_info "Pulling latest Psiphon Docker image..."
    docker pull "$DOCKER_IMAGE" >/dev/null 2>&1 || {
        log_error "Failed to pull Docker image: $DOCKER_IMAGE"
        return 1
    }
    
    # Stop and remove all existing fleet containers
    log_info "Cleaning up existing containers..."
    for container in $(docker ps -a --filter "label=psiphon-fleet=true" --format "{{.Names}}"); do
        docker stop "$container" >/dev/null 2>&1
        docker rm "$container" >/dev/null 2>&1
    done
    sleep 2
    
    # Deploy all containers with staggered delays
    log_info "Deploying containers with staggered delays..."
    local count=0
    local total=${#FLEET_INSTANCES[@]}
    local failed=0
    
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        count=$((count + 1))
        
        echo -ne "  [${count}/${total}] Deploying ${CYAN}${instance_id}${NC} [${COUNTRY_NAMES[$country]:-$country}:${port}]..."
        
        if create_docker_container "$instance_id" "$port" "$country" >/dev/null 2>&1; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${RED}✗${NC}"
            failed=$((failed + 1))
        fi
        
        # Stagger container starts for stability
        sleep 3
    done
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "All ${total} containers deployed successfully!"
    else
        log_warn "${failed} containers failed to deploy"
    fi
    
    return 0
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
    echo -e "${CYAN}║                          PSIPHON FLEET STATUS (Docker)                                   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    printf "${WHITE}%-28s %-12s %-10s %-8s %-18s %-10s${NC}\n" "CONTAINER" "COUNTRY" "STATUS" "PORT" "EXIT IP" "VERIFIED"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────"
    
    for instance_id in "${!FLEET_INSTANCES[@]}"; do
        IFS=':' read -r country port <<< "${FLEET_INSTANCES[$instance_id]}"
        local container_name="${CONTAINER_PREFIX}-${instance_id}"
        local status="DOWN"
        local status_color="${RED}"
        local exit_ip="N/A"
        local exit_country="N/A"
        local verified="${RED}✗${NC}"
        
        # Check if container is running
        if docker ps --filter "name=^${container_name}$" --format "{{.Names}}" | grep -q "^${container_name}$"; then
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
        
        local container_name="${CONTAINER_PREFIX}-${target}"
        log_info "${action^}ing $target..."
        docker "$action" "$container_name" 2>/dev/null || {
            log_error "Failed to ${action} ${target}"
            return 1
        }
        log_success "$target ${action}ed"
    else
        # All instances
        log_info "${action^}ing all fleet containers..."
        for instance_id in "${!FLEET_INSTANCES[@]}"; do
            local container_name="${CONTAINER_PREFIX}-${instance_id}"
            docker "$action" "$container_name" 2>/dev/null || true
            [[ "$action" == "start" ]] && sleep 2
        done
        log_success "All containers ${action}ed"
    fi
}

show_logs() {
    local instance="${1:-}"
    local lines="${2:-50}"
    
    if [[ -z "$instance" ]]; then
        # Show combined logs from all containers
        log_info "Showing last $lines lines from all containers..."
        for instance_id in "${!FLEET_INSTANCES[@]}"; do
            local container_name="${CONTAINER_PREFIX}-${instance_id}"
            echo -e "\n${CYAN}=== ${container_name} ===${NC}"
            docker logs --tail "$lines" "$container_name" 2>/dev/null || echo "No logs available"
        done
    else
        if [[ -z "${FLEET_INSTANCES[$instance]}" ]]; then
            log_error "Instance '$instance' not found"
            return 1
        fi
        local container_name="${CONTAINER_PREFIX}-${instance}"
        log_info "Showing last $lines lines from $instance..."
        docker logs --tail "$lines" "$container_name" 2>/dev/null || echo "No logs available"
    fi
}

uninstall_fleet() {
    log_warn "Uninstalling Psiphon Fleet..."
    read -rp "Are you sure? This removes ALL containers and data (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log_info "Cancelled."; return; }
    
    # Stop and remove all containers with 'psiphon' in the name
    log_info "Removing all Psiphon containers..."
    for container in $(docker ps -a --format "{{.Names}}" | grep -i psiphon); do
        echo -e "  ${YELLOW}Removing:${NC} $container"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
    done
    
    # Clean up directories
    rm -rf "$PSIPHON_DIR"
    
    log_success "Fleet uninstalled completely"
}

#───────────────────────────────────────────────────────────────────────────────────────────────────
show_usage() {
    cat << USAGE
${CYAN}PSIPHON FLEET COMMANDER v4.0 (Docker)${NC}

${WHITE}Usage:${NC}
  $0 install              - Interactive setup and deploy fleet
  $0 status               - Show status of all instances
  $0 start [instance]     - Start instance(s)
  $0 stop [instance]      - Stop instance(s)  
  $0 restart [instance]   - Restart instance(s)
  $0 logs [instance] [n]  - Show logs (default: all, 50 lines)
  $0 generate-xui         - Generate X-UI outbounds and routing
  $0 add <country>        - Add new instance for country
  $0 clean                - Remove ALL Psiphon containers (no prompt)
  $0 uninstall            - Remove all fleet instances (with prompt)d routing
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
    
    create_docker_container "$instance_id" "$port" "$country"
    
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
            check_docker
            setup_directories
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
            check_docker
            add_instance "$2"
            ;;
        clean)
            log_warn "Cleaning all Psiphon containers..."
            for container in $(docker ps -a --format "{{.Names}}" | grep -i psiphon); do
                echo -e "  ${YELLOW}Removing:${NC} $container"
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
            done
            log_success "All Psiphon containers removed"
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
