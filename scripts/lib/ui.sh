#!/usr/bin/env bash
set -euo pipefail

# Helpers whiptail. Dépend de scripts/lib/i18n.sh (t()).

whi_input() {
  local title="$1" prompt="$2" default="${3:-}"
  whiptail --title "$title" --inputbox "$prompt" 10 70 "$default" \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" 3>&1 1>&2 2>&3
}

whi_pass() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --passwordbox "$prompt" 10 70 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" 3>&1 1>&2 2>&3
}

whi_yesno() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
}

whi_info() {
  local title="$1" msg="$2"
  whiptail --title "$title" --msgbox "$msg" 12 80 --ok-button "$(t OK)"
}

whi_confirm() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "$(t YES)" --no-button "$(t NO)"
}

