# HA Stack (Armbian) — Home Assistant + PostgreSQL + Caddy + Backups (NAS/USB) + UPnP wizard

## Objectif

Ce projet fournit une installation **pérenne**, **reproductible** et **migrable** de Home Assistant sur une box ARM sous **Armbian** avec **Docker**.

Contraintes & objectifs principaux :
- Installer Home Assistant **en Docker** (pas HA OS / Supervised).
- Installation **facilement réinstallable** sur une autre box ou un autre support, sans oublier d’étapes.
- **Aucune interruption** voulue pour les sauvegardes (donc DB externe, pas SQLite seule).
- Exposition sur Internet via **reverse proxy HTTPS**.
- Sauvegardes **automatisées** vers :
    - **NAS SMB** et/ou
    - **support USB**
- Sauvegardes **chiffrées**, versionnées, et avec rétention.
- Assisté par un **wizard whiptail** (questions interactives).
- Optionnel : tentative d’automatisation des redirections via **UPnP** (miniupnpc), avec test de compatibilité avant.

Public visé :
- Utilisateur final (non expert) qui veut un “assistant d’installation” simple.
- Mainteneur futur / contributeur (besoin d’une doc claire et des invariants du projet).

---

## Architecture (stack Docker)

Services principaux :
- **homeassistant** : `ghcr.io/home-assistant/home-assistant:stable`
    - en `network_mode: host` (meilleure compatibilité LAN : mDNS, intégrations, etc.)
- **postgres** : `postgres:16`
    - DB robuste, backups cohérents sans arrêter HA
- **caddy** : `caddy:2`
    - reverse proxy HTTPS, certificats Let’s Encrypt automatiques
    - publie `80` et `443`

Sauvegardes (sur l’hôte) :
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

## Pré-requis

Sur la box Armbian :
- Docker et Docker Compose déjà installés (c’est le cas dans notre contexte).
- `whiptail` installé (déjà présent).
- Accès root (sudo).

Sur le réseau :
- Un nom de domaine public pointant vers votre IP publique (enregistrement DNS).
- Accès entrant au port **443** (et parfois **80** selon challenge ACME).
    - Option UPnP : le script peut tenter d’ouvrir 443 (et 80 temporairement) si le routeur le permet.
    - Sinon, redirection manuelle sur le routeur.

---

## Dossier d’installation

Tout le projet vit dans :
- `/srv/ha-stack`

Structure attendue :
- `docker-compose.yml`
- `Caddyfile`
- `.env` (créé par le wizard, permissions strictes)
- `config/` (données HA)
- `postgres/` (données DB)
- `backup/` (dumps)
- `restic/` (password + repos.conf)
- `scripts/` (install + backup)
- `systemd/` (service/timer backup)
- `caddy/` (données Caddy : certificats/config runtime)

---

## Sécurité / Secrets

Secrets et données sensibles :
- `/srv/ha-stack/.env` : mots de passe DB, domaine, email ACME
    - permissions : `chmod 600`, propriétaire `root`
- `/etc/samba/creds-ha-nas` : credentials SMB NAS
    - permissions : `chmod 600`, propriétaire `root`
- `/srv/ha-stack/restic/password` : mot de passe restic
    - permissions : `chmod 600`

⚠️ Ne jamais committer dans Git :
- `.env`
- `config/`, `postgres/`, `backup/`, `caddy/`
- credentials SMB
- tout dépôt restic

Un `.gitignore` est fourni.

---

## Installation (wizard)

### 1) Cloner / copier le repo
Recommandé :
- cloner le repo dans `/srv/ha-stack`
- ou copier les fichiers manuellement dans ce chemin

### 2) Exécuter le wizard
```bash
sudo bash /srv/ha-stack/scripts/install.sh
```

Le wizard :
- génère `.env`
- propose d’activer backups NAS/USB
- configure montage SMB (NAS) et/ou montage USB (UUID + fstab)
- initialise restic sur les cibles
- propose une restauration depuis restic (optionnel)
- propose UPnP (optionnel) : test + mapping 443 et éventuellement 80 temporaire
- configure `configuration.yaml` minimal (Postgres recorder + trusted_proxies strict)
- démarre la stack docker
- installe le timer systemd de backup si des repos restic sont configurés

