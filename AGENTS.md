# AGENTS.md — Maintainer & Contributor Reference

> This file contains architecture rationale, project invariants, internal requirements,
> and contributor instructions. It is intended for maintainers and AI agents working on this
> project, not for end users. See [README.md](README.md) for the user-facing guide.

---

## Objectif

Ce projet fournit une installation **pérenne**, **reproductible** et **migrable** de Home Assistant sur une box ARM sous **Armbian** avec **Docker**.

Contraintes & objectifs principaux :
- Installer Home Assistant **en Docker** (pas HA OS / Supervised).
- Installation **facilement réinstallable** sur une autre box ou un autre support, sans oublier d'étapes.
- **Aucune interruption** voulue pour les sauvegardes (donc DB externe, pas SQLite seule).
- Exposition sur Internet via **reverse proxy HTTPS**.
- Sauvegardes **automatisées** vers :
    - **NAS SMB** et/ou
    - **support USB**
- Sauvegardes **chiffrées**, versionnées, et avec rétention.
- Assisté par un **wizard whiptail** (questions interactives).
- Optionnel : tentative d'automatisation des redirections via **UPnP** (miniupnpc), avec test de compatibilité avant.

---

## Architecture (stack Docker)

Services principaux :
- **homeassistant** : `ghcr.io/home-assistant/home-assistant:stable`
    - en `network_mode: host` (meilleure compatibilité LAN : mDNS, intégrations, etc.)
- **postgres** : `postgres:16`
    - DB robuste, backups cohérents sans arrêter HA
- **caddy** : `caddy:2`
    - reverse proxy HTTPS, certificats Let's Encrypt automatiques
    - publie `80` et `443`

Sauvegardes (sur l'hôte) :
- Dump PostgreSQL via `pg_dump` (dans `/srv/ha-stack/backup/`)
- Restic : sauvegarde chiffrée de :
    - `/srv/ha-stack/config` (données Home Assistant)
    - `/srv/ha-stack/backup` (dumps SQL)
- Rétention Restic :
    - `--keep-daily 7`
    - `--keep-weekly 10`
    - `--prune`

Restauration (recommandée) :
- Restaurer `config/` + `backup/` depuis restic
- Redémarrer PostgreSQL vide
- Réimporter le dump SQL le plus récent (portable, robuste)

---

## Invariants (besoin à respecter)

- Tout doit être installable par **un wizard whiptail**
- Installation persistante sous `/srv/ha-stack`
- Backups sans arrêt (DB externe obligatoire)
- Sauvegardes restic chiffrées + rétention :
    - daily 7 / weekly 10
- Restauration "portable" via dump SQL (pas de restore binaire du datadir Postgres)
- Secrets jamais écrits en clair dans le repo, seulement sur la machine (root-only)

---

## Points sensibles

- `homeassistant` est en `network_mode: host`, donc le proxy (Caddy) en bridge parle à `127.0.0.1:8123`.
- `trusted_proxies` doit être en mode **strict** :
    - détecter subnet du bridge docker via `docker network inspect bridge`
- SMB credentials :
    - stocker dans `/etc/samba/creds-ha-nas` chmod 600
    - fstab doit être idempotent (ne pas dupliquer les lignes)
- USB :
    - utiliser UUID dans fstab
    - le wizard doit proposer une sélection de partition via `lsblk`
- UPnP :
    - doit toujours tester avant de proposer de mapper 443
    - si échec, afficher les instructions de redirection manuelle

---

## Tests minimaux à faire après changement

- `shellcheck` sur scripts bash
- Lancement wizard sur une machine de test (VM ou SBC) :
    - mode sans NAS/USB
    - mode NAS seul
    - mode USB seul
    - mode restore
- Tests navigation wizard (back/abort) :
    - Naviguer vers "Caddy" puis Back → retour à l'étape précédente, pas sortie.
    - Depuis "Résumé", Back → étape précédente (USB), pas sortie.
    - Depuis "Backup" (NAS/USB), Back → étape précédente (Restic).
    - Depuis "Restore", Back remonte étape par étape (snapshot → repo → menu).
- Vérifier création de cert Caddy (au moins en staging ACME si possible)
- Vérifier backup timer + exécution manuelle backup

### Testing `bootstrap.sh` locally

```bash
# Dry-run in a throw-away directory (does not run install.sh):
sudo HA_INSTALL_DIR=/tmp/ha-test bash bootstrap.sh --ref main

# Pin to a tag or commit for reproducibility:
sudo bash bootstrap.sh --ref v1.0.0

# Override install directory:
sudo bash bootstrap.sh --dir /opt/ha-stack

# Full test on a VM or container (Debian/Ubuntu):
docker run --rm -it debian:bookworm bash
apt-get update && apt-get install -y sudo curl
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo bash -s -- --ref main

# Local source (no download), e.g. for tests:
sudo bash bootstrap.sh --local
```

Expected behavior:
1. Prerequisites (`curl`, `ca-certificates`, `tar`) installed if missing.
2. `/srv/ha-stack` created with permissions `750`.
3. Repository archive downloaded from GitHub.
4. Repo-managed files synced; `config/`, `postgres/`, `backup/`, `caddy/`, `restic/` preserved if they exist.
5. `scripts/install.sh` executed.
6. Next-steps message printed.

Safety considerations:
- Always pin `--ref` to a tag or commit SHA in production.
- Review `bootstrap.sh` before piping it to bash.
- The script requires root; run in an isolated environment for first-time inspection.

---

## Roadmap (améliorations possibles)

- Détection automatique fstype USB et écriture fstab correspondante
- Support DNS-01 optionnel (providers : Cloudflare/OVH) pour éviter port 80
- Mode "443-only" strict si TLS-ALPN-01 validé de manière fiable
- Séparation plus stricte secrets : support Docker secrets / sops-age (optionnel)
