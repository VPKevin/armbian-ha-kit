#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
RESTIC_DIR="${STACK_DIR}/restic"
RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
RESTIC_PASS="${RESTIC_DIR}/password"

DEFAULT_COMPOSE_PATH="${STACK_DIR}/docker-compose.yml"
COMPOSE_PATH="${DEFAULT_COMPOSE_PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/i18n.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/ha.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/compose.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/caddy.sh"
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

# ---------------------------------------------------------------------------
# Contracts / minimal documentation for key functions (P0)
# - Inputs: via globals (STACK_DIR, ENV_FILE, COMPOSE_PATH, etc.) or args where noted
# - Outputs: files created, env variables set, side-effects (docker compose, systemd)
# - Error modes: non-zero return codes defined in scripts/lib/common.sh (RC_*)
# - Success: return RC_OK (0)
# ---------------------------------------------------------------------------

# Ensure the script runs as root and that a TTY is available for interactive UI.
# Returns: exits with RC_NOT_ROOT if not run as root (kept behavior), otherwise RC_OK.
need_root() {
  require_root_or_fail || { echo "Run as root: sudo bash $0"; exit "$RC_NOT_ROOT"; }

  # whiptail a besoin d'un TTY. Quand on lance via "curl | sudo bash",
  # stdin n'est pas un terminal => les touches (flèches) s'affichent comme ^[[C.
  if [[ ! -t 0 ]]; then
    exec </dev/tty
  fi
}

# Preflight checks: verifies presence of minimal system commands used by the installer.
# Returns: RC_OK on success, RC_MISSING_DEP when required commands are missing.
preflight_checks() {
  local missing=()
  local b
  for b in bash awk sed grep mkdir chmod; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    rc_fail "Dependances systeme manquantes: ${missing[*]}" "$RC_MISSING_DEP"
    return "$RC_MISSING_DEP"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_warn "docker non detecte pour l'instant: il sera installe/configure plus loin si necessaire."
  fi
  return "$RC_OK"
}

