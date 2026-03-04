#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="armbian-ha-kit-tests"

cd "$ROOT_DIR"

BOOTSTRAP_SOURCE="${BOOTSTRAP_SOURCE:-remote}"
# Default buildx platform and target (can be overridden via env vars)
TEST_PLATFORM="${TEST_PLATFORM:-linux/arm64}"
TEST_TARGET="${TEST_TARGET:-armbian}"

build_image() {
  local args=()
  [[ -n "$TEST_TARGET" ]] && args+=(--target "$TEST_TARGET")
  [[ -n "$TEST_PLATFORM" ]] && args+=(--platform "$TEST_PLATFORM")

  if docker buildx version >/dev/null 2>&1; then
    # Create a temporary builder to avoid leaving buildkit containers running.
    local prev_builder bx_name
    prev_builder="$(docker buildx ls 2>/dev/null | awk '/\*/{print $1}' || true)"
    bx_name="ahk-build-$(date +%s)-$$"

    docker buildx create --name "$bx_name" --use >/dev/null

    cleanup_builder() {
      # restore previous builder if present
      if [[ -n "$prev_builder" ]]; then
        docker buildx use "$prev_builder" >/dev/null 2>&1 || true
      fi
      # remove our temporary builder
      docker buildx rm "$bx_name" >/dev/null 2>&1 || true
    }
    trap cleanup_builder EXIT

    # Run the build using our temporary builder
    docker buildx build --load -f tests/Dockerfile -t "$IMAGE_NAME" "${args[@]}" .

    # Cleanup immediately (trap is a fallback)
    cleanup_builder
    trap - EXIT
  else
    docker build -f tests/Dockerfile -t "$IMAGE_NAME" "${args[@]}" .
  fi
}

build_image

# Run smoke tests inside the image in a non-interactive way by overriding the entrypoint.
# This avoids running the interactive installer and validates the test image environment.

docker run --rm \
  --platform "$TEST_PLATFORM" \
  --user root \
  --entrypoint /usr/local/bin/run-smoke.sh \
  -e "BOOTSTRAP_SOURCE=${BOOTSTRAP_SOURCE}" \
  -v "$ROOT_DIR:/repo:ro" \
  "$IMAGE_NAME"
