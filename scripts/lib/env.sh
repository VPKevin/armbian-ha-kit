#!/usr/bin/env bash
set -euo pipefail

# Helpers .env + parsing de variables docker-compose.
# Contracts (P0):
# - Functions either print a value (env_get) or return RC codes (RC_OK/RC_ERR) on success/failure.
# - env_set_kv: idempotent, crée le fichier si nécessaire, garde chmod 600, retourne RC_OK ou RC_ERR.

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

# env_get: print the value of KEY from FILE. Return 0 if found, 1 otherwise.
# stdout: value
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

strip_key_prefix_if_any() {
  local key="$1" value="$2"
  if [[ "${value:-}" == "${key}="* ]]; then
    echo "${value#"${key}"=}"
  else
    echo "$value"
  fi
}

# env_set_kv: set key=value in file idempotently. Return RC_OK on success.
env_set_kv() {
  local key="$1" value="$2" file="$3"
  value="$(strip_key_prefix_if_any "$key" "$value")"
  value="$(sanitize_env_value "$value")"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" || true

  # Mise à jour idempotente et robuste
  if env_has_key "$key" "$file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
      BEGIN{done=0}
      {
        if (!done && $0 ~ "^[[:space:]]*"k"=") {
          print k"="v
          done=1
          next
        }
        print
      }
      END{
        if(!done){ print k"="v }
      }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
  return 0
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

# env_ensure_from_compose: ensure env file contains vars used by compose file.
# - Prompts via whi_input for missing vars when interactive.
# - Returns RC_OK on success, non-zero if user aborts or whiptail returns error code.
env_ensure_from_compose() {
  local compose_file="$1"

  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true

  local vars
  vars="$(compose_extract_vars "$compose_file" || true)"
  [[ -z "$vars" ]] && return 0

  set -a
  . "$ENV_FILE" 2>/dev/null || true
  set +a

  ENV_PROMPTED=0

  while IFS=$'\t' read -r name def; do
    [[ -z "${name:-}" ]] && continue
    if env_has_key "$name" "$ENV_FILE"; then
      continue
    fi

    local default=""
    [[ -n "${def:-}" ]] && default="$def"
    default="$(strip_key_prefix_if_any "$name" "$default")"

    local val
    val="$(whi_input "Variables Compose" "$(whi_escape "$name") (manquant dans .env)" "$default")" || return $?
    env_set_kv "$name" "$val" "$ENV_FILE"
    ENV_PROMPTED=1
  done <<< "$vars"

  set -a
  . "$ENV_FILE" 2>/dev/null || true
  set +a
  return 0
}

# End of env helpers

