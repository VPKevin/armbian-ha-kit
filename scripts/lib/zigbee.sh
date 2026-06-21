#!/usr/bin/env bash
set -euo pipefail

# Helpers Zigbee / Zigbee2MQTT.

zigbee_mode_get() {
  local mode="${ZIGBEE_MODE:-}"

  if [[ -z "${mode:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    mode="$(env_get "ZIGBEE_MODE" "$ENV_FILE" 2>/dev/null || true)"
  fi

  case "${mode:-none}" in
    zha|zigbee2mqtt|none)
      printf '%s' "${mode:-none}"
      ;;
    *)
      printf '%s' "none"
      ;;
  esac
}

zigbee_mode_label() {
  case "$1" in
    zha) echo "ZHA" ;;
    zigbee2mqtt) echo "Zigbee2MQTT" ;;
    *) echo "désactivé" ;;
  esac
}

zigbee_adapter_normalize() {
  case "${1:-}" in
    zstack|ember|deconz|none)
      printf '%s' "${1:-none}"
      ;;
    ezsp)
      printf '%s' "ember"
      ;;
    "")
      printf '%s' "none"
      ;;
    *)
      printf '%s' "none"
      ;;
  esac
}

zigbee_adapter_label() {
  case "$1" in
    zstack) echo "zstack" ;;
    ember) echo "ember" ;;
    deconz) echo "deconz" ;;
    *) echo "non défini" ;;
  esac
}

