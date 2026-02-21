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
  install -m 0755 "${STACK_DIR}/scripts/backup.sh" /srv/ha-stack/scripts/backup.sh
  install -m 0755 /usr/local/sbin/ha-backup.sh /usr/local/sbin/ha-backup.sh

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
    choices+=("$name" "fs=$fstype size=$size mp=$mp uuid=$uuid")
  done < <(lsblk -rpn -o NAME,FSTYPE,SIZE,MOUNTPOINT,UUID | sed '/^$/d')

  if [[ "${#choices[@]}" -lt 2 ]]; then
    whiptail --msgbox "Aucune partition USB avec UUID détectée." 10 60
    exit 1
  fi

  whiptail --title "USB" --menu "Sélectionne la partition USB à utiliser :" 20 90 10 \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

setup_usb_mount() {
  local part mountpoint uuid fstype
  part="$(choose_usb_partition)"
  uuid="$(lsblk -no UUID "$part" | head -n1)"
  fstype="$(lsblk -no FSTYPE "$part" | head -n1)"
  mountpoint="$(whi_input "USB" "Point de montage :" "/mnt/usbbackup")"

  if [[ -z "$uuid" ]]; then
    whiptail --msgbox "UUID introuvable pour $part" 10 60
    exit 1
  fi

  if [[ -z "$fstype" ]]; then
    echo "Warning: could not detect filesystem type for $part, falling back to 'auto'."
    fstype="auto"
  fi

  mkdir -p "$mountpoint"

  sed -i "\|$mountpoint|d" /etc/fstab
  echo "UUID=$uuid  $mountpoint  $fstype  defaults,nofail,x-systemd.automount  0  2" >> /etc/fstab

  systemctl daemon-reload
  mount "$mountpoint" || true

  mkdir -p "$mountpoint/restic-ha"
  add_repo "$mountpoint/restic-ha"
  init_restic_repo "$mountpoint/restic-ha"
}

upnp_test_and_map() {
  apt_install miniupnpc

  if ! req_bin upnpc; then
    whiptail --msgbox "upnpc non trouvé après installation." 10 60
    return
  fi

  # Test : mapping temporaire
  local test_port="54321"
  upnpc -d "$test_port" TCP >/dev/null 2>&1 || true
  local add_out
  add_out="$(upnpc -a "$(hostname -I | awk '{print $1}')" "$test_port" "$test_port" TCP 120 2>&1 || true)"
  sleep 1
  local list_out
  list_out="$(upnpc -l 2>&1 || true)"
  upnpc -d "$test_port" TCP >/dev/null 2>&1 || true

  if grep -qiE "failed|error|not found|No IGD|Invalid" <<<"$add_out$list_out"; then
    whiptail --msgbox "UPnP semble indisponible ou refusé par le routeur.\n\nTu devras faire la redirection manuellement :\n- TCP 443 -> IP de la box :443\n- (optionnel) TCP 80 -> IP de la box :80\n\nSortie test:\n$add_out" 20 80
    return
  fi

  # Tente d'extraire une info de lease si visible
  local lease_info="(lease non détectable via upnpc sur ce routeur)"
  if grep -qi "lease" <<<"$list_out"; then
    lease_info="$(grep -i "lease" <<<"$list_out" | head -n 3)"
  fi

  whiptail --msgbox "UPnP OK (test réussi).\n\nInfo durée (si fournie par le routeur):\n$lease_info" 20 80

  if whi_yesno "UPnP" "Créer maintenant une redirection TCP 443 -> 443 (HTTPS) ?"; then
    upnpc -d 443 TCP >/dev/null 2>&1 || true
    upnpc -a "$(hostname -I | awk '{print $1}')" 443 443 TCP 0 >/dev/null 2>&1 || true
  fi

  if whi_yesno "UPnP" "Ouvrir temporairement TCP 80 -> 80 (utile si le cert ne sort pas) ?"; then
    upnpc -d 80 TCP >/dev/null 2>&1 || true
    upnpc -a "$(hostname -I | awk '{print $1}')" 80 80 TCP 3600 >/dev/null 2>&1 || true
    whiptail --msgbox "Port 80 ouvert via UPnP pour ~1h (selon routeur). Tu peux le refermer après obtention du cert." 12 70
  fi
}

write_templates() {
  # Ces fichiers sont supposés déjà présents si tu les as clonés depuis git.
  # Ici on vérifie juste.
  for f in docker-compose.yml Caddyfile scripts/backup.sh systemd/ha-backup.service systemd/ha-backup.timer; do
    if [[ ! -f "${STACK_DIR}/$f" ]]; then
      whiptail --msgbox "Fichier manquant: ${STACK_DIR}/$f\nPlace le repo dans ${STACK_DIR} puis relance." 12 80
      exit 1
    fi
  done
}

