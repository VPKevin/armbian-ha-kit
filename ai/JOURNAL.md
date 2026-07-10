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

---

- Date: 2026-07-03
- Auteur: Claude (Fable 5)
- Type: code + test + infra
- Impact: P0/P1
- Résumé court: Étape 3 de l'audit — backup.sh fiabilisé (échecs non silencieux ni en cascade, plus de PGPASSWORD), chmod Restic, durcissement du service systemd. Bats 27/27, E2E postgres + restic réels.
- Détails:
  - `scripts/backup.sh` réécrit :
    - Contrat d'échec : chaque étape isolée (dump ; backup puis forget par repo) — un NAS mort n'empêche plus le backup USB suivant, un échec de dump n'empêche plus restic. Échecs accumulés dans FAILURES, bilan loggé, exit 1 final ⇒ systemd marque le run failed (avant : `|| true` silencieux côté ui_run, cascade set -e côté console).
    - Sécurité : PGPASSWORD supprimé — dump via `docker exec <pg> pg_dump` par le socket local (auth trust de l'image postgres officielle, validé E2E sur postgres:16 réel). Branches ui_run/bash -lc supprimées (mortes — ui.sh jamais sourcé par backup.sh — et injectables via apostrophe dans le mot de passe).
    - Dump en pipeline `pg_dump | gzip > f` (pipefail) avec suppression du fichier partiel sur échec.
    - `restic forget --tag homeassistant` (aligné sur le tag du backup ; ne purge plus les snapshots hors kit).
    - Ordre corrigé : repos.conf absent ⇒ skip restic proprement ; le mot de passe restic n'est exigé que si des repos existent.
  - `scripts/lib/restic.sh` : chmod 600 immédiatement après chaque écriture du mot de passe (les 2 branches interactives) ; chmod final inatteignable supprimé (audit §1.3, code mort restic.sh:123).
  - `systemd/ha-backup.service` : TimeoutStartSec=1h (NAS mort ⇒ pas de restic pendu indéfiniment), Nice=10, IOSchedulingClass=best-effort prio 7.
  - `tests/backup.bats` réécrit : stub docker adapté (dump sur stdout pour le pipeline), stub restic avec journal des appels + RESTIC_FAIL_REPO ; 4 tests — skip propre si repos.conf vide ; repo mort ⇒ continue sur le suivant + rc=1 + message explicite + pas de forget sur le mort ; échec pg_dump ⇒ pas de dump partiel + restic quand même + rc=1 ; garde anti-régression grep PGPASSWORD=.
  - `tests/install_env.bats` : test permissions 600 du mot de passe Restic (chemin non-interactif).
- Tests:
  - bats (debian:bookworm) : **27/27 ok**. (2 corrections de mes propres tests en route : chaque `run` bats écrase $output — assertions sur la sortie déplacées avant les greps ; le garde PGPASSWORD matchait le commentaire ⇒ resserré sur `PGPASSWORD=`.)
  - E2E pg_dump sans mot de passe : conteneur postgres:16 réel, `docker exec pg_dump -U ha` sans PGPASSWORD ⇒ dump OK (rc=0).
  - E2E restic réel (debian + restic apt) : run nominal rc=0 + snapshot créé + dump gzippé ; run avec repo mort en 1re position ⇒ rc=1, bilan "FAILED steps", repo sain sauvegardé ET purgé (retention --keep-daily vérifiée en conditions réelles).
  - shellcheck : aucun nouveau warning (reste SC2034 RESTIC_PROMPTED, faux positif préexistant lu par install.sh).
- Commentaires / next steps: audit §1.3, §1.4, §3.1, §3.2, §3.3 marqués TRAITÉS. Nice-to-have restants notés dans l'audit : OnFailure= (notification d'échec active), restic check périodique. Étape suivante (§6.4) : file_mtime, implémentation UPnP, nettoyage fstab à l'uninstall.

---

