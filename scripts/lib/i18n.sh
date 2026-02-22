#!/usr/bin/env bash
set -euo pipefail

# i18n minimal FR/EN basé sur la locale.

detect_lang() {
  local l="${LC_ALL:-${LANG:-}}"
  l="${l,,}"
  if [[ "$l" == en* ]]; then
    echo "en"
  else
    echo "fr"
  fi
}

UI_LANG="${UI_LANG:-$(detect_lang)}"

# NOTE shellcheck:
# Les variables TXT_* sont utilisées via expansion indirecte dans t() (ex: ${!var}),
# donc shellcheck ne peut pas détecter l'usage. On désactive SC2034 pour ce fichier.
# shellcheck disable=SC2034

# shellcheck disable=SC2034
TXT_OK_fr="OK"
# shellcheck disable=SC2034
TXT_OK_en="OK"

# shellcheck disable=SC2034
TXT_VALIDATE_fr="Valider"
# shellcheck disable=SC2034
TXT_VALIDATE_en="OK"

# shellcheck disable=SC2034
TXT_BACK_fr="Retour"
# shellcheck disable=SC2034
TXT_BACK_en="Back"

# shellcheck disable=SC2034
TXT_YES_fr="Oui"
# shellcheck disable=SC2034
TXT_YES_en="Yes"

# shellcheck disable=SC2034
TXT_NO_fr="Non"
# shellcheck disable=SC2034
TXT_NO_en="No"

t() {
  local key="$1"
  local var="TXT_${key}_${UI_LANG}"
  if [[ -n "${!var:-}" ]]; then
    printf "%s" "${!var}"
  else
    printf "%s" "$key"
  fi
}
