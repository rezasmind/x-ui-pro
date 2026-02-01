#!/bin/bash

set -euo pipefail

readonly BACKUP_DIR="${BACKUP_DIR:-/var/backups/psiphon-fleet}"
readonly DATA_DIR="./warp-data"
readonly CONFIG_FILES=("docker-compose-psiphon.yml" "psiphon-docker.sh" "psiphon-health-check.sh")
readonly DATE_FORMAT="%Y%m%d_%H%M%S"

backup_fleet() {
    local timestamp=$(date +"$DATE_FORMAT")
    local backup_name="psiphon-fleet-${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    mkdir -p "$BACKUP_DIR"
    
    echo "Creating backup: ${backup_name}"
    
    mkdir -p "${backup_path}"
    
    for file in "${CONFIG_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${backup_path}/"
            echo "  Backed up: $file"
        fi
    done
    
    if [[ -d "$DATA_DIR" ]]; then
        cp -r "$DATA_DIR" "${backup_path}/"
        echo "  Backed up: $DATA_DIR"
    fi
    
    tar -czf "${backup_path}.tar.gz" -C "$BACKUP_DIR" "$backup_name"
    rm -rf "$backup_path"
    
    echo "Backup created: ${backup_path}.tar.gz"
    echo "Size: $(du -h "${backup_path}.tar.gz" | cut -f1)"
    
    cleanup_old_backups
}

restore_fleet() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        echo "Error: Backup file not found: $backup_file"
        exit 1
    fi
    
    echo "Restoring from: $backup_file"
    
    read -p "This will overwrite current configuration. Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Restore cancelled"
        exit 0
    fi
    
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"
    
    local backup_name=$(basename "$backup_file" .tar.gz)
    local extract_dir="${temp_dir}/${backup_name}"
    
    for file in "${CONFIG_FILES[@]}"; do
        if [[ -f "${extract_dir}/${file}" ]]; then
            cp "${extract_dir}/${file}" "./"
            echo "  Restored: $file"
        fi
    done
    
    if [[ -d "${extract_dir}/${DATA_DIR}" ]]; then
        rm -rf "$DATA_DIR"
        cp -r "${extract_dir}/${DATA_DIR}" "./"
        echo "  Restored: $DATA_DIR"
    fi
    
    rm -rf "$temp_dir"
    
    echo "Restore complete. Restart services to apply changes."
}

list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "No backups found"
        return
    fi
    
    echo "Available backups:"
    echo ""
    
    local backups=($(ls -t "$BACKUP_DIR"/psiphon-fleet-*.tar.gz 2>/dev/null || true))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backups found"
        return
    fi
    
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" 2>/dev/null || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup" 2>/dev/null)
        echo "  $name"
        echo "    Size: $size"
        echo "    Date: $date"
        echo ""
    done
}

cleanup_old_backups() {
    local keep_count="${KEEP_BACKUPS:-7}"
    
    local backups=($(ls -t "$BACKUP_DIR"/psiphon-fleet-*.tar.gz 2>/dev/null || true))
    
    if [[ ${#backups[@]} -gt $keep_count ]]; then
        echo "Cleaning up old backups (keeping ${keep_count} most recent)..."
        for ((i=$keep_count; i<${#backups[@]}; i++)); do
            rm -f "${backups[$i]}"
            echo "  Removed: $(basename "${backups[$i]}")"
        done
    fi
}

show_usage() {
    cat << EOF
Psiphon Fleet Backup & Restore Tool

Usage: $0 COMMAND [OPTIONS]

Commands:
  backup              Create a new backup
  restore FILE        Restore from backup file
  list                List available backups
  cleanup             Remove old backups (keeps 7 most recent)

Environment Variables:
  BACKUP_DIR         Backup directory (default: /var/backups/psiphon-fleet)
  KEEP_BACKUPS       Number of backups to keep (default: 7)

Examples:
  $0 backup
  $0 list
  $0 restore /var/backups/psiphon-fleet/psiphon-fleet-20250201_120000.tar.gz
  
  KEEP_BACKUPS=14 $0 cleanup

Automatic Backups (cron):
  0 2 * * * /opt/psiphon-fleet/psiphon-backup.sh backup
EOF
}

main() {
    case "${1:-}" in
        backup)
            backup_fleet
            ;;
        restore)
            if [[ -z "${2:-}" ]]; then
                echo "Error: Backup file required"
                echo "Usage: $0 restore FILE"
                exit 1
            fi
            restore_fleet "$2"
            ;;
        list|ls)
            list_backups
            ;;
        cleanup)
            cleanup_old_backups
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
