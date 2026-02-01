#!/bin/bash

set -euo pipefail

readonly INTERVAL="${MONITOR_INTERVAL:-60}"
readonly OUTPUT_FILE="${OUTPUT_FILE:-/var/log/psiphon-performance.log}"
readonly MAX_LOG_SIZE=52428800

readonly CONTAINERS=(
    "psiphon-us:10080"
    "psiphon-de:10081"
    "psiphon-gb:10082"
    "psiphon-fr:10083"
    "psiphon-nl:10084"
    "psiphon-sg:10085"
)

log_entry() {
    echo "$1" | tee -a "$OUTPUT_FILE"
}

rotate_log() {
    if [[ -f "$OUTPUT_FILE" ]] && [[ $(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]]; then
        mv "$OUTPUT_FILE" "${OUTPUT_FILE}.old"
        log_entry "Log rotated at $(date)"
    fi
}

collect_metrics() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    log_entry "=== PERFORMANCE METRICS - $timestamp ==="
    
    local stats=$(docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" \
                  psiphon-us psiphon-de psiphon-gb psiphon-fr psiphon-nl psiphon-sg 2>/dev/null || echo "")
    
    if [[ -n "$stats" ]]; then
        log_entry "$stats"
    else
        log_entry "ERROR: Could not collect Docker stats"
    fi
    
    log_entry ""
    log_entry "CONNECTIVITY TESTS:"
    
    for entry in "${CONTAINERS[@]}"; do
        IFS=':' read -r container port <<< "$entry"
        
        local start_time=$(date +%s%N)
        local result=$(timeout 10 curl --connect-timeout 5 --socks5 "127.0.0.1:${port}" \
                       -s "https://ipapi.co/json" 2>/dev/null || echo "")
        local end_time=$(date +%s%N)
        local latency=$(( (end_time - start_time) / 1000000 ))
        
        if [[ -n "$result" ]] && [[ "$result" != *"error"* ]]; then
            local exit_ip=$(echo "$result" | jq -r '.ip // "N/A"' 2>/dev/null)
            local exit_country=$(echo "$result" | jq -r '.country_code // "N/A"' 2>/dev/null)
            log_entry "  $container (port $port): OK - ${latency}ms - Exit: ${exit_ip} (${exit_country})"
        else
            log_entry "  $container (port $port): FAILED"
        fi
    done
    
    log_entry ""
    log_entry "SYSTEM RESOURCES:"
    log_entry "  CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)% used"
    log_entry "  Memory: $(free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100.0}')"
    log_entry "  Disk: $(df -h / | awk 'NR==2 {print $5}') used"
    log_entry "  Load: $(uptime | awk -F'load average:' '{print $2}')"
    
    log_entry "=========================================="
    log_entry ""
}

monitor_loop() {
    log_entry "Starting continuous monitoring (interval: ${INTERVAL}s)"
    log_entry "Press Ctrl+C to stop"
    log_entry ""
    
    while true; do
        rotate_log
        collect_metrics
        sleep "$INTERVAL"
    done
}

generate_report() {
    local hours="${1:-24}"
    local cutoff=$(date -d "$hours hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-${hours}H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    
    echo "Performance Report (last ${hours} hours)"
    echo "========================================"
    echo ""
    
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "No performance data available"
        return
    fi
    
    local total_samples=$(grep -c "PERFORMANCE METRICS" "$OUTPUT_FILE" || echo "0")
    local failed_checks=$(grep -c "FAILED" "$OUTPUT_FILE" || echo "0")
    
    echo "Total Samples: $total_samples"
    echo "Failed Checks: $failed_checks"
    echo ""
    
    echo "Latest Status:"
    tail -50 "$OUTPUT_FILE" | grep -A 10 "CONNECTIVITY TESTS:" | tail -8
}

show_usage() {
    cat << EOF
Psiphon Fleet Performance Monitor

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  monitor              Start continuous monitoring (default)
  collect              Collect single snapshot
  report [HOURS]       Generate performance report (default: 24 hours)

Environment Variables:
  MONITOR_INTERVAL     Monitoring interval in seconds (default: 60)
  OUTPUT_FILE          Log file path (default: /var/log/psiphon-performance.log)

Examples:
  $0 monitor
  MONITOR_INTERVAL=30 $0 monitor
  $0 collect
  $0 report 48

Setup Cron (collect every 5 minutes):
  */5 * * * * /opt/psiphon-fleet/psiphon-performance.sh collect
EOF
}

main() {
    case "${1:-monitor}" in
        monitor)
            monitor_loop
            ;;
        collect)
            collect_metrics
            ;;
        report)
            generate_report "${2:-24}"
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
