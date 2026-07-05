#!/usr/bin/env bash
set -euo pipefail

# UPnP : ouverture automatique des ports 80/443 vers cette machine (via la box).
#
# Contracts (P0):
# - Fonctions: upnp_lan_ip, upnp_map_port, upnp_apply, upnp_remove_mappings,
#   setup_upnp, remove_upnp_units
# - Entrées: ENABLE_UPNP, ENABLE_CADDY, ENV_FILE, STACK_DIR
# - Sorties: mappings UPnP sur l'IGD (box), installation du timer systemd de
#   renouvellement (beaucoup de box perdent/expirent les mappings — cf. audit
#   §2.3), /usr/local/sbin/ha-upnp.sh
# - Codes retour: 0 succès / rien à faire, 1 si l'IGD est injoignable ou si le
#   mapping échoue.

UPNP_DESC="armbian-ha-kit"
UPNP_PORTS=(80 443)

# IP LAN de la machine (interface qui route vers Internet).
upnp_lan_ip() {
  ip route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

# Mappe un port (externe:port -> lan_ip:port, TCP), de façon idempotente :
# en cas de ConflictInMappingEntry (mapping périmé vers une autre IP), on
# supprime puis on retente une fois.
upnp_map_port() {
  local lan_ip="$1" port="$2"
  local out

  out="$(upnpc -e "$UPNP_DESC" -a "$lan_ip" "$port" "$port" TCP 2>&1 || true)"
  if grep -q "is redirected to" <<<"$out"; then
    return 0
  fi

  if grep -q "ConflictInMappingEntry" <<<"$out"; then
    upnpc -d "$port" TCP >/dev/null 2>&1 || true
    out="$(upnpc -e "$UPNP_DESC" -a "$lan_ip" "$port" "$port" TCP 2>&1 || true)"
    if grep -q "is redirected to" <<<"$out"; then
      return 0
    fi
  fi

  log_warn "UPnP: échec du mapping du port ${port}: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
  return 1
}

# Applique les mappings 80/443. Return 1 si IP LAN introuvable ou si au moins
# un mapping a échoué (IGD absent / UPnP désactivé sur la box, etc.).
upnp_apply() {
  if ! req_bin upnpc; then
    log_warn "UPnP: upnpc absent (miniupnpc non installé)."
    return 1
  fi

  local lan_ip
  lan_ip="$(upnp_lan_ip)"
  if [[ -z "${lan_ip:-}" ]]; then
    log_warn "UPnP: impossible de déterminer l'IP LAN."
    return 1
  fi

  local port rc=0
  for port in "${UPNP_PORTS[@]}"; do
    upnp_map_port "$lan_ip" "$port" || rc=1
  done
  return "$rc"
}

# Supprime les mappings du kit (best-effort).
upnp_remove_mappings() {
  req_bin upnpc || return 0
  local port
  for port in "${UPNP_PORTS[@]}"; do
    upnpc -d "$port" TCP >/dev/null 2>&1 || true
  done
}

# Retire le timer/service de renouvellement (best-effort).
remove_upnp_units() {
  systemctl disable --now ha-upnp.timer 2>/dev/null || true
  rm -f /etc/systemd/system/ha-upnp.timer /etc/systemd/system/ha-upnp.service
  rm -f /usr/local/sbin/ha-upnp.sh
  systemctl daemon-reload 2>/dev/null || true
}

# Installe/désinstalle la fonctionnalité selon ENABLE_UPNP/ENABLE_CADDY, puis
# applique immédiatement. Appelé après le wizard (non bloquant pour l'install).
setup_upnp() {
  local enable_upnp="${ENABLE_UPNP:-}"
  local enable_caddy="${ENABLE_CADDY:-}"
  if [[ -z "${enable_upnp:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_upnp="$(env_get "ENABLE_UPNP" "$ENV_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "${enable_caddy:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    enable_caddy="$(env_get "ENABLE_CADDY" "$ENV_FILE" 2>/dev/null || true)"
  fi

  # Désactivé : nettoyage si une installation précédente l'avait activé.
  if [[ "${enable_upnp:-0}" != "1" && "${enable_upnp:-}" != "true" ]]; then
    if [[ -f /etc/systemd/system/ha-upnp.timer ]]; then
      upnp_remove_mappings
      remove_upnp_units
      log_info "UPnP: désactivé (mappings supprimés, timer retiré)."
    fi
    return 0
  fi

  # UPnP sans Caddy = ports 80/443 ouverts vers rien. On n'ouvre pas.
  if [[ "${enable_caddy:-0}" != "1" && "${enable_caddy:-}" != "true" ]]; then
    log_warn "UPnP: activé mais Caddy est désactivé — aucun service n'écoute sur 80/443, ouverture ignorée."
    return 0
  fi

  apt_install miniupnpc

  # Timer de renouvellement (une application unique ne survit pas aux reboots
  # de box ni aux expirations de bail).
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    if [[ -f "${STACK_DIR}/ha-upnp.sh" ]]; then
      install -m 0755 "${STACK_DIR}/ha-upnp.sh" /usr/local/sbin/ha-upnp.sh
    fi
    if [[ -f "${STACK_DIR}/scripts/upnp-renew.sh" ]]; then
      chmod 0755 "${STACK_DIR}/scripts/upnp-renew.sh" || true
    fi
    if [[ -f "${STACK_DIR}/systemd/ha-upnp.service" && -f "${STACK_DIR}/systemd/ha-upnp.timer" ]]; then
      install -m 0644 "${STACK_DIR}/systemd/ha-upnp.service" /etc/systemd/system/ha-upnp.service
      install -m 0644 "${STACK_DIR}/systemd/ha-upnp.timer" /etc/systemd/system/ha-upnp.timer
      systemctl daemon-reload
      systemctl enable --now ha-upnp.timer 2>/dev/null || true
    fi
  else
    log_warn "UPnP: systemd indisponible, pas de renouvellement automatique (application unique)."
  fi

  # Application immédiate + feedback utilisateur.
  if upnp_apply; then
    if command -v whi_info >/dev/null 2>&1 && is_interactive_tty; then
      whi_info "UPnP" "Ports 80 et 443 ouverts sur ta box vers $(upnp_lan_ip).\n\nHome Assistant sera accessible depuis Internet via Caddy (HTTPS).\nUn timer systemd (ha-upnp.timer) renouvelle l'ouverture toutes les 45 min."
    fi
    return 0
  fi

  if command -v whi_info >/dev/null 2>&1 && is_interactive_tty; then
    whi_info "UPnP" "Impossible d'ouvrir les ports via UPnP.\n\nCauses fréquentes :\n  - UPnP/IGD désactivé sur la box (à activer dans son interface)\n  - box non compatible\n\nLe timer réessaiera automatiquement (ha-upnp.timer). Tu peux aussi ouvrir les ports 80/443 manuellement sur la box."
  fi
  return 1
}
