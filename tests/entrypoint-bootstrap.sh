#!/usr/bin/env bash
set -euo pipefail

# Entrypoint minimal pour exécuter le bootstrap.
# - BOOTSTRAP_SOURCE=remote (par défaut) : télécharge et exécute bootstrap depuis GitHub (HA_REF utilisé si défini)
# - BOOTSTRAP_SOURCE=local  : utilise le projet monté dans /repo (copie dans /srv/ha-stack puis lance l'installateur local)

BOOTSTRAP_SOURCE="${BOOTSTRAP_SOURCE:-remote}"   # 'remote' ou 'local'
HA_REF="${HA_REF:-main}"
REPO_OWNER="vpk-fr"
REPO_NAME="armbian-ha-kit"

run_remote() {
  local url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${HA_REF}/bootstrap.sh"
  echo "[entrypoint] Running remote bootstrap: ${url}"

  if curl -fsSL "$url" -o /tmp/bootstrap.sh; then
    exec bash /tmp/bootstrap.sh
  fi

  echo "[entrypoint] Remote bootstrap indisponible, fallback vers local (/repo/bootstrap.sh)." >&2
  if [[ -f /repo/bootstrap.sh ]]; then
    exec bash /repo/bootstrap.sh --local
  fi

  echo "[entrypoint] Echec: ni bootstrap remote ni local disponible." >&2
  exit 1
}

if [[ "${BOOTSTRAP_SOURCE}" == "local" ]]; then
  # Prefer running local bootstrap with --local (keeps behavior consistent).
  if [[ -f /repo/bootstrap.sh ]]; then
    exec bash /repo/bootstrap.sh --local
  fi

  # Prefer running installer from a local copy placed into the writable volume (/srv/ha-stack).
  if [[ -f /repo/scripts/install.sh ]]; then
    mkdir -p /srv/ha-stack
    tar -C /repo -cf - . | tar -C /srv/ha-stack -xf -
    if [[ -f /srv/ha-stack/scripts/install.sh ]]; then
      chmod +x /srv/ha-stack/scripts/install.sh || true
      exec bash /srv/ha-stack/scripts/install.sh
    fi
  fi

  # Search for a local installer in subdirectories (limited depth)
  found_installer=$(find /repo -maxdepth 3 -type f -path '*/scripts/install.sh' 2>/dev/null | head -n1 || true)
  if [[ -n "${found_installer}" ]]; then
    repo_root=$(dirname "${found_installer}" | xargs dirname)
    mkdir -p /srv/ha-stack
    tar -C "${repo_root}" -cf - . | tar -C /srv/ha-stack -xf -
    chmod +x /srv/ha-stack/scripts/install.sh || true
    exec bash /srv/ha-stack/scripts/install.sh
  fi

  # Rien trouvé localement — fallback vers le remote
fi

# Default
run_remote
