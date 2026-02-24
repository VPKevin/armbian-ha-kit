#!/usr/bin/env bash
set -euo pipefail

setup_systemd_backup() {
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    if command -v whi_info >/dev/null 2>&1; then
      whi_info "Systemd" "Systemd n'est pas disponible dans cet environnement. Le timer de backup ne sera pas installé."
    else
      echo "[ha-backup] Systemd indisponible: timer non installé." >&2
    fi
    return 0
  fi

  local src_backup="${STACK_DIR}/scripts/backup.sh"
  local dst_backup="/srv/ha-stack/scripts/backup.sh"
  if [[ -f "$src_backup" ]]; then
    if [[ "$(readlink -f "$src_backup")" != "$(readlink -f "$dst_backup" 2>/dev/null || echo "")" ]]; then
      install -m 0755 "$src_backup" "$dst_backup"
    else
      chmod 0755 "$dst_backup" || true
    fi
  fi

  if [[ -f "${STACK_DIR}/ha-backup.sh" ]]; then
    install -m 0755 "${STACK_DIR}/ha-backup.sh" /usr/local/sbin/ha-backup.sh
  else
    whi_info "Systemd" "Fichier manquant: ${STACK_DIR}/ha-backup.sh\nImpossible d'installer le service systemd de backup."
    return
  fi

  install -d /etc/systemd/system
  install -m 0644 "${STACK_DIR}/systemd/ha-backup.service" /etc/systemd/system/ha-backup.service
  install -m 0644 "${STACK_DIR}/systemd/ha-backup.timer" /etc/systemd/system/ha-backup.timer

  systemctl daemon-reload
  systemctl enable --now ha-backup.timer
}