write_file_if_missing() {
  local path="$1"
  local content="$2"
  if [[ ! -f "$path" ]]; then
    printf "%s\n" "$content" > "$path"
  fi
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
  local existing_caddy existing_upnp existing_has_proxy
  existing_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  existing_upnp="$(env_get "ENABLE_UPNP" "$ENV_FILE" 2>/dev/null || true)"
  existing_has_proxy="$(env_get "HAS_EXTERNAL_PROXY" "$ENV_FILE" 2>/dev/null || true)"

  local default_caddy=1
  local default_upnp=0
  local default_has_proxy=0
  if [[ -n "${existing_caddy:-}" ]]; then
    if [[ "$existing_caddy" == "0" || "$existing_caddy" == "false" ]]; then default_caddy=0; fi
  fi
  if [[ -n "${existing_upnp:-}" ]]; then
    if [[ "$existing_upnp" == "1" || "$existing_upnp" == "true" ]]; then default_upnp=1; fi
  fi
  if [[ -n "${existing_has_proxy:-}" ]]; then
    if [[ "$existing_has_proxy" == "1" || "$existing_has_proxy" == "true" ]]; then default_has_proxy=1; fi
  fi

  local has_external_proxy=$default_has_proxy
  local enable_caddy=$default_caddy
  local enable_upnp=$default_upnp

  # 1) Proxy externe ? (ex: Traefik/Nginx/HAProxy sur une autre machine)
  local ans default_item
  if [[ $default_has_proxy -eq 1 ]]; then
    default_item="yes"
    ans="$(whi_yesno_back "Exposition" "Un reverse proxy externe est actuellement configuré. Le garder ?\n\nExemples: Nginx/Traefik/HAProxy, routeur/box qui fait proxy." "$default_item")" || return $?
  else
    default_item="no"
    ans="$(whi_yesno_back "Exposition" "As-tu déjà un reverse proxy (Nginx/Traefik/HAProxy) qui publiera Home Assistant ?\n\nSi oui: ce kit ne doit pas utiliser les ports 80/443 et Home Assistant devra faire confiance à l'IP du proxy." "$default_item")" || return $?
  fi
  if [[ "$ans" == "yes" ]]; then
    has_external_proxy=1
  else
    has_external_proxy=0
  fi

  # Si proxy externe: on demande les IP/CIDR à autoriser dans Home Assistant (trusted_proxies).
  if [[ $has_external_proxy -eq 1 ]]; then
    local existing_trusted
    existing_trusted="$(env_get "PROXY_TRUSTED_PROXIES" "$ENV_FILE" 2>/dev/null || true)"
    existing_trusted="$(env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" "$existing_trusted")"

    local proxy_ip
    proxy_ip="$(whi_input "Proxy externe" "IP ou CIDR du proxy à autoriser (ex: 192.168.1.10 ou 10.0.0.0/24)\n\nAstuce: si tu as plusieurs proxies, sépare par des virgules." "${existing_trusted:-}")" || return $?
    proxy_ip="$(env_csv_normalize_for_key "PROXY_TRUSTED_PROXIES" "$proxy_ip")"

    # Si renseigné, on stocke. Sinon on laisse vide (mais HA pourra refuser les headers si le proxy n'est pas ajouté).
    if [[ -n "${proxy_ip:-}" ]]; then
      env_set_kv "PROXY_TRUSTED_PROXIES" "$proxy_ip" "$ENV_FILE"
    fi
  fi

  # 2) Caddy (proxy local) uniquement si pas de proxy externe
  if [[ $has_external_proxy -eq 1 ]]; then
    enable_caddy=0
  else
    if [[ $default_caddy -eq 1 ]]; then
      ans="$(whi_yesno_back "Exposition" "Activer Caddy sur cette machine (reverse proxy + HTTPS) ?\n\nÇa utilise les ports 80/443." "yes")" || return $?
      [[ "$ans" == "yes" ]] && enable_caddy=1 || enable_caddy=0
    else
      ans="$(whi_yesno_back "Exposition" "Caddy est actuellement désactivé. Le réactiver ?\n\nÇa utilisera les ports 80/443." "no")" || return $?
      [[ "$ans" == "yes" ]] && enable_caddy=1 || enable_caddy=0
    fi
  fi

  # 3) UPnP (après le choix proxy)
  # Si un proxy externe est utilisé, UPnP n'a généralement aucun intérêt et peut être source d'ouverture de ports inutile.
  if [[ $has_external_proxy -eq 1 ]]; then
    enable_upnp=0
  else
    if [[ $default_upnp -eq 1 ]]; then
      ans="$(whi_yesno_back "Exposition" "UPnP est actuellement activé. Le laisser activé ?\n\nUPnP peut ouvrir des ports sur ta box automatiquement." "yes")" || return $?
      [[ "$ans" == "yes" ]] && enable_upnp=1 || enable_upnp=0
    else
      ans="$(whi_yesno_back "Exposition" "Activer l'UPnP (ouverture automatique des ports) ?\n\nSi tu gères déjà les ports (ou un proxy), réponds Non." "no")" || return $?
      [[ "$ans" == "yes" ]] && enable_upnp=1 || enable_upnp=0
    fi
  fi

  env_set_kv "HAS_EXTERNAL_PROXY" "$has_external_proxy" "$ENV_FILE"
  env_set_kv "ENABLE_CADDY" "$enable_caddy" "$ENV_FILE"
  env_set_kv "ENABLE_UPNP" "$enable_upnp" "$ENV_FILE"

  # Recharge pour la suite du script.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

