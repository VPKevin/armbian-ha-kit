#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
RESTIC_DIR="${STACK_DIR}/restic"
RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
RESTIC_PASS="${RESTIC_DIR}/password"
SAMBA_CREDS="/etc/samba/creds-ha"

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

whi_input() {
  local title="$1" prompt="$2" default="${3:-}"
  whiptail --title "$title" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
}

whi_pass() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3
}

whi_yesno() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70
}

is_interactive_tty() {
  [[ -t 0 && -t 1 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

ensure_dirs() {
  mkdir -p "$STACK_DIR"/{config,postgres,backup,caddy/data,caddy/config,scripts,systemd}
  mkdir -p "$RESTIC_DIR"
  chmod 700 "$STACK_DIR" || true
}

write_file_if_missing() {
  local path="$1"
  local content="$2"
  if [[ ! -f "$path" ]]; then
    printf "%s\n" "$content" > "$path"
  fi
}

detect_docker_subnet() {
  # Retourne le subnet du bridge docker, sinon fallback large
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
    chown root:root "$cfg"
    chmod 600 "$cfg"
  fi

  # Assure la présence des variables Postgres (set -u => sinon "unbound variable")
  : "${POSTGRES_USER:=ha}"
  : "${POSTGRES_DB:=homeassistant}"
  : "${POSTGRES_PASSWORD:=changeme}"

  # Ajoute un bloc minimal si pas déjà présent (sans écraser le reste)
  if ! grep -q "^recorder:" "$cfg"; then
    cat >> "$cfg" <<EOF

recorder:
  db_url: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - ${subnet}
EOF
  fi
}

setup_systemd_backup() {
  # Installer le script de backup "métier" dans le stack dir (normalement déjà présent)
  # (Sur certaines exécutions, la source et la destination peuvent être le même fichier.)
  local src_backup="${STACK_DIR}/scripts/backup.sh"
  local dst_backup="/srv/ha-stack/scripts/backup.sh"
  if [[ -f "$src_backup" ]]; then
    if [[ "$(readlink -f "$src_backup")" != "$(readlink -f "$dst_backup" 2>/dev/null || echo "")" ]]; then
      install -m 0755 "$src_backup" "$dst_backup"
    else
      chmod 0755 "$dst_backup" || true
    fi
  fi

  # Installer le wrapper appelé par systemd (source: repo)
  if [[ -f "${STACK_DIR}/ha-backup.sh" ]]; then
    install -m 0755 "${STACK_DIR}/ha-backup.sh" /usr/local/sbin/ha-backup.sh
  else
    whiptail --msgbox "Fichier manquant: ${STACK_DIR}/ha-backup.sh\nImpossible d'installer le service systemd de backup." 12 80
    return
  fi

  install -d /etc/systemd/system
  install -m 0644 "${STACK_DIR}/systemd/ha-backup.service" /etc/systemd/system/ha-backup.service
  install -m 0644 "${STACK_DIR}/systemd/ha-backup.timer" /etc/systemd/system/ha-backup.timer

  systemctl daemon-reload
  systemctl enable --now ha-backup.timer
}

add_repo() {
  local repo="$1"
  mkdir -p "$RESTIC_DIR"
  touch "$RESTIC_REPOS"
  chmod 600 "$RESTIC_REPOS"
  if ! grep -Fxq "$repo" "$RESTIC_REPOS"; then
    echo "$repo" >> "$RESTIC_REPOS"
  fi
}

init_restic_repo() {
  local repo="$1"
  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"
  if ! restic snapshots >/dev/null 2>&1; then
    restic init
  fi
}

setup_restic_password() {
  mkdir -p "$RESTIC_DIR"
  if [[ -f "$RESTIC_PASS" ]]; then
    return
  fi

  # Fallback non-interactif si pas de TTY (cron/cloud-init/pipe, etc.)
  if ! is_interactive_tty; then
    head -c 48 /dev/urandom | base64 > "$RESTIC_PASS"
    chmod 600 "$RESTIC_PASS"
    return
  fi

  if whi_yesno "Restic" "Définir un mot de passe restic maintenant ? (sinon il sera généré aléatoirement)"; then
    local p1 p2
    p1="$(whi_pass "Restic" "Mot de passe restic (à conserver !)")"
    p2="$(whi_pass "Restic" "Confirme le mot de passe restic")"
    if [[ "$p1" != "$p2" || -z "$p1" ]]; then
      whiptail --msgbox "Mot de passe invalide / différent." 10 60
      exit 1
    fi
    printf "%s" "$p1" > "$RESTIC_PASS"
  else
    head -c 48 /dev/urandom | base64 > "$RESTIC_PASS"
  fi
  chmod 600 "$RESTIC_PASS"
}

setup_nas_smb() {
  apt_install cifs-utils

  local server share user pass mountpoint subdir
  server="$(whi_input "NAS SMB" "Serveur (IP ou nom) :")"
  share="$(whi_input "NAS SMB" "Nom du partage (share) :")"
  subdir="$(whi_input "NAS SMB" "Sous-dossier (optionnel, vide si aucun) :")"
  user="$(whi_input "NAS SMB" "Utilisateur :")"
  pass="$(whi_pass "NAS SMB" "Mot de passe :")"
  mountpoint="$(whi_input "NAS SMB" "Point de montage :" "/mnt/nasbackup")"

  mkdir -p /etc/samba
  cat > "$SAMBA_CREDS" <<EOF
username=$user
password=$pass
EOF
  chmod 600 "$SAMBA_CREDS"

  mkdir -p "$mountpoint"

  local remote="//$server/$share"
  local opts="credentials=$SAMBA_CREDS,iocharset=utf8,uid=0,gid=0,file_mode=0600,dir_mode=0700,nofail,x-systemd.automount"

  # Évite doublons fstab
  sed -i "\|$mountpoint|d" /etc/fstab

  echo "$remote  $mountpoint  cifs  $opts  0  0" >> /etc/fstab

  systemctl daemon-reload
  mount "$mountpoint" || true

  local repo_path="$mountpoint"
  if [[ -n "$subdir" ]]; then
    repo_path="$mountpoint/$subdir"
  fi
  mkdir -p "$repo_path/restic-ha"

  add_repo "$repo_path/restic-ha"
  init_restic_repo "$repo_path/restic-ha"
}

choose_usb_partition() {
  local choices=()

  # Format: NAME FSTYPE SIZE MOUNTPOINT UUID (sans en-tête)
  # On utilise lsblk côté Linux (sur la box). Ne pas appeler sur macOS.
  while IFS= read -r line; do
    # NAME FSTYPE SIZE MOUNTPOINT UUID
    local name fstype size mp uuid
    name="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    size="$(awk '{print $3}' <<<"$line")"
    mp="$(awk '{print $4}' <<<"$line")"
    uuid="$(awk '{print $5}' <<<"$line")"

    [[ -z "$uuid" ]] && continue

    # Label lisible pour whiptail
    local label="$name ($fstype, $size)"
    if [[ -n "$mp" && "$mp" != "-" ]]; then
      label+=" mounted:$mp"
    fi

    choices+=("$uuid" "$label")
  done < <(lsblk -rpo NAME,FSTYPE,SIZE,MOUNTPOINT,UUID 2>/dev/null | awk '$2 != "" {print $0}')

  if [[ ${#choices[@]} -eq 0 ]]; then
    whiptail --msgbox "Aucune partition USB détectée (lsblk n'a rien retourné)." 10 70
    return 1
  fi

  whiptail --title "USB" --menu "Choisis une partition (UUID)" 20 78 10 \
    "${choices[@]}" 3>&1 1>&2 2>&3
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
EOF
    chmod 600 "$ENV_FILE"
  fi

  # Charge les variables dans l’environnement du script
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
}

setup_compose_prereqs() {
  if ! req_bin docker; then
    apt_install docker.io
  fi

  # Docker Compose plugin (compose v2)
  if ! docker compose version >/dev/null 2>&1; then
    apt_install docker-compose-plugin
  fi
}

setup_usb_backup() {
  apt_install util-linux

  local uuid
  uuid="$(choose_usb_partition)" || return 1

  local mountpoint
  mountpoint="$(whi_input "USB" "Point de montage :" "/mnt/usbbackup")"

  mkdir -p "$mountpoint"

  # Évite les doublons
  sed -i "\|$mountpoint|d" /etc/fstab
  sed -i "\|UUID=$uuid|d" /etc/fstab

  echo "UUID=$uuid  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab

  systemctl daemon-reload || true
  mount "$mountpoint" || true

  mkdir -p "$mountpoint/restic-ha"
  add_repo "$mountpoint/restic-ha"
  init_restic_repo "$mountpoint/restic-ha"
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

    whiptail --title "Résumé" --msgbox "$summary" 28 92

    local action
    action=$(whiptail --title "Résumé" --menu "Que veux-tu faire ?" 18 78 10 \
      "continuer" "Terminer l'installation" \
      "edit-env" "Modifier POSTGRES_* (.env)" \
      "restic-pass" "Redéfinir le mot de passe Restic" \
      "nas" "Configurer / reconfigurer un NAS SMB" \
      "usb" "Configurer / reconfigurer un disque USB" \
      3>&1 1>&2 2>&3) || return 1

    case "$action" in
      continuer)
        return 0
        ;;
      edit-env)
        local pg_user pg_db pg_pass
        pg_user="${POSTGRES_USER:-ha}"
        pg_db="${POSTGRES_DB:-homeassistant}"

        pg_user="$(whi_input "Postgres" "POSTGRES_USER" "$pg_user")"
        pg_db="$(whi_input "Postgres" "POSTGRES_DB" "$pg_db")"
        pg_pass="$(whi_pass "Postgres" "POSTGRES_PASSWORD")"

        cat > "$ENV_FILE" <<EOF
POSTGRES_USER=$pg_user
POSTGRES_DB=$pg_db
POSTGRES_PASSWORD=$pg_pass
EOF
        chmod 600 "$ENV_FILE"

        set -a
        . "$ENV_FILE"
        set +a

        configure_homeassistant_yaml
        ;;
      restic-pass)
        rm -f "$RESTIC_PASS"
        setup_restic_password
        ;;
      nas)
        setup_nas_smb
        ;;
      usb)
        setup_usb_backup
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

main() {
  need_root
  ensure_dirs

  # deps minimales pour l’install
  # NOTE: sur Debian trixie, `awk` est un paquet *virtuel* -> installer une implémentation.
  apt_install whiptail sed coreutils util-linux ca-certificates
  apt_install mawk || apt_install gawk

  setup_compose_prereqs
  setup_env
  configure_homeassistant_yaml
  setup_systemd_backup
  setup_restic_password

  # Optionnel: config NAS
  if whi_yesno "Backup" "Configurer un repository restic sur un NAS (SMB/CIFS) ?"; then
    setup_nas_smb
  fi

  # Optionnel: config USB
  if whi_yesno "Backup" "Configurer un repository restic sur un disque USB ?"; then
    setup_usb_backup
  fi

  show_summary_and_edit

  whiptail --msgbox "Installation terminée.\n\nDémarrage: cd $STACK_DIR && docker compose up -d" 12 70
}

main "$@"
