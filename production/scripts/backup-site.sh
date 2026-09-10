#!/bin/bash

# Backup ERPNext Site Script
#
# Usage:
#   ./backup-site.sh <site-name> [options]
#
# Recommended major-upgrade backup:
#   ./backup-site.sh erp.example.com --with-files --auto-copy
#
# The backup is created by Bench inside the backend container.
# --auto-copy mirrors the resulting backup files onto host storage.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_debug() {
    [[ "${DEBUG:-0}" == "1" ]] &&
        echo -e "${BLUE}[DEBUG]${NC} $1" ||
        true
}

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" \
        >> "/tmp/erpnext-backup-$(date '+%Y%m%d').log"
}

cleanup() {
    local exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        echo_error "Backup script failed with exit code $exit_code"
        log_action "FAILED: ${SITE_NAME:-unknown}"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PRODUCTION_DIR" || exit 1

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

if [[ ! -f "production.env" ]]; then
    echo_error "production.env not found"
    exit 1
fi

# shellcheck disable=SC1091
source production.env

PROJECT_NAME="${PROJECT_NAME:-${ROUTER:-erpnext-production}}"

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
HOST_BACKUP_ROOT="${HOST_BACKUP_ROOT:-./backups}"
HOST_BACKUP_LAYOUT="${HOST_BACKUP_LAYOUT:-flat}"

AUTO_COPY="${AUTO_COPY:-0}"
CLEANUP_OLD="${CLEANUP_OLD:-0}"
CLEANUP_POLICY="${CLEANUP_POLICY:-}"
HOST_ONLY="${HOST_ONLY:-0}"

COMPOSE_FILE="${COMPOSE_FILE:-production.yaml}"

COMPOSE_PATH="$PRODUCTION_DIR/$COMPOSE_FILE"

if [[ ! -f "$COMPOSE_PATH" ]]; then
    echo_error "Compose file '$COMPOSE_PATH' not found"
    echo_info "Run: ./scripts/deploy.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

dc_exec() {
    docker compose \
        --project-name "$PROJECT_NAME" \
        -f "$COMPOSE_PATH" \
        exec backend "$@"
}

dc_cmd() {
    docker compose \
        --project-name "$PROJECT_NAME" \
        -f "$COMPOSE_PATH" \
        "$@"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

show_help() {
    cat <<EOF
Usage:
  $0 <site-name> [options]

Options:
  --with-files             Include public/private files in the Bench backup
  --compress               Compress the SQL dump
  --auto-copy              Copy backup files from container to host
  --flat-host-path         Store host copies directly in \$HOST_BACKUP_ROOT
  --nested-host-path       Store host copies in \$HOST_BACKUP_ROOT/<site>/<run>/
  --host-only              Delete container copies after successful host copy
  --cleanup-old[=policy]   Remove stale backups
                            Policies:
                              <empty>   BACKUP_RETENTION_DAYS
                              7         files older than 7 days
                              days:7    files older than 7 days
                              keep:5    keep newest 5 backup runs
                              latest    keep only the newest run
  --retention-days N       Alias for --cleanup-old N
  --encrypt                Encrypt host copies with GPG
  --debug                  Verbose logging
  -h, --help               Show this help

Environment:
  PROJECT_NAME             Docker Compose project name
  BACKUP_RETENTION_DAYS    Default retention period (default: 30)
  HOST_BACKUP_ROOT         Host backup directory (default: ./backups)
  HOST_BACKUP_LAYOUT       flat or nested
  AUTO_COPY                Set to 1 to copy backups to host automatically
  HOST_ONLY                Set to 1 to remove container copies after host copy
  CLEANUP_OLD              Set to 1 to prune backups automatically
  CLEANUP_POLICY           Default cleanup policy
  BACKUP_PASSPHRASE        Required for --encrypt
  COMPOSE_FILE             Compose file (default: production.yaml)

Examples:

  $0 erp.example.com --with-files --auto-copy

  $0 erp.example.com --with-files --auto-copy --nested-host-path

  $0 erp.example.com --with-files --auto-copy --host-only

  $0 erp.example.com --with-files --auto-copy --cleanup-old keep:7

  AUTO_COPY=1 CLEANUP_OLD=1 CLEANUP_POLICY=keep:5 \\
      $0 erp.example.com --with-files

Major upgrade recommendation:

  $0 <site-name> --with-files --auto-copy

This keeps a host-side copy of the database backup and site files
before a major ERPNext/Frappe upgrade.
EOF
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

require_int() {
    local value="$1"
    shift

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo_error "$*"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Cleanup policy
# ---------------------------------------------------------------------------

set_policy() {

    if [[ "$CLEANUP_OLD" -ne 1 ]]; then
        CLEANUP_MODE=""
        CLEANUP_VALUE=""
        return 0
    fi

    local policy_value="$1"

    [[ -z "$policy_value" ]] &&
        policy_value="$BACKUP_RETENTION_DAYS"

    case "$policy_value" in

        latest|keep-latest)
            CLEANUP_MODE="keep"
            CLEANUP_VALUE=1
            ;;

        keep:*)
            local keep_count="${policy_value#keep:}"

            require_int "$keep_count" "keep:<n> expects an integer"

            if [[ "$keep_count" -lt 1 ]]; then
                keep_count=1
            fi

            CLEANUP_MODE="keep"
            CLEANUP_VALUE="$keep_count"
            ;;

        days:*)
            local day_count="${policy_value#days:}"

            require_int "$day_count" "days:<n> expects an integer"

            CLEANUP_MODE="days"
            CLEANUP_VALUE="$day_count"
            ;;

        "")
            CLEANUP_MODE="days"
            CLEANUP_VALUE="$BACKUP_RETENTION_DAYS"
            ;;

        *)
            if [[ "$policy_value" =~ ^[0-9]+$ ]]; then

                if [[ "$policy_value" -eq 0 ]]; then
                    CLEANUP_MODE="keep"
                    CLEANUP_VALUE=1
                else
                    CLEANUP_MODE="days"
                    CLEANUP_VALUE="$policy_value"
                fi

            else
                echo_error "Invalid cleanup policy: $policy_value"
                exit 1
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Container cleanup
# ---------------------------------------------------------------------------

