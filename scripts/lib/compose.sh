#!/usr/bin/env bash
set -euo pipefail

# Gestion du docker-compose.yml (local/URL) + démarrage de la stack.

# Contracts (P0):
# - Fonctions: choose_compose_source, compose_write_path, compose_path_resolve,
#   compose_container_id, setup_compose_prereqs, start_stack
# - Entrées: variables globales potentiellement utilisées: STACK_DIR, DEFAULT_COMPOSE_PATH,
#   COMPOSE_PATH, ENV_FILE, ENABLE_CADDY
# - Sorties: modifications de COMPOSE_PATH, écriture de ${STACK_DIR}/.compose_path,
#   lancement des commandes docker compose.
# - Codes retour: 0 succès, codes non-zero en cas d'erreur (usage UI_BACK/UI_ABORT pour UI).

choose_compose_source() {
  local action
  if action="$(whi_menu "Docker Compose" "Quel docker-compose veux-tu utiliser ?" 18 84 10 \
    "defaut" "Utiliser ${DEFAULT_COMPOSE_PATH}" \
    "local" "Saisir un chemin local" \
    "url" "Télécharger depuis une URL (http/https)")"; then
    :
  else
    return $?
  fi

  case "$action" in
    defaut)
      COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"
      ;;
    local)
      local p
      p="$(whi_input "Docker Compose" "Chemin complet du docker-compose.yml" "$DEFAULT_COMPOSE_PATH")" || return $?
      if [[ ! -f "$p" ]]; then
        whi_info "Docker Compose" "Fichier introuvable: $p"
        return "$UI_BACK"
      fi
      COMPOSE_PATH="$p"
      ;;
    url)
      apt_install curl ca-certificates
      local u dest
      u="$(whi_input "Docker Compose" "URL (http/https)" "")" || return $?
      dest="${STACK_DIR}/docker-compose.remote.yml"
      if ! curl -fsSL "$u" -o "$dest"; then
        whi_info "Docker Compose" "Téléchargement impossible. Vérifie l'URL/réseau."
        return "$UI_BACK"
      fi
      chmod 600 "$dest" || true
      COMPOSE_PATH="$dest"
      ;;
  esac

  compose_write_path || true

  return "$UI_OK"
}

compose_write_path() {
  [[ -n "${STACK_DIR:-}" ]] || return 0
  [[ -n "${COMPOSE_PATH:-}" ]] || return 0
  printf '%s\n' "$COMPOSE_PATH" > "${STACK_DIR}/.compose_path"
  chmod 600 "${STACK_DIR}/.compose_path" || true
}

compose_path_resolve() {
  if [[ -n "${COMPOSE_PATH:-}" && -f "${COMPOSE_PATH}" ]]; then
    return 0
  fi

  if [[ -n "${STACK_DIR:-}" && -f "${STACK_DIR}/.compose_path" ]]; then
    COMPOSE_PATH="$(cat "${STACK_DIR}/.compose_path" 2>/dev/null || true)"
  fi

  if [[ -z "${COMPOSE_PATH:-}" ]]; then
    COMPOSE_PATH="${DEFAULT_COMPOSE_PATH}"
  fi
}

compose_container_id() {
  local service="$1"
  compose_path_resolve
  docker compose -f "$COMPOSE_PATH" ps -q "$service" 2>/dev/null || true
}

setup_compose_prereqs() {
  if ! req_bin docker; then
    apt_install docker.io
  fi

  if ! docker compose version >/dev/null 2>&1; then
    apt_install docker-compose-plugin
  fi
}

start_stack() {
  compose_path_resolve
  if ! req_bin docker; then
    whi_info "Docker" "Docker n'est pas installé. Impossible de démarrer la stack."
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    whi_info "Docker" "Docker Compose (v2) est absent. Impossible de démarrer la stack."
    return 1
  fi

  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_caddy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi

  local profiles=()
  if [[ "${enable_caddy:-1}" == "1" || "${enable_caddy:-}" == "true" ]]; then
    profiles+=("--profile" "caddy")
  fi

  if command -v ui_run >/dev/null 2>&1; then
    (cd "$STACK_DIR" && ui_run "Démarrer stack" -- docker compose -f "$COMPOSE_PATH" "${profiles[@]}" up -d)
  else
    (cd "$STACK_DIR" && docker compose -f "$COMPOSE_PATH" "${profiles[@]}" up -d)
  fi
}
