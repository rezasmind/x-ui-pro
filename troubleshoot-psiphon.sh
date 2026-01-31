#!/bin/bash

#############################################################################
#  Psiphon Troubleshooter v1.0
#  Part of X-UI-PRO - Multi-Country VPN Configuration System
#  
#  Diagnoses and fixes common Psiphon connection issues
#############################################################################

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly PORTS=(8080 8081 8082 8083 8084)
readonly WARP_BIN="/etc/warp-plus/warp-plus"

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║           Psiphon Troubleshooter - X-UI-PRO                   ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗ Must run as root${NC}"
    exit 1
fi

echo -e "${BLUE}[1/6]${NC} Checking warp-plus binary..."
if [[ -f "$WARP_BIN" && -x "$WARP_BIN" ]]; then
    version=$("$WARP_BIN" --version 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Found: $WARP_BIN (version: $version)"
else
    echo -e "  ${RED}✗${NC} warp-plus not found or not executable"
    echo -e "  ${YELLOW}FIX:${NC} Run ./deploy-psiphon.sh to install"
fi

echo ""
echo -e "${BLUE}[2/6]${NC} Checking service files..."
for port in "${PORTS[@]}"; do
    service_file="/etc/systemd/system/psiphon-${port}.service"
    if [[ -f "$service_file" ]]; then
        country=$(grep -oP '(?<=--country )\w+' "$service_file" 2>/dev/null || echo "?")
        has_scan=$(grep -q "\-\-scan" "$service_file" && echo "yes" || echo "no")
        echo -e "  ${GREEN}✓${NC} psiphon-${port}: Country=$country, --scan=$has_scan"
        
        if [[ "$has_scan" == "no" ]]; then
            echo -e "    ${YELLOW}⚠ Missing --scan flag. This may cause connection issues.${NC}"
        fi
    else
        echo -e "  ${RED}✗${NC} psiphon-${port}: Service file not found"
    fi
done

echo ""
echo -e "${BLUE}[3/6]${NC} Checking service status..."
for port in "${PORTS[@]}"; do
    service_name="psiphon-${port}"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pid=$(systemctl show "$service_name" --property=MainPID --value 2>/dev/null)
        runtime=$(systemctl show "$service_name" --property=ActiveEnterTimestamp --value 2>/dev/null | cut -d' ' -f2-3)
        echo -e "  ${GREEN}✓${NC} $service_name: RUNNING (PID: $pid, Started: $runtime)"
    else
        state=$(systemctl is-enabled "$service_name" 2>/dev/null || echo "not installed")
        echo -e "  ${RED}✗${NC} $service_name: NOT RUNNING (enabled: $state)"
    fi
done

echo ""
echo -e "${BLUE}[4/6]${NC} Checking cache directories..."
for port in "${PORTS[@]}"; do
    cache_dir="/var/cache/psiphon-${port}"
    if [[ -d "$cache_dir" ]]; then
        files=$(ls -la "$cache_dir" 2>/dev/null | wc -l)
        size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✓${NC} $cache_dir: $size, $files files"
    else
        echo -e "  ${RED}✗${NC} $cache_dir: Not found"
    fi
done

echo ""
echo -e "${BLUE}[5/6]${NC} Testing SOCKS5 connectivity..."
for port in "${PORTS[@]}"; do
    echo -ne "  Testing port ${port}... "
    
    # First check if port is listening
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${RED}✗ Port not listening${NC}"
        continue
    fi
    
    # Then test SOCKS5 connection
    result=$(curl --connect-timeout 10 --max-time 15 \
             --socks5-hostname "127.0.0.1:${port}" \
             -s "https://ipapi.co/json" 2>/dev/null)
    
    if [[ -n "$result" && "$result" != *"error"* ]]; then
        ip=$(echo "$result" | grep -o '"ip": *"[^"]*"' | cut -d'"' -f4)
        country=$(echo "$result" | grep -o '"country_code": *"[^"]*"' | cut -d'"' -f4)
        echo -e "${GREEN}✓ ONLINE${NC} → IP: $ip, Country: $country"
    else
        echo -e "${YELLOW}⚠ Connecting... (may need more time)${NC}"
    fi
done

echo ""
echo -e "${BLUE}[6/6]${NC} Checking recent logs..."
for port in "${PORTS[@]}"; do
    log_file="/var/log/psiphon/psiphon-${port}.log"
    echo -e "  ${BOLD}psiphon-${port}:${NC}"
    if [[ -f "$log_file" ]]; then
        tail -3 "$log_file" 2>/dev/null | while read -r line; do
            echo "    $line"
        done
    else
        journalctl -u "psiphon-${port}" --no-pager -n 3 2>/dev/null | tail -3 | while read -r line; do
            echo "    $line"
        done
    fi
done

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Recommended Actions:${NC}"
echo ""

# Count issues
issues=0
for port in "${PORTS[@]}"; do
    systemctl is-active --quiet "psiphon-${port}" 2>/dev/null || ((issues++))
done

if [[ $issues -gt 0 ]]; then
    echo -e "${YELLOW}1. Restart all instances:${NC}"
    echo "   ./deploy-psiphon.sh restart"
    echo ""
fi

echo -e "${YELLOW}2. Monitor live status:${NC}"
echo "   ./deploy-psiphon.sh monitor"
echo ""

echo -e "${YELLOW}3. Reconfigure with fresh settings:${NC}"
echo "   ./deploy-psiphon.sh"
echo ""

echo -e "${YELLOW}4. View detailed logs:${NC}"
echo "   ./deploy-psiphon.sh logs 8080"
echo "   journalctl -u psiphon-8080 -f"
echo ""
