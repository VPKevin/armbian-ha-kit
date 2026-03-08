#!/usr/bin/env bash
set -euo pipefail

# Caddy domain/email prompt + persistence.

# Contracts (P0):
# - Fonctions: prompt_caddy_domain
# - Entrées: ENABLE_CADDY, ENV_FILE, STACK_DIR
# - Sorties: écrit HA_DOMAIN et LE_EMAIL dans $ENV_FILE via env_set_kv
# - Codes retour: 0 succès, UI_BACK/UI_ABORT ou code non-zero en cas d'erreur.

prompt_caddy_domain() {
  CADDY_PROMPTED=0
  # Demande uniquement si Caddy est activé.
  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_caddy:-}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi

  if [[ "$enable_caddy" == "0" || "$enable_caddy" == "false" ]]; then
    return 0
  fi

  local ha_domain le_email
  ha_domain="$(env_get "HA_DOMAIN" "$ENV_FILE" 2>/dev/null || true)"
  le_email="$(env_get "LE_EMAIL" "$ENV_FILE" 2>/dev/null || true)"

  # Nettoie si une valeur polluée "KEY=VALUE" s'est glissée.
  ha_domain="$(strip_key_prefix_if_any "HA_DOMAIN" "$ha_domain")"
  le_email="$(strip_key_prefix_if_any "LE_EMAIL" "$le_email")"

  ha_domain="$(ui_input "Caddy" "Nom de domaine (ex: ha.example.com)" "${ha_domain:-}")" || return $?
  CADDY_PROMPTED=1
  le_email="$(ui_input "Caddy" "Email Let's Encrypt" "${le_email:-}")" || return $?
  CADDY_PROMPTED=1

  ha_domain="$(strip_key_prefix_if_any "HA_DOMAIN" "$ha_domain")"
  le_email="$(strip_key_prefix_if_any "LE_EMAIL" "$le_email")"

  if [[ -z "${ha_domain:-}" || -z "${le_email:-}" ]]; then
    ui_info "Caddy" "Domaine et email sont requis si Caddy est activé."
    return 1
  fi

  env_set_kv "HA_DOMAIN" "$ha_domain" "$ENV_FILE"
  env_set_kv "LE_EMAIL" "$le_email" "$ENV_FILE"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}