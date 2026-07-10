#!/usr/bin/env bash
set -euo pipefail

# Home Assistant helpers.

# Contracts (P0):
# - Fonctions: detect_docker_subnet, configure_homeassistant_yaml
# - Entrées: variables globales: STACK_DIR, ENV_FILE, DOCKER_SUBNET, POSTGRES_* variables
# - Sorties: écrit/initialise/corrige ${STACK_DIR}/config/configuration.yaml
# - Codes retour: 0 succès, non-zero si erreur d'écriture.

# Sous-réseau du réseau applicatif (ha-network). DOIT correspondre au subnet
# figé dans docker-compose.yml (networks.ha-network.ipam). On ne devine plus le
# bridge Docker par défaut (172.17.x) : Caddy tourne sur ha-network, pas dessus,
# et son IP est donc dans CE sous-réseau. La valeur vient de .env (DOCKER_SUBNET)
# pour rester cohérente avec compose ; à défaut, on retombe sur le même défaut.
DOCKER_SUBNET_DEFAULT="172.30.0.0/24"

detect_docker_subnet() {
  if [[ -n "${DOCKER_SUBNET:-}" ]]; then
    echo "$DOCKER_SUBNET"
    return 0
  fi
  local subnet=""
  if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    subnet="$(env_get "DOCKER_SUBNET" "$ENV_FILE" 2>/dev/null || true)"
  fi
  echo "${subnet:-$DOCKER_SUBNET_DEFAULT}"
}

