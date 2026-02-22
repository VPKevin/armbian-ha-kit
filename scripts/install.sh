#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
RESTIC_DIR="${STACK_DIR}/restic"
RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
RESTIC_PASS="${RESTIC_DIR}/password"
SAMBA_CREDS="/etc/samba/creds-ha"

DEFAULT_COMPOSE_PATH="${STACK_DIR}/docker-compose.yml"
COMPOSE_PATH="${DEFAULT_COMPOSE_PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/i18n.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ha.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/compose.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/restic.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/backup_targets.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/systemd.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/health.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/uninstall.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/status.sh"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
  fi

  # whiptail a besoin d'un TTY. Quand on lance via "curl | sudo bash",
  # stdin n'est pas un terminal => les touches (flèches) s'affichent comme ^[[C.
  if [[ ! -t 0 ]]; then
    exec </dev/tty
  fi
}

req_bin() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

write_file_if_missing() {
  local path="$1"
  local content="$2"
  if [[ ! -f "$path" ]]; then
    printf "%s\n" "$content" > "$path"
  fi
}

is_interactive_tty() {
  [[ -t 0 && -t 1 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

ensure_dirs() {
  mkdir -p "$STACK_DIR"/{config,postgres,backup,caddy/data,caddy/config,scripts,systemd}
  mkdir -p "$RESTIC_DIR"
  chmod 700 "$STACK_DIR" || true
}

main_menu() {
  whiptail --title "Armbian HA Kit" --menu "Que veux-tu faire ?" 18 80 10 \
    --ok-button "$(t VALIDATE)" --cancel-button "Quitter" \
    "install" "Installer / configurer la stack" \
    "restore" "Restaurer un backup (Restic)" \
    "status" "Vérifier le status (containers, backup, options)" \
    "remove" "Tout désinstaller" \
    3>&1 1>&2 2>&3
}

prompt_features() {
  # On pose les questions uniquement en mode interactif. Sinon, on garde les valeurs existantes
  # ou des defaults sûrs (Caddy on, UPnP off).
  if ! is_interactive_tty; then
    return 0
  fi

  # Si l'env existe déjà (ré-install), on réutilise ces valeurs comme défauts.
  local existing_caddy existing_upnp
  existing_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  existing_upnp="$(env_get "ENABLE_UPNP" "$ENV_FILE" 2>/dev/null || true)"

  local default_caddy=1
  local default_upnp=0
  if [[ -n "${existing_caddy:-}" ]]; then
    if [[ "$existing_caddy" == "0" || "$existing_caddy" == "false" ]]; then default_caddy=0; fi
  fi
  if [[ -n "${existing_upnp:-}" ]]; then
    if [[ "$existing_upnp" == "1" || "$existing_upnp" == "true" ]]; then default_upnp=1; fi
  fi

  local enable_caddy=$default_caddy
  local enable_upnp=$default_upnp

  if [[ $default_caddy -eq 1 ]]; then
    if ! whi_yesno "Exposition" "Mettre en place Caddy (reverse proxy) ?\n\nUtile si tu veux exposer Home Assistant via HTTPS avec un domaine.\nSi tu as déjà un proxy ailleurs, tu peux répondre Non."; then
      enable_caddy=0
    fi
  else
    if whi_yesno "Exposition" "Caddy est actuellement désactivé. Le réactiver ?"; then
      enable_caddy=1
    fi
  fi

  if [[ $default_upnp -eq 1 ]]; then
    if ! whi_yesno "Exposition" "UPnP est actuellement activé. Le laisser activé ?\n\nUPnP peut ouvrir des ports sur ta box automatiquement."; then
      enable_upnp=0
    fi
  else
    if whi_yesno "Exposition" "Activer l'UPnP (ouverture automatique des ports) ?\n\nSi tu gères déjà les ports / un proxy, réponds Non."; then
      enable_upnp=1
    fi
  fi

  env_set_kv "ENABLE_CADDY" "$enable_caddy" "$ENV_FILE"
  env_set_kv "ENABLE_UPNP" "$enable_upnp" "$ENV_FILE"

  # Recharge pour la suite du script.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

setup_env() {
  mkdir -p "$STACK_DIR"

  # Variables utilisées par docker-compose.yml + configuration.yaml
  if [[ ! -f "$ENV_FILE" ]]; then
    local pg_user pg_db pg_pass
    pg_user="ha"
    pg_db="homeassistant"
    pg_pass="$(head -c 24 /dev/urandom | base64 | tr -d '=+/\n' | head -c 24)"

    cat > "$ENV_FILE" <<EOF
POSTGRES_USER=$pg_user
POSTGRES_DB=$pg_db
POSTGRES_PASSWORD=$pg_pass
# Features
ENABLE_CADDY=1
ENABLE_UPNP=0
EOF
    chmod 600 "$ENV_FILE"
  fi

  # Complète .env depuis le compose choisi (si des variables sont manquantes)
  env_ensure_from_compose "$COMPOSE_PATH" || true

  # Charge les variables dans l’environnement du script
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

show_summary_and_edit() {
  local docker_subnet
  docker_subnet="$(detect_docker_subnet)"

  local repos_lines="  (aucun)"
  if [[ -f "$RESTIC_REPOS" && -s "$RESTIC_REPOS" ]]; then
    repos_lines="$(sed 's/^/  - /' "$RESTIC_REPOS" 2>/dev/null || true)"
  fi

  local restic_pass_status="absent"
  if [[ -f "$RESTIC_PASS" ]]; then
    restic_pass_status="présent: ${RESTIC_PASS}"
  fi

  local samba_status="non"
  if [[ -f "$SAMBA_CREDS" ]]; then
    samba_status="oui: ${SAMBA_CREDS}"
  fi

  local usb_status="non"
  if grep -qs "^[[:space:]]*UUID=.*[[:space:]]\+/mnt/usbbackup\b" /etc/fstab 2>/dev/null; then
    usb_status="oui: /mnt/usbbackup (voir /etc/fstab)"
  fi

  local env_preview="  (fichier absent)"
  if [[ -f "$ENV_FILE" ]]; then
    env_preview="$(sed -E -e 's/^(POSTGRES_PASSWORD)=.*/\1=********/' "$ENV_FILE" 2>/dev/null || true)"
    env_preview="$(printf '%s\n' "$env_preview" | sed 's/^/  /')"
  fi

  while true; do
    local summary
    summary=$(cat <<EOF
Installation : ${STACK_DIR}

Compose : ${COMPOSE_PATH}

.env : ${ENV_FILE}
${env_preview}

Home Assistant
  - config              : ${STACK_DIR}/config
  - configuration.yaml  : ${STACK_DIR}/config/configuration.yaml
  - trusted_proxies     : ${docker_subnet}

Postgres
  - data   : ${STACK_DIR}/postgres
  - port   : 127.0.0.1:5432

Restic
  - mot de passe : ${restic_pass_status}
  - repos.conf   : ${RESTIC_REPOS}
  - repos :
${repos_lines}

Backups
  - NAS SMB creds : ${samba_status}
  - USB (physique): ${usb_status}
EOF
)

    whiptail --title "Résumé" --msgbox "$summary" 30 96 --ok-button "OK"

    local action
    action=$(whiptail --title "Résumé" --menu "Que veux-tu faire ?" 18 90 10 \
      --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
      "finaliser" "Terminer l'installation" \
      "revoir" "Revoir ce résumé" \
      "edit" "Modifier la configuration" \
      "quit" "Quitter l'installation" \
      3>&1 1>&2 2>&3)

    if [[ -z "${action:-}" ]]; then
      continue
    fi

    case "$action" in
      revoir)
        continue
        ;;
      quit)
        return 2
        ;;
      finaliser)
        if whi_confirm "Résumé" "Finaliser l'installation maintenant ?"; then
          return 0
        fi
        continue
        ;;
      edit)
        local edit_action
        edit_action=$(whiptail --title "Configuration" --menu "Que veux-tu modifier ?" 20 92 12 \
          --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
          "edit-compose" "Changer le docker-compose utilisé" \
          "edit-env" "Compléter / modifier le .env (variables compose)" \
          "caddy" "Domaine + email (Caddy)" \
          "restic-pass" "Redéfinir le mot de passe Restic" \
          "nas" "Configurer / reconfigurer un NAS SMB" \
          "usb" "Configurer / reconfigurer un disque USB" \
          3>&1 1>&2 2>&3) || continue

        case "$edit_action" in
          edit-compose)
            choose_compose_source || true
            env_ensure_from_compose "$COMPOSE_PATH" || true
            set -a
            # shellcheck disable=SC1090
            . "$ENV_FILE" 2>/dev/null || true
            set +a
            configure_homeassistant_yaml
            ;;
          edit-env)
            env_ensure_from_compose "$COMPOSE_PATH" || true

            local pg_user pg_db pg_pass
            pg_user="${POSTGRES_USER:-ha}"
            pg_db="${POSTGRES_DB:-homeassistant}"

            pg_user="$(whi_input "Postgres" "POSTGRES_USER" "$pg_user")" || true
            pg_db="$(whi_input "Postgres" "POSTGRES_DB" "$pg_db")" || true
            pg_pass="$(whi_pass "Postgres" "POSTGRES_PASSWORD")" || true

            if [[ -n "${pg_user:-}" ]]; then env_set_kv "POSTGRES_USER" "$pg_user" "$ENV_FILE"; fi
            if [[ -n "${pg_db:-}" ]]; then env_set_kv "POSTGRES_DB" "$pg_db" "$ENV_FILE"; fi
            if [[ -n "${pg_pass:-}" ]]; then env_set_kv "POSTGRES_PASSWORD" "$pg_pass" "$ENV_FILE"; fi

            set -a
            # shellcheck disable=SC1090
            . "$ENV_FILE" 2>/dev/null || true
            set +a

            configure_homeassistant_yaml
            ;;
          caddy)
            prompt_caddy_domain || true
            ;;
          restic-pass)
            rm -f "$RESTIC_PASS"
            setup_restic_password
            ;;
          nas)
            setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
            ;;
          usb)
            setup_usb_backup || whi_info "USB" "Configuration USB annulée."
            ;;
        esac
        ;;
    esac

    # refresh previews
    if [[ -f "$ENV_FILE" ]]; then
      env_preview="$(sed -E -e 's/^(POSTGRES_PASSWORD)=.*/\1=********/' "$ENV_FILE" 2>/dev/null || true)"
      env_preview="$(printf '%s\n' "$env_preview" | sed 's/^/  /')"
    fi

    if [[ -f "$RESTIC_REPOS" && -s "$RESTIC_REPOS" ]]; then
      repos_lines="$(sed 's/^/  - /' "$RESTIC_REPOS" 2>/dev/null || true)"
    else
      repos_lines="  (aucun)"
    fi

    restic_pass_status="absent"
    [[ -f "$RESTIC_PASS" ]] && restic_pass_status="présent: ${RESTIC_PASS}"

    samba_status="non"
    [[ -f "$SAMBA_CREDS" ]] && samba_status="oui: ${SAMBA_CREDS}"

    usb_status="non"
    if grep -qs "^[[:space:]]*UUID=.*[[:space:]]\+/mnt/usbbackup\b" /etc/fstab 2>/dev/null; then
      usb_status="oui: /mnt/usbbackup (voir /etc/fstab)"
    fi
  done
}

