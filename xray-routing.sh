#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════════════════════════
#  XRAY ROUTING CONFIGURATOR - Auto-configure User-based Country Routing
#  Author: Engineered for x-ui-pro
#  Purpose: Automatically configure Xray to route users to Psiphon proxies based on email
#═══════════════════════════════════════════════════════════════════════════════════════════════════
set -e

[[ $EUID -ne 0 ]] && { echo "Run as root!"; exec sudo "$0" "$@"; }

# Colors
declare -r RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' 
declare -r BLUE='\033[0;34m' CYAN='\033[0;36m' MAGENTA='\033[0;35m' NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }

# Configuration
XUIDB="/etc/x-ui/x-ui.db"
FLEET_STATE="/etc/psiphon-fleet/fleet.state"
XRAY_CONFIG_DIR="/usr/local/x-ui/bin"
OUTPUT_DIR="/etc/xui-routing"
BACKUP_DIR="/etc/xui-routing/backups"

print_banner() {
    echo -e "${MAGENTA}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════════════╗
║   XRAY ROUTING CONFIGURATOR                                                  ║
║   Auto-configure User-based Country Routing for X-UI                         ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if [[ ! -f "$FLEET_STATE" ]]; then
        log_error "Psiphon Fleet state not found: $FLEET_STATE"
        log_warn "Run 'psiphon-fleet.sh install' first"
        exit 1
    fi
    
    if ! command -v jq &>/dev/null; then
        log_info "Installing jq..."
        apt-get update -qq && apt-get install -y -qq jq
    fi
    
    if ! command -v sqlite3 &>/dev/null; then
        log_info "Installing sqlite3..."
        apt-get update -qq && apt-get install -y -qq sqlite3
    fi
    
    log_success "Prerequisites OK"
}

load_fleet_instances() {
    log_info "Loading Psiphon Fleet instances..."
    
    declare -gA FLEET_COUNTRIES=()
    declare -gA FLEET_PORTS=()
    
    while IFS='=' read -r instance_id config; do
        if [[ -n "$instance_id" && -n "$config" ]]; then
            IFS=':' read -r country port <<< "$config"
            FLEET_COUNTRIES["$instance_id"]="$country"
            FLEET_PORTS["$country"]="$port"
        fi
    done < "$FLEET_STATE"
    
    log_success "Loaded ${#FLEET_PORTS[@]} country configurations"
    
    for country in "${!FLEET_PORTS[@]}"; do
        echo -e "  ${GREEN}•${NC} $country -> 127.0.0.1:${FLEET_PORTS[$country]}"
    done
}

generate_outbounds() {
    log_info "Generating Xray outbound configurations..."
    
    mkdir -p "$OUTPUT_DIR"
    
    local outbounds_file="${OUTPUT_DIR}/outbounds.json"
    
    cat > "$outbounds_file" << 'EOF'
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
EOF

    for country in "${!FLEET_PORTS[@]}"; do
        local port="${FLEET_PORTS[$country]}"
        local tag="out-${country,,}"
        
        cat >> "$outbounds_file" << EOF
    ,{
      "tag": "${tag}",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${port}
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "mark": 255
        }
      }
    }
EOF
    done

    echo "  ]" >> "$outbounds_file"
    echo "}" >> "$outbounds_file"
    
    # Format with jq
    jq . "$outbounds_file" > "${outbounds_file}.tmp" && mv "${outbounds_file}.tmp" "$outbounds_file"
    
    log_success "Outbounds saved to: $outbounds_file"
}

