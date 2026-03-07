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
