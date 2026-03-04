# Plan d'amélioration IA - armbian-ha-kit

Date: 2026-03-03
Objectif: rendre le projet plus réutilisable, robuste et maintenable avec une rigueur d'exécution élevée.

## 1) Périmètre audité

- Documentation: `README.md`, `CONTEXT.md`, `AGENTS.md`
- Entrée principale: `bootstrap.sh`, `scripts/install.sh`
- Bibliothèques shell: `scripts/lib/*.sh`
- Sauvegarde/restauration: `ha-backup.sh`, `scripts/backup.sh`, `scripts/lib/restic.sh`, `scripts/lib/backup_targets.sh`
- Orchestration/infra: `docker-compose.yml`, `Caddyfile`, `systemd/ha-backup.service`, `systemd/ha-backup.timer`
- Tests: `tests/*.bats`, `tests/run-tests.sh`, `tests/run-smoke.sh`

## 2) Features et éléments clés de l'application

- Installation guidée de Home Assistant et de la stack associée via scripts shell.
- Wizard interactif (`whiptail`) pour piloter l'installation/configuration.
- Modularisation des responsabilités dans `scripts/lib/` (env, compose, restic, health, ui, i18n, systemd, uninstall).
- Sauvegarde/restauration avec `restic` et cibles de backup configurables.
- Automatisation périodique des backups via `systemd` (service + timer).
- Vérification de santé/état via fonctions dédiées (status/health).
- Reverse proxy avec `Caddyfile`.
- Suite de tests (Bats + smoke en environnement Docker) pour valider le comportement.

## 3) Incohérences et risques observés

### Critique

- Incohérences potentielles secrets/chemins entre docs et scripts (ex: credentials Samba):
  - `README.md`
  - `scripts/install.sh` (variable de type `SAMBA_CREDS`)
  - `scripts/lib/uninstall.sh`
  Impact: erreurs de configuration, fuite de secret, suppression incomplète.

### Majeur

- Robustesse shell hétérogène: gestion d'erreurs/idempotence non totalement unifiée dans:
  - `scripts/install.sh` (ex: `need_root`, `setup_env`)
  - `scripts/lib/status.sh` (ex: `status_wizard`)
  Impact: échec partiel difficile à diagnostiquer, relance non sûre.

