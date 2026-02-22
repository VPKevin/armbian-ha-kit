#!/usr/bin/env bash
set -euo pipefail

# Home Assistant helpers.

detect_docker_subnet() {
  local subnet
  subnet="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  if [[ -n "$subnet" ]]; then
    echo "$subnet"
  else
    echo "172.16.0.0/12"
  fi
}

configure_homeassistant_yaml() {
  local cfg="${STACK_DIR}/config/configuration.yaml"
  local subnet
  subnet="$(detect_docker_subnet)"

  if [[ ! -f "$cfg" ]]; then
    touch "$cfg"
    chown root:root "$cfg" || true
    chmod 600 "$cfg" || true
  fi

  : "${POSTGRES_USER:=ha}"
  : "${POSTGRES_DB:=homeassistant}"
  : "${POSTGRES_PASSWORD:=changeme}"

  if ! grep -q "^recorder:" "$cfg"; then
    local trusted_block

    # Par défaut, on fait confiance au subnet docker (cas Caddy dans docker).
    trusted_block="  trusted_proxies:\n    - ${subnet}"

    # Si l'utilisateur a un proxy externe, on peut ajouter ses IP/CIDR.
    local has_external_proxy="${HAS_EXTERNAL_PROXY:-}"
    if [[ -z "${has_external_proxy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
      has_external_proxy="$(env_get "HAS_EXTERNAL_PROXY" "$ENV_FILE" 2>/dev/null || true)"
    fi

    # Si PROXY_TRUSTED_PROXIES est défini dans le .env, il prime.
    # Format attendu: "192.168.1.10,10.0.0.0/24"
    local extra_trusted=""
    if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
      extra_trusted="$(env_get "PROXY_TRUSTED_PROXIES" "$ENV_FILE" 2>/dev/null || true)"
    fi

    if [[ "${has_external_proxy:-0}" == "1" || "${has_external_proxy:-}" == "true" ]]; then
      if [[ -n "${extra_trusted:-}" ]]; then
        local line
        while IFS= read -r line; do
          [[ -z "${line:-}" ]] && continue
          trusted_block+="\n    - ${line}"
        done < <(echo "$extra_trusted" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' )
      fi
    fi

    cat >> "$cfg" <<EOF

recorder:
  db_url: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}

http:
  use_x_forwarded_for: true
${trusted_block}
EOF
  fi
}

