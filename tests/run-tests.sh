#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT_IMAGE_NAME="armbian-ha-kit-tests-lint"
ARM_IMAGE_NAME="armbian-ha-kit-tests"

cd "$ROOT_DIR"

# 1) Lint + unit tests (Bats) sans interaction
docker build -f tests/Dockerfile --target lint -t "$LINT_IMAGE_NAME" .

docker run --rm -t \
  --entrypoint /bin/bash \
  -v "$ROOT_DIR:/repo" \
  -w /repo \
  "$LINT_IMAGE_NAME" \
  -lc "shellcheck -S error -e SC2034,SC2086 -x scripts/**/*.sh scripts/*.sh tests/*.bats && bats -t -r tests"

# 2) Smoke test dans une image proche Armbian (sans lancer le bootstrap interactif)
docker build -f tests/Dockerfile --target armbian -t "$ARM_IMAGE_NAME" .

docker run --rm -t \
  --entrypoint /bin/bash \
  -v "$ROOT_DIR:/repo" \
  -w /repo \
  "$ARM_IMAGE_NAME" \
  -lc "/usr/local/bin/run-smoke.sh"
