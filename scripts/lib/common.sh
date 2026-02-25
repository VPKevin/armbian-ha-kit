#!/usr/bin/env bash
set -euo pipefail

# Helpers communs (apt, binaire, TTY).

req_bin() { command -v "$1" >/dev/null 2>&1; }

is_interactive_tty() {
  [[ -t 0 && -t 1 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

# Répertoire d'état persistant (suivi des paquets installés par le kit).
# Peut être surchargé via AHK_STATE_DIR.
apt_state_dir() {
  echo "${AHK_STATE_DIR:-/var/lib/armbian-ha-kit}"
}

apt_state_file() {
  echo "$(apt_state_dir)/apt-installed.list"
}

apt_state_init() {
  local dir
  dir="$(apt_state_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  local f
  f="$(apt_state_file)"
  # Créer le fichier d'état seulement s'il n'existe pas (ne pas mettre à jour
  # la date de modification à chaque run). Lors de la création, écrire un
  # en-tête indiquant la date de création (epoch seconds) pour permettre
  # des heuristiques ultérieures.
  if [[ ! -f "$f" ]]; then
    printf '# created:%s\n' "$(date +%s)" >"$f" 2>/dev/null || true
    chmod 600 "$f" 2>/dev/null || true
  fi
}

apt_state_add() {
  local pkg="$1"
  apt_state_init
  local f
  f="$(apt_state_file)"
  # pas de doublons
  grep -Fxq "$pkg" "$f" 2>/dev/null || printf '%s\n' "$pkg" >>"$f"
}

apt_state_list() {
  local f
  f="$(apt_state_file)"
  [[ -f "$f" ]] || return 0
  # ignore lignes vides/commentaires
  grep -Ev '^[[:space:]]*($|#)' "$f" 2>/dev/null || true
}

apt_is_installed() {
  local pkg="$1"
  # Premièrement, interroger dpkg-query (précis).
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    return 0
  fi

  # Si dpkg-query ne trouve pas le paquet, essayer une heuristique: pour
  # certains paquets (ex: whiptail) le binaire a le même nom que le paquet.
  # Si un binaire du même nom est présent, considérer le paquet comme installé
  # (évite d'enregistrer des paquets préinstallés par l'image OS).
  if command -v "$pkg" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

apt_update_once() {
  export DEBIAN_FRONTEND=noninteractive

  # Évite de faire `apt-get update` plusieurs fois (même run) et si l'index est récent.
  if [[ "${__AHK_APT_UPDATED:-0}" -eq 1 ]]; then
    return 0
  fi

  local stamp="/var/lib/apt/periodic/update-success-stamp"
  if [[ ! -f "$stamp" ]] || find "$stamp" -mmin +60 >/dev/null 2>&1; then
    if command -v ui_run >/dev/null 2>&1; then
      ui_run "apt: update" -- apt-get update -y
    else
      apt-get update -y
    fi
  fi

  __AHK_APT_UPDATED=1
}

# Installe des paquets uniquement s'ils ne sont pas déjà présents.
# Et enregistre dans l'état uniquement ceux qui n'étaient pas installés avant.
apt_install() {
  export DEBIAN_FRONTEND=noninteractive

  local to_install=()
  local requested=()
  local pkg

  for pkg in "$@"; do
    [[ -n "${pkg:-}" ]] || continue
    requested+=("$pkg")
    if ! apt_is_installed "$pkg"; then
      to_install+=("$pkg")
    fi
  done

  # Rien à faire.
  if [[ ${#to_install[@]} -eq 0 ]]; then
    return 0
  fi

  apt_update_once
  if command -v ui_run >/dev/null 2>&1; then
    ui_run "Installer paquets: ${to_install[*]}" -- apt-get install -y "${to_install[@]}"
  else
    apt-get install -y "${to_install[@]}"
  fi

  # Trace uniquement les paquets explicitement demandés et réellement nouvellement installés.
  for pkg in "${requested[@]}"; do
    if apt_is_installed "$pkg"; then
      # Si le paquet était absent au début, il est forcément dans to_install.
      # On ne met dans l'état que ceux qu'on a demandé et installé via ce script.
      if printf '%s\n' "${to_install[@]}" | grep -Fxq "$pkg"; then
        apt_state_add "$pkg"
      fi
    fi
  done
}
