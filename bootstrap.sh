#!/usr/bin/env bash
# bootstrap.sh — Bootstrap installer for armbian-ha-kit
# Downloads the repository archive from GitHub (no git required) and runs install.sh.
#
# Usage:
#   sudo bash bootstrap.sh [--ref <tag|commit|branch>] [--dir <install-dir>]
#
# Environment variables (override defaults):
#   HA_REF        Git ref to download (default: main)
#   HA_INSTALL_DIR  Target installation directory (default: /srv/ha-stack)
#   HA_SKIP_NEXT_STEPS  If set to 1, do not print 'Next steps' footer
#
# ⚠  SECURITY NOTE — "curl | bash":
#   Piping a remote script directly into bash is convenient but carries risk:
#   you cannot inspect the script before it runs. Mitigations:
#     1. Download the script first, review it, then execute.
#     2. Pin to a specific tag or commit SHA (--ref v1.2.3 or --ref <sha>)
#        so the content is reproducible and cannot silently change.
#     3. Verify the SHA-256 checksum of the tarball if one is published.
#   Example (pinned):
#     curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.0.0/bootstrap.sh \
#       | sudo bash -s -- --ref v1.0.0

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridable via env vars or CLI flags)
# ---------------------------------------------------------------------------
REPO_OWNER="VPKevin"
REPO_NAME="armbian-ha-kit"
HA_REF="${HA_REF:-main}"
HA_INSTALL_DIR="${HA_INSTALL_DIR:-/srv/ha-stack}"
HA_SKIP_NEXT_STEPS="${HA_SKIP_NEXT_STEPS:-0}"

# ---------------------------------------------------------------------------
# Data directories that must never be clobbered
# ---------------------------------------------------------------------------
PRESERVE_DIRS=(config postgres backup caddy restic)

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '\e[1;34m[bootstrap]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[bootstrap]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[bootstrap]\e[0m WARNING: %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[bootstrap]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)   HA_REF="$2";         shift 2 ;;
    --dir)   HA_INSTALL_DIR="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown argument: $1. Use --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || die "This script must be run as root (sudo)."

