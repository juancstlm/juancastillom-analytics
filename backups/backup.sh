#!/usr/bin/env bash
# Dumps the umami Postgres database to ./backups/umami-YYYYMMDD-HHMMSS.sql.gz
# Run from the repo root: ./backups/backup.sh
# Schedule via cron, e.g.:
#   0 3 * * * cd /opt/juancastillom-analytics && ./backups/backup.sh >> /var/log/umami-backup.log 2>&1

set -euo pipefail

cd "$(dirname "$0")/.."

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="backups/umami-${STAMP}.sql.gz"

docker compose exec -T db pg_dump -U umami umami | gzip > "$OUT"

# Keep only the last 30 backups
ls -1t backups/umami-*.sql.gz | tail -n +31 | xargs -r rm --

echo "Backup written to $OUT"
