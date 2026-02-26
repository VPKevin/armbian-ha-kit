#!/usr/bin/env bats

setup() {
  export TMPDIR
  TMPDIR="$(mktemp -d)"

  export STACK_DIR="$TMPDIR/stack"
  export RESTIC_DIR="$STACK_DIR/restic"
  export RESTIC_REPOS="$RESTIC_DIR/repos.conf"
  export RESTIC_PASS="$RESTIC_DIR/password"

  mkdir -p "$RESTIC_DIR"
  printf 'dummy' >"$RESTIC_PASS"

  # stub whiptail + log, pour éviter toute interaction.
  WHIPTAIL_LOG="$TMPDIR/whiptail.log"
  export WHIPTAIL_LOG
  mkdir -p "$TMPDIR/bin"
  cat >"$TMPDIR/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "whiptail $*" >>"${WHIPTAIL_LOG}"
# msgbox => OK
if [[ "$*" == *"--msgbox"* ]]; then
  exit 0
fi
# menu => cancel (pour que notre wrapper gère bien les retours)
if [[ "$*" == *"--menu"* ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/whiptail"
  export PATH="$TMPDIR/bin:$PATH"
}

@test "restic_choose_repo: sans repos.conf, n'entre pas en boucle et affiche un message" {
  run bash -c '
    set -euo pipefail
    cd /repo
    export STACK_DIR RESTIC_DIR RESTIC_REPOS RESTIC_PASS WHIPTAIL_LOG
    source ./scripts/lib/i18n.sh
    source ./scripts/lib/common.sh
    source ./scripts/lib/ui.sh
    source ./scripts/lib/restic.sh

    # doit retourner non-0 car pas de repo, mais ne doit pas bloquer
    restic_choose_repo
  '

  [ "$status" -ne 0 ]
  # whi_info utilise whiptail --msgbox; on valide que l'info a bien été affichée.
  run grep -F "Aucun repository" "$WHIPTAIL_LOG"
  [ "$status" -eq 0 ]
}