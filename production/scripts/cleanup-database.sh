#!/bin/bash

# ERPNext Database Cleanup
#
# STATUS:
#   Retired for normal production use.
#
# IMPORTANT:
#   This script intentionally does NOT perform direct SQL DELETE operations
#   against ERPNext/Frappe internal tables.
#
#   Previous versions of this script directly modified internal tables such as:
#     - tabCommunication
#     - tabCommunication Link
#     - tabVersion
#     - tabScheduled Job Log
#     - tabError Log
#     - tabDeleted Document
#     - tabRoute History
#
#   That approach is too schema-specific for controlled v16 operations.
#
# For database maintenance:
#   1. Take a verified backup first.
#   2. Use supported Frappe/ERPNext maintenance commands or documented
#      application-level retention mechanisms.
#   3. Test any cleanup procedure on staging before production.
#
# This wrapper remains in place so old operational references fail safely
# instead of silently executing destructive SQL.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat <<EOF
ERPNext Database Cleanup

STATUS:
  RETIRED for normal production use.

Usage:
  $0 --help

This script intentionally performs NO direct database cleanup.

The previous implementation directly deleted records from internal
ERPNext/Frappe tables. That is not considered a safe generic maintenance
strategy for the v16 deployment.

Recommended maintenance process:
  1. Create a verified site backup:
       ./scripts/backup-site.sh <site-name> --with-files --auto-copy

  2. Test the required maintenance operation on staging first.

  3. Use supported Frappe/ERPNext mechanisms for the specific data being
     retained or removed.

  4. Promote the tested procedure to production.

For historical database investigation, inspect:
  production/troubleshooting/

Exit status:
  0  Help displayed
  1  Cleanup operation refused
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        echo_warn "Database cleanup is retired."
        echo_info "No database changes were made."
        echo ""
        show_help
        exit 1
        ;;
    *)
        echo_error "Database cleanup is retired and accepts no cleanup options."
        echo_info "No database changes were made."
        echo ""
        show_help
        exit 1
        ;;
esac
