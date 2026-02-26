#!/usr/bin/env bats

setup() {
  export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
}

@test "restore wizard: Back on first step returns UI_BACK (does not abort)" {
  run bash -c '
    set -euo pipefail
    source "'"$PROJECT_ROOT"'"/scripts/lib/ui.sh
    source "'"$PROJECT_ROOT"'"/scripts/lib/common.sh

    export STACK_DIR="/tmp/ha-stack"
    export RESTIC_DIR="/tmp/ha-stack/restic"
    export RESTIC_PASS="/tmp/ha-stack/restic/password"
    export RESTIC_REPOS="/tmp/ha-stack/restic/repos.conf"

    mkdir -p "$(dirname "$RESTIC_PASS")"
    echo "dummy" >"$RESTIC_PASS"

    ensure_restic() { return 0; }
    restic_choose_repo() { return 10; }
    whi_info() { return 0; }

    source "'"$PROJECT_ROOT"'"/scripts/lib/restic.sh

    set +e
    restore_wizard
    rc=$?
    set -e
    echo "RC:${rc}"
    echo "UI_BACK:${UI_BACK}"
    exit 0
  '

  if [ "$status" -ne 0 ]; then
    echo "Test runner status=$status" >&2
    echo "output=[$output]" >&2
  fi

  [ "$status" -eq 0 ]
  [[ "$output" == *"RC:10"* ]]
}
