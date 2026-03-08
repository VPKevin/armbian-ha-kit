#!/usr/bin/env bash
set -euo pipefail

# NAS SMB + USB setup (montage + ajout repo restic).

# Contracts (P0):
# - Fonctions: setup_nas_smb, choose_usb_partition, setup_usb_backup, fstab_remove_matching
# - Entrées: variables globales: SAMBA_CREDS, STACK_DIR, RESTIC_DIR, RESTIC_REPOS
# - Sorties: modifications de /etc/fstab, création de SAMBA_CREDS, ajout de repos dans RESTIC_REPOS
# - Codes retour: 0 succès, non-zero en cas d'erreur.

fstab_remove_matching() {
  # Supprime de /etc/fstab les lignes qui matchent un pattern regex (ERE) de façon robuste.
  # On évite `sed -i` sur des patterns non échappés (cause typique de "unterminated address regex").
  local pattern="$1"
  local fstab="/etc/fstab"

  [[ -f "$fstab" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  awk -v re="$pattern" 'BEGIN{removed=0} $0 ~ re {removed=1; next} {print} END{exit 0}' "$fstab" >"$tmp"
  cat "$tmp" >"$fstab"
  rm -f "$tmp"
}

setup_nas_smb() {
  apt_install cifs-utils

  local server share user pass mountpoint subdir

  server="$(ui_input "NAS SMB" "Serveur (IP ou nom) :")" || return $?
  share="$(ui_input "NAS SMB" "Nom du partage (share) :")" || return $?
  subdir="$(ui_input "NAS SMB" "Sous-dossier (optionnel, vide si aucun) :")" || return $?
  user="$(ui_input "NAS SMB" "Utilisateur :")" || return $?
  pass="$(ui_pass "NAS SMB" "Mot de passe :")" || return $?
  mountpoint="$(ui_input "NAS SMB" "Point de montage :" "/mnt/nasbackup")" || return $?

  mkdir -p /etc/samba
  cat > "$SAMBA_CREDS" <<EOF
username=$user
password=$pass
EOF
  chmod 600 "$SAMBA_CREDS"

  mkdir -p "$mountpoint"

  local remote="//$server/$share"
  local opts="credentials=$SAMBA_CREDS,iocharset=utf8,uid=0,gid=0,file_mode=0600,dir_mode=0700,nofail,x-systemd.automount"

  # Supprime les anciennes entrées sur ce mountpoint
  fstab_remove_matching "[[:space:]]${mountpoint//\//\/}[[:space:]]" || true

  echo "$remote  $mountpoint  cifs  $opts  0  0" >> /etc/fstab

  systemctl daemon-reload

  # Déclenche le montage (automount) puis vérifie réellement que c'est monté.
  mount "$mountpoint" 2>/tmp/ha-nas-mount.err || true
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    local err
    err="$(tail -n 50 /tmp/ha-nas-mount.err 2>/dev/null | sed 's/^/  /' || true)"
    ui_info "NAS SMB" "Le partage n'a pas pu être monté sur $mountpoint.\n\nSi tu utilises x-systemd.automount, un accès au dossier doit déclencher le montage, mais ici il a échoué.\n\nErreur:\n${err}"
    return 1
  fi

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
    ui_info "USB" "Aucune partition USB détectée.\n\nSi tu vois la clé dans 'lsusb' mais pas ici, vérifie qu'elle apparaît dans 'lsblk' (périphérique /dev/sdX) et qu'elle contient au moins une partition."
    return 1
  fi

  # Utilise le wrapper ui_menu (stdout: la clé choisie)
  ui_menu "USB" "Choisis une partition" 22 100 12 "${choices[@]}"
}

setup_usb_backup() {
  apt_install util-linux

  local id
  id="$(choose_usb_partition)" || return 1

  local mountpoint
  mountpoint="$(ui_input "USB" "Point de montage :" "/mnt/usbbackup")" || return 1

  mkdir -p "$mountpoint"

  # Nettoyage fstab sur mountpoint
  fstab_remove_matching "[[:space:]]${mountpoint//\//\/}[[:space:]]" || true

  # Si l'utilisateur a choisi un UUID => on persiste en UUID. Sinon on persiste via le PATH.
  if [[ "$id" =~ ^[0-9A-Fa-f-]{4,}$ ]]; then
    fstab_remove_matching "^UUID=${id}[[:space:]]" || true
    echo "UUID=$id  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab
  else
    fstab_remove_matching "^${id//\//\/}[[:space:]]" || true
    echo "$id  $mountpoint  auto  nofail,x-systemd.automount  0  2" >> /etc/fstab
  fi

  systemctl daemon-reload || true

  if ! mount "$mountpoint" 2>/tmp/ha-usb-mount.err; then
    local err
    err="$(tail -n 50 /tmp/ha-usb-mount.err 2>/dev/null | sed 's/^/  /' || true)"
    ui_info "USB" "Échec du montage de $mountpoint.\n\nVérifie le format (exfat/ext4) et que la partition est correcte.\n\nErreur:\n${err}"
    return 1
  fi

  # Vérifie qu'on est bien monté (évite le cas 'mount' OK mais pas de device, ou automount non déclenché)
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    ui_info "USB" "Le point $mountpoint n'est pas monté (mountpoint -q=false).\n\nAstuce: si x-systemd.automount est actif, un accès au dossier doit déclencher le montage."
    return 1
  fi

  # Vérifie que c'est bien écrivable (cause fréquente: FS en read-only, permissions exfat/ntfs, etc.)
  if ! (touch "$mountpoint/.ha_write_test" 2>/tmp/ha-usb-write.err && rm -f "$mountpoint/.ha_write_test" 2>/tmp/ha-usb-write.err); then
    local err fsline
    err="$(tail -n 50 /tmp/ha-usb-write.err 2>/dev/null | sed 's/^/  /' || true)"
    fsline="$(findmnt -n -o FSTYPE,OPTIONS --target "$mountpoint" 2>/dev/null || true)"
    ui_info "USB" "Le point de montage n'est pas écrivable: $mountpoint\n\nFS/options: ${fsline}\n\nErreur:\n${err}"
    return 1
  fi

  mkdir -p "$mountpoint/restic-ha"

  add_repo "$mountpoint/restic-ha"
  if ! init_restic_repo "$mountpoint/restic-ha" 2>/tmp/ha-usb-restic.err; then
    local err fsline
    err="$(tail -n 80 /tmp/ha-usb-restic.err 2>/dev/null | sed 's/^/  /' || true)"
    fsline="$(findmnt -n -o FSTYPE,OPTIONS --target "$mountpoint" 2>/dev/null || true)"
    ui_info "USB" "Échec d'initialisation du repository Restic sur USB.\n\nRepo: $mountpoint/restic-ha\nFS/options: ${fsline}\n\nErreur:\n${err}"
    return 1
  fi

  ui_info "USB" "USB configurée.\n\nMount: $mountpoint\nRepo Restic: $mountpoint/restic-ha"
  return 0
}
