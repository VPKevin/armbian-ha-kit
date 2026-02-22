#!/usr/bin/env bash
set -euo pipefail

# Affiche un status lisible de la stack et de ses composants.

fmt_bool() {
  local v="${1:-}"
  case "$v" in
    1|true|yes|oui|on) echo "oui" ;;
    0|false|no|non|off) echo "non" ;;
    *) echo "(inconnu)" ;;
  esac
}

fmt_bool_default_no() {
  local v="${1:-}"
  case "$v" in
    1|true|yes|oui|on) echo "oui" ;;
    0|false|no|non|off|'') echo "non" ;;
    *) echo "non" ;;
  esac
}

get_last_backup_local() {
  local backup_dir="$1"
  [[ -d "$backup_dir" ]] || return 1

  local newest=""
  # macOS: stat -f %m, Linux: stat -c %Y
  while IFS= read -r f; do
    [[ -z "${f:-}" ]] && continue
    local m
    m="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    if [[ -z "${newest:-}" ]]; then
      newest="$f:$m"
      continue
    fi
    local cur_m
    cur_m="${newest##*:}"
    if (( m > cur_m )); then
      newest="$f:$m"
    fi
  done < <(find "$backup_dir" -maxdepth 1 -type f -name 'postgres-*.sql.gz' 2>/dev/null)

  [[ -n "${newest:-}" ]] || return 1
  local newest_file
  newest_file="${newest%:*}"

  date -r "$newest_file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true
}

get_last_restic_snapshot() {
  local repo="$1" passfile="$2"
  [[ -n "${repo:-}" && -f "$passfile" ]] || return 1
  command -v restic >/dev/null 2>&1 || return 1

  RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE="$passfile" \
    restic snapshots --compact 2>/dev/null \
    | awk 'NR>2 && $1 ~ /^[0-9a-f]+$/ {print $2" "$3" "$4" "$5; exit}'
}

docker_ports_for_container() {
  local name="$1"
  command -v docker >/dev/null 2>&1 || return 0
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "-"
    return 0
  fi

  local out=""
  out="$(docker port "$name" 2>/dev/null | awk '{print $1"->"$3}' | paste -sd ',' - 2>/dev/null || true)"
  [[ -n "${out:-}" ]] && echo "$out" || echo "-"
}

compose_ps_compact() {
  local _stack_dir="$1" _compose_path="$2"

  # On n'essaye plus de parser le JSON de docker compose (format variable selon versions).
  # On utilise l'API docker (inspect + docker port) en se basant sur les noms fixes.
  local names=(ha-postgres homeassistant)

  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_caddy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi
  if [[ "${enable_caddy:-0}" == "1" || "${enable_caddy:-}" == "true" ]]; then
    names=(ha-caddy ha-postgres homeassistant)
  elif docker inspect ha-caddy >/dev/null 2>&1; then
    # fallback: si le conteneur existe, on l'inclut.
    names=(ha-caddy ha-postgres homeassistant)
  fi

  {
    printf '%-16s %-10s %-10s %s\n' "NAME" "STATE" "HEALTH" "PORTS"
    for n in "${names[@]}"; do
      local state health ports
      state="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo "missing")"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n" 2>/dev/null || true)"
      [[ -z "${health:-}" ]] && health="-"
      ports="$(docker_ports_for_container "$n")"
      printf '%-16s %-10s %-10s %s\n' "$n" "$state" "$health" "$ports"
    done
  } | cat
}

