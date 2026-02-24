#!/usr/bin/env bash
set -euo pipefail

# Helpers communs (apt, binaire, TTY).

req_bin() { command -v "$1" >/dev/null 2>&1; }

is_interactive_tty() {
  [[ -t 0 && -t 1 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive

  # Évite de faire `apt-get update` à chaque interaction. On le fait une fois par run
  # (ou si l'index est ancien/absent) pour limiter le bruit et accélérer.
  local stamp="/var/lib/apt/periodic/update-success-stamp"
  if [[ ! -f "$stamp" ]] || find "$stamp" -mmin +60 >/dev/null 2>&1; then
    apt-get update -y
  fi

  apt-get install -y "$@"
}
