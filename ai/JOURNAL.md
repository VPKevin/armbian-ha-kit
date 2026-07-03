# Journal de bord - armbian-ha-kit (IA)

Ce fichier contient la trace chronologique des actions réalisées par les agents IA et les mainteneurs humaines liées à l'amélioration du projet. Il doit être mis à jour à chaque action significative (patch, test, décision d'architecture, rollback, etc.).

Format d'entrée (obligatoire):
- Date: YYYY-MM-DD HH:MM (UTC ou timezone locale)
- Auteur: nom de l'auteur / agent
- Type: code | doc | test | infra | build | autre
- Impact: P0/P1/P2 (mapping au plan)
- Résumé court: 1 ligne
- Détails: description complète des changements, fichiers impactés
- Tests: commandes exécutées et résultat (succès/échec + extrait pertinent)
- Commentaires / next steps

---

## Entrées

- Date: 2026-03-04 14:22 UTC
- Auteur: IA (Copilot)
- Type: code,test,infra
- Impact: P0
- Résumé court: Unification gestion d'erreur + préchecks + tests smoke headless
- Détails:
  - Ajout de constantes RC_* et helpers (`rc_fail`, `require_root_or_fail`) dans `scripts/lib/common.sh`.
  - Normalisation des retours et contrats minimaux dans `scripts/install.sh`, `scripts/lib/env.sh`, `scripts/lib/uninstall.sh`.
  - Tests: `tests/run-tests.sh` adapté pour buildx et smoke non interactif; `tests/run-smoke.sh` rendu tolérant.
  - Fichiers modifiés: `scripts/lib/common.sh`, `scripts/install.sh`, `scripts/lib/env.sh`, `scripts/lib/uninstall.sh`, `tests/run-tests.sh`, `tests/entrypoint-bootstrap.sh`, `tests/run-smoke.sh`, `README.md`, `AI_IMPROVEMENT_PLAN.md` (racine) et nouveaux fichiers `ai/AI_IMPROVEMENT_PLAN.md`, `ai/JOURNAL.md`.
- Tests:
  - Commande: `bash tests/run-tests.sh`
  - Résultat: build OK, smoke checks passed
- Commentaires / next steps: ajouter job CI + tests Bats pour `env_set_kv`.

---

- Date: 2026-03-07 10:30 UTC
- Auteur: IA (Copilot)
- Type: code,doc,test
- Impact: P0
- Résumé court: Complétion P0 — centralisation, contrats modules, doc P0 et tests Bats
- Détails:
  - Centralisation des constantes et chemins par défaut dans `scripts/lib/common.sh` :
    - `STACK_DIR`, `ENV_FILE`, `RESTIC_DIR`, `RESTIC_REPOS`, `RESTIC_PASS`, `DEFAULT_COMPOSE_PATH`, `SAMBA_CREDS`, `AHK_STATE_DIR`.
    - Ces valeurs sont définies idempotemment (n'écrasent pas les variables exportées par l'appelant).
  - Ajout d'un bloc minimal `Contracts (P0)` en entête de chaque module `scripts/lib/*.sh` pour expliciter :
    - fonctions exposées attendues
    - variables globales d'entrée
    - effets de bord et codes retour (convention minimale).
  - Suppression de la duplication de `SAMBA_CREDS` dans `scripts/install.sh` (utilise maintenant la valeur centralisée).
  - Harmonisation de `scripts/backup.sh` pour :
    - sourcer `scripts/lib/common.sh` si disponible,
    - appeler `install_error_trap "backup.sh"` pour trap unifié,
    - exiger `require_root_or_fail` en mode best-effort.
  - Ajout de la documentation courte `docs/P0_CONTRACTS.md` (résumé des conventions P0, chemins sensibles et checklist PR P0).
  - Ajout d'un test Bats `tests/backup.bats` (mode non-interactif, stubs pour `docker` et `restic`) — vérifie que `scripts/backup.sh` crée un dump local et se termine proprement quand `repos.conf` est vide.
  - Diverses petites adaptations (headers, commentaires) pour s'aligner sur P0.
