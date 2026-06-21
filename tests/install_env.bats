#!/usr/bin/env bats

setup() {
  export TMPDIR
  TMPDIR="$(mktemp -d)"
  export STACK_DIR="$TMPDIR/stack"
  export ENV_FILE="$STACK_DIR/.env"
  export RESTIC_DIR="$STACK_DIR/restic"
  export RESTIC_REPOS="$RESTIC_DIR/repos.conf"
  export RESTIC_PASS="$RESTIC_DIR/password"
  export SAMBA_CREDS="$TMPDIR/creds"
  export DEFAULT_COMPOSE_PATH="$TMPDIR/docker-compose.yml"
  export COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"

  mkdir -p "$STACK_DIR"

  # stub whiptail: renvoie la valeur par défaut pour inputbox, et "yes" pour yesno
  WHIPTAIL_LOG="$TMPDIR/whiptail.log"
  export WHIPTAIL_LOG
  mkdir -p "$TMPDIR/bin"
  cat >"$TMPDIR/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Log
printf '%s\n' "whiptail $*" >>"${WHIPTAIL_LOG}"

case "$*" in
  *--inputbox*)
    # Dernier argument = valeur par défaut
    echo "${@: -1}"
    exit 0
    ;;
  *--passwordbox*)
    echo "secret"
    exit 0
    ;;
  *--yesno*)
    exit 0
    ;;
  *--menu*)
    # Renvoie 1er item (après options). Heuristique: on prend le 1er token non-option.
    # Ici, nos tests n'utilisent pas --menu.
    exit 1
    ;;
  *--msgbox*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$TMPDIR/bin/whiptail"
  export PATH="$TMPDIR/bin:$PATH"

  # stub apt_install/dockers
  cat >"$TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
# docker stub: suffit pour detect_docker_subnet
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
  echo "172.18.0.0/16"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"
}

test_install_sh_loaded() {
  # Source le script pour accéder aux fonctions
  # shellcheck disable=SC1091
  source "./scripts/install.sh"

  export STACK_DIR="$TMPDIR/stack"
  export ENV_FILE="$STACK_DIR/.env"
  export RESTIC_DIR="$STACK_DIR/restic"
  export RESTIC_REPOS="$RESTIC_DIR/repos.conf"
  export RESTIC_PASS="$RESTIC_DIR/password"
  export SAMBA_CREDS="$TMPDIR/creds"
  export DEFAULT_COMPOSE_PATH="$TMPDIR/docker-compose.yml"
  export COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"

  mkdir -p "$STACK_DIR"
}

@test "env_set_kv ajoute une clé sans supprimer les autres" {
  test_install_sh_loaded

  mkdir -p "$STACK_DIR"
  printf 'A=1\nB=2\n' >"$ENV_FILE"

  run env_set_kv "C" "3" "$ENV_FILE"
  [ "$status" -eq 0 ]

  run grep -E '^A=1$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^B=2$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^C=3$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "env_set_kv remplace une clé existante sans toucher aux autres" {
  test_install_sh_loaded

  printf 'A=1\nB=2\n' >"$ENV_FILE"
  run env_set_kv "A" "9" "$ENV_FILE"
  [ "$status" -eq 0 ]

  run grep -E '^A=9$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^B=2$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "compose_extract_vars détecte VAR et VAR:-default" {
  test_install_sh_loaded

  cat >"$COMPOSE_PATH" <<'EOF'
services:
  app:
    environment:
      - TZ=${TZ:-Europe/Paris}
      - FOO=${FOO}
      - BAR=${BAR:-baz}
EOF

  run compose_extract_vars "$COMPOSE_PATH"
  [ "$status" -eq 0 ]

  # Ordre = 1ère apparition
  [[ "$output" == *$'TZ\tEurope/Paris'* ]]
  [[ "$output" == *$'FOO\t'* ]]
  [[ "$output" == *$'BAR\tbaz'* ]]
}

