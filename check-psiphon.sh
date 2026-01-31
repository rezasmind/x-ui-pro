#!/bin/bash
# check-psiphon.sh
# Quickly check the status, IP, and Country of all Psiphon instances

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/psiphon-core/configs"

echo -e "${BLUE}=== Psiphon Instances Status ===${NC}"
printf "%-8s %-12s %-10s %-16s %-10s\n" "Port" "Service" "Config" "Real IP" "Real Country"
echo "------------------------------------------------------------------"

for port in {8080..8084}; do
    service="psiphon-${port}"
    config_file="${CONFIG_DIR}/config-${port}.json"
    
    # 1. Get Service Status
    if systemctl is-active --quiet "$service"; then
        svc_status="${GREEN}Active${NC}"
        
        # 2. Get Configured Country from Config File
        if [[ -f "$config_file" ]]; then
            if command -v jq &> /dev/null; then
                cfg_country=$(jq -r .EgressRegion "$config_file")
            else
                cfg_country=$(grep -o '"EgressRegion": *"[^"]*"' "$config_file" | cut -d'"' -f4)
            fi
        else
            cfg_country="?"
        fi
        
        # 3. Check Actual Connectivity
        # 2s timeout to be quick
        ip_info=$(curl --connect-timeout 2 --socks5 127.0.0.1:$port -s https://ipapi.co/json 2>/dev/null)
        
        if [[ -n "$ip_info" ]]; then
            if command -v jq &> /dev/null; then
                ip=$(echo "$ip_info" | jq -r .ip)
                real_country=$(echo "$ip_info" | jq -r .country_code)
            else
                ip=$(echo "$ip_info" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
                real_country=$(echo "$ip_info" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
            fi
        else
            ip="${RED}Unreachable${NC}"
            real_country="-"
        fi
    else
        svc_status="${RED}Inactive${NC}"
        cfg_country="-"
        ip="-"
        real_country="-"
    fi
    
    printf "%-8s %-20s %-10s %-16s %-10s\n" "$port" "$svc_status" "${cfg_country:-?}" "$ip" "$real_country"
done

echo ""
