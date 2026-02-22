#!/usr/bin/env bash
set -euo pipefail

# Désinstallation de la stack.

uninstall_wizard() {
  if ! whi_yesno "Désinstallation" "Tout désinstaller ?\n\nCette action peut supprimer les conteneurs et, si tu le demandes, les données dans ${STACK_DIR}."; then
    return 0
  fi

  local remove_data=0
  if whi_yesno "Désinstallation" "Supprimer aussi les données (config, postgres, backup, caddy, restic) dans ${STACK_DIR} ?\n\nATTENTION: irréversible."; then
    remove_data=1
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

  if [[ $remove_data -eq 1 ]]; then
    rm -rf "$STACK_DIR" || true
  fi

  whi_info "Désinstallation" "Désinstallation terminée."
}

