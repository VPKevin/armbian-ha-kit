#!/usr/bin/env bash
set -euo pipefail

# Helpers whiptail. Dépend de scripts/lib/i18n.sh (t()).

# Assure un encodage UTF-8 pour whiptail (sinon accents cassés).
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

# Contrat de navigation UI:
# - UI_OK    : validation
# - UI_BACK  : retour (Cancel)
# - UI_ABORT : abandon global (Esc)
UI_OK=0
UI_BACK=10
UI_ABORT=20

_ui_map_rc() {
  # whiptail: 0=OK, 1=Cancel, 255=Esc
  local rc="${1:-0}"
  case "$rc" in
    0)   return "$UI_OK" ;;
    1)   return "$UI_BACK" ;;
    255) return "$UI_ABORT" ;;
    *)   return "$UI_ABORT" ;;
  esac
}

# Exécute whiptail sans que `set -e` ne termine le script sur Cancel/Esc.
# stdout: la valeur choisie/saisie (si applicable)
# return: code whiptail brut (0/1/255)
_ui_whiptail_capture() {
  local out rc
  set +e
  out="$(whiptail "$@" 3>&1 1>&2 2>&3)"
  rc=$?
  set -e
  printf '%s' "$out"
  return "$rc"
}

whi_input() {
  local title="$1" prompt="$2" default="${3:-}"

  local out
  out="$(_ui_whiptail_capture --title "$title" --inputbox "$prompt" 10 70 "$default" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)")"
  local rc=$?

  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

whi_pass() {
  local title="$1" prompt="$2"

  local out
  out="$(_ui_whiptail_capture --title "$title" --passwordbox "$prompt" 10 70 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)")"
  local rc=$?

  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

whi_yesno() {
  local title="$1" prompt="$2"

  set +e
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
  local rc=$?
  set -e

  _ui_map_rc "$rc" || return $?
}

whi_info() {
  local title="$1" msg="$2"

  # En environnement non-interactif (CI, container sans /dev/tty), whiptail peut bloquer
  # ou échouer. On fallback sur une sortie console.
  if ! is_interactive_tty; then
    printf '\n[%s]\n%s\n\n' "$title" "$msg" >&2
    return "$UI_OK"
  fi

  # Exécute via le wrapper pour éviter que `set -e` casse le flot sur Cancel/Esc.
  _ui_whiptail_capture --title "$title" --msgbox "$msg" 12 80 --ok-button "$(t OK)" >/dev/null
  local rc=$?
  _ui_map_rc "$rc" || return $?
}

whi_confirm() {
  local title="$1" prompt="$2"

  set +e
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
  local rc=$?
  set -e

  _ui_map_rc "$rc" || return $?
}

# Yes/No menu with Back via Cancel button; optional default item (yes|no).
# stdout: "yes" or "no"
# return: UI_OK/UI_BACK/UI_ABORT
whi_yesno_back() {
  local title="$1" prompt="$2" default="${3:-}"

  local args=()
  if [[ -n "${default:-}" ]]; then
    args+=(--default-item "$default")
  fi

  local out
  out="$(_ui_whiptail_capture --title "$title" --menu "$prompt" 12 70 2 \
    "${args[@]}" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    yes "$(t YES)" \
    no "$(t NO)")"
  local rc=$?

  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

# Menu générique. Usage: whi_menu "Titre" "Prompt" H W LIST_HEIGHT key1 label1 key2 label2 ...
# - stdout: la clé choisie
# - return: UI_OK/UI_BACK/UI_ABORT
whi_menu() {
  local title="$1" prompt="$2" height="$3" width="$4" list_height="$5"
  shift 5

  local out
  out="$(_ui_whiptail_capture --title "$title" --menu "$prompt" "$height" "$width" "$list_height" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "$@")"
  local rc=$?

  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

# ----------------------
# UI helpers: run/notify/progress
# ----------------------

# Default log dir (can be overridden via UI_LOG_DIR env var). STACK_DIR is defined elsewhere.
UI_LOG_DIR="${UI_LOG_DIR:-${STACK_DIR:-/srv/ha-stack}/logs}"

_ui_ensure_log_dir() {
  mkdir -p "$UI_LOG_DIR" 2>/dev/null || true
  chmod 700 "$UI_LOG_DIR" 2>/dev/null || true
}

# ui_notify: affiche une ligne de statut simple.
# ui_notify "Libellé" [status]
# status: empty (in progress), ok, fail
ui_notify() {
  local label="$1" status="${2:-}"
  case "$status" in
    ok)
      printf "\r✓ %s\n" "$label"
      ;;
    fail)
      printf "\r✗ %s\n" "$label"
      ;;
    *)
      printf "→ %s …\n" "$label"
      ;;
  esac
}

