#!/usr/bin/env bash
set -euo pipefail

# Restic: password, repos, init, restauration.

ensure_restic() {
  # Restic est requis pour init/snapshots/restore. On l'installe si absent.
  if req_bin restic; then
    return 0
  fi

  # apt_install est défini dans scripts/install.sh (source commun).
  apt_install restic

  if ! req_bin restic; then
    whi_info "Restic" "Restic n'est pas disponible (commande 'restic' absente après installation)."
    return 1
  fi
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
  ensure_restic || return 1

  if [[ ! -f "$RESTIC_PASS" ]]; then
    echo "Restic password file missing: $RESTIC_PASS" >&2
    return 1
  fi

  # S'assure que le path existe (utile pour USB/NAS)
  mkdir -p "$repo" 2>/dev/null || true

  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"

  # Si snapshots marche => repo OK. Sinon, on tente init et on laisse stderr remonter.
  if ! restic snapshots >/dev/null 2>&1; then
    restic init 1>/dev/null
  fi
}

setup_restic_password() {
  mkdir -p "$RESTIC_DIR"
  if [[ -f "$RESTIC_PASS" ]]; then
    return
  fi

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
      whi_info "Restic" "Mot de passe invalide / différent."
      exit 1
    fi
    printf "%s" "$p1" > "$RESTIC_PASS"
  else
    head -c 48 /dev/urandom | base64 > "$RESTIC_PASS"
  fi
  chmod 600 "$RESTIC_PASS"
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
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
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
    --ok-button "$(t VALIDATE)" --cancel-button "$(t BACK)" \
    "${choices[@]}" 3>&1 1>&2 2>&3
}

restore_confirm_wizard() {
  if ! whi_yesno "Restauration" "Restaurer un backup Restic maintenant ?"; then
    return 0
  fi
  restore_wizard
}

restore_wizard() {
  ensure_restic || return 1

  if [[ ! -f "$RESTIC_PASS" ]]; then
    whi_info "Restic" "Mot de passe Restic absent (${RESTIC_PASS})."
    return 1
  fi

  # IMPORTANT: le menu principal propose déjà "Restaurer". Donc ici, on ne redemande
  # pas une confirmation: si on est ici, c'est que l'utilisateur veut restaurer.

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