# Base des trusted_proxies de HA : l'IP statique de Caddy (CADDY_STATIC_IP,
# figée dans docker-compose.yml) si connue — n'importe quel autre conteneur du
# subnet ne peut alors plus spoofer X-Forwarded-For (audit §1.6). À défaut
# (installations antérieures sans la clé), on retombe sur le subnet complet.
ha_trusted_base() {
  local ip="${CADDY_STATIC_IP:-}"
  if [[ -z "${ip:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    ip="$(env_get "CADDY_STATIC_IP" "$ENV_FILE" 2>/dev/null || true)"
  fi
  if [[ -n "${ip:-}" ]]; then
    echo "$ip"
  else
    detect_docker_subnet
  fi
}

# Encode une chaîne pour un composant d'URL (user/password du db_url) : un mot
# de passe contenant @ : / # ? casserait l'URL du recorder sinon. Byte-wise
# (LC_ALL=C) pour rester correct sur les caractères multi-octets.
urlencode() {
  local LC_ALL=C
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

build_homeassistant_trusted_lines() {
  local subnet="$1" extra_trusted="${2:-}" line trusted_csv trusted_lines=""

  trusted_csv="$(env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" "${subnet}${extra_trusted:+,${extra_trusted}}")"
  while IFS= read -r line; do
    [[ -z "${line:-}" ]] && continue
    trusted_lines+="${trusted_lines:+\n}    - ${line}"
  done < <(printf '%s\n' "$trusted_csv" | tr ',' '\n')

  printf '%s' "$trusted_lines"
}

# ha_has_http_block: vrai si un bloc top-level "http:" existe.
ha_has_http_block() {
  grep -Eq '^http:[[:space:]]*$' "$1"
}

# ha_has_trusted_proxies: vrai si une clé "trusted_proxies:" (indentée) existe.
ha_has_trusted_proxies() {
  grep -Eq '^[[:space:]]+trusted_proxies:[[:space:]]*$' "$1"
}

# ha_has_use_x_forwarded: vrai si "use_x_forwarded_for:" est déjà présent.
ha_has_use_x_forwarded() {
  grep -Eq '^[[:space:]]+use_x_forwarded_for:' "$1"
}

# replace_trusted_proxies_block: remplace UNIQUEMENT les lignes "    - ..."
# situées sous "  trusted_proxies:" par la nouvelle liste. Tout le reste du
# fichier (recorder, intégrations, automations, autres clés http) est conservé.
replace_trusted_proxies_block() {
  local cfg="$1" trusted_lines="$2" tmp
  tmp="$(mktemp)"
  awk -v trusted_lines="$trusted_lines" '
    BEGIN { n = split(trusted_lines, repl, /\n/); replaced = 0; skip = 0 }
    {
      if (skip) {
        # On saute les anciennes entrées de liste "    - ..." (et lignes vides
        # éventuelles intercalées), puis on rend la main au premier élément
        # qui ne fait plus partie de la liste.
        if ($0 ~ /^[[:space:]]+-[[:space:]]/) { next }
        skip = 0
      }
      print
      if (!replaced && $0 ~ /^[[:space:]]+trusted_proxies:[[:space:]]*$/) {
        for (i = 1; i <= n; i++) print repl[i]
        replaced = 1
        skip = 1
      }
    }
  ' "$cfg" >"$tmp"
  cat "$tmp" >"$cfg"
  rm -f "$tmp"
}

# insert_trusted_proxies_under_http: le bloc "http:" existe mais sans
# "trusted_proxies:". On insère use_x_forwarded_for (si absent) + trusted_proxies
# juste après la ligne "http:", sans toucher au reste.
insert_trusted_proxies_under_http() {
  local cfg="$1" trusted_lines="$2" add_xff="$3" tmp
  tmp="$(mktemp)"
  awk -v trusted_lines="$trusted_lines" -v add_xff="$add_xff" '
    BEGIN { n = split(trusted_lines, repl, /\n/); done = 0 }
    {
      print
      if (!done && $0 ~ /^http:[[:space:]]*$/) {
        if (add_xff == "1") print "  use_x_forwarded_for: true"
        print "  trusted_proxies:"
        for (i = 1; i <= n; i++) print repl[i]
        done = 1
      }
    }
  ' "$cfg" >"$tmp"
  cat "$tmp" >"$cfg"
  rm -f "$tmp"
}

# ensure_homeassistant_trusted_proxies: garantit, de façon idempotente, que le
# bloc http/trusted_proxies reflète le sous-réseau courant — quelle que soit la
# forme de départ du fichier — sans modifier les autres lignes.
ensure_homeassistant_trusted_proxies() {
  local cfg="$1" trusted_lines="$2"
  [[ -f "$cfg" ]] || return 0

  if ! ha_has_http_block "$cfg"; then
    # Aucun bloc http : on l'ajoute en entier en fin de fichier.
    # ip_ban/login_attempts : protection brute-force intégrée de HA — HA reste
    # accessible en HTTP sur tout le LAN (network_mode: host), et exposé sur
    # Internet si UPnP/Caddy sont actifs (audit §1.7). Ajouté uniquement à la
    # création du bloc, jamais imposé sur un bloc http existant.
    {
      printf '\n'
      printf 'http:\n'
      printf '  use_x_forwarded_for: true\n'
      printf '  ip_ban_enabled: true\n'
      printf '  login_attempts_threshold: 5\n'
      printf '  trusted_proxies:\n'
      printf '%b\n' "$trusted_lines"
    } >> "$cfg"
    return 0
  fi

  if ! ha_has_trusted_proxies "$cfg"; then
    local add_xff="1"
    ha_has_use_x_forwarded "$cfg" && add_xff="0"
    insert_trusted_proxies_under_http "$cfg" "$trusted_lines" "$add_xff"
    return 0
  fi

  # trusted_proxies existe (vide ou avec d'anciennes valeurs) : on remplace
  # uniquement sa liste.
  replace_trusted_proxies_block "$cfg" "$trusted_lines"
}

configure_homeassistant_yaml() {
  local cfg="${STACK_DIR}/config/configuration.yaml"
  local trusted_base extra_trusted trusted_lines
  trusted_base="$(ha_trusted_base)"

  if [[ ! -f "$cfg" ]]; then
    touch "$cfg"
    chown root:root "$cfg" || true
    chmod 600 "$cfg" || true
  fi

  : "${POSTGRES_USER:=ha}"
  : "${POSTGRES_DB:=homeassistant}"
  : "${POSTGRES_PASSWORD:=changeme}"

  extra_trusted=""
  if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    extra_trusted="$(env_get "PROXY_TRUSTED_PROXIES" "$ENV_FILE" 2>/dev/null || true)"
    extra_trusted="$(env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" "$extra_trusted")"
  fi

  trusted_lines="$(build_homeassistant_trusted_lines "$trusted_base" "$extra_trusted")"

  # 1) recorder : ajouté seulement s'il manque (ne réécrit jamais l'existant).
  #    user/password URL-encodés : un mot de passe contenant @ : / # ? etc.
  #    casserait l'URL sinon (audit §1.5).
  if ! grep -q "^recorder:" "$cfg"; then
    local db_user db_pass
    db_user="$(urlencode "$POSTGRES_USER")"
    db_pass="$(urlencode "$POSTGRES_PASSWORD")"
    cat >> "$cfg" <<EOF

recorder:
  db_url: postgresql://${db_user}:${db_pass}@127.0.0.1:5432/${POSTGRES_DB}
EOF
  fi

  # 2) http/trusted_proxies : vérifié et corrigé à chaque passage, de façon
  #    idempotente, sans toucher au reste du fichier.
  ensure_homeassistant_trusted_proxies "$cfg" "$trusted_lines"
}
