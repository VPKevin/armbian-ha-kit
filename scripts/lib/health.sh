#!/usr/bin/env bash
set -euo pipefail

# Vérification de santé des conteneurs (healthcheck Docker) et affichage des logs.

# Contracts (P0):
# - Fonction: wait_for_health(timeout_s)
# - Entrées: ENABLE_CADDY, ENV_FILE, STACK_DIR
# - Sorties: 0 si les containers sont prêts/healthy, 1 en cas d'échec (logs affichés)
# - Comportement: attend jusqu'au timeout et affiche les logs en cas d'échec.

wait_for_health() {
  # Attend que les conteneurs de la stack soient healthy (ou au moins running si pas de healthcheck).
  # Affiche les derniers logs en cas d'échec.
  local timeout_s="${1:-180}"

  local start now
  start="$(date +%s)"

  # Construit la liste des conteneurs attendus selon les features.
  local expected=(postgres homeassistant)
  local enable_caddy="${ENABLE_CADDY:-}"

  # Si le .env existe, on tente de lire ENABLE_CADDY depuis celui-ci.
  if [[ -z "${enable_caddy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi

  if [[ "${enable_caddy:-1}" == "1" || "${enable_caddy:-}" == "true" ]]; then
    expected+=(caddy)
  fi

  while true; do
    local unhealthy=()
    local any_running=0

    # Liste tous les containers du projet (via docker compose). Si absent, on fallback sur les noms fixes.
    for svc in "${expected[@]}"; do
      local cid name state health
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
      if [[ "$state" == "running" ]]; then
        any_running=1
      fi

      # health peut être vide si pas de healthcheck
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)"

      if [[ "$state" != "running" ]]; then
        unhealthy+=("$svc (state=$state)")
        continue
      fi

      if [[ -n "$health" && "$health" != "healthy" ]]; then
        unhealthy+=("$svc (health=$health)")
      fi
    done

    if [[ ${#unhealthy[@]} -eq 0 && $any_running -eq 1 ]]; then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      # logs
      {
        echo "Containers non healthy / non prêts:"
        printf '  - %s\n' "${unhealthy[@]}"
        echo
        for svc in "${expected[@]}"; do
          local cid name
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

          echo "--- logs: $svc (last 200) ---"
          docker logs --tail 200 "$name" 2>&1 || true
          echo
        done
      } | cat
      return 1
    fi

    sleep 5
  done
}
