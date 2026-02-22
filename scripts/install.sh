#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/srv/ha-stack"
ENV_FILE="${STACK_DIR}/.env"
RESTIC_DIR="${STACK_DIR}/restic"
RESTIC_REPOS="${RESTIC_DIR}/repos.conf"
RESTIC_PASS="${RESTIC_DIR}/password"
SAMBA_CREDS="/etc/samba/creds-ha"

# Compose utilisé pour le démarrage final + complétion du .env
DEFAULT_COMPOSE_PATH="${STACK_DIR}/docker-compose.yml"
COMPOSE_PATH="${DEFAULT_COMPOSE_PATH}"

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
  whiptail --title "$title" --inputbox "$prompt" 10 70 "$default" \
    --ok-button "Valider" --cancel-button "Retour" 3>&1 1>&2 2>&3
}

whi_pass() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --passwordbox "$prompt" 10 70 \
    --ok-button "Valider" --cancel-button "Retour" 3>&1 1>&2 2>&3
}

whi_yesno() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "Oui" --no-button "Non"
}

# Petit helper: affiche une info avec "OK"
whi_info() {
  local title="$1" msg="$2"
  whiptail --title "$title" --msgbox "$msg" 12 80 --ok-button "OK"
}

whi_confirm() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 70 \
    --yes-button "Oui" --no-button "Non"
}

is_interactive_tty() {
  [[ -t 0 && -t 1 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

ensure_dirs() {
  mkdir -p "$STACK_DIR"/{config,postgres,backup,caddy/data,caddy/config,scripts,systemd}
  mkdir -p "$RESTIC_DIR"
  chmod 700 "$STACK_DIR" || true
}

# --- Compose/.env helpers -------------------------------------------------

sanitize_env_value() {
  # Dans un .env, on évite les retours ligne. On garde tel quel sinon.
  local v="$1"
  v="${v//$'\n'/}"
  echo "$v"
}

env_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  # Support minimal des formats KEY=VALUE (ignore commentaires/exports)
  awk -F= -v k="$key" 'BEGIN{found=0} $0 ~ "^[[:space:]]*"k"=" {sub(/^[[:space:]]*"k"=/, ""); print; found=1; exit} END{exit(found?0:1)}' "$file"
}

env_has_key() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  grep -Eq "^[[:space:]]*${key}=" "$file"
}

env_set_kv() {
  # Met à jour ou ajoute KEY=VALUE, sans toucher au reste.
  local key="$1" value="$2" file="$3"
  value="$(sanitize_env_value "$value")"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" || true

  if env_has_key "$key" "$file"; then
    # Remplace la première occurrence.
    # shellcheck disable=SC2001
    sed -i "0,/^[[:space:]]*${key}=/{s|^[[:space:]]*${key}=.*|${key}=${value}|}" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
}

compose_extract_vars() {
  # Extrait: VAR [TAB] default (default peut être vide)
  # Supporte ${VAR} et ${VAR:-default}
  local compose_file="$1"
  [[ -f "$compose_file" ]] || return 0

  # On peut avoir plusieurs occurrences; on déduplique en gardant le 1er default non vide.
  awk '
    {
      line=$0
      while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/)) {
        token=substr(line, RSTART, RLENGTH)
        inner=substr(token, 3, length(token)-3)
        name=inner
        def=""
        if (index(inner,":-")>0) {
          name=substr(inner, 1, index(inner,":-")-1)
          def=substr(inner, index(inner,":-")+2)
        }
        if (!(name in seen)) {
          seen[name]=1
          defs[name]=def
          order[++n]=name
        } else if (defs[name]=="" && def!="") {
          defs[name]=def
        }
        line=substr(line, RSTART+RLENGTH)
      }
    }
    END {
      for (i=1;i<=n;i++) {
        name=order[i]
        printf "%s\t%s\n", name, defs[name]
      }
    }
  ' "$compose_file"
}

