#!/usr/bin/env bash
set -euo pipefail

# NAS SMB + USB setup (montage + ajout repo restic).

setup_nas_smb() {
  apt_install cifs-utils

  local server share user pass mountpoint subdir

  server="$(whi_input "NAS SMB" "Serveur (IP ou nom) :")" || return 1
  share="$(whi_input "NAS SMB" "Nom du partage (share) :")" || return 1
  subdir="$(whi_input "NAS SMB" "Sous-dossier (optionnel, vide si aucun) :")" || return 1
  user="$(whi_input "NAS SMB" "Utilisateur :")" || return 1
  pass="$(whi_pass "NAS SMB" "Mot de passe :")" || return 1
  mountpoint="$(whi_input "NAS SMB" "Point de montage :" "/mnt/nasbackup")" || return 1

  mkdir -p /etc/samba
  cat > "$SAMBA_CREDS" <<EOF
username=$user
password=$pass
EOF
  chmod 600 "$SAMBA_CREDS"

  mkdir -p "$mountpoint"

  local remote="//$server/$share"
  local opts="credentials=$SAMBA_CREDS,iocharset=utf8,uid=0,gid=0,file_mode=0600,dir_mode=0700,nofail,x-systemd.automount"

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
    local name fstype size mp uuid
    name="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    size="$(awk '{print $3}' <<<"$line")"
    mp="$(awk '{print $4}' <<<"$line")"
    uuid="$(awk '{print $5}' <<<"$line")"

    [[ -z "$uuid" ]] && continue

    local label="$name ($fstype, $size)"
    if [[ -n "$mp" && "$mp" != "-" ]]; then
      label+=" mounted:$mp"
    fi

    choices+=("$uuid" "$label")
  done < <(lsblk -rpo NAME,FSTYPE,SIZE,MOUNTPOINT,UUID 2>/dev/null | awk '$2 != "" {print $0}')

  if [[ ${#choices[@]} -eq 0 ]]; then
    whi_info "USB" "Aucune partition USB détectée (lsblk n'a rien retourné)."
    return 1
  fi

  whiptail --title "USB" --menu "Choisis une partition (UUID)" 20 78 10 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

setup_usb_backup() {
  apt_install util-linux

  local uuid
  uuid="$(choose_usb_partition)" || return 1

  local mountpoint
  mountpoint="$(whi_input "USB" "Point de montage :" "/mnt/usbbackup")" || return 1

  mkdir -p "$mountpoint"

  sed -i "\|$mountpoint|d" /etc/fstab
  sed -i "\|UUID=$uuid|d" /etc/fstab

  echo "UUID=$uuid  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab

  systemctl daemon-reload || true
  mount "$mountpoint" || true

  mkdir -p "$mountpoint/restic-ha"
  add_repo "$mountpoint/restic-ha"
  init_restic_repo "$mountpoint/restic-ha"
}

