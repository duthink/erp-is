#!/bin/bash

# Docker / Traefik API Compatibility Preflight Check
#
# Usage:
#   ./check-docker-compat.sh
#   ./check-docker-compat.sh --fix
#
# Run BEFORE and AFTER Docker / OS package updates on:
#   - local development machine
#   - staging server
#   - production server
#
# Purpose:
#   Protect the Traefik Docker provider from Docker Engine API-version drift.
#
# The required minimum API version is pinned to 1.24 because that is the
# compatibility requirement documented for this deployment.
#
# Exit codes:
#   0 - all checks passed
#   1 - one or more blocking issues detected
#
# Background:
#   production/troubleshooting/docker-api-compatibility-fix.md

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
# Paths / configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"

TEMPLATE="$PRODUCTION_DIR/docker-daemon.json.example"
DAEMON_JSON="/etc/docker/daemon.json"

# Required minimum Docker Engine API version for this deployment.
REQUIRED_MIN_API="1.24"

errors=0
warnings=0

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then

    cat << EOF
Usage: $0 [OPTIONS]

Checks Docker / Traefik API compatibility.

Checks:
  - Docker daemon is reachable
  - Docker Engine minimum API version
  - /etc/docker/daemon.json exists
  - daemon.json pins min-api-version=$REQUIRED_MIN_API
  - running Traefik container has no recent Docker API errors

Options:
  --fix       Back up the current daemon.json, apply the repository template,
              restart Docker, then re-run the check
  -h, --help  Show this help

Run on:
  - local development machine
  - staging server
  - production server

Run when:
  - BEFORE Docker / OS package updates
  - AFTER Docker / OS package updates

Important:
  --fix changes the Docker daemon configuration and restarts Docker.
  On staging/production this may temporarily interrupt containers.
EOF

    exit 0
fi

# Reject unknown arguments.
if [[ $# -gt 1 || ("${1:-}" != "" && "${1:-}" != "--fix") ]]; then
    echo_error "Unknown option: ${1:-}"
    echo_info "Use --help for usage."
    exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo_error "Docker is not installed."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo_error "Could not access the Docker daemon."
    echo_error "Check that Docker is running and your user has permission."
    exit 1
fi

# ---------------------------------------------------------------------------
# Docker version information
# ---------------------------------------------------------------------------

echo_info "Docker version summary:"
docker version || true
echo ""

MIN_API="$(
    docker version \
        --format '{{.Server.MinAPIVersion}}' \
        2>/dev/null ||
        echo "unknown"
)"

ENGINE_VERSION="$(
    docker version \
        --format '{{.Server.Version}}' \
        2>/dev/null ||
        echo "unknown"
)"

echo_info "Docker Engine version: $ENGINE_VERSION"
echo_info "Docker daemon minimum API version: $MIN_API"

if [[ "$MIN_API" == "unknown" ]]; then

    echo_error "Could not determine Docker daemon minimum API version."
    errors=$((errors + 1))

elif [[ "$MIN_API" != "$REQUIRED_MIN_API" ]]; then

    echo_error "Docker daemon minimum API version is $MIN_API."
    echo_error "Expected $REQUIRED_MIN_API for this deployment."
    echo_error "Review the Docker / Traefik compatibility procedure before continuing."

    errors=$((errors + 1))

else

    echo_info "Docker minimum API version OK ($REQUIRED_MIN_API)"
fi

# ---------------------------------------------------------------------------
# daemon.json validation
# ---------------------------------------------------------------------------

if [[ ! -f "$DAEMON_JSON" ]]; then

    echo_error "$DAEMON_JSON is missing."
    echo_error "Expected configuration: min-api-version=$REQUIRED_MIN_API"
    echo_error "Template: $TEMPLATE"

    errors=$((errors + 1))

else

    echo_info "$DAEMON_JSON exists."

    if command -v jq >/dev/null 2>&1; then

        if ! jq empty "$DAEMON_JSON" >/dev/null 2>&1; then

            echo_error "$DAEMON_JSON is not valid JSON."
            errors=$((errors + 1))

        else

            CONFIGURED_MIN_API="$(
                jq -r '."min-api-version" // empty' \
                    "$DAEMON_JSON" 2>/dev/null ||
                    echo ""
            )"

            if [[ "$CONFIGURED_MIN_API" != "$REQUIRED_MIN_API" ]]; then

                echo_error \
                    "$DAEMON_JSON does not pin min-api-version=$REQUIRED_MIN_API"
                echo_error \
                    "Found: '${CONFIGURED_MIN_API:-unset}'"

                errors=$((errors + 1))

            else

                echo_info \
                    "$DAEMON_JSON correctly pins min-api-version=$REQUIRED_MIN_API"
            fi
        fi

    else

        echo_warn "jq is not installed."
        echo_warn "Skipping JSON content validation of $DAEMON_JSON."

        warnings=$((warnings + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Template validation
# ---------------------------------------------------------------------------

if [[ ! -f "$TEMPLATE" ]]; then

    echo_warn "Repository template not found: $TEMPLATE"
    echo_warn "The --fix option will not be available."

    warnings=$((warnings + 1))

elif command -v jq >/dev/null 2>&1; then

    if ! jq empty "$TEMPLATE" >/dev/null 2>&1; then

        echo_error "Template is not valid JSON: $TEMPLATE"
        errors=$((errors + 1))

    else

        TEMPLATE_MIN_API="$(
            jq -r '."min-api-version" // empty' \
                "$TEMPLATE" 2>/dev/null ||
                echo ""
        )"

        if [[ "$TEMPLATE_MIN_API" != "$REQUIRED_MIN_API" ]]; then

            echo_error \
                "Template does not define min-api-version=$REQUIRED_MIN_API"
            echo_error \
                "Found: '${TEMPLATE_MIN_API:-unset}'"

            errors=$((errors + 1))

        else

            echo_info "Docker daemon template is consistent."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Traefik container check
# ---------------------------------------------------------------------------

TRAEFIK_CONTAINER="$(
    docker ps \
        --format '{{.Names}}' 2>/dev/null |
        grep -i '^traefik' |
        head -n 1 ||
        true
)"

