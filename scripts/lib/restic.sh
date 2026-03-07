#!/usr/bin/env bash
set -euo pipefail

# Restic: password, repos, init, restauration.

# Contracts (P0):
# - Fonctions exposées: ensure_restic, add_repo, init_restic_repo, setup_restic_password,
#   restic_choose_repo, restic_choose_snapshot, restore_wizard, restore_step_*
# - Entrées: variables globales: RESTIC_DIR, RESTIC_REPOS, RESTIC_PASS, ENV_FILE
# - Sorties: fichiers créés (RESTIC_PASS, RESTIC_REPOS), exportation de RESTIC_* vars,
#   et appels aux commandes restic.
# - Codes retour: 0 succès, non-zero en cas d'erreur; UI_* pour les flows interactifs.

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
  RESTIC_PROMPTED=0
  mkdir -p "$RESTIC_DIR"
  if [[ -f "$RESTIC_PASS" ]]; then
    return 0
  fi

  if ! is_interactive_tty; then
    head -c 48 /dev/urandom | base64 > "$RESTIC_PASS"
    chmod 600 "$RESTIC_PASS"
    return 0
  fi

  while true; do
    local ans
    ans="$(whi_yesno_back "Restic" "Définir un mot de passe restic maintenant ? (sinon il sera généré aléatoirement)" "yes")" || return $?
    RESTIC_PROMPTED=1
    if [[ "$ans" == "yes" ]]; then
      local back_to_prompt=0
      while true; do
        local p1 p2
        if ! p1="$(whi_pass "Restic" "Mot de passe restic (à conserver !)")"; then
          local rc=$?
          if [[ $rc -eq $UI_BACK ]]; then
            # Retourne à la question "définir un mot de passe ?"
            back_to_prompt=1
            break
          fi
          return $rc
        fi
        RESTIC_PROMPTED=1

        if ! p2="$(whi_pass "Restic" "Confirme le mot de passe restic")"; then
          local rc=$?
          if [[ $rc -eq $UI_BACK ]]; then
            # Retourne à la saisie du mot de passe
            continue
          fi
          return $rc
        fi
        RESTIC_PROMPTED=1

        if [[ -z "${p1:-}" ]]; then
          whi_info "Restic" "Mot de passe vide."
          continue
        fi
        if [[ "$p1" != "$p2" ]]; then
          whi_info "Restic" "Les mots de passe ne correspondent pas."
          continue
        fi

        printf "%s" "$p1" > "$RESTIC_PASS"
        return 0
      done
      if [[ $back_to_prompt -eq 1 ]]; then
        continue
      fi
    else
      head -c 48 /dev/urandom | base64 > "$RESTIC_PASS"
      return 0
    fi
  done

  chmod 600 "$RESTIC_PASS"
  return 0
}

restic_choose_repo() {
  if [[ ! -f "$RESTIC_REPOS" || ! -s "$RESTIC_REPOS" ]]; then
    whi_info "Restic" "Aucun repository dans ${RESTIC_REPOS}.\n\nPour restaurer, il faut d'abord rendre accessible un repository (NAS/USB monté) et l'ajouter à la configuration."

    # En mode interactif, on peut guider l'utilisateur pour configurer un target.
    if is_interactive_tty && command -v whi_menu >/dev/null 2>&1; then
      local choice rc
      if choice="$(whi_menu "Restic" "Configurer un repository de sauvegarde maintenant ?" 18 90 10 \
        "nas" "Configurer un NAS (SMB/CIFS)" \
        "usb" "Configurer un disque USB" \
        "cancel" "Annuler")"; then
        rc=$UI_OK
      else
        rc=$?
      fi

      case "$rc" in
        "$UI_BACK"|"$UI_ABORT")
          return "$rc"
          ;;
      esac

      case "$choice" in
        nas)
          if command -v setup_nas_smb >/dev/null 2>&1; then
            setup_nas_smb || true
          else
            whi_info "Restic" "Setup NAS indisponible (setup_nas_smb introuvable)."
          fi
          ;;
        usb)
          if command -v setup_usb_backup >/dev/null 2>&1; then
            setup_usb_backup || true
          else
            whi_info "Restic" "Setup USB indisponible (setup_usb_backup introuvable)."
          fi
          ;;
        cancel|*)
          return "$UI_BACK"
          ;;
      esac

      # Si un repo vient d'être ajouté, retenter la sélection.
      if [[ -f "$RESTIC_REPOS" && -s "$RESTIC_REPOS" ]]; then
        # relance la fonction (une seule fois) pour construire les choices
        restic_choose_repo
        return $?
      fi
    fi

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

  whi_info "Restauration" "Astuce: il faut d'abord que le repository Restic soit accessible (NAS/USB monté)."

  local repo="" snapshot="" target=""
  local steps=(restore_step_repo restore_step_snapshot restore_step_target restore_step_confirm restore_step_run)
  local idx=0 total=${#steps[@]}
  while (( idx < total )); do
    local fn="${steps[$idx]}"
    "$fn" repo snapshot target
    local rc=$?
    case "$rc" in
      "$UI_OK") ((idx++)) ;;
      "$UI_BACK")
        if (( idx == 0 )); then
          return "$UI_ABORT"
        fi
        ((idx--))
        ;;
      "$UI_ABORT") return "$UI_ABORT" ;;
      *) return "$UI_ABORT" ;;
    esac
  done

  whi_info "Restauration" "Restauration terminée dans: $target"
  return 0
}

restore_step_repo() {
  local _repo_var="$1" _snap_var="$2" _target_var="$3"
  local repo
  repo="$(restic_choose_repo)" || return $?
  printf -v "$_repo_var" '%s' "$repo"
  return "$UI_OK"
}

restore_step_snapshot() {
  local _repo_var="$1" _snap_var="$2" _target_var="$3"
  local repo="${!_repo_var}"
  local snapshot
  snapshot="$(restic_choose_snapshot "$repo")" || return $?
  printf -v "$_snap_var" '%s' "$snapshot"
  return "$UI_OK"
}

restore_step_target() {
  local _repo_var="$1" _snap_var="$2" _target_var="$3"
  local target
  target="$(whi_input "Restauration" "Restaurer dans quel dossier ?" "$STACK_DIR")" || return $?

  if [[ "$target" == "/" || -z "$target" ]]; then
    whi_info "Restauration" "Chemin de destination invalide."
    return 1
  fi
  mkdir -p "$target"
  printf -v "$_target_var" '%s' "$target"
  return "$UI_OK"
}

restore_step_confirm() {
  local _repo_var="$1" _snap_var="$2" _target_var="$3"
  local repo="${!_repo_var}" snapshot="${!_snap_var}" target="${!_target_var}"
  if ! whi_confirm "Restauration" "Confirme la restauration\n\nRepo: $repo\nSnapshot: $snapshot\nCible: $target\n\nÇa peut écraser des fichiers existants."; then
    return $?
  fi
  return "$UI_OK"
}

restore_step_run() {
  local _repo_var="$1" _snap_var="$2" _target_var="$3"
  local repo="${!_repo_var}" snapshot="${!_snap_var}" target="${!_target_var}"

  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS"

  if ! restic restore "$snapshot" --target "$target"; then
    whi_info "Restauration" "Échec de restauration. Vérifie le mot de passe, le montage NAS/USB et le réseau."
    return 1
  fi
  return "$UI_OK"
}