choose_compose_source() {
  # Choix du compose: défaut / chemin local / URL
  # Dépose une copie dans STACK_DIR si nécessaire.
  local action
  action=$(whiptail --title "Docker Compose" --menu "Quel docker-compose veux-tu utiliser ?" 18 84 10 \
    --ok-button "Valider" --cancel-button "Retour" \
    "defaut" "Utiliser ${DEFAULT_COMPOSE_PATH}" \
    "local" "Saisir un chemin local" \
    "url" "Télécharger depuis une URL (http/https)" \
    3>&1 1>&2 2>&3) || return 1

  case "$action" in
    defaut)
      COMPOSE_PATH="$DEFAULT_COMPOSE_PATH"
      ;;
    local)
      local p
      p="$(whi_input "Docker Compose" "Chemin complet du docker-compose.yml" "$DEFAULT_COMPOSE_PATH")" || return 1
      if [[ ! -f "$p" ]]; then
        whi_info "Docker Compose" "Fichier introuvable: $p"
        return 1
      fi
      COMPOSE_PATH="$p"
      ;;
    url)
      apt_install curl ca-certificates
      local u dest
      u="$(whi_input "Docker Compose" "URL (http/https)" "")" || return 1
      dest="${STACK_DIR}/docker-compose.remote.yml"
      if ! curl -fsSL "$u" -o "$dest"; then
        whi_info "Docker Compose" "Téléchargement impossible. Vérifie l'URL/réseau."
        return 1
      fi
      chmod 600 "$dest" || true
      COMPOSE_PATH="$dest"
      ;;
  esac

  return 0
}

