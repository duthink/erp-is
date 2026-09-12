#!/bin/bash

# Validate Environment Configuration Script
# Checks for common issues in ERPNext deployment environment files
#
# This validator checks configuration only.
# Deployment policy such as rejecting mutable image tags is enforced by deploy.sh.

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Counters
errors=0
warnings=0

# Logging functions
echo_info() {
    echo -e "${GREEN}✓${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    warnings=$((warnings + 1))
}

echo_error() {
    echo -e "${RED}✗${NC} $1"
    errors=$((errors + 1))
}

# Validation patterns
readonly WEAK_PASSWORDS="changeit|123456|admin123|password123|qwerty|letmein|welcome"
readonly PLACEHOLDER_DOMAINS="yourdomain\.com|example\.com"
readonly EMAIL_REGEX="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"

# Get script directory and change to production directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PRODUCTION_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_env_value() {
    local file="$1"
    local var="$2"

    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi

    grep "^${var}=" "$file" 2>/dev/null |
        head -n 1 |
        cut -d'=' -f2- ||
        true
}

validate_required_vars() {
    local file="$1"
    shift

    local missing_vars=()
    local var
    local value

    for var in "$@"; do
        value="$(get_env_value "$file" "$var")"

        if [[ -z "$value" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo_error "$file missing required variable(s): ${missing_vars[*]}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Validate single environment file
# ---------------------------------------------------------------------------

validate_env_file() {
    local file="$1"

    shift
    local required_vars=("$@")

    echo "Checking $file..."

    if [[ ! -f "$file" ]]; then
        echo_error "$file not found"
        echo "  Create it from ${file}.example or run ./scripts/deploy.sh --setup"
        return 1
    fi

    if [[ ! -s "$file" ]]; then
        echo_error "$file is empty"
        return 1
    fi

    echo_info "File exists"

    # Read non-comment assignments once.
    local content
    content="$(
        grep -vE '^[[:space:]]*#' "$file" 2>/dev/null |
            grep '=' ||
            true
    )"

    # Check placeholders.
    if echo "$content" | grep -q "CHANGEME_"; then
        echo_error "$file contains CHANGEME_ placeholders"
        echo "$content" | grep "CHANGEME_" | sed 's/^/    /'
    else
        echo_info "No CHANGEME_ placeholders"
    fi

    # Check weak passwords without printing password values.
    if echo "$content" |
        cut -d'=' -f2- |
        grep -Eiq "$WEAK_PASSWORDS"; then
        echo_warn "$file contains a weak/default password value"
    fi

    # Check required variables.
    validate_required_vars "$file" "${required_vars[@]}" || true

    return 0
}

# ---------------------------------------------------------------------------
# Validate email
# ---------------------------------------------------------------------------

validate_email() {
    local email="$1"
    local var_name="$2"

    if [[ ! "$email" =~ $EMAIL_REGEX ]]; then
        echo_error "$var_name has an invalid email format"
        return 1
    fi

    if echo "$email" | grep -Eqi "$PLACEHOLDER_DOMAINS"; then
        echo_error "$var_name contains a placeholder domain"
        return 1
    fi

    echo_info "$var_name format is valid"
    return 0
}

# ---------------------------------------------------------------------------
# Validate password strength
# ---------------------------------------------------------------------------

validate_password_strength() {
    local password="$1"
    local min_length="${2:-16}"

    if [[ ${#password} -lt $min_length ]]; then
        echo_warn "Password is shorter than $min_length characters (current length: ${#password})"
        return 1
    fi

    echo_info "Password length is acceptable (${#password} characters)"
    return 0
}

# ---------------------------------------------------------------------------
# Validate image configuration
# ---------------------------------------------------------------------------

validate_image_configuration() {
    local custom_image custom_tag

    custom_image="$(get_env_value "production.env" "CUSTOM_IMAGE")"
    custom_tag="$(get_env_value "production.env" "CUSTOM_TAG")"

    echo "Checking custom image configuration..."

    if [[ -z "$custom_image" ]]; then
        echo_error "CUSTOM_IMAGE is missing from production.env"
    else
        echo_info "CUSTOM_IMAGE is set"
    fi

    if [[ -z "$custom_tag" ]]; then
        echo_error "CUSTOM_TAG is missing from production.env"
    else
        echo_info "CUSTOM_TAG is set: $custom_tag"

        case "$custom_tag" in
            latest|production-latest|staging-latest)
                echo_warn "CUSTOM_TAG is mutable: $custom_tag"
                echo "  Controlled deployments should use an immutable release tag."
                echo "  Example: v16.34.2-build.20260910"
                ;;
        esac
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Validate site/routing configuration
# ---------------------------------------------------------------------------

validate_sites() {
    local sites
    local sites_rule
    sites="$(get_env_value "production.env" "SITES")"
    sites_rule="$(get_env_value "production.env" "SITES_RULE")"

    if [[ -z "$sites" ]]; then
        echo_error "SITES is empty"
        return 1
    fi

    if [[ -z "$sites_rule" ]]; then
        echo_error "SITES_RULE is empty"
        return 1
    fi

    # Require the shell-safe form used by this repository:
    #   SITES='`erp.example.com`'
    #   SITES_RULE='Host(`erp.example.com`)'
    #
    # Backticks must remain inside single quotes because production.env is
    # sourced by Bash during deployment.
    if [[ "$sites" =~ ^\'\`[^\'\`]+\`\'$ ]]; then
        echo_info "SITES format is shell-safe"
    else
        echo_error "SITES must use the shell-safe quoted backtick format"
        echo "  Example: SITES='\\`erp.example.com\\`'"
    fi

    if [[ "$sites_rule" =~ ^\'Host\(\\\`[^\\\`]+\`\\\)\'$ ]]; then
        echo_info "SITES_RULE format is shell-safe"
    else
        echo_error "SITES_RULE must use the shell-safe quoted Traefik Host() format"
        echo "  Example: SITES_RULE='Host(\\`erp.example.com\\`)'"
    fi

    return 0
}

validate_env_sourceability() {
    local env_file="production.env"
    local output

    echo "Checking Bash sourceability of $env_file..."

    if [[ ! -f "$env_file" ]]; then
        echo_error "$env_file not found; cannot test sourceability"
        return 1
    fi

    # Parse first, then source in an isolated Bash process. This catches
    # syntax problems caused by values such as unquoted backticks while
    # keeping the parent validation shell untouched.
    if ! bash -n "$env_file"; then
        echo_error "$env_file contains Bash syntax errors"
        return 1
    fi

    output="$(
        bash -c '
            set -euo pipefail
            source "$1"
            printf "SITES=%s\nSITES_RULE=%s\nCUSTOM_TAG=%s\n" \
                "${SITES-}" "${SITES_RULE-}" "${CUSTOM_TAG-}"
        ' bash "$env_file" 2>&1
    )" || {
        echo_error "$env_file could not be safely sourced by Bash"
        echo "$output" | sed 's/^/    /'
        return 1
    }

    if [[ -z "$output" ]]; then
        echo_error "$env_file source test returned no configuration values"
        return 1
    fi

    echo_info "$env_file is Bash-sourceable"
    return 0
}

# ---------------------------------------------------------------------------
# Validate Traefik configuration
# ---------------------------------------------------------------------------

validate_traefik_configuration() {
    local hashed_password
    local traefik_domain

    hashed_password="$(get_env_value "traefik.env" "HASHED_PASSWORD")"
    traefik_domain="$(get_env_value "traefik.env" "TRAEFIK_DOMAIN")"

    # Check if password is actually hashed.
    if [[ -n "$hashed_password" ]]; then

        if echo "$hashed_password" |
            grep -Eiq "openssl|changeit|yourpassword|CHANGEME"; then
            echo_error "HASHED_PASSWORD does not appear to contain a generated hash"
            echo "  Generate with: openssl passwd -apr1 'yourpassword'"
        fi

        # Check if username prefix is included.
        if [[ "$hashed_password" == admin:* ]]; then
            echo_error "HASHED_PASSWORD should NOT include the 'admin:' prefix"
            echo_warn "Remove 'admin:' from the hash in traefik.env"
            echo_warn "The Compose configuration adds the username separately"
        fi
    fi

    # Check domain.
    if [[ -n "$traefik_domain" ]]; then
        if echo "$traefik_domain" | grep -Eqi "$PLACEHOLDER_DOMAINS"; then
            echo_error "TRAEFIK_DOMAIN still contains a placeholder domain"
        else
            echo_info "TRAEFIK_DOMAIN does not use a placeholder domain"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main validation
# ---------------------------------------------------------------------------

main() {

    # Help
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        cat << EOF
Usage: $0

Validates ERPNext deployment environment configuration.

Checks:
  - Required environment files
  - Required variables
  - Placeholder values
  - Weak/default passwords
  - Password length
  - Email format
  - SITES and SITES_RULE format
  - Bash sourceability of production.env
  - Custom image configuration
  - Mutable image tag warnings
  - Traefik configuration
  - Database password consistency

Files:
  production.env
  traefik.env
  mariadb.env

Exit Codes:
  0 - Validation passed
  1 - Validation failed

Notes:
  This script warns about mutable image tags but does not reject them.
  deploy.sh enforces immutable image tags before deployment.

Examples:
  $0
  $0 --help
EOF
        exit 0
    fi

    echo "🔍 Validating ERPNext Deployment Environment"
    echo "============================================"
    echo ""

    # -----------------------------------------------------------------------
    # production.env
    # -----------------------------------------------------------------------

    if validate_env_file \
        "production.env" \
        "DB_PASSWORD" \
        "DB_HOST" \
        "LETSENCRYPT_EMAIL" \
        "SITES" \
        "CUSTOM_IMAGE" \
        "CUSTOM_TAG"; then

        local letsencrypt_email
        local db_password

        letsencrypt_email="$(get_env_value "production.env" "LETSENCRYPT_EMAIL")"
        db_password="$(get_env_value "production.env" "DB_PASSWORD")"

        if [[ -n "$letsencrypt_email" ]]; then
            validate_email "$letsencrypt_email" "LETSENCRYPT_EMAIL" || true
        fi

        validate_sites || true
        validate_env_sourceability || true

        if [[ -n "$db_password" ]]; then
            validate_password_strength "$db_password" || true
        fi

        validate_image_configuration
    fi

    echo ""

    # -----------------------------------------------------------------------
    # traefik.env
    # -----------------------------------------------------------------------

    if validate_env_file \
        "traefik.env" \
        "TRAEFIK_DOMAIN" \
        "EMAIL" \
        "HASHED_PASSWORD"; then

        local traefik_email

        traefik_email="$(get_env_value "traefik.env" "EMAIL")"

        if [[ -n "$traefik_email" ]]; then
            validate_email "$traefik_email" "traefik.env EMAIL" || true
        fi

        validate_traefik_configuration
    fi

    echo ""

    # -----------------------------------------------------------------------
    # mariadb.env
    # -----------------------------------------------------------------------

    validate_env_file "mariadb.env" "DB_PASSWORD" || true

    echo ""

    # -----------------------------------------------------------------------
    # Cross-file validation
    # -----------------------------------------------------------------------

    echo "Cross-checking configurations..."

    if [[ -f "production.env" && -f "mariadb.env" ]]; then

        local prod_pass
        local maria_pass

        prod_pass="$(get_env_value "production.env" "DB_PASSWORD")"
        maria_pass="$(get_env_value "mariadb.env" "DB_PASSWORD")"

        if [[ -n "$prod_pass" && -n "$maria_pass" ]]; then
            if [[ "$prod_pass" == "$maria_pass" ]]; then
                echo_info "Database passwords match"
            else
                echo_error "Database passwords DO NOT match between production.env and mariadb.env"
            fi
        fi
    fi

    echo ""

    # -----------------------------------------------------------------------
    # Final summary
    # -----------------------------------------------------------------------

    echo "============================================"
    echo "Validation Summary"
    echo "============================================"
    echo ""

    if (( errors > 0 )); then

        echo -e "${RED}❌ Validation Failed${NC}"
        echo "   Errors: $errors"
        echo "   Warnings: $warnings"
        echo ""
        echo "Please fix the errors above before deploying."
        exit 1

    elif (( warnings > 0 )); then

        echo -e "${YELLOW}⚠️  Validation Passed with Warnings${NC}"
        echo "   Warnings: $warnings"
        echo ""
        echo "Review the warnings before proceeding with deployment."
        exit 0

    else

        echo -e "${GREEN}✅ Validation Passed${NC}"
        echo "   No errors or warnings found."
        echo ""
        echo "You can now regenerate and review the deployment configuration:"
        echo "  ./scripts/deploy.sh --regenerate"
        exit 0
    fi
}

main "$@"
