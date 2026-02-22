#!/usr/bin/env bash
# bootstrap.sh — Download and install armbian-ha-kit without requiring git.
#
# Usage:
#   sudo bash bootstrap.sh [REF]
#
# Or with an environment variable:
#   sudo BOOTSTRAP_REF=v1.2.0 bash bootstrap.sh
#
# REF defaults to "main". Pass a branch name, tag, or full commit SHA to pin
# a specific version, e.g.:
#   sudo bash bootstrap.sh v1.2.0
#
# ⚠️  Security note: piping directly from the internet (curl | bash) means you
# trust the server and any network path between you and GitHub. Always review
# the script at https://github.com/VPKevin/armbian-ha-kit/blob/main/bootstrap.sh
# before running it. For production use, pin a specific tag/commit SHA instead
# of "main" so that updates cannot affect you silently.
#
# Example one-liner (review first!):
#   curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
#     | sudo bash -s -- main

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_OWNER="VPKevin"
REPO_NAME="armbian-ha-kit"
STACK_DIR="${STACK_DIR:-/srv/ha-stack}"
# REF: first positional arg > BOOTSTRAP_REF env var > default "main"
REF="${1:-${BOOTSTRAP_REF:-main}}"

GITHUB_ARCHIVE="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${REF}.tar.gz"

# Data directories that must never be overwritten by a re-install
PRESERVE_DIRS=(config postgres backup caddy)
PRESERVE_FILES=(.env)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] WARNING: $*" >&2; }
die()  { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root. Try: sudo bash $0 $*"
  fi
}

apt_ensure() {
  # Install a package only if the binary is not already available
  local pkg="$1" bin="${2:-$1}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "Installing missing package: $pkg"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q "$pkg"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  need_root "$@"

  log "=== armbian-ha-kit bootstrap (ref: ${REF}) ==="
  echo
  echo "  ⚠️  Security reminder: you are running a script downloaded from the internet."
  echo "     Review it first: https://github.com/${REPO_OWNER}/${REPO_NAME}/blob/main/bootstrap.sh"
  echo "     To pin a version: sudo bash bootstrap.sh v1.2.0"
  echo

  # -- 1. Ensure required tools are present (no git needed) -----------------
  apt_ensure curl curl
  apt_ensure ca-certificates update-ca-certificates
  apt_ensure tar tar

  # -- 2. Create the stack directory with strict permissions ----------------
  log "Ensuring ${STACK_DIR} exists with correct permissions"
  mkdir -p "${STACK_DIR}"
  chmod 700 "${STACK_DIR}"
  chown root:root "${STACK_DIR}"

  # -- 3. Download archive from GitHub --------------------------------------
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  local archive="${tmpdir}/ha-stack.tar.gz"
  log "Downloading ${GITHUB_ARCHIVE}"
  curl -fsSL --retry 3 --retry-delay 2 \
    -o "${archive}" \
    "${GITHUB_ARCHIVE}" \
    || die "Failed to download archive. Check the ref '${REF}' exists on GitHub."

  # -- 4. Extract to a temp staging directory -------------------------------
  local staging="${tmpdir}/staging"
  mkdir -p "${staging}"
  tar -xzf "${archive}" --strip-components=1 -C "${staging}"

  # -- 5. Copy into STACK_DIR, preserving existing user-data dirs/files -----
  log "Syncing files into ${STACK_DIR} (preserving user data)"

  # Build cp exclusion list: skip data dirs and .env if they already exist
  # We use a selective approach: copy everything except preserved paths.
  local excludes=()
  for d in "${PRESERVE_DIRS[@]}"; do
    if [[ -d "${STACK_DIR}/${d}" ]]; then
      excludes+=("$d")
    fi
  done
  for f in "${PRESERVE_FILES[@]}"; do
    if [[ -f "${STACK_DIR}/${f}" ]]; then
      excludes+=("$f")
    fi
  done

  # Copy all top-level entries from staging, skipping preserved ones
  shopt -s dotglob
  for src in "${staging}"/*; do
    local name skip=false
    name="$(basename "${src}")"
    if [[ ${#excludes[@]} -gt 0 ]]; then
      for ex in "${excludes[@]}"; do
        if [[ "$name" == "$ex" ]]; then
          skip=true
          break
        fi
      done
    fi
    if $skip; then
      log "  Skipping (preserved): ${name}"
      continue
    fi
    cp -a "${src}" "${STACK_DIR}/${name}"
  done
  shopt -u dotglob

  # Ensure scripts are executable
  chmod +x "${STACK_DIR}/scripts/"*.sh 2>/dev/null || true
  chmod +x "${STACK_DIR}/bootstrap.sh"  2>/dev/null || true

  # -- 6. Hand off to the install wizard ------------------------------------
  # Use a subshell call (not exec) so the EXIT trap can clean up tmpdir.
  log "Launching install wizard: ${STACK_DIR}/scripts/install.sh"
  bash "${STACK_DIR}/scripts/install.sh"
}

main "$@"