- Tests exécutés / validations automatisées:
  - `get_errors` (vérification syntaxe/lint fournie par l'environnement) : PAS D'ERREUR détectée sur les fichiers modifiés.
  - Tests unitaires Bats non exécutés automatiquement ici (nécessitent `bats-core` ou environnement CI); `tests/backup.bats` ajouté pour CI/local.
- Commentaires / next steps:
  - Lancer localement :

    ```bash
    # installer bats-core (ex: macOS Homebrew)
    brew install bats-core

    # lancer le test ajouté
    cd /Users/kevin/www/armbian-ha-kit
    bats tests/backup.bats
    ```

  - Ajouter job CI (GitHub Actions) pour exécuter `shellcheck`, `bats` et `tests/run-tests.sh` (buildx/smoke).
  - Étendre la documentation P0 (cas d'erreur et exécution headless) dans `README.md` si souhaité.

---

- Date: 2026-07-02
- Auteur: Claude (Fable 5)
- Type: doc
- Impact: P0
- Résumé court: Audit complet du projet (sécurité, bugs, fiabilité) consigné dans ai/AUDIT_2026-07-02.md + création de CLAUDE.md.
- Détails:
  - Lecture intégrale de bootstrap.sh, scripts/install.sh, scripts/backup.sh, scripts/lib/*.sh, docker-compose.yml, Caddyfile, systemd/*, ha-backup.sh, .env*.
  - Nouveau fichier `ai/AUDIT_2026-07-02.md` : findings priorisés (P0/P1/P2) avec références fichier:ligne et corrections proposées. Points saillants :
    - Bug confirmé par exécution : `env_get` (env.sh:27) retourne `KEY=value` au lieu de `value` (sub() awk avec "k" littéral) — cause des `strip_key_prefix_if_any` partout, casse les défauts de ré-installation.
    - Bug confirmé par grep : `file_mtime` appelée (uninstall.sh:103,121) mais jamais définie — la suppression de paquets à la désinstallation ne fait jamais rien.
    - Sécurité stack : `privileged: true` sur HA+Z2M, Mosquitto anonyme, chmod 600 manquant sur le mot de passe Restic (code mort restic.sh:123), PGPASSWORD visible dans ps + injection possible dans backup.sh, .env sourcé en root sans quoting.
    - Fiabilité : échecs de backup silencieux (|| true) vs cascade (set -e) selon la branche, restic forget sans --tag, healthcheck Caddy suit le 301 vers le domaine, ENABLE_UPNP jamais implémenté, uninstall ne nettoie pas fstab.
  - Nouveau fichier `CLAUDE.md` (racine) : carte du projet, conventions, pièges connus, pointeur vers l'audit et top-5 des priorités.
- Tests: aucun code modifié — documentation uniquement. Vérifications effectuées pendant l'audit : reproduction du bug awk env_get en isolation, grep exhaustifs (file_mtime, UPNP), vérification que .env n'est pas dans l'historique git.
- Commentaires / next steps: suivre l'ordre d'exécution recommandé en §6 de l'audit (env_get d'abord, puis privileged/MQTT, puis backup.sh). Marquer les points traités dans l'audit au fil de l'eau.

---

- Date: 2026-07-03
- Auteur: Claude (Fable 5)
- Type: code + test
- Impact: P0
- Résumé court: Étape 1 de l'audit — correction du bug env_get (retournait KEY=value), tests bats env_get ajoutés, suite 19/19 verte.
- Détails:
  - `scripts/lib/env.sh` : awk de `env_get` réécrit — l'ancien `sub(/^[[:space:]]*"k"=/, "")` utilisait `"k"` littéral dans la regex (jamais matché) → la valeur retournée gardait le préfixe `KEY=`. Nouveau : trim du leading whitespace puis `substr($0, length(k)+2)` (préserve les `=` dans la valeur). Les `strip_key_prefix_if_any` côté appelants sont CONSERVÉS comme nettoyage défensif des `.env` déployés par d'anciennes versions (pollution héritée `KEY=KEY=value`).
  - `scripts/backup.sh` : `STACK_DIR` désormais surchargeable (`${STACK_DIR:-/srv/ha-stack}`), aligné sur la convention common.sh — le test tests/backup.bats existant ne pouvait jamais passer (il exporte STACK_DIR, le script le hardcodait). Comportement systemd inchangé (variable non définie → même défaut).
  - `scripts/lib/common.sh` : `is_interactive_tty` fiabilisé — tente réellement l'ouverture de /dev/tty (`: </dev/tty >/dev/tty`) au lieu de `-r`/`-w` qui ne testent que les permissions et faisaient croire un conteneur/cron « interactif » (whi_info partait dans whiptail au lieu du fallback console). Traite partiellement l'audit §3.8 ; débloquait le test restic_choose_repo.
  - `tests/install_env.bats` :
    - 5 nouveaux tests env_get : valeur seule sans préfixe, valeur contenant des `=`, espaces de tête + clé absente (rc=1), clé préfixe d'une autre clé, valeur héritée polluée `KEY=KEY=value` (env_get brut + strip_key_prefix_if_any).
    - Stub whiptail corrigé : écrit désormais la valeur sur STDERR comme le vrai whiptail (raison du swap 3>&1 1>&2 2>&3 de ui.sh) et extrait la valeur par défaut à sa vraie position (4e arg après --inputbox ; l'ancien `${@: -1}` prenait le label du bouton --cancel-button ajouté depuis). Le test env_ensure_from_compose ne pouvait pas passer sans ça (valeur capturée toujours vide).
    - Attentes des 2 tests trusted_proxies mises à jour : `172.30.0.0/24` (subnet figé DOCKER_SUBNET, commit 3fb5c7b) au lieu de l'ancien `172.18.0.0/16`.
- Tests:
  - Baseline AVANT modifs (conteneur debian:bookworm + bats + whiptail) : 4 échecs préexistants (2 attentes de subnet périmées, backup.bats bloqué par le hardcode STACK_DIR, restic_choose_repo bloqué par la détection TTY). A/B sur HEAD confirmant qu'aucun échec n'était causé par les modifs.
  - APRÈS : `bats tests/install_env.bats tests/backup.bats tests/restic_choose_repo_no_repo.bats` → **19/19 ok** (docker run debian:bookworm, dépendances bats/whiptail/procps/gzip).
  - `shellcheck -S warning` sur les 3 scripts modifiés : aucun nouveau warning (restent SC1090 informatif et SC2034 faux positif ENV_PROMPTED, préexistants). `bash -n` OK.
- Commentaires / next steps: audit §2.1 marqué TRAITÉ, §3.8 partiellement traité. Étape suivante du plan (§6) : retirer `privileged: true` (HA sans aucun accès dongle en mode z2m) puis auth MQTT avec le plan de migration 3 scénarios. Non traité volontairement : suppression des strip_key_prefix_if_any (nettoyage défensif à garder), exec </dev/tty de install.sh.

---

- Date: 2026-07-03
- Auteur: Claude (Fable 5)
- Type: code + test + infra
- Impact: P0
- Résumé court: Étape 2 de l'audit — retrait de privileged (HA + Z2M) et authentification Mosquitto avec migration en 3 scénarios. Suite bats 23/23, E2E broker réel validé.
- Détails:
  - `docker-compose.yml` : `privileged: true` retiré de homeassistant et zigbee2mqtt. Le mapping `devices:` suffit car les deux images tournent en root (pas besoin de group_add dialout). En mode Z2M, HA n'a aucun accès matériel (/dev/null, mécanisme existant). Validé par `docker compose config` (profils caddy+zigbee2mqtt).
  - `scripts/lib/zigbee.sh` — auth MQTT :
    - Nouveaux helpers : mqtt_conf_path/mqtt_passwd_path, mqtt_conf_is_unmanaged (marqueur "Managed by armbian-ha-kit" — conf perso jamais touchée), mqtt_auth_state_get (MQTT_AUTH du .env ; défaut 1 si aucune conf mosquitto = install neuve, 0 sinon = migration explicite), mqtt_generate_password, mqtt_ensure_creds_env (ne régénère JAMAIS un secret existant), mqtt_write_passwd_file (docker run --entrypoint mosquitto_passwd eclipse-mosquitto:2, args en tableau sans interpolation shell, écriture atomique passwd.new→passwd, chown 1883 chmod 600), zigbee_upsert_z2m_mqtt_credentials (upsert awk du bloc mqtt: de la config Z2M, préserve les autres clés, échappement YAML single-quote), mqtt_show_credentials_info (msgbox identifiants à reporter dans l'intégration MQTT de HA), prompt_mqtt_auth (3 scénarios du plan §1.2).
    - zigbee_write_mosquitto_config prend un paramètre auth (allow_anonymous false + password_file, ou conf historique).
    - prepare_zigbee2mqtt_stack applique l'état : fige MQTT_AUTH dans .env AVANT d'écrire la conf (sinon le défaut "install neuve" basculerait au 2e passage), régénère le passwd file à chaque passage (hash non comparable, écriture atomique donc sans risque), upsert des creds Z2M.
    - prompt_zigbee_mode appelle prompt_mqtt_auth (gestion UI_BACK) avant sync/prepare, puis mqtt_show_credentials_info.
  - `scripts/install.sh` : résumé d'installation — ligne "MQTT auth : oui (user)/non (connexions anonymes)" dans la section Zigbee.
  - `scripts/lib/status.sh` : entrée "mqtt" du menu status — affiche les identifiants ; rotation explicite (regénère MQTT_PASSWORD, ré-applique passwd/conf/Z2M, docker restart ha-mqtt ha-zigbee2mqtt best-effort, ré-affiche les identifiants avec avertissement HA). Défaut = non.
  - `tests/install_env.bats` : 4 nouveaux tests — (1) install neuve : auth par défaut, creds générés, injectés dans Z2M ; (2) stack héritée sans auth : PAS activée (migration explicite), MQTT_AUTH=0 ; (3) creds existants respectés, idempotence sur double passage (pas de doublon), base_topic/server préservés ; (4) conf mosquitto non gérée jamais réécrite ni creds injectés.
- Tests:
  - `bats tests/install_env.bats tests/backup.bats tests/restic_choose_repo_no_repo.bats` (conteneur debian:bookworm) → **23/23 ok**.
  - E2E broker réel : conf générée + passwd via l'image eclipse-mosquitto:2, broker démarré → connexion anonyme REJETÉE, identifiants corrects ACCEPTÉS, mauvais mot de passe REJETÉ. Confirme aussi que le passwd root:600 est lu au démarrage (chown 1883 en filet pour les reloads).
  - `docker compose config --quiet` OK, 0 occurrence de privileged. shellcheck : aucun nouveau warning (5 préexistants SC2155/SC2221/SC2222 sur l'ancien code).
- Commentaires / next steps:
  - MIGRATION UTILISATEUR : sur la stack existante, relancer le wizard Zigbee et accepter l'auth ⇒ mettre à jour l'intégration MQTT dans HA avec les identifiants affichés (aussi dans /srv/ha-stack/.env). Sans action, rien ne change (défaut = non).
  - Audit §1.1 et §1.2 marqués TRAITÉS. Étape suivante (§6.3) : fiabiliser backup.sh (échecs non silencieux, PGPASSWORD hors de ps, chmod Restic, restic forget --tag, TimeoutStartSec).
