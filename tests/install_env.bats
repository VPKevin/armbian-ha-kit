#!/usr/bin/env bats

setup() {
  export TMPDIR
  TMPDIR="$(mktemp -d)"
  export STACK_DIR="$TMPDIR/stack"
  export ENV_FILE="$STACK_DIR/.env"
  export RESTIC_DIR="$STACK_DIR/restic"
  export RESTIC_REPOS="$RESTIC_DIR/repos.conf"
  export RESTIC_PASS="$RESTIC_DIR/password"
  export SAMBA_CREDS="$TMPDIR/creds"
  export DEFAULT_COMPOSE_PATH="$TMPDIR/docker-compose.yml"
  export COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"

  mkdir -p "$STACK_DIR"

  # stub dialog: renvoie la valeur par défaut pour inputbox, et "yes" pour yesno
  DIALOG_LOG="$TMPDIR/dialog.log"
  export DIALOG_LOG
  mkdir -p "$TMPDIR/bin"
  cat >"$TMPDIR/bin/dialog" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Log
printf '%s\n' "dialog $*" >>"${DIALOG_LOG}"

case "$*" in
  *--inputbox*)
    # Dernier argument = valeur par défaut
    echo "${@: -1}"
    exit 0
    ;;
  *--passwordbox*)
    echo "secret"
    exit 0
    ;;
  *--yesno*)
    exit 0
    ;;
  *--menu*)
    # Renvoie 1er item (après options). Heuristique: on prend le 1er token non-option.
    # Ici, nos tests n'utilisent pas --menu.
    exit 1
    ;;
  *--msgbox*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$TMPDIR/bin/dialog"
  export PATH="$TMPDIR/bin:$PATH"

  # stub apt_install/dockers
  cat >"$TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
# docker stub: suffit pour detect_docker_subnet
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  echo "172.18.0.0/16"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"
}

test_install_sh_loaded() {
  # Source le script pour accéder aux fonctions
  # shellcheck disable=SC1091
  source "./scripts/install.sh"
}

@test "env_set_kv ajoute une clé sans supprimer les autres" {
  test_install_sh_loaded

  mkdir -p "$STACK_DIR"
  printf 'A=1\nB=2\n' >"$ENV_FILE"

  run env_set_kv "C" "3" "$ENV_FILE"
  [ "$status" -eq 0 ]

  run grep -E '^A=1$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^B=2$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^C=3$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "env_set_kv remplace une clé existante sans toucher aux autres" {
  test_install_sh_loaded

  printf 'A=1\nB=2\n' >"$ENV_FILE"
  run env_set_kv "A" "9" "$ENV_FILE"
  [ "$status" -eq 0 ]

  run grep -E '^A=9$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^B=2$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "compose_extract_vars détecte VAR et VAR:-default" {
  test_install_sh_loaded

  cat >"$COMPOSE_PATH" <<'EOF'
services:
  app:
    environment:
      - TZ=${TZ:-Europe/Paris}
      - FOO=${FOO}
      - BAR=${BAR:-baz}
EOF

  run compose_extract_vars "$COMPOSE_PATH"
  [ "$status" -eq 0 ]

  # Ordre = 1ère apparition
  [[ "$output" == *$'TZ\tEurope/Paris'* ]]
  [[ "$output" == *$'FOO\t'* ]]
  [[ "$output" == *$'BAR\tbaz'* ]]
}

@test "env_ensure_from_compose complète les variables manquantes dans .env" {
  test_install_sh_loaded

  cat >"$COMPOSE_PATH" <<'EOF'
services:
  app:
    environment:
      - TZ=${TZ:-Europe/Paris}
      - FOO=${FOO:-x}
EOF

  # .env ne contient rien au départ
  : >"$ENV_FILE"

  run env_ensure_from_compose "$COMPOSE_PATH"
  [ "$status" -eq 0 ]

  # notre dialog stub renvoie la valeur par défaut
  run grep -E '^TZ=Europe/Paris$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^FOO=x$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}