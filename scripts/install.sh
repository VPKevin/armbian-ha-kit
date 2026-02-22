#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
RESTIC_DIR="${STACK_DIR}/restic"
RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
RESTIC_PASS="${RESTIC_DIR}/password"
SAMBA_CREDS="/etc/samba/creds-ha-nas"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
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
  install -m 0755 "${STACK_DIR}/scripts/backup.sh" /srv/ha-stack/scripts/backup.sh

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
  while IFS= read -r line; do
    # NAME FSTYPE SIZE MOUNTPOINT UUID
    local name fstype size mp uuid
    name="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    size="$(awk '{print $3}' <<<"$line")"
    mp="$(awk '{print $4}' <<<"$line")"
    uuid="$(awk '{print $5}' <<<"$line")"

    [[ -z "$uuid" ]] && continue

main "$@"