generate_routing_rules() {
    log_info "Generating Xray routing rules (user-based)..."
    
    local routing_file="${OUTPUT_DIR}/routing.json"
    
    cat > "$routing_file" << 'EOF'
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
EOF

    # Add user-based routing rules for each country
    local first=true
    for country in "${!FLEET_PORTS[@]}"; do
        local user_pattern="user-${country,,}"
        local outbound_tag="out-${country,,}"
        
        cat >> "$routing_file" << EOF
      ,{
        "type": "field",
        "user": ["${user_pattern}"],
        "outboundTag": "${outbound_tag}"
      }
EOF
    done

    cat >> "$routing_file" << 'EOF'
      ,{
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "udp,tcp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

    # Format with jq
    jq . "$routing_file" > "${routing_file}.tmp" && mv "${routing_file}.tmp" "$routing_file"
    
    log_success "Routing rules saved to: $routing_file"
}

generate_combined_config() {
    log_info "Generating combined Xray configuration snippet..."
    
    local combined_file="${OUTPUT_DIR}/xray-config-snippet.json"
    local outbounds_file="${OUTPUT_DIR}/outbounds.json"
    local routing_file="${OUTPUT_DIR}/routing.json"
    
    # Combine outbounds and routing
    jq -s '.[0] * .[1]' "$outbounds_file" "$routing_file" > "$combined_file"
    
    log_success "Combined config saved to: $combined_file"
}

generate_user_email_list() {
    log_info "Generating user email patterns for each country..."
    
    local users_file="${OUTPUT_DIR}/user-emails.txt"
    
    cat > "$users_file" << 'EOF'
# User Email Patterns for Country-based Routing
# Format: email_pattern -> country -> outbound_tag -> port
#
# When creating users in X-UI, use these email patterns
# to automatically route their traffic through the specified country.
#
# Example: A user with email "user-de-abc123" will route through Germany
#
EOF

    for country in "${!FLEET_PORTS[@]}"; do
        local port="${FLEET_PORTS[$country]}"
        local tag="out-${country,,}"
        local pattern="user-${country,,}-*"
        
        echo "# ${country}" >> "$users_file"
        echo "Email Pattern: ${pattern}" >> "$users_file"
        echo "Outbound Tag: ${tag}" >> "$users_file"
        echo "SOCKS Port: ${port}" >> "$users_file"
        echo "" >> "$users_file"
    done
    
    log_success "User patterns saved to: $users_file"
}

apply_to_xui() {
    log_info "Applying configuration to X-UI..."
    
    if [[ ! -f "$XUIDB" ]]; then
        log_warn "X-UI database not found. Skipping database update."
        log_warn "You'll need to manually add the routing rules in the X-UI panel."
        return
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/x-ui.db.$(date +%Y%m%d_%H%M%S)"
    cp "$XUIDB" "$backup_file"
    log_info "Database backed up to: $backup_file"
    
    # Stop x-ui to safely modify database
    systemctl stop x-ui 2>/dev/null || true
    sleep 2
    
    # Get current xray template settings
    local current_template=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || echo "")
    
    if [[ -z "$current_template" ]]; then
        log_warn "No existing Xray template found in database"
        log_warn "Please add the configuration manually through X-UI panel"
        systemctl start x-ui 2>/dev/null || true
        return
    fi
    
    log_info "Found existing Xray template configuration"
    
    # Parse and update the template
    local routing_json=$(cat "${OUTPUT_DIR}/routing.json")
    local outbounds_json=$(cat "${OUTPUT_DIR}/outbounds.json")
    
    # This is a simplified approach - for full integration, manual config is recommended
    log_warn "Automatic template update is complex and may break existing config."
    log_warn "It's recommended to manually add the configurations through X-UI panel."
    
    # Restart x-ui
    systemctl start x-ui 2>/dev/null || true
    
    log_success "X-UI restarted"
}

