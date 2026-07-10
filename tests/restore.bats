#!/usr/bin/env bats

# Cycle complet backup -> perte -> restore avec un restic RÉEL (pas de stub).
# C'est la promesse centrale du kit (audit §P2 tests) : vérifier que les
# données sauvegardées par scripts/backup.sh sont effectivement restaurables.
# Skippé si restic n'est pas installé (il l'est en CI).

setup() {
  command -v restic >/dev/null 2>&1 || skip "restic absent"

  export TMPDIR
  TMPDIR="$(mktemp -d)"
  export STACK_DIR="$TMPDIR/stack"
  mkdir -p "$STACK_DIR/restic" "$STACK_DIR/config" "$STACK_DIR/backup" "$TMPDIR/repo"

  cat > "$STACK_DIR/.env" <<EOF
POSTGRES_USER=test
POSTGRES_DB=ha
POSTGRES_PASSWORD=secret
EOF

  echo "resticpass" > "$STACK_DIR/restic/password"
  chmod 600 "$STACK_DIR/restic/password"
  printf '%s\n' "$TMPDIR/repo" > "$STACK_DIR/restic/repos.conf"

  # Contenu "précieux" à sauvegarder
  printf 'homeassistant:\n  name: MaMaison\n' > "$STACK_DIR/config/configuration.yaml"
  printf 'secret-yaml-content\n' > "$STACK_DIR/config/secrets.yaml"

  # stub docker (le dump Postgres n'est pas l'objet de ce test)
  mkdir -p "$TMPDIR/bin"
  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "exec" ]]; then
  echo "-- fake pg dump"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"
  export PATH="$TMPDIR/bin:$PATH"

  RESTIC_REPOSITORY="$TMPDIR/repo" RESTIC_PASSWORD_FILE="$STACK_DIR/restic/password" \
    restic init >/dev/null 2>&1
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "cycle backup -> perte des données -> restore : contenu restauré identique" {
  # 1) backup réel via le script du kit
  run bash ./scripts/backup.sh
  [ "$status" -eq 0 ]

  # 2) perte des données
  rm -rf "$STACK_DIR/config"

  # 3) restore réel (même mécanique que restore_step_run)
  export RESTIC_REPOSITORY="$TMPDIR/repo"
  export RESTIC_PASSWORD_FILE="$STACK_DIR/restic/password"
  run restic restore latest --target "$TMPDIR/restored"
  [ "$status" -eq 0 ]

  # 4) le contenu restauré est identique (restic préserve les chemins absolus)
  run cat "$TMPDIR/restored$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MaMaison"* ]]
  run cat "$TMPDIR/restored$STACK_DIR/config/secrets.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "secret-yaml-content" ]
  # le dump postgres du backup fait aussi partie du snapshot
  run bash -c "ls $TMPDIR/restored$STACK_DIR/backup/postgres-*.sql.gz"
  [ "$status" -eq 0 ]
}