# setup_env: crée et recharge un .env minimal si absent.
# Returns: RC_OK on success, non-zero codes from env_ensure_from_compose propagated.
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
# Si tu as déjà un reverse proxy ailleurs (Nginx/Traefik/HAProxy), mets HAS_EXTERNAL_PROXY=1.
HAS_EXTERNAL_PROXY=0
# Caddy ne doit être activé que si la machine peut utiliser les ports 80/443.
ENABLE_CADDY=1
ENABLE_UPNP=0
EOF
    chmod 600 "$ENV_FILE"
  fi

  # Complète .env depuis le compose choisi (si des variables sont manquantes)
  env_ensure_from_compose "$COMPOSE_PATH" || return $?

  # Charge les variables dans l’environnement du script
  load_env_file "$ENV_FILE"
  return "$RC_OK"
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

    local action action_rc
    if action="$(whi_menu "Résumé" "Que veux-tu faire ?" 18 90 10 \
      "finaliser" "Terminer l'installation" \
      "revoir" "Revoir ce résumé" \
      "edit" "Modifier la configuration" \
      "quit" "Quitter l'installation")"; then
      action_rc=$UI_OK
    else
      action_rc=$?
    fi

    case "$action_rc" in
      "$UI_BACK")
        return "$UI_BACK"
        ;;
      "$UI_ABORT")
        return "$UI_ABORT"
        ;;
    esac

    case "$action" in
      revoir)
        continue
        ;;
      quit)
        return "$UI_ABORT"
        ;;
      finaliser)
        if whi_confirm "Résumé" "Finaliser l'installation maintenant ?"; then
          return 0
        fi
        continue
        ;;
      edit)
        while true; do
          local edit_action edit_rc
          if edit_action="$(whi_menu "Configuration" "Que veux-tu modifier ?" 20 92 12 \
            "edit-compose" "Changer le docker-compose utilisé" \
            "edit-env" "Compléter / modifier le .env (variables compose)" \
            "caddy" "Domaine + email (Caddy)" \
            "restic-pass" "Redéfinir le mot de passe Restic" \
            "nas" "Configurer / reconfigurer un NAS SMB" \
            "usb" "Configurer / reconfigurer un disque USB")"; then
            edit_rc=$UI_OK
          else
            edit_rc=$?
          fi

          case "$edit_rc" in
            "$UI_BACK")
              # Retour => on revient au menu résumé (pas au début de boucle summary)
              break
              ;;
            "$UI_ABORT")
              return 2
              ;;
          esac

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
              pg_pass="${POSTGRES_PASSWORD:-}"

              pg_user="$(strip_key_prefix_if_any "POSTGRES_USER" "$pg_user")"
              pg_db="$(strip_key_prefix_if_any "POSTGRES_DB" "$pg_db")"
              pg_pass="$(strip_key_prefix_if_any "POSTGRES_PASSWORD" "$pg_pass")"

              # Les whi_input / whi_pass retournent potentiellement UI_BACK/UI_ABORT.
              # Ici on préserve le comportement d'annulation en testant le rc.
              if pg_user_tmp="$(whi_input "Postgres" "POSTGRES_USER" "$pg_user")"; then
                pg_user="$pg_user_tmp"
              else
                # si Cancel/Back/Abort, respecter le code de retour
                local tmp_rc=$?
                if [[ $tmp_rc -ne $UI_OK ]]; then
                  # remonte l'erreur vers l'appelant pour traitement (ou ignorer selon le cas)
                  # On choisit ici de continuer la boucle d'édition si c'était un BACK, sinon retourner.
                  if [[ $tmp_rc -eq $UI_BACK ]]; then
                    # revenir au menu précédent (on sort de l'édition)
                    break
                  else
                    return "$UI_ABORT"
                  fi
                fi
              fi

              if pg_db_tmp="$(whi_input "Postgres" "POSTGRES_DB" "$pg_db")"; then
                pg_db="$pg_db_tmp"
              else
                local tmp_rc=$?
                if [[ $tmp_rc -ne $UI_OK ]]; then
                  if [[ $tmp_rc -eq $UI_BACK ]]; then
                    break
                  else
                    return "$UI_ABORT"
                  fi
                fi
              fi

              if pg_pass_tmp="$(whi_pass "Postgres" "POSTGRES_PASSWORD")"; then
                pg_pass="$pg_pass_tmp"
              else
                local tmp_rc=$?
                if [[ $tmp_rc -ne $UI_OK ]]; then
                  if [[ $tmp_rc -eq $UI_BACK ]]; then
                    break
                  else
                    return "$UI_ABORT"
                  fi
                fi
              fi

              pg_user="$(strip_key_prefix_if_any "POSTGRES_USER" "$pg_user")"
              pg_db="$(strip_key_prefix_if_any "POSTGRES_DB" "$pg_db")"
              pg_pass="$(strip_key_prefix_if_any "POSTGRES_PASSWORD" "$pg_pass")"

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
              setup_restic_password || true
              ;;
            nas)
              setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
              ;;
            usb)
              setup_usb_backup || true
              ;;
          esac

          # refresh previews après une action d'édition
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
        ;;
    esac
  done
}