create_env() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi

  local tz domain email db dbu dbp
  tz="$(whi_input "Général" "Timezone :" "Europe/Paris")"
  domain="$(whi_input "Caddy" "Domaine (FQDN) :")"
  email="$(whi_input "Caddy" "Email ACME (Let's Encrypt) :")"
  db="homeassistant"
  dbu="ha"
  dbp="$(whi_pass "PostgreSQL" "Mot de passe PostgreSQL (vide = générer)")"

  if [[ -z "$dbp" ]]; then
    dbp="$(head -c 24 /dev/urandom | base64 | tr -d '\n' | cut -c1-32)"
  fi

  cat > "$ENV_FILE" <<EOF
TZ=$tz
HA_DOMAIN=$domain
LE_EMAIL=$email

POSTGRES_DB=$db
POSTGRES_USER=$dbu
POSTGRES_PASSWORD=$dbp
EOF

  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

restore_from_backup() {
  apt_install restic

  if [[ ! -f "$RESTIC_PASS" ]]; then
    whiptail --msgbox "Aucun mot de passe restic trouvé (${RESTIC_PASS}).\nImpossible de restaurer." 12 80
    return
  fi
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"

  if [[ ! -f "$RESTIC_REPOS" ]]; then
    whiptail --msgbox "Aucun repo restic configuré (${RESTIC_REPOS}).\nConfigure NAS/USB d'abord." 12 80
    return
  fi

  # Choix repo
  local repos=() r
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    [[ "$r" =~ ^# ]] && continue
    repos+=("$r" "$r")
  done < "$RESTIC_REPOS"

  local chosen_repo
  chosen_repo="$(whiptail --title "Restauration" --menu "Choisis la cible restic :" 20 90 10 "${repos[@]}" 3>&1 1>&2 2>&3)"
  export RESTIC_REPOSITORY="$chosen_repo"

  # Liste snapshots (compact)
  local snaps
  snaps="$(restic snapshots --json | jq -r '.[] | "\(.short_id) \(.time) \(.tags|join(","))"' | tail -n 20 || true)"
  if [[ -z "$snaps" ]]; then
    whiptail --msgbox "Aucun snapshot trouvé dans $chosen_repo" 10 60
    return
  fi

  local menu=()
  while IFS= read -r line; do
    local id rest
    id="$(awk '{print $1}' <<<"$line")"
    rest="${line#*$id }"
    menu+=("$id" "$rest")
  done <<<"$snaps"

  local sid
  sid="$(whiptail --title "Restauration" --menu "Choisis un snapshot :" 20 100 10 "${menu[@]}" 3>&1 1>&2 2>&3)"

  whiptail --msgbox \
"Restauration (méthode recommandée):
1) Restaure /srv/ha-stack/config (configuration HA)
2) Restaure /srv/ha-stack/backup (dumps PostgreSQL)
3) Redémarre postgres puis réimporte le dump le plus récent

Snapshot: $sid
Repo: $chosen_repo" 18 80

  # Stop stack
  (cd "$STACK_DIR" && docker compose down) || true

  # Restore config + backup dumps
  mkdir -p "$STACK_DIR"
  restic restore "$sid" --target / --include "${STACK_DIR}/config" --include "${STACK_DIR}/backup"

  # Start postgres only
  (cd "$STACK_DIR" && docker compose up -d postgres)

  # Import dump le plus récent
  local latest_dump
  latest_dump="$(ls -1t "${STACK_DIR}/backup"/postgres-*.sql.gz 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest_dump" ]]; then
    whiptail --msgbox "Aucun dump postgres trouvé dans ${STACK_DIR}/backup.\nLa DB ne sera pas restaurée." 12 80
  else
    gunzip -c "$latest_dump" | docker exec -i ha-postgres psql -U ha -d homeassistant
  fi

  # Start full stack
  (cd "$STACK_DIR" && docker compose up -d)
}

main() {
  need_root

  if ! req_bin whiptail; then
    echo "whiptail is required."
    exit 1
  fi

  ensure_dirs
  write_templates
  create_env

  # Installer outils de base
  apt_install jq curl ca-certificates

  # Restic password setup (si backups activés)
  if whi_yesno "Backups" "Activer des sauvegardes restic (NAS et/ou USB) ?"; then
    apt_install restic
    setup_restic_password

    if whi_yesno "Backups" "Configurer sauvegarde NAS (SMB) ?"; then
      setup_nas_smb
    fi

    if whi_yesno "Backups" "Configurer sauvegarde USB ?"; then
      setup_usb_mount
    fi
  fi

  if whi_yesno "Restauration" "Souhaites-tu repartir d'une sauvegarde restic maintenant ?"; then
    restore_from_backup
  fi

  if whi_yesno "UPnP" "Tenter une configuration UPnP automatique (test + redirection) ?"; then
    upnp_test_and_map
  fi

  # Configure HA yaml minimal (trusted_proxies strict)
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  configure_homeassistant_yaml

  # Déploiement / démarrage
  (cd "$STACK_DIR" && docker compose up -d)

  # Installer backup timer si repos configurés
  if [[ -f "$RESTIC_REPOS" ]]; then
    setup_systemd_backup
  fi

  # Vérification HTTPS
  local domain
  domain="$(grep -E '^HA_DOMAIN=' "$ENV_FILE" | cut -d= -f2-)"
  whiptail --msgbox \
"Installation terminée.

- Home Assistant (local): http://$(hostname -I | awk '{print $1}'):8123
- Home Assistant (internet): https://$domain

Backups:
- Rétention: daily=7, weekly=10
- Timer: systemctl status ha-backup.timer

Pour mise à jour:
cd /srv/ha-stack && sudo docker compose pull && sudo docker compose up -d
" 22 80
}

main "$@"