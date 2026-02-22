#!/usr/bin/env bash
set -euo pipefail

# Helpers .env + parsing de variables docker-compose.

sanitize_env_value() {
  local v="$1"
  v="${v//$'\n'/}"
  echo "$v"
}

whi_escape() {
  # whiptail interprète certains caractères. On neutralise le plus problématique.
  local s="$1"
  s="${s//=/\=}"
  echo "$s"
}

env_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" 'BEGIN{found=0} $0 ~ "^[[:space:]]*"k"=" {sub(/^[[:space:]]*"k"=/, ""); print; found=1; exit} END{exit(found?0:1)}' "$file"
}

env_has_key() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  grep -Eq "^[[:space:]]*${key}=" "$file"
}

env_set_kv() {
  local key="$1" value="$2" file="$3"
  value="$(sanitize_env_value "$value")"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" || true

  if env_has_key "$key" "$file"; then
    sed -i "0,/^[[:space:]]*${key}=/{s|^[[:space:]]*${key}=.*|${key}=${value}|}" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
}

compose_extract_vars() {
  local compose_file="$1"
  [[ -f "$compose_file" ]] || return 0

  awk '
    {
      line=$0
      while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/)) {
        token=substr(line, RSTART, RLENGTH)
        inner=substr(token, 3, length(token)-3)
        name=inner
        def=""
        if (index(inner,":-")>0) {
          name=substr(inner, 1, index(inner,":-")-1)
          def=substr(inner, index(inner,":-")+2)
        }
        if (!(name in seen)) {
          seen[name]=1
          defs[name]=def
          order[++n]=name
        } else if (defs[name]=="" && def!="") {
          defs[name]=def
        }
        line=substr(line, RSTART+RLENGTH)
      }
    }
    END {
      for (i=1;i<=n;i++) {
        name=order[i]
        printf "%s\t%s\n", name, defs[name]
      }
    }
  ' "$compose_file"
}

env_ensure_from_compose() {
  local compose_file="$1"

  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true

  local vars
  vars="$(compose_extract_vars "$compose_file" || true)"
  [[ -z "$vars" ]] && return 0

  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a

  while IFS=$'\t' read -r name def; do
    [[ -z "${name:-}" ]] && continue
    if env_has_key "$name" "$ENV_FILE"; then
      continue
    fi

    local default=""
    [[ -n "${def:-}" ]] && default="$def"

    local val
    val="$(whi_input "Variables Compose" "$(whi_escape "$name") (manquant dans .env)" "$default")" || return 1
    env_set_kv "$name" "$val" "$ENV_FILE"
  done <<< "$vars"

  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}
