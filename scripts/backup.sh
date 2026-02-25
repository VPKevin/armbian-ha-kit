#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
BACKUP_DIR="${STACK_DIR}/backup"
LOG_TAG="[ha-backup]"
COMPOSE_PATH="${COMPOSE_PATH:-}"

if [[ -z "${COMPOSE_PATH:-}" && -f "${STACK_DIR}/.compose_path" ]]; then
  COMPOSE_PATH="$(cat "${STACK_DIR}/.compose_path" 2>/dev/null || true)"
fi
if [[ -z "${COMPOSE_PATH:-}" ]]; then
  COMPOSE_PATH="${STACK_DIR}/docker-compose.yml"
fi

compose_container_id() {
  local service="$1"
  docker compose -f "$COMPOSE_PATH" ps -q "$service" 2>/dev/null || true
}

pg_container_id() {
  local cid
  cid="$(compose_container_id postgres)"
  if [[ -n "${cid:-}" ]]; then
    echo "$cid"
    return 0
  fi
  echo "ha-postgres"
}

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

if command -v ui_run >/dev/null 2>&1; then
  ui_notify "Dump PostgreSQL vers ${DUMP_FILE}.gz"
  # Exécuter la commande via bash -lc pour que la redirection soit faite dans
  # le sous-shell invoqué par ui_run (sinon la redirection serait appliquée
  # par le shell appelant et le dump n'irait pas dans $DUMP_FILE).
  ui_run "pg_dump" -- bash -lc "docker exec -e PGPASSWORD=\'${POSTGRES_PASSWORD}\' $(pg_container_id) pg_dump -U \"${POSTGRES_USER}\" -d \"${POSTGRES_DB}\" --no-owner --no-privileges > \"${DUMP_FILE}\"" || true
  gzip -f "$DUMP_FILE"
else
  echo "$LOG_TAG Dumping PostgreSQL database to $DUMP_FILE.gz ..."
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$(pg_container_id)" \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-privileges \
    > "$DUMP_FILE"
  gzip -f "$DUMP_FILE"
fi

# Sauvegarder avec restic vers les repos configurés (NAS/USB)
# Les repos sont décrits dans ${STACK_DIR}/restic/repos.conf
REPOS_CONF="${STACK_DIR}/restic/repos.conf"
PASSFILE="${STACK_DIR}/restic/password"

if [[ ! -f "$PASSFILE" ]]; then
  echo "$LOG_TAG Missing restic password file: $PASSFILE"
  exit 1
fi

export RESTIC_PASSWORD_FILE="$PASSFILE"

if [[ ! -f "$REPOS_CONF" ]]; then
  echo "$LOG_TAG No repos configured ($REPOS_CONF). Skipping restic backup."
  exit 0
fi

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  [[ "$repo" =~ ^# ]] && continue

  export RESTIC_REPOSITORY="$repo"

  if command -v ui_run >/dev/null 2>&1; then
    ui_notify "Restic -> $RESTIC_REPOSITORY"
    ui_run "restic backup -> ${RESTIC_REPOSITORY}" -- restic backup "${STACK_DIR}/config" "${STACK_DIR}/backup" --tag homeassistant || true
    ui_run "restic forget -> ${RESTIC_REPOSITORY}" -- restic forget --keep-daily 7 --keep-weekly 10 --prune || true
  else
    echo "$LOG_TAG Restic backup to: $RESTIC_REPOSITORY"
    restic backup "${STACK_DIR}/config" "${STACK_DIR}/backup" --tag homeassistant

    echo "$LOG_TAG Retention (daily=7 weekly=10) on: $RESTIC_REPOSITORY"
    restic forget --keep-daily 7 --keep-weekly 10 --prune
  fi

done < "$REPOS_CONF"

# Nettoyage des dumps locaux très anciens (au cas où restic n'est pas dispo)
find "$BACKUP_DIR" -type f -name "postgres-*.sql.gz" -mtime +21 -delete || true

if command -v ui_notify >/dev/null 2>&1; then
  ui_notify "Backup terminé" ok
else
  echo "$LOG_TAG Done."
fi
