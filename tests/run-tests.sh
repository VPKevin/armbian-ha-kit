#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="armbian-ha-kit-tests"

cd "$ROOT_DIR"

docker build -f tests/Dockerfile -t "$IMAGE_NAME" .

# Permet de tester soit le bootstrap remote, soit le bootstrap local du repo monté.
# Par défaut on garde le comportement actuel (remote) pour coller au parcours utilisateur.
BOOTSTRAP_SOURCE="${BOOTSTRAP_SOURCE:-remote}"

docker run --rm -t \
  -e "BOOTSTRAP_SOURCE=${BOOTSTRAP_SOURCE}" \
  -v "$ROOT_DIR:/repo" \
  "$IMAGE_NAME"
