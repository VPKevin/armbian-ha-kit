#!/usr/bin/env bash
# install-remote.sh — Bootstrap installer for armbian-ha-kit
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/install-remote.sh | sudo bash
#
# Or with options:
#   sudo bash install-remote.sh [--ref <branch|tag|commit>] [--dir <path>] [--yes]
#
# ⚠ SECURITY WARNING: Piping a script from the internet directly into bash is convenient
#   but carries risk.  For production installs, consider:
#     1. Download the script first, inspect it, then run it.
#     2. Pin a specific --ref (tag or full commit SHA) instead of using 'main'.
#   Example (pinned version):
#     curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.0.0/install-remote.sh \
#       | sudo bash -s -- --ref v1.0.0
#
set -euo pipefail

REPO_URL="https://github.com/VPKevin/armbian-ha-kit.git"
DEFAULT_DIR="/srv/ha-stack"
DEFAULT_REF="main"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m[install-remote]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-remote] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-remote] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_DIR="${HA_STACK_DIR:-$DEFAULT_DIR}"
TARGET_REF="${HA_STACK_REF:-$DEFAULT_REF}"
AUTO_YES=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --ref <branch|tag|SHA>  Git ref to clone/checkout (default: $DEFAULT_REF)
  --dir <path>            Installation directory     (default: $DEFAULT_DIR)
  --yes                   Skip all confirmation prompts
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)   TARGET_REF="$2"; shift 2 ;;
    --dir)   TARGET_DIR="$2"; shift 2 ;;
    --yes)   AUTO_YES=1;       shift   ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1.  Run '$0 --help' for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root.  Try: sudo bash $0 $*"
  fi
}

need_root "$@"

# ---------------------------------------------------------------------------
# Security banner
# ---------------------------------------------------------------------------
cat <<'BANNER'

  ╔══════════════════════════════════════════════════════════════════╗
  ║          armbian-ha-kit — Remote Bootstrap Installer            ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║  ⚠  You are about to run a script downloaded from the internet. ║
  ║     Review the source before proceeding:                        ║
  ║     https://github.com/VPKevin/armbian-ha-kit                   ║
  ║                                                                  ║
  ║     For safer installs, pin a specific tag or commit SHA:        ║
  ║       sudo bash install-remote.sh --ref v1.0.0                  ║
  ╚══════════════════════════════════════════════════════════════════╝

BANNER

if [[ "$AUTO_YES" -eq 0 ]]; then
  read -r -p "Continue? [y/N] " CONFIRM
  case "$CONFIRM" in
    [yY][eE][sS]|[yY]) : ;;
    *) log "Aborted."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Install prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  local missing=()
  command -v git      >/dev/null 2>&1 || missing+=(git)
  command -v curl     >/dev/null 2>&1 || missing+=(curl)
  # Ensure ca-certificates is always current
  missing+=(ca-certificates)

  log "Updating package list and installing prerequisites: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq "${missing[@]}"
}

install_prerequisites

# ---------------------------------------------------------------------------
# Clone or update the repository
# ---------------------------------------------------------------------------
clone_or_update() {
  if [[ -d "${TARGET_DIR}/.git" ]]; then
    log "Repository already exists at ${TARGET_DIR} — updating to ref '${TARGET_REF}'..."
    git -C "$TARGET_DIR" fetch --tags --quiet origin
    git -C "$TARGET_DIR" checkout --quiet "$TARGET_REF"
    # If the ref is a branch, pull the latest commits
    if git -C "$TARGET_DIR" rev-parse --verify "origin/${TARGET_REF}" >/dev/null 2>&1; then
      git -C "$TARGET_DIR" reset --hard "origin/${TARGET_REF}" --quiet
    fi
  else
    log "Cloning ${REPO_URL} (ref: ${TARGET_REF}) into ${TARGET_DIR}..."
    mkdir -p "$TARGET_DIR"
    git clone --branch "$TARGET_REF" --depth 1 "$REPO_URL" "$TARGET_DIR"
  fi

  # Apply correct permissions to the stack directory
  chown root:root "$TARGET_DIR"
  chmod 700 "$TARGET_DIR"
}

clone_or_update

# ---------------------------------------------------------------------------
# Verify integrity (optional commit pinning)
# ---------------------------------------------------------------------------
verify_ref() {
  local resolved
  resolved="$(git -C "$TARGET_DIR" rev-parse HEAD 2>/dev/null)" \
    || die "Could not determine current HEAD in ${TARGET_DIR}.  The repository may be corrupted."
  log "Checked-out commit: ${resolved}"

  # If the caller passed a full 40-char SHA, verify it matches exactly
  if [[ "${TARGET_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    if [[ "$resolved" != "$TARGET_REF" ]]; then
      die "Integrity check failed: expected ${TARGET_REF}, got ${resolved}"
    fi
    log "Integrity check passed (SHA matches)."
  else
    log "Ref '${TARGET_REF}' resolved to ${resolved}."
    warn "For maximum security, pin a full commit SHA with --ref <40-char-sha>."
  fi
}

verify_ref

# ---------------------------------------------------------------------------
# Hand off to the main install wizard
# ---------------------------------------------------------------------------
INSTALL_SCRIPT="${TARGET_DIR}/scripts/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  die "Install script not found at ${INSTALL_SCRIPT}.  The clone may be incomplete."
fi

log "Starting install wizard: ${INSTALL_SCRIPT}"
exec bash "$INSTALL_SCRIPT"
