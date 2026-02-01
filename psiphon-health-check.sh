#!/bin/bash
# Psiphon Fleet Health Check & Auto-Recovery Script
# Version: 1.0
# Description: Monitors Psiphon containers and auto-restarts failed instances

set -euo pipefail

readonly VERSION="1.0"
readonly LOG_FILE="/var/log/psiphon-health-check.log"
readonly MAX_LOG_SIZE=10485760  # 10MB
readonly COMPOSE_FILE="${COMPOSE_FILE:-docker-compose-psiphon.yml}"
readonly ALERT_EMAIL="${ALERT_EMAIL:-}"
readonly ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"

# Container configurations
readonly CONTAINERS=(
    "psiphon-us:US:10080"
    "psiphon-de:DE:10081"
    "psiphon-gb:GB:10082"
    "psiphon-fr:FR:10083"
    "psiphon-nl:NL:10084"
    "psiphon-sg:SG:10085"
)

# Logging functions
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $1"
}

log_warn() {
    log "WARN: $1"
}

log_info() {
    log "INFO: $1"
}

# Rotate log if too large
rotate_log() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log_info "Log file rotated"
    fi
}

# Send alert via email
send_email_alert() {
    local subject="$1"
    local message="$2"
    
    if [[ -n "$ALERT_EMAIL" ]] && command -v mail &>/dev/null; then
        echo "$message" | mail -s "$subject" "$ALERT_EMAIL"
        log_info "Email alert sent to $ALERT_EMAIL"
    fi
}

# Send alert via webhook (Slack, Discord, Telegram, etc.)
send_webhook_alert() {
    local message="$1"
    
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        curl -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"$message\"}" \
            --silent --show-error --max-time 10 || true
        log_info "Webhook alert sent"
    fi
}

# Check if Docker is running
check_docker() {
    if ! docker ps &>/dev/null; then
        log_error "Docker daemon is not running!"
        send_email_alert "Psiphon Health Check: Docker Down" "Docker daemon is not responding. Manual intervention required."
        send_webhook_alert "🚨 CRITICAL: Docker daemon is not running on $(hostname)"
        return 1
    fi
    return 0
}

# Check if container is running
is_container_running() {
    local container="$1"
    docker ps --filter "name=^${container}$" --format "{{.Names}}" | grep -q "^${container}$"
}

# Check if container is healthy (can establish SOCKS connection)
check_container_health() {
    local container="$1"
    local port="$2"
    
    # Try to connect via SOCKS5 with timeout
    local result
    result=$(timeout 15 curl --connect-timeout 10 --max-time 15 \
             --socks5 "127.0.0.1:${port}" \
             -s "https://ipapi.co/json" 2>/dev/null || echo "")
    
    if [[ -n "$result" ]] && [[ "$result" != *"error"* ]] && [[ "$result" != *"limit"* ]]; then
        return 0  # Healthy
    else
        return 1  # Unhealthy
    fi
}

# Restart a specific container
restart_container() {
    local container="$1"
    
    log_warn "Restarting container: $container"
    
    if docker-compose -f "$COMPOSE_FILE" restart "$container" &>/dev/null; then
        log_info "Container $container restarted successfully"
        return 0
    else
        log_error "Failed to restart container: $container"
        return 1
    fi
}

# Start a stopped container
start_container() {
    local container="$1"
    
    log_warn "Starting container: $container"
    
    if docker-compose -f "$COMPOSE_FILE" start "$container" &>/dev/null; then
        log_info "Container $container started successfully"
        return 0
    else
        log_error "Failed to start container: $container"
        return 1
    fi
}

# Recreate a container (last resort)
recreate_container() {
    local container="$1"
    
    log_warn "Recreating container: $container (last resort)"
    
    if docker-compose -f "$COMPOSE_FILE" up -d --force-recreate "$container" &>/dev/null; then
        log_info "Container $container recreated successfully"
        return 0
    else
        log_error "Failed to recreate container: $container"
        return 1
    fi
}