# ui_run: exécute une commande, journalise la sortie et affiche une ligne de statut.
# Usage: ui_run "Libellé" -- <command> [args...]
# Expose: UI_LAST_LOG, UI_LAST_EXIT
ui_run() {
  local label="${1:-}"; shift || true
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if [[ -z "$label" ]]; then
    echo "ui_run: missing label" >&2
    return 2
  fi
  if [[ $# -eq 0 ]]; then
    echo "ui_run: missing command" >&2
    return 2
  fi

  _ui_ensure_log_dir
  local ts pid rc
  ts="$(date +%Y%m%d-%H%M%S)"
  local safe_label
  safe_label="$(printf '%s' "$label" | tr ' /' '__' | tr -cd '[:alnum:]_-')"
  local logf="$UI_LOG_DIR/${ts}-$$-${safe_label}.log"

  UI_LAST_LOG="$logf"

  # Mode verbeux: stream la sortie en direct + log via tee
  if [[ "${UI_VERBOSE:-0}" -eq 1 ]]; then
    printf "→ %s …\n" "$label"
    # shellcheck disable=SC2046
    "$@" 2>&1 | tee -a "$logf"
    rc=${PIPESTATUS[0]:-0}
    UI_LAST_EXIT=${rc}
    if [[ $rc -eq 0 ]]; then
      printf "✓ %s\n" "$label"
    else
      printf "✗ %s (voir log: %s)\n" "$label" "$logf"
    fi
    return $rc
  fi

  # Mode terse: rediriger la sortie vers le log et afficher un spinner
  printf "→ %s …" "$label"
  (
    # Exécuter la commande dans un sous-shell pour capturer sortie dans log
    "$@" >"$logf" 2>&1
  ) &
  pid=$!

  local spinner=("/" "-" "\\" "|")
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    local sc="${spinner[i % ${#spinner[@]}]}"
    printf "\r→ %s … %s" "$label" "$sc"
    i=$((i+1))
    sleep 0.12
  done
  wait "$pid" || rc=$?
  rc=${rc:-0}
  UI_LAST_EXIT=${rc}

  if [[ $rc -eq 0 ]]; then
    printf "\r✓ %s\n" "$label"
  else
    printf "\r✗ %s (voir log: %s)\n" "$label" "$logf"
  fi

  return $rc
}

# ui_progress: gestion simple d'une progression basée sur étapes.
# ui_progress start "Label" total_steps
# ui_progress step
# ui_progress finish [ok|fail]
ui_progress() {
  local cmd="${1:-}"
  case "$cmd" in
    start)
      UI_PROGRESS_LABEL="${2:-Progress}"
      UI_PROGRESS_TOTAL=${3:-0}
      UI_PROGRESS_CUR=0
      UI_PROGRESS_BAR_WIDTH=40
      printf "→ %s … 0%%" "$UI_PROGRESS_LABEL"
      ;;
    step)
      UI_PROGRESS_CUR=$((UI_PROGRESS_CUR + 1))
      if [[ ${UI_PROGRESS_TOTAL:-0} -gt 0 ]]; then
        local pct=$((UI_PROGRESS_CUR * 100 / UI_PROGRESS_TOTAL))
        local filled=$(( (pct * UI_PROGRESS_BAR_WIDTH) / 100 ))
        local empty=$((UI_PROGRESS_BAR_WIDTH - filled))
        local bar
        bar="$(printf '%0.s#' $(seq 1 $filled))$(printf '%0.s-' $(seq 1 $empty))"
        printf "\r→ %s … %3d%% [%s]" "$UI_PROGRESS_LABEL" "$pct" "$bar"
        if [[ $UI_PROGRESS_CUR -ge $UI_PROGRESS_TOTAL ]]; then
          printf "\n"
        fi
      else
        # fallback: spinner-like output
        local s=("/" "-" "\\" "|")
        local idx=$((UI_PROGRESS_CUR % 4))
        printf "\r→ %s … %s" "$UI_PROGRESS_LABEL" "${s[idx]}"
      fi
      ;;
    finish)
      local status="${2:-ok}"
      if [[ "$status" == "ok" ]]; then
        printf "\r✓ %s\n" "${UI_PROGRESS_LABEL:-Progress}"
      else
        printf "\r✗ %s\n" "${UI_PROGRESS_LABEL:-Progress}"
      fi
      UI_PROGRESS_LABEL=""
      UI_PROGRESS_TOTAL=0
      UI_PROGRESS_CUR=0
      ;;
    *)
      return 2
      ;;
  esac
}
