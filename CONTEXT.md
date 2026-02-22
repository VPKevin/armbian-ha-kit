# Contexte (notes de dev)

## 2026-02-22

- Le wizard `scripts/install.sh` a été enrichi (compose distant, complétion automatique du `.env`, wizard de restauration Restic, menu résumé avec quitter/revoir/finaliser).
- Les tests sont exécutés dans un conteneur Docker (Bats + ShellCheck) via `tests/run-tests.sh`.
- Modularisation avancée : `scripts/install.sh` est maintenant un orchestrateur, et la logique est répartie dans `scripts/lib/` :
  - `i18n.sh` (FR/EN), `ui.sh` (whiptail)
  - `env.sh` (parsing compose + .env)
  - `ha.sh` (configuration.yaml + trusted_proxies)
  - `compose.sh` (choix compose + démarrage stack)
  - `restic.sh` (repos/password/restore)
  - `backup_targets.sh` (NAS/USB)
  - `systemd.sh` (timer backup)
- Le script d'installation démarre maintenant réellement la stack lors de la finalisation (`docker compose up -d`).
- `bootstrap.sh` affiche désormais les *Next steps* en FR/EN selon la locale système.

## À faire ensuite

- Étendre i18n sur les *textes* (pas seulement boutons et message bootstrap), idéalement en regroupant toutes les chaînes dans des fichiers dédiés.
- Réduire les warnings ShellCheck SC1090 (source dynamique de `.env`) si souhaité (directives locales).