prompt_caddy_domain() {
  # Demande uniquement si Caddy est activé.
  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_caddy:-}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi

  if [[ "$enable_caddy" == "0" || "$enable_caddy" == "false" ]]; then
    return 0
  fi

  local ha_domain le_email
  ha_domain="$(env_get "HA_DOMAIN" "$ENV_FILE" 2>/dev/null || true)"
  le_email="$(env_get "LE_EMAIL" "$ENV_FILE" 2>/dev/null || true)"

  ha_domain="$(whi_input "Caddy" "Nom de domaine (ex: ha.example.com)" "${ha_domain:-}")" || return 1
  le_email="$(whi_input "Caddy" "Email Let's Encrypt" "${le_email:-}")" || return 1

  if [[ -z "${ha_domain:-}" || -z "${le_email:-}" ]]; then
    whi_info "Caddy" "Domaine et email sont requis si Caddy est activé."
    return 1
  fi

  env_set_kv "HA_DOMAIN" "$ha_domain" "$ENV_FILE"
  env_set_kv "LE_EMAIL" "$le_email" "$ENV_FILE"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

main() {
  need_root
  ensure_dirs

  # deps minimales pour l’install
  # NOTE: sur Debian trixie, `awk` est un paquet *virtuel* -> installer une implémentation.
  apt_install whiptail sed coreutils util-linux ca-certificates
  apt_install mawk || apt_install gawk

  setup_compose_prereqs

  while true; do
    local action
    action="$(main_menu || true)"

    if [[ -z "${action:-}" ]]; then
      exit 0
    fi

    case "$action" in
      install)
        # Choix du compose (important avant setup_env pour compléter le .env)
        choose_compose_source || true

        setup_env
        prompt_features
        prompt_caddy_domain || true
        configure_homeassistant_yaml
        setup_systemd_backup
        setup_restic_password

        # À propos de l'ordre: sur une ré-install/migration, l'env/restic peuvent déjà exister.
        # On propose donc d'abord de rendre accessible un repo Restic (NAS/USB) pour backup *ou restauration*.
        if whi_yesno "Backup" "Rendre accessible un repository restic sur un NAS (SMB/CIFS) ?"; then
          setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
        fi

        if whi_yesno "Backup" "Rendre accessible un repository restic sur un disque USB ?"; then
          setup_usb_backup || whi_info "USB" "Configuration USB annulée."
        fi

        # NOTE: la restauration est maintenant un choix explicite au menu principal.

        local summary_rc=0
        show_summary_and_edit || summary_rc=$?

        if [[ "$summary_rc" -eq 2 ]]; then
          whi_info "Installation" "Installation quittée. Rien n'a été démarré."
          continue
        fi

        if start_stack; then
          if wait_for_health 240; then
            whi_info "Installation" "Installation terminée.\n\nStack démarrée et healthy.\n\nCommandes utiles:\n  cd $STACK_DIR\n  docker compose -f $COMPOSE_PATH ps\n  docker compose -f $COMPOSE_PATH logs -f"
          else
            whi_info "Installation" "La stack a démarré mais certains services ne sont pas healthy.\n\nSi les conteneurs restent en état 'Created', vérifie les variables du .env (ex: TZ, HA_DOMAIN/LE_EMAIL si Caddy).\n\nLes derniers logs ont été affichés dans la console."
          fi
        else
          whi_info "Installation" "Installation terminée, mais la stack n'a pas pu être démarrée automatiquement.\n\nDémarrage manuel:\n  cd $STACK_DIR && docker compose -f $COMPOSE_PATH up -d"
        fi
        ;;

      restore)
        choose_compose_source || true
        setup_env
        prompt_features
        prompt_caddy_domain || true
        if restore_wizard; then
          whi_info "Restauration" "Restauration terminée."
        else
          whi_info "Restauration" "Restauration annulée / échouée."
        fi
        ;;

      status)
        status_wizard || true
        ;;

      remove)
        uninstall_wizard || true
        # Important: on ne revient pas au menu après une désinstallation.
        # Et si on a été lancé via bootstrap.sh, on évite d'afficher les "Next steps".
        export HA_SKIP_NEXT_STEPS=1
        exit 0
        ;;
    esac
  done
}

# N'exécute main que si le script est lancé directement.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