# Main health check logic
health_check() {
    local issues_found=0
    local containers_checked=0
    local containers_restarted=0
    local containers_failed=0
    
    log_info "Starting health check..."
    
    # Check Docker first
    if ! check_docker; then
        return 1
    fi
    
    # Check each container
    for entry in "${CONTAINERS[@]}"; do
        IFS=':' read -r container country port <<< "$entry"
        containers_checked=$((containers_checked + 1))
        
        # Check if container is running
        if ! is_container_running "$container"; then
            log_error "Container $container is not running"
            issues_found=$((issues_found + 1))
            
            # Try to start it
            if start_container "$container"; then
                containers_restarted=$((containers_restarted + 1))
                # Wait for it to initialize
                sleep 5
            else
                containers_failed=$((containers_failed + 1))
                send_webhook_alert "🔴 Failed to start $container (${country}) on $(hostname)"
                continue
            fi
        fi
        
        # Check if container is healthy (SOCKS5 connectivity)
        if ! check_container_health "$container" "$port"; then
            log_warn "Container $container health check failed (port $port not responding)"
            issues_found=$((issues_found + 1))
            
            # Try to restart it
            if restart_container "$container"; then
                containers_restarted=$((containers_restarted + 1))
                # Wait for it to initialize
                sleep 10
                
                # Verify health after restart
                if check_container_health "$container" "$port"; then
                    log_info "Container $container is healthy after restart"
                    send_webhook_alert "✅ $container (${country}) recovered after restart on $(hostname)"
                else
                    log_warn "Container $container still unhealthy after restart, attempting recreate..."
                    
                    # Last resort: recreate
                    if recreate_container "$container"; then
                        sleep 15
                        if check_container_health "$container" "$port"; then
                            log_info "Container $container is healthy after recreation"
                            send_webhook_alert "✅ $container (${country}) recovered after recreation on $(hostname)"
                        else
                            log_error "Container $container failed to recover after recreation"
                            containers_failed=$((containers_failed + 1))
                            send_email_alert "Psiphon Health Check: Critical Failure" \
                                "Container $container (${country}, port ${port}) failed to recover. Manual intervention required."
                            send_webhook_alert "🚨 CRITICAL: $container (${country}) failed to recover on $(hostname)"
                        fi
                    else
                        containers_failed=$((containers_failed + 1))
                    fi
                fi
            else
                containers_failed=$((containers_failed + 1))
                send_webhook_alert "🔴 Failed to restart $container (${country}) on $(hostname)"
            fi
        fi
    done
    
    # Summary
    log_info "Health check complete: $containers_checked checked, $issues_found issues found, $containers_restarted recovered, $containers_failed failed"
    
    if [[ $containers_failed -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# Generate health report
generate_report() {
    local report=""
    report+="Psiphon Fleet Health Report - $(date '+%Y-%m-%d %H:%M:%S')\n"
    report+="=" | head -c 70 && report+="\n\n"
    
    for entry in "${CONTAINERS[@]}"; do
        IFS=':' read -r container country port <<< "$entry"
        
        local status="DOWN"
        local health="UNHEALTHY"
        
        if is_container_running "$container"; then
            status="UP"
            if check_container_health "$container" "$port"; then
                health="HEALTHY"
            fi
        fi
        
        report+="[$status] $container ($country) - Port: $port - Health: $health\n"
    done
    
    echo -e "$report"
}

# Show usage
show_usage() {
    cat << EOF
Psiphon Fleet Health Check v${VERSION}

Usage: $0 [OPTION]

Options:
  check        Perform health check and auto-recovery (default)
  report       Generate health status report
  test         Test alert mechanisms
  help         Show this help message

Environment Variables:
  COMPOSE_FILE    Path to docker-compose file (default: docker-compose-psiphon.yml)
  ALERT_EMAIL     Email address for critical alerts
  ALERT_WEBHOOK   Webhook URL for alerts (Slack, Discord, etc.)

Examples:
  # Run health check (typical cron usage)
  $0 check
  
  # Generate status report
  $0 report
  
  # Test alerts
  ALERT_EMAIL="admin@example.com" $0 test
  
  # Set up cron job (every 5 minutes)
  */5 * * * * /opt/psiphon-fleet/psiphon-health-check.sh check

Log File: $LOG_FILE
EOF
}

# Test alert mechanisms
test_alerts() {
    log_info "Testing alert mechanisms..."
    
    if [[ -n "$ALERT_EMAIL" ]]; then
        send_email_alert "Psiphon Health Check: Test Alert" \
            "This is a test alert from $(hostname) at $(date). If you received this, email alerts are working."
    else
        log_warn "ALERT_EMAIL not set, skipping email test"
    fi
    
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        send_webhook_alert "🧪 Test alert from Psiphon Health Check on $(hostname)"
    else
        log_warn "ALERT_WEBHOOK not set, skipping webhook test"
    fi
    
    log_info "Alert test complete"
}

# Main
main() {
    rotate_log
    
    case "${1:-check}" in
        check)
            health_check
            ;;
        report)
            generate_report
            ;;
        test)
            test_alerts
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
