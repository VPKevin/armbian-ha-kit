#!/usr/bin/env bash
set -euo pipefail

# Entrypoint: télécharge et exécute bootstrap.sh depuis le repo ou exécute la version locale
# Par défaut, utilise HA_REF=main et BOOTSTRAP_SOURCE=remote
# Pour exécuter le bootstrap depuis le projet local monté (ex: /repo), définir BOOTSTRAP_SOURCE=local

BOOTSTRAP_SOURCE="${BOOTSTRAP_SOURCE:-remote}"   # 'remote' or 'local'
HA_REF="${HA_REF:-main}"
REPO_OWNER="VPKevin"
REPO_NAME="armbian-ha-kit"

if [[ "${BOOTSTRAP_SOURCE}" == "local" ]]; then
  echo "[entrypoint] BOOTSTRAP_SOURCE=local -> will execute local /repo/bootstrap.sh"
  if [[ -f /repo/bootstrap.sh ]]; then
    echo "[entrypoint] Running local bootstrap: /repo/bootstrap.sh"
    # Ensure executable then run as root (script demands root)
    chmod +x /repo/bootstrap.sh || true
    exec bash /repo/bootstrap.sh
  else
    echo "[entrypoint] ERROR: /repo/bootstrap.sh not found. Falling back to remote bootstrap." >&2
  fi
fi

# Default: remote
BOOTSTRAP_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${HA_REF}/bootstrap.sh"

echo "[entrypoint] BOOTSTRAP_SOURCE=${BOOTSTRAP_SOURCE} -> Running bootstrap from: ${BOOTSTRAP_URL}"
# Exécute le bootstrap tel que sur une box (pas de params par défaut)
exec bash -c "curl -fsSL '${BOOTSTRAP_URL}' | bash -s --"
