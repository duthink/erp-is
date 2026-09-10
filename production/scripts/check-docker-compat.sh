#!/bin/bash

# Docker / Traefik API Compatibility Preflight Check
# Usage: ./check-docker-compat.sh [--fix]
#
# Run this BEFORE and AFTER every OS/Docker package update, on local, staging
# AND production. Prevents a repeat of the Nov 13 2025 incident where Docker
# 29.0.0 raised its default minimum API version from 1.24 to 1.44 and broke
# Traefik's Docker provider (Traefik negotiates starting at API 1.24).
#
# Background: production/troubleshooting/docker-api-compatibility-fix.md
#
# Exit codes:
#   0 - all checks passed
#   1 - drift detected (see output) - do NOT proceed with the update/rollout

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$PRODUCTION_DIR/docker-daemon.json.example"
DAEMON_JSON="/etc/docker/daemon.json"
REQUIRED_MIN_API="1.24"
errors=0

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << EOF
Usage: $0 [--fix]

Checks that this host's Docker daemon accepts the API version Traefik needs
(min-api-version=$REQUIRED_MIN_API) and that /etc/docker/daemon.json is
configured to survive future Docker engine upgrades.

Options:
  --fix       Copy $TEMPLATE to $DAEMON_JSON and restart docker (requires sudo)
  -h, --help  Show this help

Run on: local dev machine, staging server, production server.
Run when: before AND after any 'apt upgrade'/Docker engine update.
EOF
    exit 0
fi

command -v docker &> /dev/null || { echo_error "docker not installed"; exit 1; }

echo_info "Docker version summary:"
docker version || true
echo ""

MIN_API=$(docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null || echo "unknown")
ENGINE_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
echo_info "Docker Engine version: $ENGINE_VERSION"
echo_info "Docker daemon minimum API version: $MIN_API"

if [[ "$MIN_API" == "unknown" ]]; then
    echo_error "Could not query the Docker daemon (is it running / do you have permission?)"
    ((errors++))
elif [[ "$MIN_API" != "$REQUIRED_MIN_API" ]]; then
    echo_error "Minimum API version is $MIN_API, expected $REQUIRED_MIN_API."
    echo_error "Traefik's Docker provider negotiates starting at 1.24 and will be rejected."
    ((errors++))
else
    echo_info "Minimum API version OK ($REQUIRED_MIN_API)"
fi

if [[ ! -f "$DAEMON_JSON" ]]; then
    echo_error "$DAEMON_JSON is missing."
    echo_error "  Fix: sudo cp $TEMPLATE $DAEMON_JSON && sudo systemctl restart docker"
    ((errors++))
elif command -v jq &> /dev/null; then
    configured=$(jq -r '."min-api-version" // empty' "$DAEMON_JSON" 2>/dev/null || true)
    if [[ "$configured" != "$REQUIRED_MIN_API" ]]; then
        echo_error "$DAEMON_JSON does not pin min-api-version=$REQUIRED_MIN_API (found: '${configured:-unset}')"
        ((errors++))
    else
        echo_info "$DAEMON_JSON correctly pins min-api-version=$REQUIRED_MIN_API"
    fi
else
    echo_warn "jq not installed, skipping content check of $DAEMON_JSON (file exists)"
fi

# If Traefik is running, check its logs for the exact error signature from the incident
TRAEFIK_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i '^traefik' | head -1 || true)
if [[ -n "$TRAEFIK_CONTAINER" ]]; then
    if docker logs --since 5m "$TRAEFIK_CONTAINER" 2>&1 | grep -qi "too old\|Minimum supported API version"; then
        echo_error "Traefik container '$TRAEFIK_CONTAINER' is currently logging Docker API errors."
        ((errors++))
    else
        echo_info "Traefik container '$TRAEFIK_CONTAINER' has no recent Docker API errors"
    fi
else
    echo_warn "No running Traefik container found (skipped log check)"
fi

if [[ "${1:-}" == "--fix" ]]; then
    [[ -f "$TEMPLATE" ]] || { echo_error "Template $TEMPLATE not found"; exit 1; }
    echo_info "Applying $TEMPLATE to $DAEMON_JSON (requires sudo)..."
    sudo mkdir -p "$(dirname "$DAEMON_JSON")"
    sudo cp "$TEMPLATE" "$DAEMON_JSON"
    sudo systemctl restart docker
    echo_info "Done. Re-run $0 (without --fix) to confirm."
    exit 0
fi

echo ""
if [[ $errors -gt 0 ]]; then
    echo_error "$errors issue(s) found. Do not proceed with the rollout on this host."
    echo_error "See production/troubleshooting/docker-api-compatibility-fix.md and re-run with --fix."
    exit 1
fi

echo_info "All checks passed. Safe to proceed."
