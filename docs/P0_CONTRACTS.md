# P0 — Contrats et conventions (résumé)

But: documenter rapidement la source de vérité, les chemins sensibles et les conventions P0
utilisées par les scripts shell du projet (armbian-ha-kit).

1) Source de vérité et chemins

- STACK_DIR: répertoire racine de la stack (par défaut `/srv/ha-stack`).
  - Fichiers importants:
    - `${STACK_DIR}/.env` — fichier d'environnement principal utilisé par les scripts.
    - `${STACK_DIR}/docker-compose.yml` — compose par défaut (peut être remplacé).
    - `${STACK_DIR}/restic/password` — mot de passe Restic (chmod 600).
    - `${STACK_DIR}/restic/repos.conf` — liste de repositories Restic (une ligne par repo).
    - `${STACK_DIR}/config` — configuration Home Assistant.
    - `${STACK_DIR}/postgres` — données Postgres.
    - `${STACK_DIR}/backup` — dumps locaux temporaires.

- AHK_STATE_DIR: répertoire d'état global utilisé pour tracker paquets installés
  (par défaut `/var/lib/armbian-ha-kit`).

- SAMBA_CREDS: chemin vers le fichier d'identifiants SMB (par défaut `/etc/samba/creds-ha-nas`).
  - Doit être protégée en `chmod 600`.

2) Permissions recommandées

- `.env`, `restic/password`, `restic/repos.conf`, `SAMBA_CREDS` : `chmod 600` (read/write owner only).
- `STACK_DIR` : `chmod 700` ou `750` selon besoin (protéger contenus).
- Scripts installés comme binaires (ex: `/usr/local/sbin/ha-backup.sh`) : `chmod 755`.

3) Conventions P0 pour les modules `scripts/lib/*.sh`

- Chaque module expose un petit contrat (bloc `Contracts (P0)` en tête de fichier) qui décrit:
  - Fonctions publiques attendues
  - Variables d'entrée globales (ex: `STACK_DIR`, `ENV_FILE`, `RESTIC_DIR`)
  - Effets de bord (fichiers créés/modifiés, unités systemd installées)
  - Codes retour attendus (0 réussite, non-zero erreurs; UI flows utilisent `UI_OK/UI_BACK/UI_ABORT`).

- Les modules ne doivent pas écraser des variables globales déjà définies par l'appelant. On utilise
  la forme idempotente `: "${VAR:=default}"` dans `scripts/lib/common.sh`.

4) Politique d'erreur (shell)

- Tous les scripts doivent commencer par :
  - `set -euo pipefail`
  - utiliser `install_error_trap "scriptname"` pour trapper erreurs et logger via `log_error`
  - utiliser les codes standard définis dans `scripts/lib/common.sh`: `RC_OK`, `RC_ERR`, `RC_NOT_ROOT`, `RC_MISSING_DEP`, etc.

- `require_root_or_fail` est le helper central pour vérifier les privilèges root dans les fonctions ou scripts qui en
  ont besoin; il retourne `RC_NOT_ROOT` si non-root.

5) Gestion des secrets

- Toutes les écritures de secrets doivent:
  - Créer le répertoire parent (`mkdir -p`) si nécessaire
  - Écrire le fichier avec `chmod 600`
  - Ne jamais afficher le secret en clair dans les logs ou messages interactifs

- Exemple: l'utilisation de `RESTIC_PASS` et `SAMBA_CREDS` doit être protégée et leur existence contrôlée avant usage.

6) Pré-checks

- Les scripts d'entrée (ex: `scripts/install.sh`, `scripts/backup.sh`) doivent:
  - Vérifier la présence des commandes nécessaires (via `req_bin` ou `preflight_checks`).
  - Indiquer en sortie claire les dépendances manquantes et un code `RC_MISSING_DEP`.
  - Ne pas demander d'interaction si en environnement non-interactif (CI) — tomber en mode headless ou erreur claire.

7) Tests et stubs

- Tests unitaires/bats doivent stubber les dépendances externes (docker, restic, systemctl) et fournir une version
  minimale de `scripts/lib/common.sh` si le test exige d'éviter les contrôles `require_root_or_fail`.
- Les tests doivent vérifier les effets de bord (fichiers `.env`, `restic/password`, dumps) et ne pas toucher à
  ressources système persistantes.

8) Checklist rapide pour PRs P0

- [ ] Le fichier modifié contient un petit header `Contracts (P0)` (si nouveau module)
- [ ] Les chemins sensibles sont référencés via variables globales dans `common.sh`
- [ ] Les modifications conservent les permissions 600/700 pour secrets/dossiers
- [ ] `install_error_trap` est utilisé dans les scripts d'entrée
- [ ] Tests Bats couvrent le flux modifié et stubent les dépendances externes

-- Fin --

