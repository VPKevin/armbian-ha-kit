#!/usr/bin/env bash
set -euo pipefail

# Désinstallation de la stack.

uninstall_remove_packages() {
  # Best-effort: retirer des dépendances installées par le projet.
  # On ne purge pas docker/caddy (peut être utilisé par d'autres services).

  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi

  local pkgs=()

  # Si on a un état (nouvelle version), on l'utilise.
  if command -v apt_state_list >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "${p:-}" ]] || continue
      pkgs+=("$p")
    done < <(apt_state_list)
  fi

  # Aucun fallback: on n'essaie pas de deviner des paquets quand l'état est manquant.
  # Seuls les paquets explicitement enregistrés par le kit (apt_state_list) sont pris en compte.
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    return 0
  fi

  # Sécurité: ne jamais retirer docker/caddy via ce mécanisme.
  local filtered=()
  local p
  for p in "${pkgs[@]}"; do
    case "$p" in
      docker.io|docker-compose-plugin|caddy)
        continue
        ;;
    esac
    # Inclure uniquement si le paquet est réellement installé sur le système.
    if apt_is_installed "$p"; then
      filtered+=("$p")
    fi
  done

  if [[ ${#filtered[@]} -eq 0 ]]; then
    return 0
  fi

  apt-get remove -y "${filtered[@]}" 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
}

uninstall_wizard() {
  if ! whi_yesno "Désinstallation" "Tout désinstaller ?\n\nCette action peut supprimer les conteneurs et, si tu le demandes, les données dans ${STACK_DIR}."; then
    return 0
  fi

  local remove_data=0
  if whi_yesno "Désinstallation" "Supprimer aussi les données (config, postgres, backup, caddy, restic) dans ${STACK_DIR} ?\n\nATTENTION: irréversible."; then
    remove_data=1
  fi

  # Préparer la liste des paquets connus installés par le kit pour l'afficher
  local pkg_list=()
  if command -v apt-get >/dev/null 2>&1; then
    if command -v apt_state_list >/dev/null 2>&1; then
      while IFS= read -r p; do
        [[ -n "${p:-}" ]] || continue
        pkg_list+=("$p")
      done < <(apt_state_list)
    fi

    # Pas de fallback : si le fichier d'état est vide/absent, on considère qu'il
    # n'y a pas de paquets gérés par le kit et la frame sera sautée.
    if [[ ${#pkg_list[@]} -eq 0 ]]; then
      pkg_list=()
    fi
  fi

  # Filtrer les paquets sensibles qu'on ne doit jamais proposer de supprimer.
  local filtered_pkgs=()
  local _p
  # Lire le timestamp de création du fichier d'état si présent (en-tête '# created:...')
  local state_file
  state_file="$(apt_state_file)"
  local state_created_ts=0
  if [[ -f "$state_file" ]]; then
    # extraire la première ligne # created:NUM
    if grep -E '^# created:' "$state_file" >/dev/null 2>&1; then
      state_created_ts=$(grep -E '^# created:' "$state_file" | head -n1 | sed -E 's/^# created:([0-9]+).*/\1/') || true
    else
      # fallback to file mtime
      state_created_ts=$(file_mtime "$state_file" 2>/dev/null || echo 0)
    fi
  fi
  for _p in "${pkg_list[@]}"; do
    case "$_p" in
      docker.io|docker-compose-plugin|caddy)
        continue
        ;;
    esac
    # N'inclure que les paquets qui sont effectivement installés
    if ! apt_is_installed "$_p"; then
      continue
    fi

    # Tenter d'inférer la date d'installation via le fichier dpkg info.
    local pkg_info="/var/lib/dpkg/info/${_p}.list"
    if [[ -f "$pkg_info" ]] && [[ "$state_created_ts" -gt 0 ]]; then
      local pkg_mtime
      pkg_mtime=$(file_mtime "$pkg_info" 2>/dev/null || echo 0)
      # N'inclure que si le paquet a été installé/modifié après la création de l'état
      if [[ "$pkg_mtime" -ge "$state_created_ts" ]]; then
        filtered_pkgs+=("$_p")
      else
        # Ignorer: paquet existait probablement avant le kit
        continue
      fi
    else
      # Si on ne peut pas vérifier la date (pkg_info absent) mais que l'état
      # contient un timestamp, considérer le paquet comme pré-existant et
      # l'exclure (sécurité). Si l'état n'a pas de timestamp (0), inclure.
      if [[ "$state_created_ts" -gt 0 ]]; then
        continue
      else
        filtered_pkgs+=("$_p")
      fi
    fi
  done

  # Si aucun paquet connu n'est à supprimer, on saute la frame de confirmation.
  local remove_pkgs=0
  if [[ ${#filtered_pkgs[@]} -gt 0 ]]; then
    # Construire un message lisible et l'afficher dans une boîte distincte (msgbox gère le multi-lignes).
    local pkg_text
    pkg_text=$'Paquets installés par ce kit (sélectionnés pour suppression) :\n\n'
    for _p in "${filtered_pkgs[@]}"; do
      pkg_text+=$' - '"${_p}"$'\n'
    done

    # Afficher la liste proprement
    whi_info "Désinstallation - paquets" "$pkg_text"

    # Demander confirmation simple (yes/no). Utiliser la variante _back qui imprime "yes" ou "no".
    local ans
    ans="$(whi_yesno_back "Désinstallation" "Supprimer aussi les paquets installés pour le projet ?" "no")" || true
    if [[ "${ans:-}" == "yes" ]]; then
      remove_pkgs=1
    else
      remove_pkgs=0
    fi
  else
    # Pas de paquet connu -> on ignore la frame
    remove_pkgs=0
  fi

  # Stop stack
  if [[ -d "$STACK_DIR" ]]; then
    (cd "$STACK_DIR" && docker compose -f "$COMPOSE_PATH" down --remove-orphans) || true
  fi

  # systemd
  systemctl disable --now ha-backup.timer 2>/dev/null || true
  rm -f /etc/systemd/system/ha-backup.timer /etc/systemd/system/ha-backup.service
  systemctl daemon-reload 2>/dev/null || true

  # bin
  rm -f /usr/local/sbin/ha-backup.sh 2>/dev/null || true

  # creds
  rm -f "$SAMBA_CREDS" 2>/dev/null || true

  # Bootstrap synced to STACK_DIR (if present)
  rm -f "${STACK_DIR}/bootstrap.sh" 2>/dev/null || true

  if [[ $remove_data -eq 1 ]]; then
    rm -rf "$STACK_DIR" || true
  fi

  if [[ $remove_pkgs -eq 1 ]]; then
    uninstall_remove_packages
  fi

  whi_info "Désinstallation" "Désinstallation terminée."
}