@test "env_ensure_from_compose complète les variables manquantes dans .env" {
  test_install_sh_loaded

  cat >"$COMPOSE_PATH" <<'EOF'
services:
  app:
    environment:
      - TZ=${TZ:-Europe/Paris}
      - FOO=${FOO:-x}
EOF

  # .env ne contient rien au départ
  : >"$ENV_FILE"

  run env_ensure_from_compose "$COMPOSE_PATH"
  [ "$status" -eq 0 ]

  # notre whiptail stub renvoie la valeur par défaut
  run grep -E '^TZ=Europe/Paris$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^FOO=x$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "setup_env ajoute les defaults Zigbee pour les anciennes installations" {
  test_install_sh_loaded

  cat >"$ENV_FILE" <<'EOF'
POSTGRES_USER=ha
POSTGRES_DB=homeassistant
POSTGRES_PASSWORD=secret
EOF

  run setup_env
  [ "$status" -eq 0 ]

  run grep -E '^ZIGBEE_MODE=none$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_DEVICE_PATH=/dev/ttyUSB0$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_SERIAL_PORT=/dev/ttyUSB0$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^HOMEASSISTANT_ZIGBEE_DEVICE=/dev/null$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_ADAPTER=none$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "sync_zigbee_env expose le dongle à Home Assistant quand ZHA est choisi" {
  test_install_sh_loaded

  : >"$ENV_FILE"

  run sync_zigbee_env "zha" "/dev/serial/by-id/usb-test-zigbee"
  [ "$status" -eq 0 ]

  run grep -E '^ZIGBEE_MODE=zha$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_DEVICE_PATH=/dev/serial/by-id/usb-test-zigbee$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_SERIAL_PORT=/dev/serial/by-id/usb-test-zigbee$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^HOMEASSISTANT_ZIGBEE_DEVICE=/dev/serial/by-id/usb-test-zigbee$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_ADAPTER=none$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "sync_zigbee_env masque le dongle à Home Assistant hors mode ZHA" {
  test_install_sh_loaded

  : >"$ENV_FILE"

  run sync_zigbee_env "zigbee2mqtt" "/dev/ttyACM0" "ember"
  [ "$status" -eq 0 ]

  run grep -E '^HOMEASSISTANT_ZIGBEE_DEVICE=/dev/null$' "$ENV_FILE"
  [ "$status" -eq 0 ]
  run grep -E '^ZIGBEE_ADAPTER=ember$' "$ENV_FILE"
  [ "$status" -eq 0 ]
}

@test "prepare_zigbee2mqtt_stack génère les fichiers persistants gérés" {
  test_install_sh_loaded

  run prepare_zigbee2mqtt_stack "/dev/ttyACM0" "ember"
  [ "$status" -eq 0 ]

  run grep -F 'listener 1883 0.0.0.0' "$STACK_DIR/mosquitto/config/mosquitto.conf"
  [ "$status" -eq 0 ]
  run grep -F 'server: mqtt://mqtt:1883' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'port: /dev/ttyACM0' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'adapter: ember' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
}

@test "prepare_zigbee2mqtt_stack migre une ancienne configuration existante en mettant à jour serial" {
  test_install_sh_loaded

  mkdir -p "$STACK_DIR/zigbee2mqtt/data"
  cat >"$STACK_DIR/zigbee2mqtt/data/configuration.yaml" <<'EOF'
homeassistant:
  enabled: true
frontend:
  enabled: true
  port: 8080
mqtt:
  server: mqtt://mqtt:1883
serial:
  port: >-
    /dev/serial/by-id/usb-Texas_Instruments_TI_CC2531_USB_CDC___0X00124B0008B84E6E-if00
advanced:
  network_key:
    - 126
    - 32
  pan_id: 4848
version: 5
EOF

  run prepare_zigbee2mqtt_stack "/dev/ttyUSB0" "zstack"
  [ "$status" -eq 0 ]

  run grep -F '  port: /dev/ttyUSB0' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F '  adapter: zstack' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F '  baudrate: 115200' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'version: 5' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'pan_id: 4848' "$STACK_DIR/zigbee2mqtt/data/configuration.yaml"
  [ "$status" -eq 0 ]
}

@test "env_csv_normalize_for_key nettoie les préfixes parasites, espaces et doublons" {
  test_install_sh_loaded

  run env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" " PROXY_TRUSTED_PROXIES=192.168.1.150 , 10.0.0.0/24,PROXY_TRUSTED_PROXIES=192.168.1.150 ,, "
  [ "$status" -eq 0 ]
  [ "$output" = "192.168.1.150,10.0.0.0/24" ]
}

@test "configure_homeassistant_yaml génère une liste trusted_proxies propre depuis .env" {
  test_install_sh_loaded

  mkdir -p "$STACK_DIR/config"
  printf 'PROXY_TRUSTED_PROXIES=PROXY_TRUSTED_PROXIES=192.168.1.150, 10.0.0.0/24\n' >"$ENV_FILE"

  run configure_homeassistant_yaml
  [ "$status" -eq 0 ]

  run grep -F '    - 172.18.0.0/16' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F '    - 192.168.1.150' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F '    - 10.0.0.0/24' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'PROXY_TRUSTED_PROXIES=' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -ne 0 ]
}

@test "configure_homeassistant_yaml répare une liste trusted_proxies déjà polluée" {
  test_install_sh_loaded

  mkdir -p "$STACK_DIR/config"
  cat >"$STACK_DIR/config/configuration.yaml" <<'EOF'
homeassistant:
  name: Test

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - PROXY_TRUSTED_PROXIES=192.168.1.150
EOF
  printf 'PROXY_TRUSTED_PROXIES=PROXY_TRUSTED_PROXIES=192.168.1.150\n' >"$ENV_FILE"

  run configure_homeassistant_yaml
  [ "$status" -eq 0 ]

  run grep -F '    - 172.18.0.0/16' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F '    - 192.168.1.150' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'PROXY_TRUSTED_PROXIES=' "$STACK_DIR/config/configuration.yaml"
  [ "$status" -ne 0 ]
}

