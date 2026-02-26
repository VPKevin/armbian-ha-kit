#!/usr/bin/env bash
set -euo pipefail

# Gestion du docker-compose.yml (local/URL) + démarrage de la stack.

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

# Insère dans le service 'homeassistant' une entrée environment pour
# PROXY_TRUSTED_PROXIES si la variable est définie dans le .env et absente
# du docker-compose actuel. L'insertion est idempotente.
compose_ensure_proxy_env() {
  compose_path_resolve
  [[ -f "$COMPOSE_PATH" ]] || return 0
  [[ -f "${ENV_FILE:-}" ]] || return 0

  local val cleaned_val
  val="$(env_get "PROXY_TRUSTED_PROXIES" "$ENV_FILE" 2>/dev/null || true)"
  [[ -n "${val:-}" ]] || return 0

  # Nettoie les caractères non imprimables éventuels (contrôle, retour chariot, DEL)
  cleaned_val="$(printf '%s' "$val" | tr -d '\000-\037\177')"
  # Trim leading/trailing whitespace
  cleaned_val="$(echo "$cleaned_val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  # Ne rien faire si déjà présent dans le compose (quel que soit le contenu)
  if grep -q 'PROXY_TRUSTED_PROXIES' "$COMPOSE_PATH"; then
    return 0
  fi

  # repère la plage du service homeassistant
  local home_start end_line
  home_start="$(grep -n '^[[:space:]]*homeassistant:' "$COMPOSE_PATH" 2>/dev/null | cut -d: -f1 | head -n1 || true)"
  [[ -n "$home_start" ]] || return 0
  end_line="$(awk -v s="$home_start" 'NR>s && /^[^[:space:]].*:/{print NR; exit}' "$COMPOSE_PATH" 2>/dev/null || true)"
  if [[ -z "$end_line" || "$end_line" -le 0 ]]; then
    end_line=$(wc -l < "$COMPOSE_PATH" | tr -d ' ')
  fi

  # Prepare lines to insert (use quoted value to be safe in YAML)
  local env_entry env_entry_quoted env_line indent tmp
  # Escape any double quotes in the cleaned value for safe insertion into YAML
  env_entry_quoted="${cleaned_val//\"/\\\"}"
  env_entry="- PROXY_TRUSTED_PROXIES=\"${env_entry_quoted}\""

  # 1) Si 'environment:' existe dans le bloc, insère la ligne après.
  env_line="$(awk -v s="$home_start" -v e="$end_line" 'NR>=s && NR<=e && /^[[:space:]]*environment:/{print NR; exit}' "$COMPOSE_PATH" || true)"
  if [[ -n "$env_line" ]]; then
    indent="$(sed -n "${env_line}p" "$COMPOSE_PATH" | sed -E 's/^([[:space:]]*).*/\1/')"
    insert_line="${indent}  ${env_entry}"
    tmp="$(mktemp)"
    awk -v n=$((env_line+1)) -v nl="$insert_line" 'NR==n{print nl} {print}' "$COMPOSE_PATH" > "$tmp" && mv "$tmp" "$COMPOSE_PATH"
    return 0
  fi

  # 2) Sinon, si 'env_file:' existe, insère un bloc environment après.
  local envfile_line
  envfile_line="$(awk -v s="$home_start" -v e="$end_line" 'NR>=s && NR<=e && /^[[:space:]]*env_file:/{print NR; exit}' "$COMPOSE_PATH" || true)"
  if [[ -n "$envfile_line" ]]; then
    indent="$(sed -n "${envfile_line}p" "$COMPOSE_PATH" | sed -E 's/^([[:space:]]*).*/\1/')"
    local l1 l2
    l1="${indent}environment:"
    l2="${indent}  ${env_entry}"
    tmp="$(mktemp)"
    awk -v n=$((envfile_line+1)) -v l1="$l1" -v l2="$l2" 'NR==n{print l1; print l2} {print}' "$COMPOSE_PATH" > "$tmp" && mv "$tmp" "$COMPOSE_PATH"
    return 0
  fi

  # 3) Sinon, insère un petit bloc après la ligne homeassistant:
  local hs_line
  hs_line="$home_start"
  indent="$(sed -n "${hs_line}p" "$COMPOSE_PATH" | sed -E 's/^([[:space:]]*).*/\1/')"
  local b1 b2
  b1="${indent}  environment:"
  b2="${indent}    ${env_entry}"
  tmp="$(mktemp)"
  awk -v n=$((hs_line+1)) -v l1="$b1" -v l2="$b2" 'NR==n{print l1; print l2} {print}' "$COMPOSE_PATH" > "$tmp" && mv "$tmp" "$COMPOSE_PATH"
  return 0
}