- Couplage implicite entre modules `scripts/lib/*.sh` (contrats d'API interne peu explicites).
  Impact: faible réemploi, risques de régressions transverses.

### Modéré

- Couverture de tests surtout smoke/happy path; cas d'erreur/rollback/restauration limités.
  Impact: régressions détectées tardivement.

- Standardisation logs/messages UX perfectible (actionnabilité, niveau, contexte).
  Impact: support/exploitation plus coûteux.

## 4) Plan d'amélioration priorisé

### P0 - Fondations (immédiat)

1. Définir un contrat d'API interne pour chaque module de `scripts/lib/`:
   - Entrants/sortants
   - Codes retour
   - Effets de bord
   - Préconditions/postconditions
2. Uniformiser la politique d'erreur shell:
   - `set -Eeuo pipefail` selon contexte
   - `trap` centralisé
   - helper unique de gestion d'erreur
3. Unifier la gestion secrets/chemins:
   - source de vérité unique (`.env` + helpers)
   - aligner docs + install + uninstall
4. Vérifications pre-flight systématiques:
   - droits/root
   - dépendances
   - état Docker
   - connectivité/stockage
5. Logging cohérent:
   - niveaux `INFO|WARN|ERROR`
   - message court + cause + action recommandée

### P1 - Réutilisabilité et architecture

1. Découpler UI (whiptail) de la logique métier:
   - fonctions headless réutilisables par tests/CI.
2. Introduire une façade d'API interne stable (ex: `scripts/lib/lib_api.sh`).
3. Standardiser structure des modules:
   - `validate_*`, `apply_*`, `rollback_*`, `status_*`.
4. Interface d'adaptateurs backup:
   - restic local
   - samba
   - cloud futur (S3/WebDAV/...) sans casser l'existant.
5. Template de nouveau module:
   - squelette + tests + section doc obligatoire.

### P1 - Qualité et tests

1. Étendre Bats aux scenarios critiques:
   - annulation wizard (abort/back)
   - restore complet
   - repo absent/corrompu
   - erreurs réseau/permissions
2. Ajouter tests d'idempotence:
   - install -> re-install
   - backup répété
   - uninstall partiel puis reprise
3. Intégrer quality gates:
   - `shellcheck`
   - `shfmt --diff`
   - tests obligatoires avant merge
4. Tester les unités systemd:
   - validité service/timer
   - comportement au boot

### P2 - CI/CD, observabilité, documentation

1. Pipeline CI clair:
   - lint -> unit/smoke -> integration Docker -> publication rapports
2. Gouvernance repo:
   - conventions commit
   - checklist PR (sécurité, idempotence, docs, tests)
3. Observabilité:
   - commande de diagnostic unique (etat compose/systemd/backup)
4. I18n/UX:
   - clés harmonisées, fallback explicite
   - messages orientés résolution
5. Documentation mainteneur:
   - architecture
   - flux install/backup/restore/uninstall
   - playbook incidents

## 5) Plan d'exécution concret (90 jours)

### Semaine 1-2 (P0)
- Geler conventions shell et contrats modules.
- Corriger incohérences secrets/paths entre docs et scripts.
- Ajouter pre-flight checks et logging unifié.

### Semaine 3-6 (P1)
- Découpler UI/logic et créer façade interne stable.
- Refactor progressif des modules critiques (`env`, `compose`, `restic`, `systemd`).
- Étendre tests Bats sur cas d'erreur et idempotence.

### Semaine 7-10 (P1/P2)
- Mettre en place quality gates + pipeline CI complete.
- Ajouter tests systemd et scenario restore bout-en-bout.

### Semaine 11-12 (P2)
- Finaliser documentation technique et playbooks d'exploitation.
- Stabiliser KPI qualité et boucle d'amélioration continue.

## 6) Indicateurs de succès (KPI)

- 0 secret en dur dans scripts/docs.
- 100% modules `scripts/lib/` avec contrat documenté.
- Couverture tests scenario critique: >90% des flux install/backup/restore/uninstall.
- Taux de réussite CI stable (>95% sur 30 jours).
- Diminution des incidents d'exploitation et du temps de diagnostic.

## 7) Backlog technique détaillé (exemples)

- Harmoniser variables d'environnement et nomenclature (`scripts/lib/env.sh`).
- Clarifier API compose (`scripts/lib/compose.sh`) et codes retour.
- Rendre `restic` interchangeable via adaptateur (`scripts/lib/restic.sh`).
- Renforcer checks sante (`scripts/lib/health.sh`, `scripts/lib/status.sh`).
- Standardiser nettoyage/désinstallation (`scripts/lib/uninstall.sh`).
- Ajouter tests non-regression sur `scripts/install.sh` et `bootstrap.sh`.

## 8) Hypothèses / points à confirmer

- Emplacement final du fichier de plan IA: ce document est maintenant placé dans `ai/AI_IMPROVEMENT_PLAN.md` (journal déplacé vers `ai/JOURNAL.md`).
- Le niveau de sévérité retenu combine audit (Critique/Majeur/Modéré) et exécution backlog (P0/P1/P2).
- L'ordre de priorité est optimisé pour réduire le risque avant le refactor profond.

## 9) Recommandation de gouvernance

- Nommer un propriétaire technique du socle shell.
- Exiger au minimum pour chaque changement:
  - contrat module mis à jour
  - tests ajoutés/modifiés
  - doc impactée mise à jour
- Mettre en place une revue mensuelle du plan et des KPI.

---

*Journal de bord déplacé vers `ai/JOURNAL.md`.*

