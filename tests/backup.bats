#!/usr/bin/env bats

# Tests non-interactifs pour scripts/backup.sh
#
# Contrat testé (audit §3.1) :
# - un repo restic en échec n'empêche pas les suivants, mais le script sort
#   non-zéro ;
# - un échec de pg_dump ne laisse pas de dump partiel et n'empêche pas restic ;
# - aucun repo configuré => succès (skip restic).

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

  # repos.conf vide par défaut -> comportement skip
  : > "$STACK_DIR/restic/repos.conf"

  mkdir -p "$TMPDIR/bin"

  # stub docker :
  # - `docker exec ... pg_dump ...` écrit le dump sur STDOUT (le script le pipe
  #   dans gzip) ; échoue si PG_FAIL=1.
  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "exec" ]]; then
  if [[ "${PG_FAIL:-0}" == "1" ]]; then
    echo "pg_dump: error (stub)" >&2
    exit 1
  fi
  echo "-- fake pg dump"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  # stub restic : journalise chaque appel (repo + sous-commande) dans
  # RESTIC_LOG ; échoue si RESTIC_REPOSITORY == RESTIC_FAIL_REPO.
  export RESTIC_LOG="$TMPDIR/restic.log"
  cat > "$TMPDIR/bin/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${RESTIC_REPOSITORY:-}" "$1" >> "${RESTIC_LOG}"
if [[ -n "${RESTIC_FAIL_REPO:-}" && "${RESTIC_REPOSITORY:-}" == "${RESTIC_FAIL_REPO}" ]]; then
  exit 1
fi
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
  # le dump local a été créé (gzippé, non vide)
  run bash -c "ls $STACK_DIR/backup/postgres-*.sql.gz"
  [ "$status" -eq 0 ]
}

@test "backup.sh continue sur le repo suivant quand un repo échoue, et sort non-zéro" {
  printf '%s\n%s\n' "$TMPDIR/repo-dead" "$TMPDIR/repo-ok" > "$STACK_DIR/restic/repos.conf"
  export RESTIC_FAIL_REPO="$TMPDIR/repo-dead"

  run bash ./scripts/backup.sh
  [ "$status" -eq 1 ]
  # l'échec est explicite dans la sortie (avant tout autre `run` qui écrase $output)
  [[ "$output" == *"restic backup failed"* ]]

  # le repo sain a bien été sauvegardé ET purgé
  run grep -F "$TMPDIR/repo-ok backup" "$RESTIC_LOG"
  [ "$status" -eq 0 ]
  run grep -F "$TMPDIR/repo-ok forget" "$RESTIC_LOG"
  [ "$status" -eq 0 ]
  # pas de forget tenté sur le repo mort
  run grep -F "$TMPDIR/repo-dead forget" "$RESTIC_LOG"
  [ "$status" -ne 0 ]
}

@test "backup.sh sur échec pg_dump: pas de dump partiel, restic tenté quand même, exit non-zéro" {
  printf '%s\n' "$TMPDIR/repo-ok" > "$STACK_DIR/restic/repos.conf"
  export PG_FAIL=1

  run bash ./scripts/backup.sh
  [ "$status" -eq 1 ]
  # l'échec est explicite dans la sortie (avant tout autre `run` qui écrase $output)
  [[ "$output" == *"pg_dump"* ]]

  # aucun dump partiel laissé sur disque
  run bash -c "ls $STACK_DIR/backup/postgres-*.sql.gz"
  [ "$status" -ne 0 ]
  # restic a quand même tourné (le backup de config/ reste utile)
  run grep -F "$TMPDIR/repo-ok backup" "$RESTIC_LOG"
  [ "$status" -eq 0 ]
}

@test "backup.sh n'expose aucun secret sur la ligne de commande (pas de PGPASSWORD=)" {
  # usage réel (PGPASSWORD=...), pas le commentaire qui documente son retrait
  run grep -F "PGPASSWORD=" ./scripts/backup.sh
  [ "$status" -ne 0 ]
}
