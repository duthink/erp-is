#!/bin/bash

# ERPNext Deployment Script
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --setup
#   ./deploy.sh --regenerate
#   ./deploy.sh --skip-infra
#
# Deployment model:
#   - Images are built and tested outside the server
#   - Git changes are made locally and pushed to GitHub
#   - Staging and production servers are deployment targets only
#   - Staging and production use separate Docker Compose projects
#   - Traefik and MariaDB are shared infrastructure
#   - The same immutable custom image is promoted from staging to production

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helpers
echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$PRODUCTION_DIR")"

cd "$PRODUCTION_DIR" || exit 1

# Defaults
MODE="deploy"
SKIP_INFRA="false"

# Load environment
if [[ -f "production.env" ]]; then
    # shellcheck disable=SC1091
    source production.env
fi

COMPOSE_PROJECT_NAME="${ROUTER:-erpnext-production}"

# Parse arguments
case "${1:-}" in
    --help|-h)
        cat << EOF
Usage: $0 [OPTIONS]

Options:
  --setup       Setup environment files from templates
  --regenerate  Regenerate production.yaml only (do not deploy)
  --skip-infra  Skip Traefik and MariaDB deployment
  --help, -h    Show this help

Examples:
  $0
  $0 --setup
  $0 --skip-infra
  $0 --regenerate

Deployment model:
  1. Build/test the custom image outside the server
  2. Push the immutable image tag to the registry
  3. Deploy that image to staging
  4. Perform UAT
  5. Promote the same immutable image to production
  6. Do not build images or merge Git branches on the server

Notes:
  --skip-infra is intended for staging on the same host as production,
  where Traefik and MariaDB are already provided by shared infrastructure.
EOF
        exit 0
        ;;
    --setup)
        MODE="setup"
        ;;
    --regenerate)
        MODE="regenerate"
        ;;
    --skip-infra)
        MODE="deploy"
        SKIP_INFRA="true"
        ;;
    "")
        MODE="deploy"
        SKIP_INFRA="false"
        ;;
    *)
        echo_error "Unknown option: $1 (use --help)"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Setup mode
# ---------------------------------------------------------------------------

if [[ "$MODE" == "setup" ]]; then
    echo_info "Setting up environment files..."

    [[ ! -f "production.env.example" ]] && {
        echo_error "Template files missing!"
        exit 1
    }

    for template in production.env.example traefik.env.example mariadb.env.example; do
        target="${template%.example}"

        if [[ -f "$target" ]]; then
            echo_warn "$target exists, skipping..."
        else
            cp "$template" "$target"
            chmod 600 "$target"
            echo_info "✓ Created $target"
        fi
    done

    echo ""
    echo_info "Edit these files before deploying:"
    echo_info "  1. production.env - SITES, image reference, project/network settings"
    echo_info "  2. mariadb.env    - DB_PASSWORD"
    echo_info "  3. traefik.env    - domain, email, credentials"
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] && {
    echo_error "Do not run this script as root."
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo_error "Docker is not installed."
    exit 1
}

docker compose version >/dev/null 2>&1 || {
    echo_error "Docker Compose V2 is not available."
    exit 1
}

echo_info "ERPNext Deployment"
echo_info "Compose Project: $COMPOSE_PROJECT_NAME"

# ---------------------------------------------------------------------------
# Required environment files
# ---------------------------------------------------------------------------

for file in production.env traefik.env mariadb.env; do
    [[ ! -f "$file" ]] && {
        echo_error "$file not found!"
        echo_info "Run: $0 --setup"
        exit 1
    }
done

# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------

echo_info "Validating configuration..."

./scripts/validate-env.sh || {
    echo_error "Environment validation failed."
    exit 1
}

# ---------------------------------------------------------------------------
# Validate custom image configuration
# ---------------------------------------------------------------------------

if [[ -z "${CUSTOM_IMAGE:-}" ]]; then
    echo_error "CUSTOM_IMAGE is not set in production.env."
    exit 1
fi

if [[ -z "${CUSTOM_TAG:-}" ]]; then
    echo_error "CUSTOM_TAG is not set in production.env."
    exit 1
fi

