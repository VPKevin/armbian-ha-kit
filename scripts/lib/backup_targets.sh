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
  apt_install util-linux

  local choices=()

  # On ne liste QUE les partitions (TYPE=part). Une clé USB = /dev/sda (disk) + /dev/sda1 (part).
  # Monter /dev/sda (disk) ne marche pas => on l'exclut.

  # Méthode principale: lsblk en mode tableau, facile à parser sans jq.
  # Colonnes: PATH TYPE RM TRAN SIZE FSTYPE MOUNTPOINT UUID MODEL
  while IFS= read -r line; do
    # shellcheck disable=SC2206
    local cols=($line)

    local path type rm tran size fstype mp uuid
    path="${cols[0]:-}"
    type="${cols[1]:-}"
    rm="${cols[2]:-}"
    tran="${cols[3]:-}"
    size="${cols[4]:-}"
    fstype="${cols[5]:-}"
    mp="${cols[6]:-}"
    uuid="${cols[7]:-}"

    [[ "$type" != "part" ]] && continue

    # Filtre USB/removable
    if [[ "$tran" != "usb" && "$rm" != "1" && "$rm" != "true" ]]; then
      continue
    fi

    # Sur certains lsblk, MOUNTPOINT peut être vide => mp="-" via -P pas possible ici.
    [[ -z "${mp:-}" ]] && mp="-"
    [[ -z "${uuid:-}" ]] && uuid="-"
    [[ -z "${fstype:-}" ]] && fstype="-"

    local label
    label="$path  ($fstype, $size)"
    if [[ "$mp" != "-" ]]; then
      label+=" mounted:$mp"
    fi

    local id
    if [[ "$uuid" != "-" ]]; then
      id="$uuid"
      label+=" uuid:$uuid"
    else
      id="$path"
    fi

    choices+=("$id" "$label")
  done < <(lsblk -nrpo PATH,TYPE,RM,TRAN,SIZE,FSTYPE,MOUNTPOINT,UUID 2>/dev/null || true)

  # Fallback (très rare): ancienne commande
  if [[ ${#choices[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      local name fstype size mp uuid
      name="$(awk '{print $1}' <<<"$line")"
      fstype="$(awk '{print $2}' <<<"$line")"
      size="$(awk '{print $3}' <<<"$line")"
      mp="$(awk '{print $4}' <<<"$line")"
      uuid="$(awk '{print $5}' <<<"$line")"

      [[ -z "$name" ]] && continue
      [[ "$name" != */* ]] && continue

      local label="$name ($fstype, $size)"
      [[ -n "$mp" && "$mp" != "-" ]] && label+=" mounted:$mp"

      local id
      if [[ -n "$uuid" && "$uuid" != "-" ]]; then
        id="$uuid"
        label+=" uuid:$uuid"
      else
        id="$name"
      fi

      choices+=("$id" "$label")
    done < <(lsblk -rpo NAME,FSTYPE,SIZE,MOUNTPOINT,UUID 2>/dev/null | awk '$2 != "" {print $0}')
  fi

  if [[ ${#choices[@]} -eq 0 ]]; then
    whi_info "USB" "Aucune partition USB détectée.\n\nSi tu vois la clé dans 'lsusb' mais pas ici, vérifie qu'elle apparaît dans 'lsblk' (périphérique /dev/sdX) et qu'elle contient au moins une partition."
    return 1
  fi

  whiptail --title "USB" --menu "Choisis une partition" 22 100 12 \
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

setup_usb_backup() {
  apt_install util-linux

  local id
  id="$(choose_usb_partition)" || return 1

  local mountpoint
  mountpoint="$(whi_input "USB" "Point de montage :" "/mnt/usbbackup")" || return 1

  mkdir -p "$mountpoint"

  sed -i "\|$mountpoint|d" /etc/fstab

  # Si l'utilisateur a choisi un UUID => on persiste en UUID. Sinon on persiste via le PATH.
  if [[ "$id" =~ ^[0-9A-Fa-f-]{4,}$ ]]; then
    sed -i "\|UUID=$id|d" /etc/fstab
    echo "UUID=$id  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab
  else
    sed -i "\|^${id}[[:space:]]|d" /etc/fstab
    echo "$id  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab
  fi

  systemctl daemon-reload || true
  mount "$mountpoint" || true

  mkdir -p "$mountpoint/restic-ha"
  add_repo "$mountpoint/restic-ha"
  init_restic_repo "$mountpoint/restic-ha"
}

