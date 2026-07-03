# CLAUDE.md — armbian-ha-kit

Kit d'installation de Home Assistant sur Armbian/Debian : scripts shell (wizard
whiptail) qui déploient une stack Docker Compose (HA + Postgres + Caddy +
optionnellement Mosquitto/Zigbee2MQTT) avec backups Restic (NAS SMB / USB) et
timer systemd. Tout est en bash, cible = box ARM en root.

## Carte du projet

- `bootstrap.sh` — point d'entrée `curl | bash` : télécharge l'archive GitHub,
  synchronise vers `/srv/ha-stack` (préserve les dossiers de données), lance l'installeur.
- `scripts/install.sh` — wizard principal (menu install/restore/status/remove).
- `scripts/lib/*.sh` — modules sourcés par install.sh :
  `common.sh` (apt, logging, RC_*), `env.sh` (.env + parsing compose),
  `ui.sh` (whiptail, codes UI_OK=0/UI_BACK=10/UI_ABORT=20), `ha.sh`
  (configuration.yaml, trusted_proxies), `zigbee.sh` (ZHA/Z2M/Mosquitto),
  `compose.sh` (profils, start_stack), `caddy.sh`, `restic.sh`,
  `backup_targets.sh` (NAS/USB/fstab), `systemd.sh`, `health.sh`, `status.sh`,
  `uninstall.sh`, `i18n.sh`.
- `scripts/backup.sh` — exécuté par le timer systemd : pg_dump + restic vers
  chaque repo de `restic/repos.conf`.
- `docker-compose.yml` — profils : `caddy`, `zigbee2mqtt` (persistés via
  `COMPOSE_PROFILES` dans le .env). HA est en `network_mode: host`.
- `tests/` — bats + smoke en conteneur Docker (`tests/run-tests.sh`).
- `ai/` — docs pour agents IA : plan d'amélioration, journal, audits.

## Conventions du repo

- Tous les scripts : `set -euo pipefail` ; retours d'erreur via `RC_*`
  (common.sh) et navigation UI via `UI_OK/UI_BACK/UI_ABORT` (ui.sh).
- Idempotence exigée : re-lancer l'installeur ne doit rien casser ni écraser
  les données (`config/ postgres/ backup/ caddy/ restic/` sont préservés).
- Commentaires et UI en français.
- **Mettre à jour `ai/JOURNAL.md` à chaque changement significatif** (format
  imposé en tête de fichier).
- Tester avec `bash tests/run-tests.sh` (bats) ; smoke complet :
  `bash tests/run-smoke.sh` (nécessite Docker).
- Ne jamais committer `.env` (contient un vrai mot de passe en local).

## Pièges connus (lire avant de toucher au code)

- `env_get` (env.sh) : bug historique corrigé le 2026-07-03 (retournait
  `KEY=value`). Les `strip_key_prefix_if_any` restants sont CONSERVÉS exprès :
  ils assainissent les `.env` déployés par d'anciennes versions, potentiellement
  pollués en `KEY=KEY=value`. Ne pas les supprimer sans couvrir ce cas (test
  bats dédié dans tests/install_env.bats).
- Stub whiptail des tests : le vrai whiptail écrit la saisie sur STDERR (d'où
  le swap `3>&1 1>&2 2>&3` dans ui.sh) — tout stub de test doit faire pareil.
- Le `.env` est à la fois sourcé par bash ET parsé par docker compose : les
  deux parsers divergent sur les quotes/caractères spéciaux.
- `wait_for_health`/`status.sh` dupliquent le mapping service→conteneur ; toute
  modif doit être faite aux 3 endroits (ou factorisée, cf. audit).
- whiptail exige un TTY : `install.sh` fait `exec </dev/tty` ; le mode headless
  n'est pas vraiment supporté aujourd'hui.

## Audit & backlog

**→ `ai/AUDIT_2026-07-02.md`** : audit complet (sécurité de la stack installée,
bugs confirmés, fiabilité backup, perfectible), avec références fichier:ligne,
corrections proposées et **ordre d'exécution recommandé en §6**. C'est le
backlog de référence : le consulter avant d'entreprendre des corrections, et y
marquer les points traités.

Résumé des priorités (maj 2026-07-03) :
1. ✅ FAIT — Bug `env_get` (audit §2.1) : awk corrigé, strips conservés en
   nettoyage défensif, 5 tests bats ajoutés, suite 19/19 verte.
2. ✅ FAIT — `privileged` retiré (devices: suffit, images en root) ; auth MQTT
   implémentée avec le cycle de vie complet (fresh=on par défaut, migration
   explicite défaut=non, rotation via menu status). Clés .env : MQTT_AUTH,
   MQTT_USER, MQTT_PASSWORD. Une conf mosquitto sans le marqueur
   "# Managed by armbian-ha-kit" n'est JAMAIS touchée.
3. Fiabiliser `backup.sh` (échecs silencieux, PGPASSWORD dans `ps`, chmod du
   mot de passe Restic manquant — code mort ligne restic.sh:123).
4. `file_mtime` jamais défini (uninstall ne supprime jamais les paquets) ;
   `ENABLE_UPNP` : à IMPLÉMENTER (décision mainteneur — miniupnpc + timer de
   renouvellement, voir audit §2.3), ne pas retirer la feature.
5. Ajouter une CI GitHub Actions : shellcheck + shfmt + bats.
