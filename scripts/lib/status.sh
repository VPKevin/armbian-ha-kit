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
  # On utilise docker compose ps -q (services) puis docker inspect/port.
  local services=(postgres homeassistant)

  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_caddy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi
  if [[ "${enable_caddy:-0}" == "1" || "${enable_caddy:-}" == "true" ]]; then
    services=(caddy postgres homeassistant)
  elif docker inspect ha-caddy >/dev/null 2>&1; then
    # fallback: si le conteneur existe, on l'inclut.
    services=(caddy postgres homeassistant)
  fi

  {
    printf '%-16s %-10s %-10s %s\n' "NAME" "STATE" "HEALTH" "PORTS"
    for svc in "${services[@]}"; do
      local cid name state health ports
      cid="$(compose_container_id "$svc")"
      if [[ -n "${cid:-}" ]]; then
        name="$cid"
      else
        case "$svc" in
          postgres) name="ha-postgres" ;;
          homeassistant) name="homeassistant" ;;
          caddy) name="ha-caddy" ;;
          *) name="$svc" ;;
        esac
      fi

      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)"
      [[ -z "${health:-}" ]] && health="-"
      ports="$(docker_ports_for_container "$name")"
      printf '%-16s %-10s %-10s %s\n' "$svc" "$state" "$health" "$ports"
    done
  } | cat
}

status_wizard() {
  local stack_dir="${STACK_DIR:-/srv/ha-stack}"
  local env_file="${ENV_FILE:-${stack_dir}/.env}"
  export STACK_DIR="$stack_dir"
  export ENV_FILE="$env_file"
  export DEFAULT_COMPOSE_PATH="${DEFAULT_COMPOSE_PATH:-${stack_dir}/docker-compose.yml}"

  if [[ -f "${stack_dir}/scripts/lib/i18n.sh" ]]; then
    # shellcheck source=/dev/null
    source "${stack_dir}/scripts/lib/i18n.sh" || true
  fi
  if [[ -f "${stack_dir}/scripts/lib/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "${stack_dir}/scripts/lib/ui.sh" || true
  fi
  if [[ -f "${stack_dir}/scripts/lib/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${stack_dir}/scripts/lib/common.sh" || true
  fi
  if [[ -f "${stack_dir}/scripts/lib/env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${stack_dir}/scripts/lib/env.sh" || true
  fi
  if [[ -f "${stack_dir}/scripts/lib/compose.sh" ]]; then
    # shellcheck source=/dev/null
    source "${stack_dir}/scripts/lib/compose.sh" || true
  fi

  while true; do
    local action
    if action="$(whi_menu "Status" "Que veux-tu faire ?" 18 88 10 \
      "view" "Afficher le status" \
      "backup" "Configurer / modifier les sauvegardes (NAS/USB, Restic, timer)" \
      "caddy" "Configurer Caddy (domaine/email)" \
      "quit" "Retour")"; then
      :
    else
      return $?
    fi

    case "$action" in
      quit)
        return 0
        ;;
      caddy)
        # Edition Caddy dédiée (ne relance pas l'install complète)
        if [[ -f "${stack_dir}/scripts/lib/env.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/env.sh" || true
        fi
        if [[ -f "${stack_dir}/scripts/lib/ui.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/ui.sh" || true
        fi
        if [[ -f "${stack_dir}/scripts/lib/caddy.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/caddy.sh" || true
        fi

        export STACK_DIR="$stack_dir"
        export ENV_FILE="$env_file"
        prompt_caddy_domain || true
        ;;
      backup)
        # On charge les libs si pas déjà chargées (status.sh est sourcé par install.sh, mais peut être utilisé isolément).
        if [[ -f "${stack_dir}/scripts/lib/restic.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/restic.sh" || true
        fi
        if [[ -f "${stack_dir}/scripts/lib/backup_targets.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/backup_targets.sh" || true
        fi
        if [[ -f "${stack_dir}/scripts/lib/systemd.sh" ]]; then
          # shellcheck source=/dev/null
          source "${stack_dir}/scripts/lib/systemd.sh" || true
        fi

        # Assure que les chemins globaux sont cohérents (utilisés par les fonctions des libs sourcées)
        export STACK_DIR="$stack_dir"
        export ENV_FILE="$env_file"
        export RESTIC_DIR="${stack_dir}/restic"
        export RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
        export RESTIC_PASS="${RESTIC_DIR}/password"

        # Mot de passe restic + timer
        if command -v setup_restic_password >/dev/null 2>&1; then
          setup_restic_password || true
        fi
        if command -v setup_systemd_backup >/dev/null 2>&1; then
          setup_systemd_backup || true
        fi

        local ans
        ans="$(whi_yesno_back "Backup" "Configurer / reconfigurer un NAS SMB (repository Restic) ?" "no")" || return $?
        if [[ "$ans" == "yes" ]]; then
          setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
        fi

        ans="$(whi_yesno_back "Backup" "Configurer / reconfigurer un disque USB (repository Restic) ?" "no")" || return $?
        if [[ "$ans" == "yes" ]]; then
          setup_usb_backup || true
        fi
        ;;
      view|*)
        break
        ;;
    esac
  done

  # ...existing code...
}
