#!/usr/bin/env bash
set -euo pipefail

# Gestion du docker-compose.yml (local/URL) + démarrage de la stack.

choose_compose_source() {
  local action
  action=$(whiptail --title "Docker Compose" --menu "Quel docker-compose veux-tu utiliser ?" 18 84 10 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "defaut" "Utiliser ${DEFAULT_COMPOSE_PATH}" \
    "local" "Saisir un chemin local" \
    "url" "Télécharger depuis une URL (http/https)" \
    3>&1 1>&2 2>&3) || return 1

  case "$action" in
    defaut)
      COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"
      ;;
    local)
      local p
      p="$(whi_input "Docker Compose" "Chemin complet du docker-compose.yml" "$DEFAULT_COMPOSE_PATH")" || return 1
      if [[ ! -f "$p" ]]; then
        whi_info "Docker Compose" "Fichier introuvable: $p"
        return 1
      fi
      COMPOSE_PATH="$p"
      ;;
    url)
      apt_install curl ca-certificates
      local u dest
      u="$(whi_input "Docker Compose" "URL (http/https)" "")" || return 1
      dest="${STACK_DIR}/docker-compose.remote.yml"
      if ! curl -fsSL "$u" -o "$dest"; then
        whi_info "Docker Compose" "Téléchargement impossible. Vérifie l'URL/réseau."
        return 1
      fi
      chmod 600 "$dest" || true
      COMPOSE_PATH="$dest"
      ;;
  esac

  return 0
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
  if ! req_bin docker; then
    whi_info "Docker" "Docker n'est pas installé. Impossible de démarrer la stack."
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    whi_info "Docker" "Docker Compose (v2) est absent. Impossible de démarrer la stack."
    return 1
  fi

  (cd "$STACK_DIR" && docker compose -f "$COMPOSE_PATH" up -d)
}

