# tests - Environnements de test

Ce dossier contient un Dockerfile multi-target pour deux usages :

- `lint` : image légère (Debian slim) avec outils de lint (shellcheck, shfmt, bats).
- `armbian` : image proche d'une box Armbian (basée sur `ophub/armbian-trixie`) configurée pour exécuter le `bootstrap.sh` comme sur une box.

Fichiers importants
- `tests/Dockerfile` : Dockerfile multi-target (lint + armbian)
- `tests/entrypoint-bootstrap.sh` : entrypoint qui télécharge et exécute `bootstrap.sh` depuis GitHub (utilise `HA_REF` si défini)
- `tests/run-smoke.sh` : smoke tests pour vérifier présence du client Docker et interaction avec le socket

Builder et utiliser

1) Target `lint` (rapide, local)

Construire l'image `lint` :

```bash
docker build --target lint -t armbian-tests:lint -f tests/Dockerfile .
```

Exemple d'utilisation (shellcheck sur les scripts) :

```bash
docker run --rm -it -v "$(pwd)":/repo -w /repo armbian-tests:lint \
  shellcheck scripts/*.sh
```

2) Target `armbian` (simule une box Armbian, arm64)

Sur macOS (x86), utilisez `buildx` + qemu pour builder l'image arm64 :

```bash
# activer buildx (si nécessaire)
docker buildx create --use || true
# optionnel : initialiser qemu (Docker Desktop le fait souvent)
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# builder l'image arm64 et la charger localement (--load)
docker buildx build --platform linux/arm64 --target armbian -t armbian-tests:armbian -f tests/Dockerfile --load .
```

Exécuter le container (dry-run, ne démarre pas la stack Docker de l'hôte) :

```bash
mkdir -p /tmp/ha-stack-dry
sudo chown "$(id -u):$(id -g)" /tmp/ha-stack-dry

docker run --platform linux/arm64 --rm -it \
  -v "$(pwd)":/repo:ro \
  -v /tmp/ha-stack-dry:/srv/ha-stack \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

Exécuter la version réelle (équivalent à `sudo bash bootstrap.sh`, le script pourra lancer `docker compose up -d`) :

```bash
mkdir -p /tmp/ha-stack-test
sudo chown "$(id -u):$(id -g)" /tmp/ha-stack-test

docker run --platform linux/arm64 --rm -it \
  -v "$(pwd)":/repo:ro \
  -v /tmp/ha-stack-test:/srv/ha-stack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

Astuce : pour pinner une version du bootstrap, définissez la variable d'environnement `HA_REF` (ex: `-e HA_REF=v1.2.3`).

Nettoyage / fichiers redondants

Les anciens Dockerfiles spécifiques (`Dockerfile.arm64`, `Dockerfile.armbian-trixie`) et les README doublons ont été marqués comme dépréciés. Si vous préférez, je peux déplacer ces fichiers dans `tests/deprecated/` pour garder le dossier propre.

Sécurité

- Monter `/var/run/docker.sock` donne au conteneur un accès total au démon Docker de l'hôte — à n'utiliser que sur des machines de confiance.
- L'entrypoint télécharge et exécute un script depuis GitHub. Pour les installations reproductibles, pinner `HA_REF` (tag ou SHA) est fortement recommandé.

Support

Si vous voulez, je peux :
- archiver (`git mv`) les anciens fichiers dans `tests/deprecated/`,
- ajouter un script helper `tests/run-bootstrap-dry.sh`,
- ajouter un job GitHub Actions (lint + build arm) pour CI.

Dites-moi ce que vous préférez que je fasse ensuite.