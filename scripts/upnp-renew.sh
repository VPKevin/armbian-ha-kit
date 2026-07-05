#!/usr/bin/env bash
set -euo pipefail

# Renouvellement périodique des mappings UPnP (exécuté par ha-upnp.timer).
# Beaucoup de box perdent les mappings au reboot ou les expirent : une
# application unique à l'installation ne suffit pas (cf. audit §2.3).

STACK_DIR="${STACK_DIR:-/srv/ha-stack}"
ENV_FILE="${STACK_DIR}/.env"
LOG_TAG="[ha-upnp]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/upnp.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "$LOG_TAG Missing $ENV_FILE — nothing to do." >&2
  exit 0
fi

load_env_file "$ENV_FILE"

if [[ "${ENABLE_UPNP:-0}" != "1" && "${ENABLE_UPNP:-}" != "true" ]]; then
  echo "$LOG_TAG UPnP disabled (ENABLE_UPNP=${ENABLE_UPNP:-0}) — nothing to do."
  exit 0
fi

if [[ "${ENABLE_CADDY:-0}" != "1" && "${ENABLE_CADDY:-}" != "true" ]]; then
  echo "$LOG_TAG Caddy disabled — no local listener on 80/443, skipping."
  exit 0
fi

if upnp_apply; then
  echo "$LOG_TAG Mappings 80/443 renouvelés vers $(upnp_lan_ip)."
else
  echo "$LOG_TAG ERROR: renouvellement UPnP échoué (IGD injoignable ? UPnP désactivé sur la box ?)" >&2
  exit 1
fi
