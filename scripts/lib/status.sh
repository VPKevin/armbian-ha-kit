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

compose_ps_compact() {
  local stack_dir="$1" compose_path="$2"
  command -v docker >/dev/null 2>&1 || return 1
  [[ -d "$stack_dir" && -f "$compose_path" ]] || return 1

  # Format: name|state|health|ports
  (cd "$stack_dir" && docker compose -f "$compose_path" ps --format json 2>/dev/null) \
    | awk '
      BEGIN{print "NAME\tSTATE\tHEALTH\tPORTS"}
      /"Name"/ {name=$0; sub(/.*"Name"[[:space:]]*:[[:space:]]*"/ ,"",name); sub(/".*/,"",name)}
      /"State"/ {state=$0; sub(/.*"State"[[:space:]]*:[[:space:]]*"/ ,"",state); sub(/".*/,"",state)}
      /"Health"/ {health=$0; sub(/.*"Health"[[:space:]]*:[[:space:]]*"/ ,"",health); sub(/".*/,"",health)}
      /"Publishers"/ {ports=""}
      /"URL"/ {
        u=$0; sub(/.*"URL"[[:space:]]*:[[:space:]]*"/,"",u); sub(/".*/,"",u);
        if (u!="") { if (ports!="") ports=ports","; ports=ports u }
      }
      /}\s*,?\s*$/ && name!="" && state!="" {
        if (health=="") health="-";
        if (ports=="") ports="-";
        print name"\t"state"\t"health"\t"ports;
        name=state=health=ports="";
      }
    '
}

status_wizard() {
  local stack_dir="${STACK_DIR:-/srv/ha-stack}"
  local compose_path="${COMPOSE_PATH:-${stack_dir}/docker-compose.yml}"
  local env_file="${ENV_FILE:-${stack_dir}/.env}"

  local installed="non"
  [[ -d "$stack_dir" ]] && installed="oui"

  local compose_present="non"
  [[ -f "$compose_path" ]] && compose_present="oui"

  local env_present="non"
  [[ -f "$env_file" ]] && env_present="oui"

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
    fi
  fi

  local caddy_enabled
  caddy_enabled="$(fmt_bool "$enable_caddy_raw")"
  local upnp_enabled
  upnp_enabled="$(fmt_bool "$enable_upnp_raw")"

  local timer_status="absent"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ha-backup\.timer'; then
    timer_status="$(systemctl is-enabled ha-backup.timer 2>/dev/null || true) / $(systemctl is-active ha-backup.timer 2>/dev/null || true)"
  fi

  local docker_status="absent"
  if command -v docker >/dev/null 2>&1; then
    docker_status="ok"
  fi

  # Backup infos
  local last_local="-"
  last_local="$(get_last_backup_local "${stack_dir}/backup" 2>/dev/null || echo "-")"

  local repos_info="-"
  local last_restic="-"
  local repos_conf="${stack_dir}/restic/repos.conf"
  local passfile="${stack_dir}/restic/password"

  if [[ -f "$repos_conf" && -s "$repos_conf" ]]; then
    repos_info="$(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$repos_conf" 2>/dev/null | head -n 2 | sed 's/^/  - /')"

    # On essaie de donner une date de dernier snapshot sur le 1er repo (rapide, lisible).
    if [[ -f "$passfile" ]]; then
      local first_repo
      first_repo="$(grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$repos_conf" 2>/dev/null | head -n 1 || true)"
      if [[ -n "${first_repo:-}" ]]; then
        last_restic="$(get_last_restic_snapshot "$first_repo" "$passfile" 2>/dev/null || echo "-")"
      fi
    fi
  fi

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
  - Timer systemd   : ${timer_status}
  - Dernier dump local (backup/) : ${last_local}
  - Repos Restic (repos.conf) :
${repos_info}
  - Dernier snapshot Restic (1er repo) : ${last_restic}

Docker : ${docker_status}

Containers (résumé):
${compose_ps}
EOF
)"

  whiptail --title "Status" --msgbox "$msg" 32 100 --ok-button "$(t OK)"
}
