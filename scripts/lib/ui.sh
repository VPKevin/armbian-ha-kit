#!/usr/bin/env bash
set -euo pipefail

# Helpers whiptail. Dépend de scripts/lib/i18n.sh (t()).

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

whi_input() {
  local title="$1" prompt="$2" default="${3:-}"
  local out
  out="$(whiptail --title "$title" --inputbox "$prompt" 10 70 "$default" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" 3>&1 1>&2 2>&3)"
  local rc=$?
  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

whi_pass() {
  local title="$1" prompt="$2"
  local out
  out="$(whiptail --title "$title" --passwordbox "$prompt" 10 70 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" 3>&1 1>&2 2>&3)"
  local rc=$?
  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}

whi_yesno() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
  local rc=$?
  _ui_map_rc "$rc" || return $?
}

whi_info() {
  local title="$1" msg="$2"
  whiptail --title "$title" --msgbox "$msg" 12 80 --ok-button "$(t OK)"
}

whi_confirm() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
  local rc=$?
  _ui_map_rc "$rc" || return $?
}

# Menu générique. Usage: whi_menu "Titre" "Prompt" H W LIST_HEIGHT key1 label1 key2 label2 ...
# - stdout: la clé choisie
# - return: UI_OK/UI_BACK/UI_ABORT
whi_menu() {
  local title="$1" prompt="$2" height="$3" width="$4" list_height="$5"
  shift 5
  local out
  out="$(whiptail --title "$title" --menu "$prompt" "$height" "$width" "$list_height" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "$@" 3>&1 1>&2 2>&3)"
  local rc=$?
  _ui_map_rc "$rc" || return $?
  printf '%s' "$out"
}
