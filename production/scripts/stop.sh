#!/bin/bash

# Stop ERPNext Services
#
# Usage:
#   ./stop.sh
#   ./stop.sh --all
#   ./stop.sh --help
#
# Normal behavior:
#   Stops ONLY the current ERPNext Compose project.
#
# Shared infrastructure:
#   Traefik and MariaDB are shared by staging and production.
#   They are intentionally NOT stopped by default.
#
# Use --all only for a deliberate full-host shutdown/maintenance operation.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helpers
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Navigate to production directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$PRODUCTION_DIR")"

cd "$PRODUCTION_DIR" || exit 1

# Load environment
if [[ ! -f "production.env" ]]; then
    echo_error "production.env not found!"
    exit 1
fi

# shellcheck disable=SC1091
source production.env

PROJECT_NAME="${ROUTER:-erpnext-production}"

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --all         Stop ERPNext, shared MariaDB, and shared Traefik
  -h, --help    Show this help

Default:
  Stops ONLY the ERPNext services belonging to this deployment project.

Examples:
  $0
      Stop this ERPNext environment only.

  $0 --all
      Stop this ERPNext environment plus shared MariaDB and Traefik.
      Use only for deliberate full-host maintenance.

Important:
  Staging and production share the same MariaDB and Traefik containers.
  Stopping shared infrastructure affects BOTH environments.
EOF
    exit 0
fi

# Reject unexpected arguments
if [[ $# -gt 1 ]] || [[ "${1:-}" != "" && "${1:-}" != "--all" ]]; then
    echo_error "Unknown option: ${1:-}"
    echo_info "Use --help for usage."
    exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || {
    echo_error "Docker is not installed."
    exit 1
}

docker compose version >/dev/null 2>&1 || {
    echo_error "Docker Compose V2 is not available."
    exit 1
}

if [[ ! -f "production.yaml" ]]; then
    echo_warn "production.yaml not found."
    echo_info "ERPNext services may already be stopped or deployment has not been generated."
else
    echo_info "Compose project: $PROJECT_NAME"
fi

# ---------------------------------------------------------------------------
# Stop current ERPNext environment
# ---------------------------------------------------------------------------

echo_info "Stopping ERPNext services for project: $PROJECT_NAME"

if docker compose \
    --project-name "$PROJECT_NAME" \
    -f production.yaml \
    ps -q 2>/dev/null | grep -q .; then

    docker compose \
        --project-name "$PROJECT_NAME" \
        -f production.yaml \
        down

    echo_info "✓ ERPNext services stopped."
else
    echo_warn "No running ERPNext services found for project: $PROJECT_NAME"
fi

# ---------------------------------------------------------------------------
# Optional shared infrastructure shutdown
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--all" ]]; then

    echo ""
    echo_warn "WARNING: MariaDB and Traefik are shared infrastructure."
    echo_warn "Stopping them will affect BOTH staging and production."

    read -r -p "Type STOP-SHARED to continue: " CONFIRM

    if [[ "$CONFIRM" != "STOP-SHARED" ]]; then
        echo_info "Shared infrastructure shutdown cancelled."
        echo_info "The ERPNext project has already been stopped."
        exit 0
    fi

    # Check whether mariadb.env and traefik.env exist before attempting shutdown.
    if [[ ! -f "mariadb.env" ]]; then
        echo_error "mariadb.env not found; refusing to stop MariaDB."
        exit 1
    fi

    if [[ ! -f "traefik.env" ]]; then
        echo_error "traefik.env not found; refusing to stop Traefik."
        exit 1
    fi

    echo_info "Stopping shared MariaDB..."

    docker compose \
        --project-name mariadb \
        --env-file mariadb.env \
        -f "$PROJECT_ROOT/overrides/compose.mariadb-shared.yaml" \
        down

    echo_info "✓ Shared MariaDB stopped."

    echo_info "Stopping shared Traefik..."

    docker compose \
        --project-name traefik \
        --env-file traefik.env \
        -f "$PROJECT_ROOT/overrides/compose.traefik.yaml" \
        -f "$PROJECT_ROOT/overrides/compose.traefik-ssl.yaml" \
        down

    echo_info "✓ Shared Traefik stopped."
fi

echo ""
echo_info "✓ Stop operation complete."

if [[ "${1:-}" != "--all" ]]; then
    echo_info "Shared MariaDB and Traefik were left running."
fi

echo_info "Restart this environment with: ./scripts/deploy.sh"