status_wizard() {
  local stack_dir="${STACK_DIR:-/srv/ha-stack}"
  local compose_path="${COMPOSE_PATH:-${stack_dir}/docker-compose.yml}"
  local env_file="${ENV_FILE:-${stack_dir}/.env}"

  local compose_present="non"
  [[ -f "$compose_path" ]] && compose_present="oui"

  local env_present="non"
  [[ -f "$env_file" ]] && env_present="oui"

  local any_project_artifact=0
  [[ -f "$compose_path" || -f "$env_file" || -f "${stack_dir}/config/configuration.yaml" ]] && any_project_artifact=1

  local any_runtime=0
  if command -v docker >/dev/null 2>&1; then
    docker inspect ha-postgres >/dev/null 2>&1 && any_runtime=1
    docker inspect homeassistant >/dev/null 2>&1 && any_runtime=1
    docker inspect ha-caddy >/dev/null 2>&1 && any_runtime=1
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^ha-backup\.timer'; then
    any_runtime=1
  fi

  local installed="non"
  if [[ -d "$stack_dir" && $any_project_artifact -eq 1 && $any_runtime -eq 1 ]]; then
    installed="oui"
  fi

  local enable_caddy_raw=""
  local enable_upnp_raw=""
  if [[ -f "$env_file" ]]; then
    enable_caddy_raw="$(env_get "ENABLE_CADDY" "$env_file" 2>/dev/null || true)"
    enable_upnp_raw="$(env_get "ENABLE_UPNP" "$env_file" 2>/dev/null || true)"
  fi

  # Fallback: si les flags ne sont pas dans le .env, on déduit depuis l'état docker.
  if [[ -z "${enable_caddy_raw:-}" ]] && command -v docker >/dev/null 2>&1; then
    if docker inspect ha-caddy >/dev/null 2>&1; then
      enable_caddy_raw="1"
    else
      enable_caddy_raw="0"
    fi
  fi

  local caddy_enabled
  caddy_enabled="$(fmt_bool_default_no "$enable_caddy_raw")"
  local upnp_enabled
  upnp_enabled="$(fmt_bool_default_no "$enable_upnp_raw")"

  local timer_status="absent"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ha-backup\.timer'; then
    timer_status="$(systemctl is-enabled ha-backup.timer 2>/dev/null || true) / $(systemctl is-active ha-backup.timer 2>/dev/null || true)"
  fi

  local docker_status="absent"
  if command -v docker >/dev/null 2>&1; then
    docker_status="ok"
  fi

  # Backup / Restic: si aucun repo, on considère désactivé.
  local repos_conf="${stack_dir}/restic/repos.conf"
  local passfile="${stack_dir}/restic/password"

  local backup_enabled="non"
  local repos_info=""
  local last_restic="-"
  if [[ -f "$repos_conf" ]]; then
    local repo_count
    repo_count="$(grep -Evc '^[[:space:]]*#|^[[:space:]]*$' "$repos_conf" 2>/dev/null || echo 0)"
    if [[ "${repo_count:-0}" -gt 0 ]]; then
      backup_enabled="oui"
      repos_info="$(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$repos_conf" 2>/dev/null | head -n 2 | sed 's/^/  - /')"

      if [[ -f "$passfile" ]]; then
        local first_repo
        first_repo="$(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$repos_conf" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${first_repo:-}" ]]; then
          last_restic="$(get_last_restic_snapshot "$first_repo" "$passfile" 2>/dev/null || echo "-")"
        fi
      fi
    fi
  fi

  # Backup infos (local dump)
  local last_local="-"
  last_local="$(get_last_backup_local "${stack_dir}/backup" 2>/dev/null || echo "-")"

  # docker compose ps compact
  local compose_ps
  compose_ps="(docker/compose indisponible ou stack non démarrée)"
  if command -v docker >/dev/null 2>&1 && [[ -d "$stack_dir" ]] && [[ -f "$compose_path" ]]; then
    if compose_ps="$(compose_ps_compact "$stack_dir" "$compose_path" 2>/dev/null)"; then
      :
    else
      compose_ps="$({ cd "$stack_dir" && docker compose -f "$compose_path" ps 2>&1; } || true)"
    fi
  fi

  local sauvegardes_block
  if [[ "$backup_enabled" == "non" ]]; then
    sauvegardes_block="  - Restic : désactivé (aucun repo NAS/USB)"
  else
    sauvegardes_block=$(cat <<EOF
  - Restic : activé
  - Dernier dump local (backup/) : ${last_local}
  - Repos Restic (repos.conf) :
${repos_info}
  - Dernier snapshot Restic (1er repo) : ${last_restic}
EOF
)
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

Sauvegardes
  - Timer systemd : ${timer_status}
${sauvegardes_block}

Docker : ${docker_status}

Containers (résumé):
${compose_ps}
EOF
)"

  whiptail --title "Status" --msgbox "$msg" 32 100 --ok-button "$(t OK)"
}

