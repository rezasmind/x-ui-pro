#!/bin/bash

#############################################################################
#  Psiphon Status Checker v2.0
#  Part of X-UI-PRO - Multi-Country VPN Configuration System
#  
#  Quick health check for all Psiphon instances
#############################################################################

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly PORTS=(8080 8081 8082 8083 8084 8085 8086 8087 8088 8089)

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║           Psiphon Multi-Instance Status Check                 ║${NC}"
echo -e "${CYAN}${BOLD}║                  X-UI-PRO v2.0                                 ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Checking at:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

printf "${CYAN}╔══════════╦════════════╦════════════╦══════════════════╦══════════╗${NC}\n"
printf "${CYAN}║${NC} ${BOLD}%-8s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-10s${NC} ${CYAN}║${NC} ${BOLD}%-16s${NC} ${CYAN}║${NC} ${BOLD}%-8s${NC} ${CYAN}║${NC}\n" \
       "Port" "Service" "Config" "Real IP" "Country"
printf "${CYAN}╠══════════╬════════════╬════════════╬══════════════════╬══════════╣${NC}\n"

online_count=0
configured_count=0

# First, find which ports have services configured
ACTIVE_PORTS=()
for config in /etc/psiphon-core/configs/config-*.json; do
    if [[ -f "$config" ]]; then
        port=$(jq -r .LocalSocksProxyPort "$config" 2>/dev/null)
        if [[ -n "$port" ]]; then
            ACTIVE_PORTS+=($port)
            ((configured_count++)) || true
        fi
    fi
done

if [[ ${#ACTIVE_PORTS[@]} -eq 0 ]]; then
    echo -e "${RED}No Psiphon services found. Run ./deploy-psiphon.sh to configure.${NC}"
    exit 1
fi

total_count=${#ACTIVE_PORTS[@]}

for port in "${ACTIVE_PORTS[@]}"; do
    service="psiphon-${port}"
    status_color="$RED"
    svc_status="STOPPED"
    cfg_country="-"
    ip="-"
    real_country="-"
    
    # Get configured country from service file
    if [[ -f "/etc/systemd/system/${service}.service" ]]; then
        cfg_country=$(grep -oP '(?<=--country )\w+' "/etc/systemd/system/${service}.service" 2>/dev/null || echo "-")
    fi
    
    # Check service status
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        svc_status="ACTIVE"
        status_color="$YELLOW"
        
        # Check actual connectivity
        ip_info=$(curl --connect-timeout 5 --max-time 10 \
                  --socks5-hostname "127.0.0.1:$port" \
                  -s "https://ipapi.co/json" 2>/dev/null || echo "")
        
        if [[ -n "$ip_info" && "$ip_info" != *"error"* ]]; then
            svc_status="ONLINE"
            status_color="$GREEN"
            ((online_count++))
            
            if command -v jq &> /dev/null; then
                ip=$(echo "$ip_info" | jq -r '.ip // "-"')
                real_country=$(echo "$ip_info" | jq -r '.country_code // "-"')
            else
                ip=$(echo "$ip_info" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
                real_country=$(echo "$ip_info" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
            fi
            
            # Truncate long IPs
            [[ ${#ip} -gt 16 ]] && ip="${ip:0:13}..."
        fi
    fi
    
    printf "${CYAN}║${NC} %-8s ${CYAN}║${NC} ${status_color}%-10s${NC} ${CYAN}║${NC} %-10s ${CYAN}║${NC} %-16s ${CYAN}║${NC} %-8s ${CYAN}║${NC}\n" \
           "$port" "$svc_status" "${cfg_country:-?}" "$ip" "$real_country"
done

printf "${CYAN}╚══════════╩════════════╩════════════╩══════════════════╩══════════╝${NC}\n"

echo ""

# Summary
if [[ $online_count -eq $total_count ]]; then
    echo -e "${GREEN}${BOLD}✓ All $total_count instances are ONLINE${NC}"
elif [[ $online_count -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}⚠ $online_count/$total_count instances are ONLINE${NC}"
else
    echo -e "${RED}${BOLD}✗ No instances are online${NC}"
    echo -e "${YELLOW}TIP: Instances may still be initializing. Check again in 1-2 minutes.${NC}"
fi

echo ""
echo -e "${BLUE}Commands:${NC}"
echo -e "  • Full management: ${BOLD}./deploy-psiphon.sh${NC}"
echo -e "  • Live monitoring: ${BOLD}./deploy-psiphon.sh monitor${NC}"
echo -e "  • View logs:       ${BOLD}./deploy-psiphon.sh logs 8080${NC}"
echo ""
