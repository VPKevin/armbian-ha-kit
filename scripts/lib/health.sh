#!/usr/bin/env bash
set -euo pipefail

# Vérification de santé des conteneurs (healthcheck Docker) et affichage des logs.

wait_for_health() {
  # Attend que les conteneurs de la stack soient healthy (ou au moins running si pas de healthcheck).
  # Affiche les derniers logs en cas d'échec.
  local timeout_s="${1:-180}"

  local start now
  start="$(date +%s)"

  while true; do
    local unhealthy=()
    local any_running=0

    # Liste tous les containers du projet (ceux du compose). On se base sur les noms fixés.
    # NB: si un container n'existe pas encore, on le considère comme non prêt.
    for name in ha-postgres homeassistant ha-caddy; do
      local state health
      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")"
      if [[ "$state" == "running" ]]; then
        any_running=1
      fi

      # health peut être vide si pas de healthcheck
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)"

      if [[ "$state" != "running" ]]; then
        unhealthy+=("$name (state=$state)")
        continue
      fi

      if [[ -n "$health" && "$health" != "healthy" ]]; then
        unhealthy+=("$name (health=$health)")
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
        for name in ha-postgres homeassistant ha-caddy; do
          echo "--- logs: $name (last 200) ---"
          docker logs --tail 200 "$name" 2>&1 || true
          echo
        done
      } | cat
      return 1
    fi

    sleep 5
  done
}

