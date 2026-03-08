#!/usr/bin/env bash
set -euo pipefail

# Helpers dialog. Dépend de scripts/lib/i18n.sh (t()).

# Contracts (P0):
# - Fournit une API pour interactions CLI/UI via dialog: ui_input, ui_pass, ui_yesno,
#   ui_info, ui_confirm, ui_menu, ui_yesno_back, ui_run, ui_notify, ui_progress.
# - Codes retour UI: UI_OK(0), UI_BACK, UI_ABORT.
# - Entrées: variables globales comme STACK_DIR, UI_LOG_DIR, UI_VERBOSE.
# - Sorties: messages affichés et fichiers logs sous UI_LOG_DIR.

# Assure un encodage UTF-8 pour dialog (sinon accents cassés).
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
  # dialog: 0=OK, 1=Cancel, 255=Esc
  local rc="${1:-0}"
  case "$rc" in
    0)   return "$UI_OK" ;;
    1)   return "$UI_BACK" ;;
    255) return "$UI_ABORT" ;;
    *)   return "$UI_ABORT" ;;
  esac
}

# Exécute dialog sans que `set -e` ne termine le script sur Cancel/Esc.
# stdout: la valeur choisie/saisie (si applicable)
# return: code dialog brut (0/1/255)
_ui_dialog_capture() {
  local out rc
  set +e
  out="$(dialog --clear "$@" 3>&1 1>&2 2>&3)"
  rc=$?
  set -e

  # Restore terminal state on the real TTY so the last dialog frame is removed
  # and the cursor/state are sane. We explicitly write to /dev/tty to avoid
  # polluting stdout (which may be captured by callers).
  if [[ -c /dev/tty ]]; then
    if command -v tput >/dev/null 2>&1; then
      tput rmcup >/dev/tty 2>/dev/null || true
    fi
    printf '%b' '\e[?1049l' >/dev/tty 2>/dev/null || true

    # Clear the visible screen and move cursor to home
    printf '%b' '\e[H\e[2J' >/dev/tty 2>/dev/null || true

    # Some environments may not have tput; guard it
    command -v tput >/dev/null 2>&1 && tput cnorm >/dev/tty 2>/dev/null || true
    # restore terminal modes
    stty sane </dev/tty >/dev/tty 2>/dev/null || true
  fi

  # Emit captured output after terminal restoration to avoid mixing with dialog frame
  printf '%s' "$out"

  return "$rc"
}

# Map RC pour dialog (même mapping que pour whiptail)
_ui_map_rc_dialog() {
  local rc="${1:-0}"
  case "$rc" in
    0)   return "$UI_OK" ;;
    1)   return "$UI_BACK" ;;
    255) return "$UI_ABORT" ;;
    *)   return "$UI_ABORT" ;;
  esac
}

# --- New: Generic UI helpers using dialog ---
# ui_input: inputbox (stdout: la valeur saisie)
ui_input() {
  local title="$1" prompt="$2" default="${3:-}"
  local out
  out="$(_ui_dialog_capture --title "$title" --inputbox "$prompt" 10 70 "$default" \
    --ok-label "$(t VALIDATE)" --cancel-label "$(t BACK)")"
  local rc=$?
  _ui_map_rc_dialog "$rc" || return $?
  printf '%s' "$out"
}

# ui_pass: passwordbox
ui_pass() {
  local title="$1" prompt="$2"
  local out
  out="$(_ui_dialog_capture --title "$title" --passwordbox "$prompt" 10 70 \
    --ok-label "$(t VALIDATE)" --cancel-label "$(t BACK)")"
  local rc=$?
  _ui_map_rc_dialog "$rc" || return $?
  printf '%s' "$out"
}

# ui_yesno: simple yes/no (returns UI_OK/UI_BACK/UI_ABORT)
ui_yesno() {
  local title="$1" prompt="$2"
  _ui_dialog_capture --title "$title" --yesno "$prompt" 10 70 \
    --yes-label "$(t YES)" --no-label "$(t NO)" >/dev/null
  local rc=$?
  _ui_map_rc_dialog "$rc" || return $?
}

# ui_info: msgbox with non-interactive fallback
ui_info() {
  local title="$1" msg="$2"
  if ! is_interactive_tty; then
    printf '\n[%s]\n%s\n\n' "$title" "$msg" >&2
    return "$UI_OK"
  fi
  _ui_dialog_capture --title "$title" --msgbox "$msg" 12 80 --ok-label "$(t OK)" >/dev/null
  local rc=$?
  _ui_map_rc_dialog "$rc" || return $?
}

# ui_confirm: yes/no confirmation (same as ui_yesno)
ui_confirm() { ui_yesno "$@"; }

# ui_yesno_back: menu-based yes/no with Back via Cancel; stdout: yes|no
ui_yesno_back() {
  local title="$1" prompt="$2" default_item="${3:-}"
  local args=()
  if [[ -n "$default_item" ]]; then
    args+=(--default-item "$default_item")
  fi
  local out
  out="$(_ui_dialog_capture --title "$title" --menu "$prompt" 12 70 2 "${args[@]}" \
    yes "$(t YES)" no "$(t NO)" --ok-label "$(t VALIDATE)" --cancel-label "$(t BACK)")"
  local rc=$?
  _ui_map_rc_dialog "$rc" || return $?
  printf '%s' "$out"
}

# Menu générique: implémentation basée sur dialog (API compatible)
# Usage: ui_menu "Titre" "Prompt" H W LIST_HEIGHT key1 label1 key2 label2 ...
# - stdout: la clé choisie
# - return: UI_OK/UI_BACK/UI_ABORT
_ui_menu() {
  local title="$1" prompt="$2" height="$3" width="$4" list_height="$5"
  shift 5

  local out
  out="$(_ui_dialog_capture --title "$title" --menu "$prompt" "$height" "$width" "$list_height" "$@")"
  local rc=$?

  _ui_map_rc_dialog "$rc" || return $?
  printf '%s' "$out"
}

# Public wrapper demandé: ui_menu
ui_menu() { _ui_menu "$@"; }

# Alias historique demandé: di_menu -> ui_menu
di_menu() { ui_menu "$@"; }

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


# Ensure terminal is restored on script exit as a safety net (clears lingering dialog frame)
_ui_restore_terminal() {
  if [[ -c /dev/tty ]]; then
    if command -v tput >/dev/null 2>&1; then
      tput rmcup >/dev/tty 2>/dev/null || true
    fi
    printf '%b' '\e[?1049l' >/dev/tty 2>/dev/null || true
    printf '%b' '\e[H\e[2J' >/dev/tty 2>/dev/null || true
    command -v tput >/dev/null 2>&1 && tput cnorm >/dev/tty 2>/dev/null || true
    stty sane </dev/tty >/dev/tty 2>/dev/null || true
  fi
}
trap _ui_restore_terminal EXIT