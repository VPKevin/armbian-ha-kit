#!/usr/bin/env bash
set -euo pipefail

# Backup Home Assistant : dump PostgreSQL + snapshots Restic vers chaque repo
# de restic/repos.conf.
#
# Contrat d'échec (audit §3.1) :
# - Chaque étape (dump, backup/forget par repo) est tentée même si une étape
#   précédente a échoué : un NAS débranché ne doit pas empêcher le backup USB.
# - Aucune erreur n'est silencieuse : tout échec est loggé ET le script sort
#   avec un code non-zéro pour que systemd marque le run "failed".
#
# Sécurité (audit §1.4) : pas de PGPASSWORD — le dump passe par le socket
# local du conteneur (auth "trust" de l'image postgres officielle), donc aucun
# secret sur la ligne de commande ni dans /proc.

STACK_DIR="${STACK_DIR:-/srv/ha-stack}"
ENV_FILE="${STACK_DIR}/.env"
BACKUP_DIR="${STACK_DIR}/backup"
LOG_TAG="[ha-backup]"
COMPOSE_PATH="${COMPOSE_PATH:-}"

# Load common helpers if available to standardize logging/error handling.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/common.sh" || true
  install_error_trap "backup.sh"
  # require root for backup operations (best-effort)
  require_root_or_fail || exit $RC_NOT_ROOT
fi

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
  echo "$LOG_TAG Missing $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

mkdir -p "$BACKUP_DIR"

# Échecs accumulés : on continue le run, on sort non-zéro à la fin.
FAILURES=()

# ---------------------------------------------------------------------------
# 1) Dump PostgreSQL (via le socket local du conteneur, sans mot de passe)
# ---------------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_FILE="${BACKUP_DIR}/postgres-${TS}.sql.gz"

echo "$LOG_TAG Dumping PostgreSQL database to $DUMP_FILE ..."
if ! docker exec "$(pg_container_id)" \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-privileges \
    | gzip > "$DUMP_FILE"; then
  echo "$LOG_TAG ERROR: pg_dump failed" >&2
  rm -f "$DUMP_FILE"
  FAILURES+=("pg_dump")
fi

# ---------------------------------------------------------------------------
# 2) Snapshots Restic vers chaque repo configuré (NAS/USB)
# ---------------------------------------------------------------------------
REPOS_CONF="${STACK_DIR}/restic/repos.conf"
PASSFILE="${STACK_DIR}/restic/password"

if [[ ! -f "$REPOS_CONF" ]]; then
  echo "$LOG_TAG No repos configured ($REPOS_CONF). Skipping restic backup."
else
  if [[ ! -f "$PASSFILE" ]]; then
    echo "$LOG_TAG ERROR: Missing restic password file: $PASSFILE" >&2
    FAILURES+=("restic password file")
  else
    export RESTIC_PASSWORD_FILE="$PASSFILE"

    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      [[ "$repo" =~ ^# ]] && continue

      export RESTIC_REPOSITORY="$repo"

      echo "$LOG_TAG Restic backup to: $repo"
      if ! restic backup "${STACK_DIR}/config" "${BACKUP_DIR}" --tag homeassistant; then
        echo "$LOG_TAG ERROR: restic backup failed for: $repo (repo inaccessible ? NAS/USB monté ?)" >&2
        FAILURES+=("restic backup: $repo")
        # Repo inaccessible : inutile de tenter le forget, on passe au suivant.
        continue
      fi

      echo "$LOG_TAG Retention (tag=homeassistant, daily=7 weekly=10) on: $repo"
      if ! restic forget --tag homeassistant --keep-daily 7 --keep-weekly 10 --prune; then
        echo "$LOG_TAG ERROR: restic forget failed for: $repo" >&2
        FAILURES+=("restic forget: $repo")
      fi
    done < "$REPOS_CONF"
  fi
fi

# ---------------------------------------------------------------------------
# 3) Nettoyage des dumps locaux anciens (filet si restic indisponible)
# ---------------------------------------------------------------------------
find "$BACKUP_DIR" -type f -name "postgres-*.sql.gz" -mtime +21 -delete || true

# ---------------------------------------------------------------------------
# Bilan
# ---------------------------------------------------------------------------
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "$LOG_TAG FAILED steps (${#FAILURES[@]}):" >&2
  for f in "${FAILURES[@]}"; do
    echo "$LOG_TAG   - $f" >&2
  done
  exit 1
fi

echo "$LOG_TAG Done."