- Date: 2026-07-04
- Auteur: Claude (Fable 5)
- Type: code + test + infra
- Impact: P0/P1
- Résumé court: Étape 4 de l'audit — file_mtime défini, UPnP implémenté (miniupnpc + timer de renouvellement), nettoyage fstab à la désinstallation. Bats 32/32.
- Détails:
  - `scripts/lib/common.sh` : file_mtime (GNU puis BSD stat — la fonction était appelée par uninstall.sh sans exister : la suppression de paquets ne faisait jamais rien) ; helpers mounts_state_file/add/list (suivi des mountpoints NAS/USB créés par le kit dans $AHK_STATE_DIR/mounts.list). status.sh refactoré pour utiliser file_mtime.
  - UPnP (audit §2.3, décision mainteneur : implémenter) :
    - `scripts/lib/upnp.sh` : upnp_lan_ip (ip route get), upnp_map_port (idempotent, résout ConflictInMappingEntry 718 par delete+retry), upnp_apply (80+443 TCP), upnp_remove_mappings, remove_upnp_units, setup_upnp (installe miniupnpc tracé dans l'état apt, unités systemd, application immédiate + msgbox succès/échec IGD ; nettoie tout si ENABLE_UPNP repasse à 0 ; skip avec warning si Caddy désactivé — ports vers rien).
    - `scripts/upnp-renew.sh` + `ha-upnp.sh` (exec sbin) + `systemd/ha-upnp.service`/`ha-upnp.timer` (OnBootSec=2min, OnUnitActiveSec=45min) : renouvellement périodique, les box perdant les mappings au reboot/expiration.
    - `scripts/install.sh` : source upnp.sh, setup_upnp après le wizard, question UPnP enrichie de l'avertissement d'exposition Internet.
  - `scripts/lib/uninstall.sh` : uninstall_cleanup_fstab (umount + retrait fstab des mountpoints tracés + défauts historiques /mnt/nasbackup, /mnt/usbbackup + lignes credentials=$SAMBA_CREDS pour les installs antérieures au suivi ; exécuté AVANT la suppression des creds) ; retrait des mappings UPnP et de ha-upnp.timer.
  - `scripts/lib/backup_targets.sh` : FSTAB_PATH surchargeable (tests), mounts_state_add après chaque écriture fstab.
  - Tests (5 nouveaux) : file_mtime, mounts_state dédup, uninstall_cleanup_fstab (lignes kit retirées, lignes utilisateur préservées), upnp_map_port (ok/conflit résolu/no-IGD), upnp_lan_ip.
- Tests:
  - bats (debian:bookworm) : **32/32 ok**.
  - Exécution réelle de scripts/upnp-renew.sh (libs sourcées, .env réel, stubs upnpc/ip) dans les 4 états : désactivé rc=0, actif+Caddy rc=0 avec mappings, actif sans Caddy skip rc=0, IGD absent rc=1 avec message explicite.
  - shellcheck : 0 warning sur les nouveaux fichiers (restent les faux positifs préexistants de common.sh).
- Commentaires / next steps: audit §2.2, §2.3, §3.6 marqués TRAITÉS. Étape suivante (§6.5) : quoting des valeurs .env (sourcé en root) + URL-encoding du db_url recorder, healthcheck Caddy, pin zigbee2mqtt:2, IP statique Caddy + trusted_proxies /32.

---

- Date: 2026-07-05
- Auteur: Claude (Fable 5)
- Type: code + test + infra
- Impact: P0/P1
- Résumé court: Étape 5 de l'audit — quoting .env (sourcing root sûr), db_url URL-encodé, healthcheck Caddy /healthz, zigbee2mqtt épinglé :2, Caddy en IP statique seule trustée par HA. Bats 38/38 + E2E compose/Caddy réels.
- Détails:
  - `scripts/lib/env.sh` (audit §1.5) : env_set_kv single-quote les valeurs contenant des caractères spéciaux — le single-quote est la seule forme comprise identiquement par bash (sourcing) et par le parser dotenv de docker compose. Apostrophes retirées avec log_warn (irreprésentables de façon compatible dans les deux parsers). env_value_needs_quoting (charset sûr documenté). env_get retire symétriquement les quotes enveloppantes. Valeurs simples inchangées (rétrocompatibilité .env existants).
  - `scripts/lib/ha.sh` : urlencode() byte-wise (LC_ALL=C) ; db_url du recorder écrit avec user/password URL-encodés (un mot de passe @ : / # ? cassait l'URL) ; ha_trusted_base() — trusted_proxies = CADDY_STATIC_IP si définie, fallback subnet complet pour les .env antérieurs (resserrage automatique au premier re-run).
  - `docker-compose.yml` : caddy en ipv4_address figée ${CADDY_STATIC_IP:-172.30.0.10} (spoof X-Forwarded-For impossible depuis les autres conteneurs) ; healthcheck caddy sur /healthz ; image zigbee2mqtt épinglée :2 (existence du tag vérifiée au registre — :latest peut sauter une majeure, Z2M a déjà cassé des configs en 1.x→2.x).
  - `Caddyfile` : bloc :80 avec handle /healthz (200) + handle redir https. Piège découvert au test E2E : l'ordre STANDARD des directives Caddy exécute redir avant respond quel que soit l'ordre du fichier → première version (respond+redir à plat) redirigeait aussi /healthz ; corrigé par blocs handle mutuellement exclusifs. Un bloc :80 explicite désactivant la redirection auto de Caddy, elle est refaite à la main.
  - `scripts/install.sh` : le résumé affiche la base trusted_proxies effective (ha_trusted_base).
  - Tests (6 nouveaux) : aller-retour valeur piégée `pa$s; touch … $(id) &` (écriture quotée, env_get exact, sourcing bash sans exécution ni effet de bord), valeurs simples non quotées, apostrophes retirées, urlencode (réservés + charset sûr), db_url encodé dans configuration.yaml, CADDY_STATIC_IP trustée seule (subnet absent).
- Tests:
  - bats (debian:bookworm) : **38/38 ok, 0 échec**.
  - E2E parsing .env : même valeur piégée lue par `docker compose config` et par sourcing bash — identiques, aucune exécution.
  - E2E Caddy réel (caddy:2) : caddy validate OK ; /healthz → 200 "OK" ; commande exacte du healthcheck compose → exit 0 ; / → 301 Location https://… (vérifié depuis l'hôte). C'est ce test E2E qui a révélé le piège d'ordre des directives.
  - `docker compose config` : ipv4_address 172.30.0.10 + image :2 résolues, config valide.
  - shellcheck : 0 nouveau warning.
- Commentaires / next steps: audit §1.5, §1.6, §3.4, §3.5 marqués TRAITÉS. Migration : le resserrage trusted_proxies s'applique au premier re-run une fois CADDY_STATIC_IP écrite dans .env (recréation du conteneur caddy nécessaire pour prendre l'IP figée : docker compose up -d --force-recreate caddy). Étape suivante (§6.6) : CI GitHub Actions (shellcheck + shfmt + bats), test de restore dans le smoke, HSTS sans preload, exclusion .env de bootstrap --local, dédup mapping service→conteneur.
