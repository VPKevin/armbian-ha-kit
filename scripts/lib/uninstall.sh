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

  # Fallback compat: anciennes installs sans fichier d'état.
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    pkgs=(restic cifs-utils whiptail)
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
    filtered+=("$p")
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

  local remove_pkgs=0
  if whi_yesno "Désinstallation" "Supprimer aussi les paquets installés pour le projet (ex: restic, cifs-utils, whiptail) ?\n\nConseillé seulement si cette machine ne s'en sert pas pour autre chose."; then
    remove_pkgs=1
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