run_install_wizard() {
  local steps=(
    step_choose_compose
    step_setup_env
    step_features
    step_caddy
    step_systemd
    step_restic
    step_backup_targets
    step_summary
  )

  local idx=0 total=${#steps[@]}
  while (( idx < total )); do
    local fn="${steps[$idx]}"
    if [[ "${WIZARD_NAV_DIR:-}" != "back" ]]; then
      WIZARD_NAV_DIR="forward"
    fi
    "$fn"
    local rc=$?
    case "$rc" in
      "$UI_OK")
        WIZARD_NAV_DIR="forward"
        ((idx++))
        ;;
      "$UI_BACK")
        if (( idx == 0 )); then
          return "$UI_ABORT"
        fi
        WIZARD_NAV_DIR="back"
        ((idx--))
        ;;
      "$UI_ABORT")
        return "$UI_ABORT"
        ;;
      *)
        return "$UI_ABORT"
        ;;
    esac
  done
  return 0
}

step_choose_compose() {
  choose_compose_source || return $?
  return "$UI_OK"
}

step_setup_env() {
  setup_env
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi
  if [[ "${WIZARD_NAV_DIR:-}" == "back" && "${ENV_PROMPTED:-0}" -eq 0 ]]; then
    return "$UI_BACK"
  fi
  return "$UI_OK"
}

step_features() {
  prompt_features || return $?
  return "$UI_OK"
}

step_caddy() {
  while true; do
    prompt_caddy_domain
    local rc=$?
    case "$rc" in
      "$UI_OK")
        if [[ "${WIZARD_NAV_DIR:-}" == "back" && "${CADDY_PROMPTED:-0}" -eq 0 ]]; then
          return "$UI_BACK"
        fi
        return "$UI_OK"
        ;;
      "$UI_BACK") return "$UI_BACK" ;;
      "$UI_ABORT") return "$UI_ABORT" ;;
      *) continue ;;
    esac
  done
}

step_systemd() {
  setup_systemd_backup
  if [[ "${WIZARD_NAV_DIR:-}" == "back" ]]; then
    return "$UI_BACK"
  fi
  return "$UI_OK"
}

step_restic() {
  setup_restic_password
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    return $rc
  fi
  if [[ "${WIZARD_NAV_DIR:-}" == "back" && "${RESTIC_PROMPTED:-0}" -eq 0 ]]; then
    return "$UI_BACK"
  fi
  return "$UI_OK"
}

step_backup_targets() {
  local ans
  ans="$(whi_yesno_back "Backup" "Rendre accessible un repository restic sur un NAS (SMB/CIFS) ?" "no")" || return $?
  if [[ "$ans" == "yes" ]]; then
    setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
  fi

  ans="$(whi_yesno_back "Backup" "Rendre accessible un repository restic sur un disque USB ?" "no")" || return $?
  if [[ "$ans" == "yes" ]]; then
    setup_usb_backup || true
  fi
  return "$UI_OK"
}

step_summary() {
  show_summary_and_edit
}

main() {
  install_error_trap "install.sh"
  need_root
  preflight_checks
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
        if ! run_install_wizard; then
          whi_info "Installation" "Installation quittée. Rien n'a été démarré."
          continue
        fi

        configure_homeassistant_yaml
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
        compose_path_resolve || true
        setup_env
        # En mode restauration, on évite les questions d'exposition (Caddy/UPnP/proxy).
        # On a seulement besoin de variables de base + accès au repo Restic.
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
