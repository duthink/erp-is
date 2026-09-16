#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

WITH_FILES="${1:-0}"

case "$WITH_FILES" in
    0|1)
        ;;
    *)
        echo "Usage: $0 [0|1]" >&2
        exit 2
        ;;
esac

exec docker compose \
    --env-file production.env \
    -f production.yaml \
    -f backup/compose.backup-runner.yaml \
    run --rm \
    -e "BACKUP_WITH_FILES=${WITH_FILES}" \
    backup-runner \
    /bin/bash -lc '/usr/local/bin/backup-to-s3.sh'