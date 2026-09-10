#!/bin/bash

# Create ERPNext Site Script
# Usage:
#   ./create-site.sh <site-name> [admin-password]
#   ./create-site.sh <site-name> [admin-password] --with-hrms
#   ./create-site.sh <site-name> [admin-password] --with-india-compliance
#
# Examples:
#   ./create-site.sh erp.example.com
#   ./create-site.sh erp.example.com MySecurePass123
#   ./create-site.sh erp.example.com MySecurePass123 --with-hrms
#   ./create-site.sh erp.example.com MySecurePass123 --with-hrms --with-india-compliance

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper functions
echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage:
  $0 <site-name> [admin-password] [options]

Arguments:
  site-name                      Site domain (e.g. erp.example.com)
  admin-password                 Optional admin password

Options:
  --with-hrms                    Install HRMS on the new site
  --with-india-compliance        Install India Compliance on the new site
  -h, --help                     Show this help

Examples:
  $0 erp.example.com
  $0 erp.example.com MySecurePass123
  $0 erp.example.com MySecurePass123 --with-hrms
  $0 erp.example.com MySecurePass123 --with-hrms --with-india-compliance

Notes:
  - Requires the backend container to be running
  - Requires production.yaml to already exist
  - The image used by the backend must contain any requested optional apps
  - DNS should point to the server before accessing the site
  - Change the Administrator password after first login if appropriate
  - SSL certificate provisioning may take a few minutes
EOF
}

# Navigate to production directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PRODUCTION_DIR" || exit 1

# Load environment to get project name
if [[ -f "production.env" ]]; then
    # shellcheck disable=SC1091
    source production.env
else
    echo_error "production.env not found!"
    exit 1
fi

PROJECT_NAME="${ROUTER:-erpnext-production}"

# Defaults
SITE_NAME=""
ADMIN_PASSWORD=""
WITH_HRMS="no"
WITH_INDIA_COMPLIANCE="no"

# Parse arguments
POSITIONAL_ARGS=()

for ARG in "$@"; do
    case "$ARG" in
        -h|--help)
            usage
            exit 0
            ;;
        --with-hrms)
            WITH_HRMS="yes"
            ;;
        --with-india-compliance)
            WITH_INDIA_COMPLIANCE="yes"
            ;;
        -*)
            echo_error "Unknown option: $ARG"
            usage
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$ARG")
            ;;
    esac
done

# Get site name
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
    SITE_NAME="${POSITIONAL_ARGS[0]}"
else
    read -r -p "Enter site name (e.g., erp.example.com): " SITE_NAME
fi

[[ -z "$SITE_NAME" ]] && {
    echo_error "Site name cannot be empty"
    exit 1
}

# Get admin password
if [[ ${#POSITIONAL_ARGS[@]} -ge 2 ]]; then
    ADMIN_PASSWORD="${POSITIONAL_ARGS[1]}"
else
    read -r -s -p "Enter admin password (Enter for 'admin'): " ADMIN_PASSWORD
    echo

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD="admin"
        echo_warn "Using default password 'admin' - change it after login!"
    fi
fi

# Reject unexpected positional arguments
if [[ ${#POSITIONAL_ARGS[@]} -gt 2 ]]; then
    echo_error "Too many positional arguments."
    usage
    exit 1
fi

# Get DB password from mariadb.env
if [[ ! -f "mariadb.env" ]]; then
    echo_error "mariadb.env not found!"
    exit 1
fi

DB_ROOT_PASSWORD="$(grep -E '^DB_PASSWORD=' mariadb.env | head -n 1 | cut -d'=' -f2-)"

if [[ -z "$DB_ROOT_PASSWORD" ]]; then
    echo_error "DB_PASSWORD not found in mariadb.env"
    exit 1
fi

# Check if production.yaml exists
if [[ ! -f "production.yaml" ]]; then
    echo_error "production.yaml not found!"
    echo_info "Run: ./scripts/deploy.sh"
    exit 1
fi

# Check if backend is running
if ! docker compose -f production.yaml ps --status running 2>/dev/null | grep -q backend; then
    echo_error "Backend container is not running!"
    echo_info "Run: ./scripts/deploy.sh"
    exit 1
fi

echo_info "Project: $PROJECT_NAME"
echo_info "Creating site: $SITE_NAME"

if [[ "$WITH_HRMS" == "yes" ]]; then
    echo_info "Optional app: HRMS"
fi

if [[ "$WITH_INDIA_COMPLIANCE" == "yes" ]]; then
    echo_info "Optional app: India Compliance"
fi

# Check whether site already exists in this bench's sites volume
if docker compose -f production.yaml exec -T backend \
    test -d "sites/$SITE_NAME"; then

    echo_error "Site folder 'sites/$SITE_NAME' already exists in this bench!"
    echo_info "To recreate, first drop the site:"
    echo_info "  docker compose -f production.yaml exec backend bench drop-site $SITE_NAME --force"
    exit 1
fi

# Verify optional apps exist in the image before creating the site.
if [[ "$WITH_HRMS" == "yes" ]]; then
    if ! docker compose -f production.yaml exec -T backend \
        test -d "apps/hrms"; then
        echo_error "HRMS is not available in the running backend image."
        echo_info "Deploy an image containing HRMS before using --with-hrms."
        exit 1
    fi
fi

if [[ "$WITH_INDIA_COMPLIANCE" == "yes" ]]; then
    if ! docker compose -f production.yaml exec -T backend \
        test -d "apps/india_compliance"; then
        echo_error "India Compliance is not available in the running backend image."
        echo_info "Deploy an image containing India Compliance before using --with-india-compliance."
        exit 1
    fi
fi

# Build the bench new-site command
NEW_SITE_CMD=(
    bench
    new-site
    --mariadb-user-host-login-scope='%'
    --db-root-password
    "$DB_ROOT_PASSWORD"
    --install-app
    erpnext
    --admin-password
    "$ADMIN_PASSWORD"
    "$SITE_NAME"
)

# Create the site
docker compose -f production.yaml exec -T backend \
    "${NEW_SITE_CMD[@]}"

# Install optional applications after site creation
if [[ "$WITH_HRMS" == "yes" ]]; then
    echo_info "Installing HRMS..."
    docker compose -f production.yaml exec -T backend \
        bench --site "$SITE_NAME" install-app hrms
fi

if [[ "$WITH_INDIA_COMPLIANCE" == "yes" ]]; then
    echo_info "Installing India Compliance..."
    docker compose -f production.yaml exec -T backend \
        bench --site "$SITE_NAME" install-app india_compliance
fi

# Success message
echo ""
echo_info "Site created successfully!"
echo_info "URL: https://$SITE_NAME"
echo_info "Username: Administrator"
echo ""
echo_warn "Next steps:"
echo_warn "1. Ensure DNS for $SITE_NAME points to this server"
echo_warn "2. Ensure SITES in production.env includes this domain"
echo_warn "3. Log in and complete initial configuration"
echo_warn "4. Wait for SSL certificate provisioning if this is a new domain"

if [[ "$WITH_HRMS" == "no" && "$WITH_INDIA_COMPLIANCE" == "no" ]]; then
    echo ""
    echo_info "Optional apps can be installed later:"
    echo_info "  HRMS:              docker compose -f production.yaml exec backend bench --site $SITE_NAME install-app hrms"
    echo_info "  India Compliance: docker compose -f production.yaml exec backend bench --site $SITE_NAME install-app india_compliance"
fi