env_ensure_from_compose() {
  local compose_file="$1"

  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true

  local vars
  vars="$(compose_extract_vars "$compose_file" || true)"
  if [[ -z "$vars" ]]; then
    return 0
  fi

  # Charge ce qu'on peut (pour pré-remplir l'input)
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE" 2>/dev/null || true
  set +a

  while IFS=$'\t' read -r name def; do
    [[ -z "${name:-}" ]] && continue

    # Ignore les variables Compose internes fréquentes si tu veux (aucune pour l'instant)

    if env_has_key "$name" "$ENV_FILE"; then
      continue
    fi

    # pour set -u: éviter une sortie si l'utilisateur annule
    local current=""
    current="$(env_get "$name" "$ENV_FILE" 2>/dev/null || true)"

    local default="${current:-}"
    if [[ -z "$default" && -n "${def:-}" ]]; then
      default="$def"
    fi

    local val
    val="$(whi_input "Variables Compose" "$name (manquant dans .env)" "$default")" || return 1
    env_set_kv "$name" "$val" "$ENV_FILE"
  done <<< "$vars"

  # Recharge les variables dans l’environnement du script
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

# --- Restic restore -------------------------------------------------------

restic_can_run() {
  req_bin restic || return 1
  [[ -f "$RESTIC_PASS" ]] || return 1
  return 0
}

restic_choose_repo() {
  if [[ ! -f "$RESTIC_REPOS" || ! -s "$RESTIC_REPOS" ]]; then
    whi_info "Restic" "Aucun repository dans ${RESTIC_REPOS}. Configure d'abord un NAS/USB."
    return 1
  fi

  local choices=()
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    choices+=("$repo" "$repo")
  done < "$RESTIC_REPOS"

  whiptail --title "Restic" --menu "Choisis un repository" 20 92 12 \
    --ok-button "Valider" --cancel-button "Retour" \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

restic_choose_snapshot() {
  local repo="$1"
  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"

  local snaps
  if ! snaps="$(restic snapshots --compact 2>/dev/null | awk 'NR>2 && $1 ~ /^[0-9a-f]+$/ {print $1"\t"$2" "$3" "$4" "$5}' | head -n 30)"; then
    return 1
  fi

  if [[ -z "$snaps" ]]; then
    whi_info "Restic" "Aucun snapshot trouvé dans $repo."
    return 1
  fi

  local choices=()
  while IFS=$'\t' read -r id label; do
    [[ -z "$id" ]] && continue
    choices+=("$id" "$label")
  done <<< "$snaps"

  whiptail --title "Restic" --menu "Choisis un snapshot (30 derniers max)" 22 92 12 \
    --ok-button "Valider" --cancel-button "Retour" \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

restore_wizard() {
  # Pré-requis: repos configurés + password + restic installé
  if ! req_bin restic; then
    apt_install restic
  fi

  if [[ ! -f "$RESTIC_PASS" ]]; then
    whi_info "Restic" "Mot de passe Restic absent (${RESTIC_PASS})."
    return 1
  fi

  if ! whi_yesno "Restauration" "Restaurer un backup Restic maintenant ?"; then
    return 0
  fi

  whi_info "Restauration" "Astuce: il faut d'abord que le repository Restic soit accessible (NAS/USB monté)."

  local repo snapshot target
  repo="$(restic_choose_repo)" || return 1
  snapshot="$(restic_choose_snapshot "$repo")" || return 1
  target="$(whi_input "Restauration" "Restaurer dans quel dossier ?" "$STACK_DIR")" || return 1

  if [[ "$target" == "/" || -z "$target" ]]; then
    whi_info "Restauration" "Chemin de destination invalide."
    return 1
  fi

  mkdir -p "$target"

  if ! whi_confirm "Restauration" "Confirme la restauration\n\nRepo: $repo\nSnapshot: $snapshot\nCible: $target\n\nÇa peut écraser des fichiers existants."; then
    return 1
  fi

  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"

  if ! restic restore "$snapshot" --target "$target"; then
    whi_info "Restauration" "Échec de restauration. Vérifie le mot de passe, le montage NAS/USB et le réseau."
    return 1
  fi

  whi_info "Restauration" "Restauration terminée dans: $target"
  return 0
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
    --ok-button "Valider" --cancel-button "Retour" \
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

  # Complète .env depuis le compose choisi (si des variables sont manquantes)
  env_ensure_from_compose "$COMPOSE_PATH" || true

  # Charge les variables dans l’environnement du script
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE" 2>/dev/null || true
  set +a
}

setup_usb_backup() {
  apt_install util-linux

  local uuid
  uuid="$(choose_usb_partition)" || return 1

  local mountpoint
  mountpoint="$(whi_input "USB" "Point de montage :" "/mnt/usbbackup")" || return 1

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
    action=$(whiptail --title "Résumé" --menu "Que veux-tu faire ?" 20 90 12 \
      --ok-button "Valider" --cancel-button "Retour" \
      "revoir" "Revoir ce résumé" \
      "finaliser" "Terminer l'installation" \
      "quit" "Quitter l'installation" \
      "edit-compose" "Changer le docker-compose utilisé" \
      "edit-env" "Compléter / modifier le .env (variables compose)" \
      "restic-pass" "Redéfinir le mot de passe Restic" \
      "restore" "Restaurer un backup Restic" \
      "nas" "Configurer / reconfigurer un NAS SMB" \
      "usb" "Configurer / reconfigurer un disque USB" \
      3>&1 1>&2 2>&3)

    if [[ -z "${action:-}" ]]; then
      # Retour => revient au menu (donc permet de "rester" sans finaliser)
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
      edit-compose)
        choose_compose_source || true
        # Re-complète .env en fonction du nouveau compose
        env_ensure_from_compose "$COMPOSE_PATH" || true
        set -a
        . "$ENV_FILE" 2>/dev/null || true
        set +a
        configure_homeassistant_yaml
        ;;
      edit-env)
        # Complète d'abord depuis compose, puis options Postgres (historique)
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
        . "$ENV_FILE" 2>/dev/null || true
        set +a

        configure_homeassistant_yaml
        ;;
      restic-pass)
        rm -f "$RESTIC_PASS"
        setup_restic_password
        ;;
      restore)
        restore_wizard || whi_info "Restauration" "Restauration annulée / échouée."
        ;;
      nas)
        setup_nas_smb || whi_info "NAS" "Configuration NAS annulée."
        ;;
      usb)
        setup_usb_backup || whi_info "USB" "Configuration USB annulée."
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

setup_compose_prereqs() {
  if ! req_bin docker; then
    apt_install docker.io
  fi

  # Docker Compose plugin (compose v2)
  if ! docker compose version >/dev/null 2>&1; then
    apt_install docker-compose-plugin
  fi
}

main() {
  need_root
  ensure_dirs

  # deps minimales pour l’install
  # NOTE: sur Debian trixie, `awk` est un paquet *virtuel* -> installer une implémentation.
  apt_install whiptail sed coreutils util-linux ca-certificates
  apt_install mawk || apt_install gawk

  setup_compose_prereqs

  # Choix du compose (important avant setup_env pour compléter le .env)
  choose_compose_source || true

  setup_env
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

  # Wizard restauration (optionnel)
  restore_wizard || true

  local summary_rc=0
  show_summary_and_edit || summary_rc=$?

  if [[ "$summary_rc" -eq 2 ]]; then
    whi_info "Installation" "Installation quittée. Rien n'a été démarré."
    exit 0
  fi

  whiptail --msgbox "Installation terminée.\n\nDémarrage: cd $STACK_DIR && docker compose -f $COMPOSE_PATH up -d" 12 78 --ok-button "OK"
}

main "$@"