if [[ -n "$TRAEFIK_CONTAINER" ]]; then

    echo_info "Checking recent Traefik Docker API errors..."

    if docker logs \
        --since 5m \
        "$TRAEFIK_CONTAINER" 2>&1 |
        grep -Eqi \
            "too old|Minimum supported API version|client version .* too old"; then

        echo_error \
            "Traefik container '$TRAEFIK_CONTAINER' is reporting Docker API errors."

        errors=$((errors + 1))

    else

        echo_info \
            "Traefik container '$TRAEFIK_CONTAINER' has no recent Docker API errors."
    fi

else

    echo_warn "No running Traefik container found."
    echo_warn "Traefik log verification was skipped."

    warnings=$((warnings + 1))
fi

# ---------------------------------------------------------------------------
# --fix
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--fix" ]]; then

    echo ""

    if [[ ! -f "$TEMPLATE" ]]; then
        echo_error "Template not found: $TEMPLATE"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo_error "jq is required for --fix."
        echo_info "Install jq before applying the Docker daemon template."
        exit 1
    fi

    if ! jq empty "$TEMPLATE" >/dev/null 2>&1; then
        echo_error "Template is invalid JSON: $TEMPLATE"
        exit 1
    fi

    TEMPLATE_MIN_API="$(
        jq -r '."min-api-version" // empty' \
            "$TEMPLATE"
    )"

    if [[ "$TEMPLATE_MIN_API" != "$REQUIRED_MIN_API" ]]; then
        echo_error \
            "Refusing to apply template because min-api-version is '$TEMPLATE_MIN_API'."
        echo_error \
            "Expected '$REQUIRED_MIN_API'."
        exit 1
    fi

    echo_warn "Applying Docker daemon compatibility configuration."
    echo_warn "Docker will be restarted."

    # Back up current configuration when present.
    if [[ -f "$DAEMON_JSON" ]]; then

        BACKUP_FILE="${DAEMON_JSON}.backup.$(date +%Y%m%d_%H%M%S)"

        echo_info "Backing up current daemon.json to:"
        echo_info "  $BACKUP_FILE"

        sudo cp "$DAEMON_JSON" "$BACKUP_FILE"
    fi

    echo_info "Installing compatibility configuration..."

    sudo mkdir -p "$(dirname "$DAEMON_JSON")"
    sudo cp "$TEMPLATE" "$DAEMON_JSON"
    sudo chmod 644 "$DAEMON_JSON"

    echo_info "Validating installed daemon.json..."

    if ! sudo jq empty "$DAEMON_JSON" >/dev/null 2>&1; then
        echo_error "Installed daemon.json is invalid JSON."
        exit 1
    fi

    INSTALLED_MIN_API="$(
        sudo jq -r '."min-api-version" // empty' "$DAEMON_JSON"
    )"

    if [[ "$INSTALLED_MIN_API" != "$REQUIRED_MIN_API" ]]; then
        echo_error "Installed daemon.json has unexpected min-api-version."
        exit 1
    fi

    echo_info "Restarting Docker..."

    sudo systemctl restart docker

    echo_info "Docker restarted successfully."

    echo ""
    echo_info "Re-running compatibility check..."
    echo ""

    "$0"

    exit 0
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

echo ""
echo "=================================================="
echo "Docker / Traefik Compatibility Summary"
echo "=================================================="
echo ""

if [[ "$errors" -gt 0 ]]; then

    echo_error "$errors blocking issue(s) found."
    echo_warn "$warnings warning(s)."
    echo ""
    echo_error "Do NOT proceed with Docker/OS rollout on this host."
    echo_info \
        "Review production/troubleshooting/docker-api-compatibility-fix.md"

    exit 1

elif [[ "$warnings" -gt 0 ]]; then

    echo_warn "Compatibility checks passed with $warnings warning(s)."
    echo ""
    echo_info "Review warnings before making infrastructure changes."

    exit 0

else

    echo_info "All compatibility checks passed."
    echo ""
    echo_info "Safe to proceed with the planned Docker/OS update."

    exit 0
fi