print_instructions() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                         CONFIGURATION COMPLETE                               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${YELLOW}STEP 1: Add Outbounds to X-UI${NC}"
    echo -e "  Go to X-UI Panel → Panel Settings → Xray Configurations"
    echo -e "  Find the 'outbounds' section and add from:"
    echo -e "  ${GREEN}${OUTPUT_DIR}/outbounds.json${NC}"
    echo ""
    
    echo -e "${YELLOW}STEP 2: Add Routing Rules to X-UI${NC}"
    echo -e "  In the same settings page, find the 'routing' section"
    echo -e "  Add the rules from:"
    echo -e "  ${GREEN}${OUTPUT_DIR}/routing.json${NC}"
    echo ""
    
    echo -e "${YELLOW}STEP 3: Create Users with Country-specific Emails${NC}"
    echo -e "  When adding clients in your inbound, use these email patterns:"
    echo ""
    
    for country in "${!FLEET_PORTS[@]}"; do
        local port="${FLEET_PORTS[$country]}"
        echo -e "  ${GREEN}user-${country,,}-UNIQUE${NC} → Traffic exits via ${country} (port ${port})"
    done
    
    echo ""
    echo -e "${YELLOW}EXAMPLE:${NC}"
    echo -e "  Create inbound on port 2083 (VLESS+WebSocket+TLS)"
    echo -e "  Add 5 clients with emails:"
    echo -e "    • user-us-john   → Traffic exits via USA"
    echo -e "    • user-de-mary   → Traffic exits via Germany"
    echo -e "    • user-gb-peter  → Traffic exits via UK"
    echo ""
    
    echo -e "${YELLOW}STEP 4: Share Configs${NC}"
    echo -e "  Each client gets their own subscription link"
    echo -e "  The UUID is different but all use the same port (2083)"
    echo -e "  Traffic is routed based on the email pattern!"
    echo ""
    
    echo -e "${CYAN}Generated Files:${NC}"
    echo -e "  • ${OUTPUT_DIR}/outbounds.json"
    echo -e "  • ${OUTPUT_DIR}/routing.json"
    echo -e "  • ${OUTPUT_DIR}/xray-config-snippet.json"
    echo -e "  • ${OUTPUT_DIR}/user-emails.txt"
    echo ""
}

show_quick_copy() {
    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}                           QUICK COPY CONFIGURATIONS                            ${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${YELLOW}OUTBOUNDS (copy this to Xray config):${NC}"
    echo ""
    cat "${OUTPUT_DIR}/outbounds.json"
    echo ""
    
    echo -e "${YELLOW}ROUTING RULES (copy this to Xray config):${NC}"
    echo ""
    cat "${OUTPUT_DIR}/routing.json"
    echo ""
}

test_routing() {
    log_info "Testing routing configuration..."
    echo ""
    
    for country in "${!FLEET_PORTS[@]}"; do
        local port="${FLEET_PORTS[$country]}"
        
        echo -ne "  Testing ${country} (port ${port})... "
        
        local result=$(timeout 10 curl --connect-timeout 5 --socks5 127.0.0.1:${port} -s https://ipapi.co/country_code 2>/dev/null || echo "FAIL")
        
        if [[ "$result" == "$country" ]]; then
            echo -e "${GREEN}✓ ${result}${NC}"
        elif [[ "$result" == "FAIL" ]]; then
            echo -e "${RED}✗ Connection failed${NC}"
        else
            echo -e "${YELLOW}≈ Got ${result} (expected ${country})${NC}"
        fi
    done
    
    echo ""
}

show_usage() {
    cat << EOF
${CYAN}XRAY ROUTING CONFIGURATOR${NC}

${YELLOW}Usage:${NC}
  $0 generate     - Generate all configuration files
  $0 apply        - Generate and attempt to apply to X-UI
  $0 test         - Test all Psiphon proxy connections
  $0 show         - Show generated configurations
  $0 help         - Show this help

${YELLOW}Description:${NC}
  This tool generates Xray routing configurations that allow
  multiple users on a single inbound port to exit through
  different countries based on their email pattern.

${YELLOW}How it works:${NC}
  1. Reads Psiphon Fleet state to get available countries
  2. Generates outbound configs for each country's SOCKS proxy
  3. Generates routing rules based on user email patterns
  4. Users with email "user-XX-*" route through country XX

${YELLOW}Example:${NC}
  User "user-de-customer1" → exits via Germany
  User "user-us-customer2" → exits via USA
  Both can use the same inbound port!

EOF
}

main() {
    print_banner
    
    case "${1:-generate}" in
        generate)
            check_prerequisites
            load_fleet_instances
            generate_outbounds
            generate_routing_rules
            generate_combined_config
            generate_user_email_list
            print_instructions
            ;;
        apply)
            check_prerequisites
            load_fleet_instances
            generate_outbounds
            generate_routing_rules
            generate_combined_config
            generate_user_email_list
            apply_to_xui
            print_instructions
            ;;
        test)
            check_prerequisites
            load_fleet_instances
            test_routing
            ;;
        show)
            check_prerequisites
            load_fleet_instances
            show_quick_copy
            ;;
        help|--help|-h)
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
