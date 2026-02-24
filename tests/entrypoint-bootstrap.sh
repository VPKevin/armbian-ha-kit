#!/usr/bin/env bash
set -euo pipefail

# Entrypoint: télécharge et exécute bootstrap.sh depuis le repo.
# Par défaut, utilise HA_REF=main; tu peux exporter HA_REF pour pinner un tag/commit.

HA_REF="${HA_REF:-main}"
REPO_OWNER="VPKevin"
REPO_NAME="armbian-ha-kit"
BOOTSTRAP_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${HA_REF}/bootstrap.sh"

echo "[entrypoint] Running bootstrap from: ${BOOTSTRAP_URL}"
# Exécute le bootstrap tel que sur une box (pas de params par défaut)
exec bash -c "curl -fsSL '${BOOTSTRAP_URL}' | bash -s --"
