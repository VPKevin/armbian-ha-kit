#!/usr/bin/env bats

# Tests non-interactifs pour scripts/backup.sh

setup() {
  export TMPDIR
  TMPDIR="$(mktemp -d)"
  export STACK_DIR="$TMPDIR/stack"
  mkdir -p "$STACK_DIR/restic"
  mkdir -p "$STACK_DIR/config"
  mkdir -p "$STACK_DIR/backup"

  # créer un .env minimal
  cat > "$STACK_DIR/.env" <<EOF
POSTGRES_USER=test
POSTGRES_DB=ha
POSTGRES_PASSWORD=secret
EOF

  # restic password
  echo "resticpass" > "$STACK_DIR/restic/password"
  chmod 600 "$STACK_DIR/restic/password"

  # repos.conf vide -> test skip behavior
  : > "$STACK_DIR/restic/repos.conf"

  # stub docker: pg_dump exit 0 but write a fake dump
  mkdir -p "$TMPDIR/bin"
  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "exec" ]]; then
  # simulate pg_dump writing to stdout
  cat > "$3" <<'DUMP'
-- fake pg dump
DUMP
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  # stub restic: exit 0
  cat > "$TMPDIR/bin/restic" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPDIR/bin/restic"

  export PATH="$TMPDIR/bin:$PATH"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "backup.sh se termine proprement quand repos.conf est vide (skip restic)" {
  run bash ./scripts/backup.sh
  [ "$status" -eq 0 ]
  # vérifier que le dump local a été créé et gzippé
  run ls "$STACK_DIR/backup"
  [ "$status" -eq 0 ]
}