# ---------------------------------------------------------------------------
# Temporary directory — cleaned up on exit
# ---------------------------------------------------------------------------
TMPDIR_WORK=""
cleanup() {
  if [[ -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK}" ]]; then
    rm -rf "${TMPDIR_WORK}"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Ensure prerequisites
# ---------------------------------------------------------------------------
install_prerequisites() {
  local missing=()
  for cmd in curl tar; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  # ca-certificates needed for HTTPS verification
  if [[ ${#missing[@]} -gt 0 ]] || ! dpkg -s ca-certificates &>/dev/null 2>&1; then
    log "Installing missing prerequisites: ${missing[*]:-} ca-certificates ..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates tar
  fi
}

# ---------------------------------------------------------------------------
# Create install directory
# ---------------------------------------------------------------------------
prepare_install_dir() {
  if [[ ! -d "${HA_INSTALL_DIR}" ]]; then
    log "Creating install directory: ${HA_INSTALL_DIR}"
    mkdir -p "${HA_INSTALL_DIR}"
    chmod 750 "${HA_INSTALL_DIR}"
  else
    log "Install directory already exists: ${HA_INSTALL_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# Download archive
# ---------------------------------------------------------------------------
download_archive() {
  ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${HA_REF}.tar.gz"
  TMPDIR_WORK="$(mktemp -d)"
  ARCHIVE_PATH="${TMPDIR_WORK}/repo.tar.gz"

  log "Downloading repository archive (ref: ${HA_REF}) ..."
  log "URL: ${ARCHIVE_URL}"
  curl -fsSL --retry 3 --retry-delay 2 \
    -o "${ARCHIVE_PATH}" \
    "${ARCHIVE_URL}" \
    || die "Download failed. Check the ref '${HA_REF}' and your network connection."

  [[ -s "${ARCHIVE_PATH}" ]] || die "Downloaded archive is empty."
  ok "Download complete."
}

# ---------------------------------------------------------------------------
# Extract archive (idempotent — preserves data dirs)
# ---------------------------------------------------------------------------
extract_archive() {
  local extract_dir="${TMPDIR_WORK}/extracted"
  mkdir -p "${extract_dir}"

  log "Extracting archive ..."
  tar -xzf "${ARCHIVE_PATH}" -C "${extract_dir}" \
    || die "Failed to extract archive."

  # GitHub archives contain a single top-level directory: <repo>-<ref>/
  local src_dir
  src_dir="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "${src_dir}" ]] || die "Could not find extracted source directory."

  log "Syncing repository files to ${HA_INSTALL_DIR} ..."
  log "(Data directories are preserved: ${PRESERVE_DIRS[*]})"

  # Build rsync-style exclusions using cp --no-clobber semantics:
  # We simply copy everything, but skip preserved directories if they exist.
  # Strategy: copy new/changed repo-managed files; never touch data dirs.
  local exclude_args=()
  for d in "${PRESERVE_DIRS[@]}"; do
    if [[ -d "${HA_INSTALL_DIR}/${d}" ]]; then
      exclude_args+=("--exclude=${d}/")
      log "  Preserving existing: ${HA_INSTALL_DIR}/${d}"
    fi
  done

  # rsync is not guaranteed present; use tar pipe for portability
  # (re-archive the source excluding data dirs, then extract into target)
  local tar_exclude_args=()
  for d in "${PRESERVE_DIRS[@]}"; do
    if [[ -d "${HA_INSTALL_DIR}/${d}" ]]; then
      tar_exclude_args+=(--exclude="${d}")
    fi
  done

  # Stream source tree into target (overwrite repo files, skip preserved dirs)
  tar -C "${src_dir}" "${tar_exclude_args[@]}" -cf - . \
    | tar -C "${HA_INSTALL_DIR}" -xf - \
    || die "Failed to sync files to ${HA_INSTALL_DIR}."

  ok "Files synced to ${HA_INSTALL_DIR}."
}

# ---------------------------------------------------------------------------
# Run install script
# ---------------------------------------------------------------------------
run_installer() {
  local installer="${HA_INSTALL_DIR}/scripts/install.sh"
  [[ -f "${installer}" ]] || die "Installer not found: ${installer}"
  chmod +x "${installer}"
  log "Running installer: ${installer}"
  bash "${installer}"
}

# ---------------------------------------------------------------------------
# Detect language
# ---------------------------------------------------------------------------
detect_lang() {
  local l="${LC_ALL:-${LANG:-}}"
  l="${l,,}"
  if [[ "$l" == en* ]]; then
    echo "en"
  else
    echo "fr"
  fi
}

# ---------------------------------------------------------------------------
# Print next steps
# ---------------------------------------------------------------------------
print_next_steps() {
  ok "Bootstrap complete!"

  local ui_lang
  ui_lang="$(detect_lang)"

  if [[ "$ui_lang" == "fr" ]]; then
    cat <<EOF

Prochaines étapes :
  1. Vérifier le .env généré :   ${HA_INSTALL_DIR}/.env
  2. Démarrer la stack :         cd ${HA_INSTALL_DIR} && docker compose up -d
  3. Voir les logs :             docker compose logs -f
  4. Accéder à Home Assistant :  http://<ip-de-la-box>:8123

Mise à jour (bootstrap.sh est synchronisé dans ${HA_INSTALL_DIR} ; relance-le en pinning un tag) :
  sudo bash ${HA_INSTALL_DIR}/bootstrap.sh --ref v1.2.3
  # Ou le récupérer depuis GitHub :
  # curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.2.3/bootstrap.sh | sudo bash -s -- --ref v1.2.3

Rappel sécurité :
  - Pinner un tag ou un SHA de commit pour des installs reproductibles.
  - Ne jamais commit .env ou les dossiers de données.

EOF
  else
    cat <<EOF

Next steps:
  1. Review generated .env:   ${HA_INSTALL_DIR}/.env
  2. Start the stack:         cd ${HA_INSTALL_DIR} && docker compose up -d
  3. Check logs:              docker compose logs -f
  4. Access Home Assistant:   http://<box-ip>:8123

Update (bootstrap.sh is synced to ${HA_INSTALL_DIR}; re-run it pinned to new tag):
  sudo bash ${HA_INSTALL_DIR}/bootstrap.sh --ref v1.2.3
  # Or fetch fresh from GitHub:
  # curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.2.3/bootstrap.sh | sudo bash -s -- --ref v1.2.3

Security reminder:
  - Pin to a specific tag or commit SHA for reproducible installs.
  - Never commit .env or data directories to version control.

EOF
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== armbian-ha-kit bootstrap ==="
  log "Ref:         ${HA_REF}"
  log "Install dir: ${HA_INSTALL_DIR}"

  install_prerequisites
  prepare_install_dir
  download_archive
  extract_archive
  run_installer
  if [[ "${HA_SKIP_NEXT_STEPS}" != "1" ]]; then
    print_next_steps
  fi
}

main "$@"
