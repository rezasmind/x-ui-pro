#!/bin/bash
# check-psiphon.sh
# Quickly check the status, IP, and Country of all Psiphon instances
# Updated for PRD compliance

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BASE_DIR="/opt/psiphon"

# Format: "NAME|COUNTRY|HTTP_PORT|SOCKS_PORT"
INSTANCES=(
    "psiphon-us|US|8081|1081"
    "psiphon-gb|GB|8082|1082"
    "psiphon-fr|FR|8083|1083"
    "psiphon-sg|SG|8084|1084"
    "psiphon-nl|NL|8085|1085"
)

echo -e "${BLUE}=== Psiphon Instances Status ===${NC}"
printf "%-12s %-12s %-10s %-16s %-10s\n" "Instance" "Status" "Target" "Real IP" "Real Country"
echo "------------------------------------------------------------------"

for instance in "${INSTANCES[@]}"; do
    IFS='|' read -r name country http_port socks_port <<< "$instance"
    
    service="psiphon@${name}"
    
    # 1. Get Service Status
    if systemctl is-active --quiet "$service"; then
        svc_status="${GREEN}Active${NC}"
        
        # 2. Check Actual Connectivity
        # 2s timeout to be quick
        ip_info=$(curl --connect-timeout 2 --socks5 127.0.0.1:$socks_port -s https://ipapi.co/json 2>/dev/null)
        
        if [[ -n "$ip_info" ]]; then
            if command -v jq &> /dev/null; then
                ip=$(echo "$ip_info" | jq -r .ip)
                real_country=$(echo "$ip_info" | jq -r .country_code)
            else
                ip=$(echo "$ip_info" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
                real_country=$(echo "$ip_info" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
            fi
            
            if [[ "$real_country" != "$country" ]]; then
                 real_country="${RED}${real_country}${NC}"
            else
                 real_country="${GREEN}${real_country}${NC}"
            fi
        else
            ip="${RED}Unreachable${NC}"
            real_country="-"
        fi
    else
        svc_status="${RED}Inactive${NC}"
        ip="-"
        real_country="-"
    fi
    
    printf "%-12s %-20s %-10s %-16s %-10s\n" "$name" "$svc_status" "$country" "$ip" "$real_country"
done

echo ""