zigbee_selected_port_get() {
  local selected="${ZIGBEE_DEVICE_PATH:-}"

  if [[ -z "${selected:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    selected="$(env_get "ZIGBEE_DEVICE_PATH" "$ENV_FILE" 2>/dev/null || true)"
  fi

  if [[ -z "${selected:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    selected="$(env_get "ZIGBEE_SERIAL_PORT" "$ENV_FILE" 2>/dev/null || true)"
  fi

  zigbee_default_serial_port "$selected"
}

zigbee_resolve_serial_port() {
  local selected_port="$(zigbee_default_serial_port "${1:-}")"
  local resolved

  resolved="$(readlink -f "$selected_port" 2>/dev/null || printf '%s' "$selected_port")"
  if [[ -n "${resolved:-}" ]]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$selected_port"
  fi
}

zigbee_adapter_get() {
  local adapter="${ZIGBEE_ADAPTER:-}"

  if [[ -z "${adapter:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    adapter="$(env_get "ZIGBEE_ADAPTER" "$ENV_FILE" 2>/dev/null || true)"
  fi

  zigbee_adapter_normalize "$adapter"
}

zigbee_infer_adapter_from_port() {
  local hint
  hint="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$hint" in
    *conbee*|*raspbee*)
      printf '%s' "deconz"
      ;;
    *skyconnect*|*zbdongle-e*|*dongle_plus_v2*|*efr32*|*ezsp*|*ember*|*nabu_casa*)
      printf '%s' "ember"
      ;;
    *zbdongle-p*|*cc2652*|*slaesh*|*sonoff*plus*|*sonoff*cc2652*)
      printf '%s' "zstack"
      ;;
    *)
      printf '%s' "zstack"
      ;;
  esac
}

zigbee_list_serial_candidates() {
  local dev resolved
  local seen=$'\n'

  for dev in /dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$dev" ]] || continue
    resolved="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"

    if [[ "$seen" == *$'\n'"$resolved"$'\n'* || "$seen" == *$'\n'"$dev"$'\n'* ]]; then
      continue
    fi

    printf '%s\n' "$dev"
    seen+="$dev"$'\n'"$resolved"$'\n'
  done
}

zigbee_default_serial_port() {
  local existing="${1:-}"
  if [[ -n "${existing:-}" ]]; then
    printf '%s' "$existing"
    return 0
  fi

  local first
  first="$(zigbee_list_serial_candidates | head -n 1 || true)"
  if [[ -n "${first:-}" ]]; then
    printf '%s' "$first"
  else
    printf '%s' "/dev/ttyUSB0"
  fi
}

zigbee_serial_label() {
  local dev="$1"
  local resolved
  resolved="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"

  if [[ "$resolved" != "$dev" ]]; then
    printf '%s' "$dev → $resolved"
  else
    printf '%s' "$dev"
  fi
}

zigbee_manual_serial_prompt() {
  local default_port="$1"
  local detected=""
  local dev

  while IFS= read -r dev; do
    [[ -z "${dev:-}" ]] && continue
    detected+="${detected:+\n}  - $(zigbee_serial_label "$dev")"
  done < <(zigbee_list_serial_candidates)

  cat <<EOF
Chemin du dongle Zigbee à utiliser.

Exemples: /dev/serial/by-id/... ou /dev/ttyUSB0

Dongles détectés :
${detected:-  (aucun dongle détecté automatiquement)}

Valeur proposée : ${default_port}
EOF
}

zigbee_choose_serial_port() {
  local title="$1"
  local current_port="$(zigbee_default_serial_port "${2:-}")"
  local -a choices=()
  local dev label selected rc
  local current_present=0

  while IFS= read -r dev; do
    [[ -z "${dev:-}" ]] && continue
    [[ "$dev" == "$current_port" ]] && current_present=1
    label="$(zigbee_serial_label "$dev")"
    choices+=("$dev" "$label")
  done < <(zigbee_list_serial_candidates)

  if [[ ${#choices[@]} -eq 0 ]]; then
    whi_info "$title" "Aucun dongle Zigbee n'a été détecté automatiquement. Tu peux saisir le chemin manuellement."
    whi_input "$title" "$(zigbee_manual_serial_prompt "$current_port")" "$current_port"
    return $?
  fi

  if [[ $current_present -eq 0 && -n "${current_port:-}" ]]; then
    choices=("$current_port" "Valeur actuelle / manuelle : $(zigbee_serial_label "$current_port")" "${choices[@]}")
  fi

  choices+=("manual" "Saisir manuellement un autre chemin")

  if selected="$(whi_menu "$title" "Choisis le dongle Zigbee à utiliser" 22 110 14 "${choices[@]}")"; then
    :
  else
    rc=$?
    return "$rc"
  fi

  if [[ "$selected" == "manual" ]]; then
    whi_input "$title" "$(zigbee_manual_serial_prompt "$current_port")" "$current_port"
    return $?
  fi

  printf '%s' "$selected"
}

zigbee_choose_adapter() {
  local title="$1"
  local selected_port="$2"
  local current_adapter
  current_adapter="$(zigbee_adapter_normalize "${3:-}")"
  if [[ "$current_adapter" == "none" ]]; then
    current_adapter="$(zigbee_infer_adapter_from_port "$selected_port")"
  fi

  whi_menu "$title" "Choisis le type d'adaptateur Zigbee" 18 100 8 \
    "zstack" "CC2652 / Sonoff ZBDongle-P / clés TI" \
    "ember" "EFR32 / Sonoff ZBDongle-E / SkyConnect" \
    "deconz" "ConBee / RaspBee"
}

zigbee_homeassistant_device_for_mode() {
  local mode="$1"
  local serial_port="$2"

  if [[ "$mode" == "zha" ]]; then
    printf '%s' "$serial_port"
  else
    printf '%s' "/dev/null"
  fi
}

sync_zigbee_env() {
  local mode="$1"
  local selected_port="${2:-}"
  local adapter="$(zigbee_adapter_normalize "${3:-}")"
  local serial_port ha_device

  selected_port="$(zigbee_default_serial_port "$selected_port")"
  serial_port="$(zigbee_resolve_serial_port "$selected_port")"

  if [[ "$mode" != "zigbee2mqtt" ]]; then
    adapter="none"
  elif [[ "$adapter" == "none" ]]; then
    adapter="$(zigbee_infer_adapter_from_port "$selected_port")"
  fi

  ha_device="$(zigbee_homeassistant_device_for_mode "$mode" "$serial_port")"

  env_set_kv "ZIGBEE_MODE" "$mode" "$ENV_FILE"
  env_set_kv "ZIGBEE_DEVICE_PATH" "$selected_port" "$ENV_FILE"
  env_set_kv "ZIGBEE_SERIAL_PORT" "$serial_port" "$ENV_FILE"
  env_set_kv "HOMEASSISTANT_ZIGBEE_DEVICE" "$ha_device" "$ENV_FILE"
  env_set_kv "ZIGBEE_ADAPTER" "$adapter" "$ENV_FILE"
  load_env_file "$ENV_FILE"
}

zigbee_write_mosquitto_config() {
  local cfg="${STACK_DIR}/mosquitto/config/mosquitto.conf"

  if [[ -f "$cfg" ]] && ! grep -q '^# Managed by armbian-ha-kit$' "$cfg"; then
    return 0
  fi

  cat >"$cfg" <<'EOF'
# Managed by armbian-ha-kit
persistence true
persistence_location /mosquitto/data/
log_dest stdout
listener 1883 0.0.0.0
allow_anonymous true
EOF
  chmod 600 "$cfg" || true
}

zigbee_upsert_z2m_serial_config() {
  local cfg="$1"
  local serial_port="$2"
  local adapter="$3"
  local tmp block_file

  block_file="$(mktemp)"
  cat >"$block_file" <<EOF
serial:
  port: ${serial_port}
$(if [[ "$adapter" != "none" ]]; then printf '  adapter: %s\n' "$adapter"; fi)
$(if [[ "$adapter" == "zstack" ]]; then printf '  baudrate: 115200\n'; fi)
EOF

  tmp="$(mktemp)"
  awk -v block_file="$block_file" '
    BEGIN {
      while ((getline line < block_file) > 0) {
        repl[++n] = line
      }
      close(block_file)
      in_serial = 0
      saw_serial = 0
      inserted = 0
    }

    function print_block() {
      if (inserted) {
        return
      }
      for (i = 1; i <= n; i++) {
        print repl[i]
      }
      inserted = 1
    }

    {
      if (!in_serial && $0 ~ /^serial:[[:space:]]*$/) {
        in_serial = 1
        saw_serial = 1
        next
      }

      if (in_serial) {
        if ($0 ~ /^[^[:space:]][^:]*:[[:space:]]*$/ || $0 ~ /^[^[:space:]][^:]*:[[:space:]]*[^[:space:]].*$/) {
          print_block()
          in_serial = 0
          print
        }
        next
      }

      print
    }

    END {
      if (in_serial) {
        print_block()
      }

      if (!saw_serial) {
        if (NR > 0) {
          print ""
        }
        print_block()
      }
    }
  ' "$cfg" >"$tmp"

  cat "$tmp" >"$cfg"
  rm -f "$block_file"
  rm -f "$tmp"
  chmod 600 "$cfg" || true
}

zigbee_write_z2m_config() {
  local serial_port="$1"
  local adapter="$2"
  local cfg="${STACK_DIR}/zigbee2mqtt/data/configuration.yaml"

  if [[ -f "$cfg" ]]; then
    zigbee_upsert_z2m_serial_config "$cfg" "$serial_port" "$adapter"
    return 0
  fi

  cat >"$cfg" <<EOF
# Managed by armbian-ha-kit
homeassistant:
  enabled: true
frontend:
  enabled: true
  port: 8080
mqtt:
  server: mqtt://mqtt:1883
serial:
  port: ${serial_port}
$(if [[ "$adapter" != "none" ]]; then printf '  adapter: %s\n' "$adapter"; fi)
advanced:
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
EOF
  chmod 600 "$cfg" || true
}

prepare_zigbee2mqtt_stack() {
  local serial_port="$1"
  local adapter="${2:-none}"

  mkdir -p \
    "${STACK_DIR}/zigbee2mqtt/data" \
    "${STACK_DIR}/mosquitto/config" \
    "${STACK_DIR}/mosquitto/data" \
    "${STACK_DIR}/mosquitto/log"

  zigbee_write_mosquitto_config
  zigbee_write_z2m_config "$serial_port" "$adapter"
}

prompt_zigbee_mode() {
  local existing_mode existing_selected existing_adapter
  existing_mode="$(zigbee_mode_get)"
  existing_selected="$(zigbee_selected_port_get)"
  existing_adapter="$(zigbee_adapter_get)"

  if ! is_interactive_tty; then
    sync_zigbee_env "$existing_mode" "$existing_selected" "$existing_adapter"
    if [[ "$existing_mode" == "zigbee2mqtt" ]]; then
      prepare_zigbee2mqtt_stack "${ZIGBEE_SERIAL_PORT:-$(zigbee_resolve_serial_port "$existing_selected")}" "$(zigbee_adapter_get)"
    fi
    return 0
  fi

  local default_enable="no"
  [[ "$existing_mode" != "none" ]] && default_enable="yes"

  while true; do
    local ans
    ans="$(whi_yesno_back "Zigbee" "Souhaites-tu utiliser Zigbee sur cette box ?" "$default_enable")" || return $?

    if [[ "$ans" == "no" ]]; then
      sync_zigbee_env "none" "$existing_selected" "none"
      return 0
    fi

    local mode_choice mode_rc selected_port serial_rc adapter_choice adapter_rc
    if mode_choice="$(whi_menu "Zigbee" "Quel mode Zigbee veux-tu utiliser ?" 16 90 6 \
      "zha" "Utiliser ZHA dans Home Assistant" \
      "zigbee2mqtt" "Utiliser Zigbee2MQTT + broker MQTT local")"; then
      :
    else
      mode_rc=$?
      case "$mode_rc" in
        "$UI_BACK")
          continue
          ;;
        *)
          return "$mode_rc"
          ;;
      esac
    fi

    if selected_port="$(zigbee_choose_serial_port "Dongle Zigbee" "$existing_selected")"; then
      :
    else
      serial_rc=$?
      case "$serial_rc" in
        "$UI_BACK")
          continue
          ;;
        *)
          return "$serial_rc"
          ;;
      esac
    fi

    selected_port="$(sanitize_env_value "$selected_port" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -z "${selected_port:-}" ]]; then
      whi_info "Dongle Zigbee" "Le chemin du dongle ne peut pas être vide."
      continue
    fi

    adapter_choice="none"
    if [[ "$mode_choice" == "zigbee2mqtt" ]]; then
      if adapter_choice="$(zigbee_choose_adapter "Type de dongle Zigbee" "$selected_port" "$existing_adapter")"; then
        :
      else
        adapter_rc=$?
        case "$adapter_rc" in
          "$UI_BACK")
            continue
            ;;
          *)
            return "$adapter_rc"
            ;;
        esac
      fi
    fi

    sync_zigbee_env "$mode_choice" "$selected_port" "$adapter_choice"
    if [[ "$mode_choice" == "zigbee2mqtt" ]]; then
      prepare_zigbee2mqtt_stack "${ZIGBEE_SERIAL_PORT:-$(zigbee_resolve_serial_port "$selected_port")}" "$(zigbee_adapter_get)"
    fi
    return 0
  done
}







