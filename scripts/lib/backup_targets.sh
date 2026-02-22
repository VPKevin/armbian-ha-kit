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

  # lsblk JSON est plus fiable (pas d'alignement à parser)
  if lsblk --json -o NAME,PATH,TYPE,RM,TRAN,SIZE,FSTYPE,MOUNTPOINT,UUID,MODEL >/dev/null 2>&1; then
    local json
    json="$(lsblk --json -o NAME,PATH,TYPE,RM,TRAN,SIZE,FSTYPE,MOUNTPOINT,UUID,MODEL 2>/dev/null || true)"

    # Extraction simple sans jq: on repère les blocs TYPE=part et RM=1 ou TRAN=usb
    # et on récupère PATH/UUID/MODEL/SIZE/FSTYPE/MOUNTPOINT.
    # NOTE: best-effort, si parsing échoue on retombe sur la méthode texte.
    local lines
    lines="$(printf '%s\n' "$json" \
      | tr '{' '\n' \
      | grep -E '"type"\s*:\s*"part"' -n 2>/dev/null || true)"

    if [[ -n "${lines:-}" ]]; then
      # Re-parse with awk in a streaming way: keep last seen fields.
      while IFS= read -r blk; do
        local path uuid size fstype mp model tran rm
        path="$(grep -oE '"path"\s*:\s*"[^"]+"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
        uuid="$(grep -oE '"uuid"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        size="$(grep -oE '"size"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        fstype="$(grep -oE '"fstype"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        mp="$(grep -oE '"mountpoint"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        model="$(grep -oE '"model"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        tran="$(grep -oE '"tran"\s*:\s*"[^"]*"' <<<"$blk" | head -n1 | sed -E 's/.*"([^"]*)"/\1/')"
        rm="$(grep -oE '"rm"\s*:\s*(true|false|[0-9]+)' <<<"$blk" | head -n1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')"

        # Filtre: USB (TRAN=usb) ou removable (RM=true/1)
        if [[ "${tran:-}" != "usb" && "${rm:-}" != "true" && "${rm:-}" != "1" ]]; then
          continue
        fi

        [[ -z "${path:-}" ]] && continue

        local label="${path}"
        [[ -n "${model:-}" ]] && label+=" (${model})"
        [[ -n "${size:-}" ]] && label+=" ${size}"
        [[ -n "${fstype:-}" ]] && label+=" ${fstype}"
        [[ -n "${mp:-}" && "${mp:-}" != "null" ]] && label+=" mounted:${mp}"
        [[ -n "${uuid:-}" && "${uuid:-}" != "null" ]] && label+=" uuid:${uuid}"

        # ID: uuid si dispo, sinon path (on utilisera /dev/... dans /etc/fstab via /dev/disk/by-uuid si uuid)
        local id
        if [[ -n "${uuid:-}" && "${uuid:-}" != "null" ]]; then
          id="$uuid"
        else
          id="$path"
        fi

        choices+=("$id" "$label")
      done < <(printf '%s\n' "$json" | tr '}' '\n' | grep -E '"type"\s*:\s*"part"' 2>/dev/null || true)
    fi
  fi

  # Fallback texte si pas de choix
  if [[ ${#choices[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      local path name fstype size mp uuid
      name="$(awk '{print $1}' <<<"$line")"
      fstype="$(awk '{print $2}' <<<"$line")"
      size="$(awk '{print $3}' <<<"$line")"
      mp="$(awk '{print $4}' <<<"$line")"
      uuid="$(awk '{print $5}' <<<"$line")"

      [[ -z "$name" ]] && continue

      path="$name"

      local label="$path ($fstype, $size)"
      if [[ -n "$mp" && "$mp" != "-" ]]; then
        label+=" mounted:$mp"
      fi
      if [[ -n "$uuid" && "$uuid" != "-" ]]; then
        label+=" uuid:$uuid"
      fi

      local id
      if [[ -n "$uuid" && "$uuid" != "-" ]]; then id="$uuid"; else id="$path"; fi

      choices+=("$id" "$label")
    done < <(lsblk -rpo NAME,FSTYPE,SIZE,MOUNTPOINT,UUID 2>/dev/null | awk '$2 != "" {print $0}')
  fi

  if [[ ${#choices[@]} -eq 0 ]]; then
    whi_info "USB" "Aucune partition USB détectée (lsblk n'a rien retourné).\n\nSi tu vois la clé dans 'lsusb' mais pas dans 'lsblk', c'est souvent qu'elle n'apparaît pas comme stockage de masse, ou qu'elle n'a pas encore de partition."
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
    # Exemple: /dev/sda1
    sed -i "\|^${id}[[:space:]]|d" /etc/fstab
    echo "$id  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab
  fi

  systemctl daemon-reload || true
  mount "$mountpoint" || true

  mkdir -p "$mountpoint/restic-ha"
  add_repo "$mountpoint/restic-ha"
  init_restic_repo "$mountpoint/restic-ha"
}