---

## Accès

- Local :
    - `http://IP_DE_LA_BOX:8123`
- Internet (via Caddy) :
    - `https://<votre_domaine>`

---

## Sauvegardes

### Lancement manuel
```bash
sudo /srv/ha-stack/scripts/backup.sh
```

### Timer systemd
- Vérifier :
```bash
systemctl status ha-backup.timer
systemctl list-timers | grep ha-backup
```

- Logs :
```bash
journalctl -u ha-backup.service -n 200 --no-pager
```

---

## Restauration / Migration (résumé)

Objectif : déplacer l’installation vers une autre box/support avec un minimum de risques.

Étapes recommandées :
1. Installer Docker + Compose sur la nouvelle box
2. Monter NAS/USB (ou au moins rendre le dépôt restic accessible)
3. Copier le repo dans `/srv/ha-stack` (scripts + compose + Caddyfile)
4. Lancer :
    - `sudo bash /srv/ha-stack/scripts/install.sh`
    - répondre **Oui** à “repartir d’une sauvegarde”
5. Le wizard :
    - restaure `config/` + `backup/`
    - redémarre postgres
    - réimporte le dump SQL
    - redémarre HA + Caddy

Pourquoi on restaure Postgres via dump :
- évite les soucis de compatibilité de répertoire `postgres/` entre machines/versions
- meilleure portabilité et diagnostic

---

## UPnP : comportement attendu

- Le wizard peut installer `miniupnpc`.
- Il effectue un test :
    - ajoute une règle TCP temporaire
    - liste les règles
    - supprime la règle
- Si le test échoue :
    - le wizard indique à l’utilisateur quoi configurer manuellement sur le routeur
- Si OK :
    - propose de créer une redirection TCP 443 -> 443
    - propose d’ouvrir TCP 80 temporairement (utile si ACME ne passe pas sans 80)
- Le script tente d’extraire une information de "lease duration" si le routeur la fournit, mais ce n’est pas garanti selon les modèles.

---

## Dépannage

### Certificat HTTPS ne se génère pas
Causes fréquentes :
- DNS du domaine ne pointe pas vers l’IP publique
- port 443 fermé/non redirigé
- port 80 nécessaire selon challenge / routeur / CGNAT
- CGNAT chez certains FAI : pas d’accès entrant possible

Actions :
- vérifier `A/AAAA` DNS
- tester depuis l’extérieur :
    - `curl -vk https://<domaine>`
- consulter les logs Caddy :
    - `docker logs ha-caddy --tail 200`

### Home Assistant ne voit pas le proxy / erreur 400
- vérifier dans `/srv/ha-stack/config/configuration.yaml` :
    - `http: use_x_forwarded_for: true`
    - `trusted_proxies:` (subnet docker détecté)
- redémarrer HA :
    - `docker restart homeassistant`

---

## Pour contributeurs / prochains agents (instructions de maintenance)

### Besoin à respecter (invariants)
- Tout doit être installable par **un wizard whiptail**
- Installation persistante sous `/srv/ha-stack`
- Backups sans arrêt (DB externe obligatoire)
- Sauvegardes restic chiffrées + rétention :
    - daily 7 / weekly 10
- Restauration “portable” via dump SQL (pas de restore binaire du datadir Postgres)
- Secrets jamais écrits en clair dans le repo, seulement sur la machine (root-only)

### Points sensibles
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

### Tests minimaux à faire après changement
- `shellcheck` sur scripts bash
- Lancement wizard sur une machine de test (VM ou SBC) :
    - mode sans NAS/USB
    - mode NAS seul
    - mode USB seul
    - mode restore
- Vérifier création de cert Caddy (au moins en staging ACME si possible)
- Vérifier backup timer + exécution manuelle backup

### Roadmap (améliorations possibles)
- Détection automatique fstype USB et écriture fstab correspondante
- Support DNS-01 optionnel (providers : Cloudflare/OVH) pour éviter port 80
- Mode “443-only” strict si TLS-ALPN-01 validé de manière fiable
- Séparation plus stricte secrets : support Docker secrets / sops-age (optionnel)

---

## Licence
MIT