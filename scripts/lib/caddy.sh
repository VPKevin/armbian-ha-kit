#!/usr/bin/env bash
set -euo pipefail

# Caddy domain/email prompt + persistence.

prompt_caddy_domain() {
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

  ha_domain="$(whi_input "Caddy" "Nom de domaine (ex: ha.example.com)" "${ha_domain:-}")" || return 1
  le_email="$(whi_input "Caddy" "Email Let's Encrypt" "${le_email:-}")" || return 1

  ha_domain="$(strip_key_prefix_if_any "HA_DOMAIN" "$ha_domain")"
  le_email="$(strip_key_prefix_if_any "LE_EMAIL" "$le_email")"

  if [[ -z "${ha_domain:-}" || -z "${le_email:-}" ]]; then
    whi_info "Caddy" "Domaine et email sont requis si Caddy est activé."
    return 1
  fi

  env_set_kv "HA_DOMAIN" "$ha_domain" "$ENV_FILE"
  env_set_kv "LE_EMAIL" "$le_email" "$ENV_FILE"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}
