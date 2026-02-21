#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
BACKUP_DIR="${STACK_DIR}/backup"
LOG_TAG="[ha-backup]"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "$LOG_TAG Missing $ENV_FILE"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

mkdir -p "$BACKUP_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_FILE="${BACKUP_DIR}/postgres-${TS}.sql"

echo "$LOG_TAG Dumping PostgreSQL database to $DUMP_FILE.gz ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" ha-postgres \
  pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-privileges \
  > "$DUMP_FILE"
gzip -f "$DUMP_FILE"

# Sauvegarder avec restic vers les repos configurés (NAS/USB)
# Les repos sont décrits dans ${STACK_DIR}/restic/repos.conf
REPOS_CONF="${STACK_DIR}/restic/repos.conf"
PASSFILE="${STACK_DIR}/restic/password"

if [[ ! -f "$REPOS_CONF" ]]; then
  echo "$LOG_TAG No repos configured ($REPOS_CONF). Skipping restic backup."
  exit 0
fi

if [[ ! -f "$PASSFILE" ]]; then
  echo "$LOG_TAG Missing restic password file: $PASSFILE"
  exit 1
fi

export RESTIC_PASSWORD_FILE="$PASSFILE"

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  [[ "$repo" =~ ^# ]] && continue

  if ! mountpoint -q "$(dirname "$repo")" 2>/dev/null; then
    echo "$LOG_TAG Mount point $(dirname "$repo") not mounted for repo $repo — skipping."
    continue
  fi

  export RESTIC_REPOSITORY="$repo"

  echo "$LOG_TAG Restic backup to: $RESTIC_REPOSITORY"
  restic backup "${STACK_DIR}/config" "${STACK_DIR}/backup" --tag homeassistant

  echo "$LOG_TAG Retention (daily=7 weekly=10) on: $RESTIC_REPOSITORY"
  restic forget --keep-daily 7 --keep-weekly 10 --prune

done < "$REPOS_CONF"

# Nettoyage des dumps locaux très anciens (au cas où restic n'est pas dispo)
find "$BACKUP_DIR" -type f -name "postgres-*.sql.gz" -mtime +21 -delete || true

echo "$LOG_TAG Done."