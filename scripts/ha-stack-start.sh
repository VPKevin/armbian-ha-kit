#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/srv/ha-stack/.env"
COMPOSE_FILE="/srv/ha-stack/docker-compose.yml"
DOCKER_TIMEOUT=60

# Load .env if present
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Wait for docker to become available
wait_for_docker() {
  local elapsed=0
  until docker info >/dev/null 2>&1; do
    if [[ $elapsed -ge $DOCKER_TIMEOUT ]]; then
      echo "Timeout waiting for docker after ${DOCKER_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

compose_cmd() {
  local args=("-f" "$COMPOSE_FILE")
  if [[ "${ENABLE_CADDY:-0}" == "1" || "${ENABLE_CADDY:-0}" == "true" ]]; then
    args+=("--profile" "caddy")
  fi
  docker compose "${args[@]}" "$@"
}

cmd="${1:-start}"

case "$cmd" in
  start)
    wait_for_docker
    compose_cmd up -d --remove-orphans
    ;;
  stop)
    compose_cmd down || true
    ;;
  restart)
    wait_for_docker
    compose_cmd down
    compose_cmd up -d --remove-orphans
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}" >&2
    exit 1
    ;;
esac
