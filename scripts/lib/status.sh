#!/usr/bin/env bash
set -euo pipefail

# Affiche un status lisible de la stack et de ses composants.

status_wizard() {
  local stack_dir="${STACK_DIR:-/srv/ha-stack}"
  local compose_path="${COMPOSE_PATH:-${stack_dir}/docker-compose.yml}"

  local installed="non"
  [[ -d "$stack_dir" ]] && installed="oui"

  local compose_present="non"
  [[ -f "$compose_path" ]] && compose_present="oui"

  local env_present="non"
  [[ -f "${ENV_FILE:-${stack_dir}/.env}" ]] && env_present="oui"

  local caddy_enabled="(inconnu)"
  if [[ -f "${ENV_FILE:-${stack_dir}/.env}" ]]; then
    local v
    v="$(env_get "ENABLE_CADDY" "${ENV_FILE:-${stack_dir}/.env}" 2>/dev/null || true)"
    if [[ -n "${v:-}" ]]; then
      if [[ "$v" == "1" || "$v" == "true" ]]; then caddy_enabled="oui"; else caddy_enabled="non"; fi
    fi
  fi

  local upnp_enabled="(inconnu)"
  if [[ -f "${ENV_FILE:-${stack_dir}/.env}" ]]; then
    local v
    v="$(env_get "ENABLE_UPNP" "${ENV_FILE:-${stack_dir}/.env}" 2>/dev/null || true)"
    if [[ -n "${v:-}" ]]; then
      if [[ "$v" == "1" || "$v" == "true" ]]; then upnp_enabled="oui"; else upnp_enabled="non"; fi
    fi
  fi

  local timer_status="absent"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ha-backup\.timer'; then
    timer_status="$(systemctl is-enabled ha-backup.timer 2>/dev/null || true) / $(systemctl is-active ha-backup.timer 2>/dev/null || true)"
  fi

  local docker_status="absent"
  if command -v docker >/dev/null 2>&1; then
    docker_status="ok"
  fi

  local compose_ps="(docker/compose indisponible ou stack non démarrée)"
  if command -v docker >/dev/null 2>&1 && [[ -d "$stack_dir" ]] && [[ -f "$compose_path" ]]; then
    compose_ps="$({ cd "$stack_dir" && docker compose -f "$compose_path" ps 2>&1; } || true)"
  fi

  local msg
  msg="$(cat <<EOF
Stack installée : ${installed}
STACK_DIR       : ${stack_dir}
Compose présent : ${compose_present}
.env présent    : ${env_present}

Fonctionnalités
  - Caddy/Proxy : ${caddy_enabled}
  - UPnP        : ${upnp_enabled}

Sauvegarde (systemd)
  - ha-backup.timer : ${timer_status}

Docker : ${docker_status}

Docker Compose - ps:
${compose_ps}
EOF
)"

  whiptail --title "Status" --msgbox "$msg" 30 100 --ok-button "$(t OK)"
}

