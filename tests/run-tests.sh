#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="armbian-ha-kit-tests"

cd "$ROOT_DIR"

docker build -f tests/Dockerfile -t "$IMAGE_NAME" .
docker run --rm -t -v "$ROOT_DIR:/repo" "$IMAGE_NAME"
