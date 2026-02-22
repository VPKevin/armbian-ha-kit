# Contexte (notes de dev)

## 2026-02-22

- Le wizard `scripts/install.sh` a été enrichi (compose distant, complétion automatique du `.env`, wizard de restauration Restic, menu résumé avec quitter/revoir/finaliser).
- Les tests sont exécutés dans un conteneur Docker (Bats + ShellCheck) via `tests/run-tests.sh`.
- Début de modularisation : ajout de `scripts/lib/` (i18n/ui/env/ha). Objectif : réduire la taille de `scripts/install.sh` en déplaçant progressivement les fonctionnalités.
- Le script d'installation démarre maintenant réellement la stack lors de la finalisation (`docker compose up -d`).
- `bootstrap.sh` affiche désormais les *Next steps* en FR/EN selon la locale système.

## À faire ensuite

- Finaliser la modularisation (retirer les doubles définitions encore présentes dans `scripts/install.sh`, déplacer Restic/NAS/USB/systemd dans `scripts/lib/*`).
- Étendre i18n sur les textes (pas seulement boutons).

