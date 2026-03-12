#!/usr/bin/env bash
set -euo pipefail

# Home Assistant helpers.

# Contracts (P0):
# - Fonctions: detect_docker_subnet, configure_homeassistant_yaml
# - Entrées: variables globales: STACK_DIR, ENV_FILE, POSTGRES_* variables
# - Sorties: écrit/initialise ${STACK_DIR}/config/configuration.yaml si absent
# - Codes retour: 0 succès, non-zero si erreur d'écriture.

detect_docker_subnet() {
  local subnet
  subnet="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  if [[ -n "$subnet" ]]; then
    echo "$subnet"
  else
    echo "172.16.0.0/12"
  fi
}

build_homeassistant_trusted_lines() {
  local subnet="$1" extra_trusted="${2:-}" line trusted_csv trusted_lines=""

  trusted_csv="$(env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" "${subnet}${extra_trusted:+,${extra_trusted}}")"
  while IFS= read -r line; do
    [[ -z "${line:-}" ]] && continue
    trusted_lines+="${trusted_lines:+\n}    - ${line}"
  done < <(printf '%s' "$trusted_csv" | tr ',' '\n')

  printf '%s' "$trusted_lines"
}

rewrite_homeassistant_trusted_proxies() {
  local cfg="$1" trusted_lines="$2"
  local tmp

  [[ -f "$cfg" ]] || return 0
  grep -q '^http:' "$cfg" || return 0
  grep -q '^  trusted_proxies:[[:space:]]*$' "$cfg" || return 0

  tmp="$(mktemp)"
  awk -v trusted_lines="$trusted_lines" '
    BEGIN {
      n = split(trusted_lines, repl, /\n/)
      replaced = 0
      skip = 0
    }
    {
      if (skip) {
        if ($0 ~ /^    - / || $0 ~ /^[[:space:]]*$/) {
          next
        }
        skip = 0
      }

      print

      if (!replaced && $0 ~ /^  trusted_proxies:[[:space:]]*$/) {
        for (i = 1; i <= n; i++) {
          print repl[i]
        }
        replaced = 1
        skip = 1
      }
    }
  ' "$cfg" >"$tmp"

  cat "$tmp" >"$cfg"
  rm -f "$tmp"
}

configure_homeassistant_yaml() {
  local cfg="${STACK_DIR}/config/configuration.yaml"
  local subnet extra_trusted trusted_lines
  subnet="$(detect_docker_subnet)"

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

  trusted_lines="$(build_homeassistant_trusted_lines "$subnet" "$extra_trusted")"

  if ! grep -q "^recorder:" "$cfg"; then
    cat >> "$cfg" <<EOF

recorder:
  db_url: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}

http:
  use_x_forwarded_for: true
  trusted_proxies:
$(printf '%b' "$trusted_lines")
EOF
  else
    rewrite_homeassistant_trusted_proxies "$cfg" "$trusted_lines"
  fi
}
