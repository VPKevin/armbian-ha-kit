# tests - Environnements de test (usage par volume Docker uniquement)

Ce dossier fournit un `Dockerfile` multi-target et des instructions pour tester le bootstrap sur une image proche d'une box Armbian sans créer de dossier physique sur l'hôte : tout se fait via des volumes Docker.

Principes
- Aucune référence ni création de dossier physique sur l'hôte : on utilise un volume Docker dédié (ex: `ha-stack`).
- Avantages : isolation, pas de problèmes de permissions/UID, nettoyage simple (`docker volume rm`).
- Le README ci‑dessous donne les commandes manuelles pour créer le volume, builder l'image et lancer le bootstrap.

Fichiers importants
- `tests/Dockerfile` : Dockerfile multi-target (targets `lint` et `armbian`).
- `tests/entrypoint-bootstrap.sh` : entrypoint qui télécharge et exécute `bootstrap.sh` depuis GitHub (utilise `HA_REF` si défini). Il supporte maintenant `BOOTSTRAP_SOURCE=local|remote` (default remote) et appelle `bootstrap.sh --local` quand `BOOTSTRAP_SOURCE=local`.
- `tests/run-smoke.sh` : smoke tests pour vérifier la présence du client Docker et interaction avec le socket.

1) Target `lint` (usage rapide)

Construire l'image `lint` :

```bash
docker build --target lint -t armbian-tests:lint -f tests/Dockerfile .
```

Exemple d'utilisation (shellcheck sur les scripts) :

```bash
docker run --rm -it -v "$(pwd)":/repo -w /repo armbian-tests:lint shellcheck scripts/*.sh
```

2) Target `armbian` (simule une box Armbian, utilisation par volume Docker)

Builder l'image `armbian` (sur macOS/x86 utilisez buildx + qemu) :

```bash
# activer buildx (si nécessaire)
docker buildx create --use || true
```
```bash
# builder l'image arm64 et la charger localement (--load)
docker buildx build --platform linux/arm64 --target armbian -t armbian-tests:armbian -f tests/Dockerfile --load .
```

3) Créer un volume Docker et lancer le bootstrap (manuellement)

- Créer le volume :

```bash
docker volume create ha-stack
```

- Dry-run (recommandé) : exécuter le bootstrap dans le conteneur et écrire dans le volume sans donner accès au démon Docker de l'hôte :

```bash
docker run --platform linux/arm64 --rm -it \
  -v "$(pwd)":/repo:ro \
  -v ha-stack:/srv/ha-stack \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

- Exécuter le bootstrap depuis le projet local monté (option `BOOTSTRAP_SOURCE=local`, équivalent à `bootstrap.sh --local`) :

```bash
docker run --platform linux/arm64 --rm -it \
  -v "$(pwd)":/repo:ro \
  -v ha-stack:/srv/ha-stack \
  -e BOOTSTRAP_SOURCE=local \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

> Remarque : pour que `BOOTSTRAP_SOURCE=local` fonctionne, assurez-vous que le repo local contient `bootstrap.sh` à la racine (c'est le cas si vous lancez la commande depuis la racine du dépôt montée en `/repo`).

- Si vous voulez pinner une ref du bootstrap (tag/sha) :

```bash
docker run --platform linux/arm64 --rm -it \
  -e HA_REF=v1.2.3 \
  -v "$(pwd)":/repo:ro \
  -v ha-stack:/srv/ha-stack \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

- Exécution réelle (équivalent à `sudo bash bootstrap.sh`) — le script pourra lancer `docker compose up -d` :

> ATTENTION : cela nécessite de monter le socket Docker de l'hôte et donne au conteneur un contrôle total sur le démon Docker.

```bash
docker run --platform linux/arm64 --rm -it \
  -v "$(pwd)":/repo:ro \
  -v ha-stack:/srv/ha-stack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --workdir /repo \
  --user root \
  armbian-tests:armbian
```

4) Inspecter et récupérer les fichiers du volume

- Lister le contenu du volume :

```bash
docker run --rm -v ha-stack:/data alpine:3.18 ls -la /data
```

- Afficher le fichier `.env` généré :

```bash
docker run --rm -v ha-stack:/data alpine:3.18 cat /data/.env
```

- Copier le contenu du volume vers un dossier hôte (si vous souhaitez l'analyser localement) :

```bash
mkdir -p ./out
docker run --rm -v ha-stack:/data -v "$(pwd)/out":/out alpine:3.18 sh -c "cp -a /data/. /out/"
```

5) Nettoyage

- Supprimer le volume lorsque vous avez fini :

```bash
docker volume rm ha-stack
```

6) Sécurité & bonnes pratiques

- N'utilisez le montage `/var/run/docker.sock` que sur des machines de confiance.
- Pour des runs reproductibles, pinnez la ref du bootstrap (`-e HA_REF=...`).
- Ce README n'utilise aucun script helper : toutes les commandes nécessaires sont documentées ci‑dessous et utilisent exclusivement des volumes Docker.

Support

Si vous souhaitez que j'ajoute un job GitHub Actions (lint + build arm) ou d'autres instructions, dites‑le et je l'ajouterai.