cleanup_container_days() {
    local days="$1"
    local minutes=$((days * 1440))

    echo_info "Pruning container backups older than $days day(s)"

    dc_exec bash -lc \
        "find '$BACKUP_PATH' -maxdepth 1 -type f -mmin +$minutes -delete" ||
        true
}

cleanup_container_keep() {
    local keep_runs="$1"

    echo_info "Keeping newest $keep_runs container backup run(s)"

    local prefixes=()

    mapfile -t prefixes < <(
        dc_exec bash -lc \
            "cd '$BACKUP_PATH' && \
             ls -1t 2>/dev/null | \
             awk -F'-' '!seen[\$1]++ {print \$1}'"
    ) || true

    if [[ ${#prefixes[@]} -le "$keep_runs" ]]; then
        echo_info "Nothing to prune in container"
        return
    fi

    local stale_prefixes=("${prefixes[@]:$keep_runs}")

    for prefix in "${stale_prefixes[@]}"; do
        [[ -z "$prefix" ]] && continue

        dc_exec bash -lc \
            "find '$BACKUP_PATH' -maxdepth 1 -type f -name '${prefix}-*' -delete"
    done
}

# ---------------------------------------------------------------------------
# Host cleanup
# ---------------------------------------------------------------------------

cleanup_host_days() {
    local days="$1"

    if [[ "$HOST_LAYOUT_MODE" == "nested" ]]; then

        [[ -d "$HOST_SITE_ROOT" ]] || return

        echo_info "Pruning host backups older than $days day(s)"

        find "$HOST_SITE_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -mtime +"$days" \
            -print \
            -exec rm -rf {} + ||
            true

    else

        [[ -d "$HOST_BACKUP_ROOT" ]] || return

        echo_info "Pruning host backup files older than $days day(s)"

        find "$HOST_BACKUP_ROOT" \
            -maxdepth 1 \
            -type f \
            -name "*-${SITE_FILE_KEY}-*" \
            -mtime +"$days" \
            -print \
            -delete ||
            true
    fi
}

cleanup_host_keep() {
    local keep_runs="$1"

    if [[ "$HOST_LAYOUT_MODE" == "nested" ]]; then

        [[ -d "$HOST_SITE_ROOT" ]] || return

        local dirs=()

        mapfile -t dirs < <(
            ls -1dt "$HOST_SITE_ROOT"/* 2>/dev/null
        ) || true

        if [[ ${#dirs[@]} -le "$keep_runs" ]]; then
            return
        fi

        echo_info "Keeping newest $keep_runs host backup run(s)"

        local stale_dirs=("${dirs[@]:$keep_runs}")

        for dir in "${stale_dirs[@]}"; do
            rm -rf "$dir"
        done

    else

        [[ -d "$HOST_BACKUP_ROOT" ]] || return

        local prefixes=()

        mapfile -t prefixes < <(
            find "$HOST_BACKUP_ROOT" \
                -maxdepth 1 \
                -type f \
                -name "*-${SITE_FILE_KEY}-*" \
                -printf '%f\n' |
                sort -r |
                awk -F'-' '!seen[$1]++ {print $1}'
        ) || true

        if [[ ${#prefixes[@]} -le "$keep_runs" ]]; then
            return
        fi

        echo_info "Keeping newest $keep_runs host backup run(s)"

        local stale_prefixes=("${prefixes[@]:$keep_runs}")

        for prefix in "${stale_prefixes[@]}"; do
            find "$HOST_BACKUP_ROOT" \
                -maxdepth 1 \
                -type f \
                -name "${prefix}-${SITE_FILE_KEY}-*" \
                -delete
        done
    fi
}

# ---------------------------------------------------------------------------
# Copy backups from container to host
# ---------------------------------------------------------------------------

copy_backups_to_host() {

    [[ "$AUTO_COPY" -eq 1 ]] || return 0
    [[ ${#BACKUP_FILES[@]} -gt 0 ]] || return 0

    local dest

    if [[ "$HOST_LAYOUT_MODE" == "nested" ]]; then
        dest="$HOST_SITE_ROOT/$CURRENT_PREFIX"
    else
        dest="$HOST_BACKUP_ROOT"
    fi

    mkdir -p "$dest"

    BACKEND_CONTAINER="$(dc_cmd ps -q backend)"

    if [[ -z "$BACKEND_CONTAINER" ]]; then
        echo_error "Backend container not running"
        exit 1
    fi

    HOST_RUN_FILES=()

    local file_path
    local base
    local target

    for file_path in "${BACKUP_FILES[@]}"; do

        [[ -z "$file_path" ]] && continue

        base="$(basename "$file_path")"
        target="$dest/$base"

        if docker cp \
            "${BACKEND_CONTAINER}:${file_path}" \
            "$target" 2>/dev/null; then

            echo_info "  → Copied $base"
            HOST_RUN_FILES+=("$target")

        else
            echo_error "  ✗ Failed to copy $base"
            exit 1
        fi
    done

    if [[ ${#HOST_RUN_FILES[@]} -gt 0 ]]; then
        HOST_COPY_SUCCESS=1
        HOST_RUN_DIR="$dest"
        echo_info "✓ Host copy complete: $dest"
    else
        echo_error "No files were copied to host"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Encrypt host backups
# ---------------------------------------------------------------------------

encrypt_host_backups() {

    [[ "$ENCRYPT" -eq 1 ]] || return 0

    if [[ "$HOST_COPY_SUCCESS" -ne 1 ]]; then
        echo_error "Cannot encrypt because host copy was not successful"
        exit 1
    fi

    command -v gpg >/dev/null 2>&1 || {
        echo_error "GPG is not installed"
        exit 1
    }

    [[ -n "${BACKUP_PASSPHRASE:-}" ]] || {
        echo_error "BACKUP_PASSPHRASE is not set"
        exit 1
    }

    local encrypted=0
    local backup_file

    for backup_file in "${HOST_RUN_FILES[@]}"; do

        [[ -f "$backup_file" ]] || continue

        if printf '%s' "$BACKUP_PASSPHRASE" |
            gpg \
                --batch \
                --yes \
                --passphrase-fd 0 \
                --symmetric \
                --cipher-algo AES256 \
                -o "${backup_file}.gpg" \
                "$backup_file"; then

            rm -f "$backup_file"

            encrypted=$((encrypted + 1))

            echo_info "  ✓ Encrypted $(basename "${backup_file}.gpg")"

        else
            echo_error "  ✗ Encryption failed for $(basename "$backup_file")"
            exit 1
        fi
    done

    echo_info "Encrypted $encrypted file(s)"
    log_action "SUCCESS: Encrypted $encrypted files"
}

# ---------------------------------------------------------------------------
# Remove container backups
# ---------------------------------------------------------------------------

remove_container_backups() {

    [[ "$HOST_ONLY" -eq 1 ]] || return 0

    if [[ "$HOST_COPY_SUCCESS" -ne 1 ]]; then
        echo_error "Refusing host-only cleanup because host copy was not successful"
        exit 1
    fi

    echo_info "Removing container backups (host-only mode)"

    dc_exec bash -lc \
        "find '$BACKUP_PATH' -maxdepth 1 -type f -delete"
}

# ---------------------------------------------------------------------------
# Verify backup
# ---------------------------------------------------------------------------

verify_backup_presence() {

    if [[ "$AUTO_COPY" -eq 1 ]]; then

        if [[ "$HOST_COPY_SUCCESS" -ne 1 ]] ||
            [[ ${#HOST_RUN_FILES[@]} -eq 0 ]]; then

            echo_error "Host backup missing after copy"
            exit 1
        fi

        local backup_file

        for backup_file in "${HOST_RUN_FILES[@]}"; do

            if [[ -f "$backup_file" ]] ||
                [[ -f "${backup_file}.gpg" ]]; then
                continue
            fi

            echo_error "Host backup file missing: $(basename "$backup_file")"
            exit 1
        done

    else

        local base

        for base in "${BACKUP_BASENAMES[@]}"; do

            if ! dc_exec test -f "$BACKUP_PATH/$base"; then
                echo_error "Container backup file missing: $base"
                exit 1
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Host summary
# ---------------------------------------------------------------------------

print_host_summary() {

    if [[ "$AUTO_COPY" -ne 1 ]]; then
        echo_info "Use --auto-copy to mirror backups onto host storage"
        return
    fi

    if [[ "$HOST_LAYOUT_MODE" == "nested" ]]; then

        echo_info "Latest host backups:"

        ls -lht "$HOST_SITE_ROOT" 2>/dev/null |
            head -n 6 ||
            true

    else

        echo_info "Latest host backup files:"

        if [[ -d "$HOST_BACKUP_ROOT" ]]; then
            (
                ls -lht "$HOST_BACKUP_ROOT" 2>/dev/null |
                    grep "$SITE_FILE_KEY" |
                    head -n 6
            ) || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Runtime values
# ---------------------------------------------------------------------------

SITE_NAME=""

WITH_FILES=0
COMPRESS=0
ENCRYPT=0

DEBUG="${DEBUG:-0}"

CLEANUP_MODE=""
CLEANUP_VALUE=""

HOST_LAYOUT_OVERRIDE=""
HOST_LAYOUT_MODE=""

HOST_SITE_ROOT=""

SITE_SAFE_NAME=""
SITE_FILE_KEY=""

BACKUP_PATH=""
MARKER=""
CURRENT_PREFIX=""

BACKEND_CONTAINER=""

HOST_COPY_SUCCESS=0
HOST_RUN_DIR=""

TOTAL_SIZE=0

declare -a BACKUP_FILES=()
declare -a BACKUP_BASENAMES=()
declare -a HOST_RUN_FILES=()

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do

    case "$1" in

        -h|--help)
            show_help
            exit 0
            ;;

        --with-files)
            WITH_FILES=1
            shift
            ;;

        --compress)
            COMPRESS=1
            shift
            ;;

        --auto-copy)
            AUTO_COPY=1
            shift
            ;;

        --host-only)
            HOST_ONLY=1
            AUTO_COPY=1
            shift
            ;;

        --flat-host-path)
            AUTO_COPY=1
            HOST_LAYOUT_OVERRIDE="flat"
            shift
            ;;

        --nested-host-path)
            AUTO_COPY=1
            HOST_LAYOUT_OVERRIDE="nested"
            shift
            ;;

        --cleanup-old)

            CLEANUP_OLD=1

            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                CLEANUP_POLICY="$2"
                shift 2
            else
                shift
            fi
            ;;

        --cleanup-old=*)
            CLEANUP_OLD=1
            CLEANUP_POLICY="${1#*=}"
            shift
            ;;

        --retention-days)

            CLEANUP_OLD=1

            [[ -n "${2:-}" ]] || {
                echo_error "--retention-days requires a value"
                exit 1
            }

            CLEANUP_POLICY="$2"

            shift 2
            ;;

        --retention-days=*)
            CLEANUP_OLD=1
            CLEANUP_POLICY="${1#*=}"
            shift
            ;;

        --encrypt)
            ENCRYPT=1
            shift
            ;;

        --debug)
            DEBUG=1
            shift
            ;;

        *)
            if [[ -z "$SITE_NAME" ]]; then
                SITE_NAME="$1"
                shift
            else
                echo_error "Unknown argument: $1"
                show_help
                exit 1
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Site validation
# ---------------------------------------------------------------------------

if [[ -z "$SITE_NAME" ]]; then
    read -r -p "Enter site name (e.g., erp.example.com): " SITE_NAME
fi

[[ -n "$SITE_NAME" ]] || {
    echo_error "Site name is required"
    exit 1
}

if [[ ! "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo_error "BACKUP_RETENTION_DAYS must be a non-negative integer"
    exit 1
fi

# ---------------------------------------------------------------------------
# Host layout
# ---------------------------------------------------------------------------

HOST_LAYOUT_MODE="${HOST_LAYOUT_OVERRIDE:-$HOST_BACKUP_LAYOUT}"
HOST_LAYOUT_MODE="${HOST_LAYOUT_MODE,,}"

case "$HOST_LAYOUT_MODE" in
    flat|nested)
        ;;
    *)
        echo_warn "Unknown HOST_BACKUP_LAYOUT '$HOST_LAYOUT_MODE', defaulting to flat"
        HOST_LAYOUT_MODE="flat"
        ;;
esac

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------

SITE_SAFE_NAME="${SITE_NAME//[^A-Za-z0-9._-]/_}"
SITE_FILE_KEY="$(echo "$SITE_NAME" | sed 's/[^A-Za-z0-9]/_/g')"

HOST_SITE_ROOT="$HOST_BACKUP_ROOT/$SITE_SAFE_NAME"

BACKUP_PATH="/home/frappe/frappe-bench/sites/$SITE_NAME/private/backups"

MARKER="/tmp/backup-${SITE_NAME//[^A-Za-z0-9]/-}-$$.marker"

set_policy "$CLEANUP_POLICY"

# ---------------------------------------------------------------------------
# Basic Docker checks
# ---------------------------------------------------------------------------

echo_debug "Site: $SITE_NAME"
echo_debug "Project: $PROJECT_NAME"
echo_debug "Compose file: $COMPOSE_PATH"
echo_debug "Backup path: $BACKUP_PATH"

docker info >/dev/null 2>&1 || {
    echo_error "Docker is not running"
    exit 1
}

dc_exec echo "test" >/dev/null 2>&1 || {
    echo_error "Backend container is not running"
    exit 1
}

# ---------------------------------------------------------------------------
# Verify site exists
# ---------------------------------------------------------------------------

echo_info "Verifying site: $SITE_NAME"

if ! dc_exec bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
    echo_error "Site '$SITE_NAME' was not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create timestamp marker
# ---------------------------------------------------------------------------

dc_exec bash -lc "touch '$MARKER'"

# ---------------------------------------------------------------------------
# Create backup
# ---------------------------------------------------------------------------

echo_info "Creating backup for: $SITE_NAME"
log_action "STARTED: $SITE_NAME"

bench_cmd=(
    bench
    --site "$SITE_NAME"
    backup
)

if (( WITH_FILES )); then
    bench_cmd+=(--with-files)
fi

if (( COMPRESS )); then
    bench_cmd+=(--compress)
fi

if ! dc_exec "${bench_cmd[@]}"; then
    echo_error "Backup command failed"
    log_action "FAILED: backup command"
    exit 1
fi

# ---------------------------------------------------------------------------
# Find files created by this backup
# ---------------------------------------------------------------------------

mapfile -t BACKUP_FILES < <(
    dc_exec bash -lc \
        "find '$BACKUP_PATH' -maxdepth 1 -type f -newer '$MARKER' -print"
) || true

dc_exec bash -lc "rm -f '$MARKER'" || true

if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
    echo_error "No backup files detected"
    log_action "FAILED: no files"
    exit 1
fi

# ---------------------------------------------------------------------------
# Report backup contents
# ---------------------------------------------------------------------------

TOTAL_SIZE=0

local_file_path=""
base=""
size_bytes=""
size_hr=""

for local_file_path in "${BACKUP_FILES[@]}"; do

    [[ -z "$local_file_path" ]] && continue

    base="$(basename "$local_file_path")"

    BACKUP_BASENAMES+=("$base")

    size_bytes="$(
        dc_exec stat -c%s "$local_file_path" 2>/dev/null |
            tr -d '\r' ||
            echo "0"
    )"

    [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0

    TOTAL_SIZE=$((TOTAL_SIZE + size_bytes))

    size_hr="$(
        numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null ||
            echo "$size_bytes bytes"
    )"

    echo_info "  - $base ($size_hr)"
done

CURRENT_PREFIX="${BACKUP_BASENAMES[0]%%-*}"

if [[ -z "$CURRENT_PREFIX" ]]; then
    CURRENT_PREFIX="$(date '+%Y%m%d_%H%M%S')"
fi

if [[ "$TOTAL_SIZE" -gt 0 ]]; then
    echo_info "Total backup size: $(
        numfmt --to=iec-i --suffix=B "$TOTAL_SIZE" 2>/dev/null ||
            echo "$TOTAL_SIZE bytes"
    )"
fi

log_action "SUCCESS: ${#BACKUP_FILES[@]} files, $TOTAL_SIZE bytes"

# ---------------------------------------------------------------------------
# Copy to host
# ---------------------------------------------------------------------------

if [[ "$AUTO_COPY" -eq 1 ]]; then

    if [[ "$HOST_LAYOUT_MODE" == "nested" ]]; then
        echo_info "Copying backups to $HOST_SITE_ROOT/$CURRENT_PREFIX"
    else
        echo_info "Copying backups to $HOST_BACKUP_ROOT"
    fi

    copy_backups_to_host
    encrypt_host_backups

else

    echo_info "Backups stored inside container:"
    echo_info "  $BACKUP_PATH"
fi

# ---------------------------------------------------------------------------
# Host-only mode
# ---------------------------------------------------------------------------

remove_container_backups

# ---------------------------------------------------------------------------
# Cleanup old backups
# ---------------------------------------------------------------------------

if [[ "$CLEANUP_OLD" -eq 1 ]]; then

    if [[ "$CLEANUP_MODE" == "days" ]]; then

        cleanup_container_days "$CLEANUP_VALUE"

        if [[ "$AUTO_COPY" -eq 1 ]]; then
            cleanup_host_days "$CLEANUP_VALUE"
        fi

    elif [[ "$CLEANUP_MODE" == "keep" ]]; then

        cleanup_container_keep "$CLEANUP_VALUE"

        if [[ "$AUTO_COPY" -eq 1 ]]; then
            cleanup_host_keep "$CLEANUP_VALUE"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

verify_backup_presence
print_host_summary

echo ""
echo_info "✓ Backup completed successfully!"
log_action "COMPLETED: $SITE_NAME"