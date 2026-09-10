#!/bin/bash

# View ERPNext Logs
#
# Usage:
#   ./logs.sh
#   ./logs.sh backend
#   ./logs.sh backend --tail 50
#   ./logs.sh --tail=200
#
# Services:
#   backend, frontend, websocket, queue-short, queue-long, scheduler, all

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ---------------------------------------------------------------------------
# Directories / environment
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PRODUCTION_DIR" || exit 1

if [[ ! -f "production.env" ]]; then
    echo_error "production.env not found!"
    exit 1
fi

# shellcheck disable=SC1091
source production.env

PROJECT_NAME="${ROUTER:-erpnext-production}"
COMPOSE_FILE="${COMPOSE_FILE:-production.yaml}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo_error "$COMPOSE_FILE not found!"
    echo_info "Run: ./scripts/deploy.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Runtime defaults
# ---------------------------------------------------------------------------

FOLLOW_MODE="follow"
TAIL_LINES=200
SERVICE_ARG=""

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

show_help() {
    cat << EOF
Usage:
  $0 [service] [options]

Services:
  1 or backend       Gunicorn backend
  2 or frontend      Nginx frontend
  3 or websocket     Socket.io service
  4 or queue-short   Short queue worker
  5 or queue-long    Long queue worker
  6 or scheduler     Background scheduler
  7 or all           All ERPNext services

Options:
  --tail[=N]         Show the last N log lines and exit
  --lines N          Alias for --tail N
  -h, --help         Show this help

Examples:
  $0
      Interactive menu; follow logs

  $0 backend
      Follow backend logs

  $0 backend --tail 50
      Show last 50 backend log lines

  $0 --tail=200
      Show last 200 lines for all services

  $0 all --tail 100
      Show last 100 lines from all services

Project:
  Docker Compose project: $PROJECT_NAME
  Compose file: $COMPOSE_FILE

Press Ctrl+C to stop following logs.
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do

    case "$1" in

        --tail)
            FOLLOW_MODE="tail"

            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                TAIL_LINES="$2"
                shift 2
            else
                shift
            fi
            ;;

        --tail=*)
            FOLLOW_MODE="tail"
            VALUE="${1#*=}"

            [[ "$VALUE" =~ ^[0-9]+$ ]] || {
                echo_error "--tail expects a non-negative integer"
                exit 1
            }

            TAIL_LINES="$VALUE"
            shift
            ;;

        --lines)
            [[ "${2:-}" =~ ^[0-9]+$ ]] || {
                echo_error "--lines expects a non-negative integer"
                exit 1
            }

            TAIL_LINES="$2"
            FOLLOW_MODE="tail"
            shift 2
            ;;

        -h|--help)
            show_help
            exit 0
            ;;

        -*)
            echo_error "Unknown option: $1"
            echo_info "Use '$0 --help' for usage."
            exit 1
            ;;

        *)
            if [[ -z "$SERVICE_ARG" ]]; then
                SERVICE_ARG="$1"
                shift
            else
                echo_error "Multiple services specified: '$SERVICE_ARG' and '$1'"
                exit 1
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Select service
# ---------------------------------------------------------------------------

if [[ -z "$SERVICE_ARG" ]]; then

    if [[ "$FOLLOW_MODE" == "tail" ]]; then
        INPUT="all"
    else
        echo ""
        echo_info "Available ERPNext services:"
        echo "  1. backend"
        echo "  2. frontend"
        echo "  3. websocket"
        echo "  4. queue-short"
        echo "  5. queue-long"
        echo "  6. scheduler"
        echo "  7. all"
        echo ""

        read -r -p "Enter number or service name: " INPUT
    fi

else

    INPUT="$SERVICE_ARG"
fi

# ---------------------------------------------------------------------------
# Map service aliases
# ---------------------------------------------------------------------------

case "$INPUT" in
    1|backend)
        SERVICE="backend"
        ;;

    2|frontend)
        SERVICE="frontend"
        ;;

    3|websocket)
        SERVICE="websocket"
        ;;

    4|queue-short)
        SERVICE="queue-short"
        ;;

    5|queue-long)
        SERVICE="queue-long"
        ;;

    6|scheduler)
        SERVICE="scheduler"
        ;;

    7|all)
        SERVICE=""
        ;;

    *)
        echo_error "Invalid service: $INPUT"
        echo_info "Use 1-7 or a valid service name."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Docker checks
# ---------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || {
    echo_error "Docker is not installed."
    exit 1
}

docker compose version >/dev/null 2>&1 || {
    echo_error "Docker Compose V2 is not available."
    exit 1
}

if ! docker info >/dev/null 2>&1; then
    echo_error "Docker daemon is not available."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check ERPNext project
# ---------------------------------------------------------------------------

if ! docker compose \
    --project-name "$PROJECT_NAME" \
    -f "$COMPOSE_FILE" \
    ps -q >/dev/null 2>&1; then

    echo_error "Unable to access Compose project: $PROJECT_NAME"
    exit 1
fi

# Backend is the best indicator that the ERPNext environment exists.
BACKEND_CONTAINER="$(
    docker compose \
        --project-name "$PROJECT_NAME" \
        -f "$COMPOSE_FILE" \
        ps -q backend 2>/dev/null ||
        true
)"

if [[ -z "$BACKEND_CONTAINER" ]]; then
    echo_warn "No backend container found for project '$PROJECT_NAME'."
    echo_info "Check deployment with:"
    echo_info "  docker compose --project-name $PROJECT_NAME -f $COMPOSE_FILE ps"
    exit 1
fi

# ---------------------------------------------------------------------------
# Display selected target
# ---------------------------------------------------------------------------

echo_info "Project: $PROJECT_NAME"

if [[ -n "$SERVICE" ]]; then
    echo_info "Logs for: $SERVICE"
else
    echo_info "Logs for: all services"
fi

# ---------------------------------------------------------------------------
# Show logs
# ---------------------------------------------------------------------------

if [[ "$FOLLOW_MODE" == "follow" ]]; then

    echo_info "Streaming logs — press Ctrl+C to exit."

    if [[ -n "$SERVICE" ]]; then
        docker compose \
            --project-name "$PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            logs -f "$SERVICE"
    else
        docker compose \
            --project-name "$PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            logs -f
    fi

else

    echo_info "Showing last $TAIL_LINES log lines."

    if [[ -n "$SERVICE" ]]; then
        docker compose \
            --project-name "$PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            logs --tail "$TAIL_LINES" "$SERVICE"
    else
        docker compose \
            --project-name "$PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            logs --tail "$TAIL_LINES"
    fi
fi