IMAGE_REFERENCE="${CUSTOM_IMAGE}:${CUSTOM_TAG}"

echo_info "Custom image: $IMAGE_REFERENCE"

# Mutable tags are not acceptable for controlled promotion.
case "$CUSTOM_TAG" in
    latest|production-latest|staging-latest)
        echo_error "Mutable image tag detected: $CUSTOM_TAG"
        echo_error "Use an immutable release tag, e.g. v16.34.2-build.20260910"
        echo_error "The same immutable image must be promoted from staging to production."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Warn about placeholder values
# ---------------------------------------------------------------------------

if grep -q "changeit" production.env mariadb.env traefik.env 2>/dev/null; then
    echo_warn "Default password(s) detected."

    read -r -p "Have all default passwords been updated? (yes/no): " CONFIRM

    [[ "$CONFIRM" != "yes" ]] && {
        echo_error "Update the default passwords before deploying."
        exit 1
    }
fi

if grep -qE "yourdomain\.com|CHANGEME_" production.env traefik.env 2>/dev/null; then
    echo_warn "Default domain/placeholder values detected."

    read -r -p "Have all domain values been updated? (yes/no): " CONFIRM

    [[ "$CONFIRM" != "yes" ]] && {
        echo_error "Update the domain values before deploying."
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Generate production.yaml
# ---------------------------------------------------------------------------

generate_yaml() {
    if [[ -f "production.yaml" ]]; then
        BACKUP_FILE="production.yaml.backup.$(date +%Y%m%d_%H%M%S)"
        cp production.yaml "$BACKUP_FILE"
        echo_info "Backed up existing production.yaml to $BACKUP_FILE"
    fi

    docker compose \
        --project-name "$COMPOSE_PROJECT_NAME" \
        --env-file production.env \
        -f "$PROJECT_ROOT/compose.yaml" \
        -f "$PROJECT_ROOT/overrides/compose.redis.yaml" \
        -f "$PROJECT_ROOT/overrides/compose.multi-bench.yaml" \
        -f "$PROJECT_ROOT/overrides/compose.multi-bench-ssl.yaml" \
        config > production.yaml

    # Validate the generated Compose file.
    docker compose \
        --project-name "$COMPOSE_PROJECT_NAME" \
        -f production.yaml \
        config --quiet
}

# ---------------------------------------------------------------------------
# Regenerate-only mode
# ---------------------------------------------------------------------------

if [[ "$MODE" == "regenerate" ]]; then
    echo_info "Regenerating production.yaml..."

    generate_yaml

    echo_info "✓ production.yaml regenerated successfully."
    echo_info "No containers were started or changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Deploy shared infrastructure
# ---------------------------------------------------------------------------

echo ""

STEP=1

if [[ "$SKIP_INFRA" == "true" ]]; then

    echo_info "Step $STEP: Skipping shared infrastructure"
    echo_info "Traefik and MariaDB are expected to already be running."

    # Confirm shared MariaDB exists.
    if ! docker ps --format '{{.Names}}' | grep -qx "mariadb-database"; then
        echo_error "Shared MariaDB container 'mariadb-database' is not running."
        echo_error "Do not deploy staging without shared infrastructure."
        exit 1
    fi

    # Confirm shared Traefik exists.
    if ! docker ps --format '{{.Names}}' | grep -qx "traefik-traefik-1"; then
        echo_error "Shared Traefik container 'traefik-traefik-1' is not running."
        echo_error "Do not deploy staging without shared infrastructure."
        exit 1
    fi

    echo_info "✓ Shared MariaDB and Traefik are running."

else

    echo_info "Step $STEP: Deploying shared Traefik..."

    docker compose \
        --project-name traefik \
        --env-file traefik.env \
        -f "$PROJECT_ROOT/overrides/compose.traefik.yaml" \
        -f "$PROJECT_ROOT/overrides/compose.traefik-ssl.yaml" \
        up -d

    echo_info "✓ Traefik deployed."

    STEP=$((STEP + 1))

    echo_info "Step $STEP: Deploying shared MariaDB..."

    docker compose \
        --project-name mariadb \
        --env-file mariadb.env \
        -f "$PROJECT_ROOT/overrides/compose.mariadb-shared.yaml" \
        up -d

    echo_info "✓ MariaDB deployed."

    echo_info "Waiting for MariaDB to become available..."

    for attempt in {1..30}; do
        if docker exec mariadb-database \
            mariadb-admin ping \
            -uroot \
            -p"${DB_PASSWORD:-}" \
            --silent >/dev/null 2>&1; then
            echo_info "✓ MariaDB is ready."
            break
        fi

        if [[ "$attempt" -eq 30 ]]; then
            echo_error "MariaDB did not become ready within the expected time."
            exit 1
        fi

        sleep 2
    done

    STEP=$((STEP + 1))
fi

# ---------------------------------------------------------------------------
# Generate Compose configuration
# ---------------------------------------------------------------------------

echo_info "Step $STEP: Generating production.yaml..."

generate_yaml

echo_info "✓ production.yaml generated and validated."

STEP=$((STEP + 1))

# ---------------------------------------------------------------------------
# Show the image that will be deployed
# ---------------------------------------------------------------------------

echo_info "Step $STEP: Preparing ERPNext deployment..."

echo_info "Image:"
echo_info "  $IMAGE_REFERENCE"

if [[ -n "${PULL_POLICY:-}" ]]; then
    echo_info "Pull policy:"
    echo_info "  $PULL_POLICY"
fi

STEP=$((STEP + 1))

# ---------------------------------------------------------------------------
# Pull and deploy ERPNext
# ---------------------------------------------------------------------------

echo_info "Step $STEP: Pulling deployment image..."

docker compose \
    --project-name "$COMPOSE_PROJECT_NAME" \
    --env-file production.env \
    -f production.yaml \
    pull

echo_info "✓ Image pull completed."

echo_info "Starting ERPNext services..."

docker compose \
    --project-name "$COMPOSE_PROJECT_NAME" \
    --env-file production.env \
    -f production.yaml \
    up -d

echo_info "✓ ERPNext services started."

# ---------------------------------------------------------------------------
# Post-deployment verification
# ---------------------------------------------------------------------------

echo_info "Waiting for backend container..."

for attempt in {1..30}; do
    if docker compose \
        --project-name "$COMPOSE_PROJECT_NAME" \
        -f production.yaml \
        ps --status running 2>/dev/null |
        grep -q backend; then
        echo_info "✓ Backend container is running."
        break
    fi

    if [[ "$attempt" -eq 30 ]]; then
        echo_error "Backend container did not become healthy/running."
        echo_info "Check logs with: ./scripts/logs.sh"
        exit 1
    fi

    sleep 2
done

# Show deployed application versions when available.
echo ""
echo_info "Application versions:"

if docker compose \
    --project-name "$COMPOSE_PROJECT_NAME" \
    -f production.yaml \
    exec -T backend bench version 2>/dev/null; then
    :
else
    echo_warn "Could not read Bench application versions yet."
    echo_warn "The containers are running, but version verification was not available."
fi

# ---------------------------------------------------------------------------
# Success message
# ---------------------------------------------------------------------------

TRAEFIK_DOMAIN=""
if [[ -f "traefik.env" ]]; then
    TRAEFIK_DOMAIN="$(grep '^TRAEFIK_DOMAIN=' traefik.env | head -n 1 | cut -d'=' -f2- || true)"
fi

echo ""
echo_info "✓ Deployment complete!"
echo_info "Compose project: $COMPOSE_PROJECT_NAME"
echo_info "Image: $IMAGE_REFERENCE"

if [[ -n "$TRAEFIK_DOMAIN" ]]; then
    echo_info "Traefik: https://$TRAEFIK_DOMAIN"
fi

echo ""
echo_info "Useful checks:"
echo_info "  docker compose -f production.yaml ps"
echo_info "  ./scripts/logs.sh"
echo_info "  ./scripts/create-site.sh"

echo ""
echo_warn "Important:"
echo_warn "  This server is a deployment target only."
echo_warn "  Do not build images, merge branches, rebase, or resolve Git conflicts here."
echo_warn "  Promote the exact same immutable image from staging to production."
echo_warn "  SSL certificates may take a few minutes to provision."
