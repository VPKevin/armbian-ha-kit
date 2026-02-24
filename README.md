# HA Stack (Armbian) — Home Assistant + PostgreSQL + Caddy + Backups + UPnP

A reproducible, migratable Home Assistant installation for ARM boards running **Armbian**, using Docker.

> 📖 **Maintainers / contributors**: see [AGENTS.md](AGENTS.md) for architecture rationale, project invariants, and contributor instructions.

---

## Quickstart (installation interactive recommandée)

> ⚠️ **Security note** — piping a remote script to `bash` is convenient but carries risk.
> You cannot inspect the script before it runs. Mitigations:
> - Download `bootstrap.sh`, review it, then run it.
> - **Pin to a specific tag or commit SHA** (`--ref v1.0.0`) for reproducible installs.

### Méthode recommandée (compatible `whiptail`)

`install.sh` est interactif (UI texte via `whiptail`). Pour que les flèches / Oui-Non fonctionnent, il faut un vrai TTY.

```bash
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh
```

### One‑liner (à éviter si tu veux l’UI interactive)

Le one‑liner ci-dessous peut casser l’interactivité (stdin n’est pas un terminal), selon ton environnement.

```bash
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo bash
```

**Pinned to a tag (recommended for production):**
```bash
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.0.0/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh --ref v1.0.0
```

`bootstrap.sh` will:
1. Install missing prerequisites (`curl`, `ca-certificates`, `tar`).
2. Create `/srv/ha-stack` with correct permissions.
3. Download the repository archive from GitHub (no `git` required).
4. Sync repo-managed files; **preserve** existing `config/`, `postgres/`, `backup/`, `caddy/`, `restic/`.
5. Run `scripts/install.sh` (interactive wizard).

---

## Options du bootstrap et mode simulation

Le script `bootstrap.sh` accepte plusieurs façons de préciser quel contenu Git télécharger et un mode de simulation non destructif :

- `--ref <tag|commit|branch>` ou `--ref=<value>` : télécharge l'archive correspondant au ref Git (tag, SHA, ou nom de branche).
- `--branch <branch>` ou `--branch=<value>` ou `-b <branch>` : alias de `--ref` — même effet.
- `--dir <install-dir>` : change le répertoire d'installation (variable d'environnement `HA_INSTALL_DIR`).
- `--source <remote|local>` : source du bootstrap. `remote` télécharge l’archive GitHub (défaut), `local` synchronise le repo local (pas de download).
- `--local` : alias de `--source local`.
- `--dry-run` : affiche les actions prévues sans rien modifier (utile pour valider ce que fera le bootstrap). En `--dry-run` le script n'exige pas `sudo`.

Exemples :

```bash
# Simuler l'installation depuis une branche (aucun changement réalisé)
bash bootstrap.sh --branch copilot/add-systemd-service-wrapper --dry-run

# Télécharger un bootstrap épinglé sur un tag (exécution réelle)
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.0.0/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh --ref v1.0.0

# Utilisation en one-liner (piping) en choisissant une branche
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh | sudo bash -s -- --ref=copilot/add-systemd-service-wrapper
```

Remarques techniques :
- Le script construit l'URL d'archive GitHub comme suit :
  `https://github.com/<owner>/<repo>/archive/<ref>.tar.gz`. Ainsi, fournir un nom de branche contenant des barres (`feature/xyz`) fonctionne tant que la branche existe sur GitHub.
- Pour des installations reproductibles en production, il est fortement recommandé de pinner un tag ou un SHA (ex: `--ref v1.2.3` ou `--ref <sha>`).

---

## Manual install

If you prefer full control:

```bash
# 1. Copy repo files to /srv/ha-stack (e.g. via git clone or scp)
git clone https://github.com/VPKevin/armbian-ha-kit.git /srv/ha-stack

# 2. Run the wizard
sudo bash /srv/ha-stack/scripts/install.sh
```

The wizard:
- Generates `.env` (passwords, domain, ACME email)
- Configures optional NAS (SMB) and/or USB backup targets
- Initialises restic on configured targets
- Offers restore from an existing restic backup
- Optionally tries UPnP port mapping (443, and 80 temporarily)
- Configures `configuration.yaml` (Postgres recorder + strict `trusted_proxies`)
- Starts the Docker stack
- Installs the systemd backup timer

---

## Prerequisites

On the Armbian box:
- Docker and Docker Compose installed.
- `whiptail` installed (present by default on Armbian/Debian).
- Root access (`sudo`).

Network:
- A public domain name pointing to your public IP (DNS A/AAAA record).
- Inbound port **443** open (and sometimes **80** for ACME challenge).

---

## Update

`bootstrap.sh` is synced to `/srv/ha-stack/` during installation, so you can re-run it directly.
Pin to the new tag for a reproducible update:

```bash
sudo bash /srv/ha-stack/bootstrap.sh --ref v1.2.3
```

Or fetch it fresh from GitHub (always pins to the version you specify):

```bash
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/v1.2.3/bootstrap.sh \
  | sudo bash -s -- --ref v1.2.3
```

Or manually pull new files and re-run the installer:

```bash
cd /srv/ha-stack && git pull && sudo bash scripts/install.sh
```

---

## Backup & Restore

### Run backup manually
```bash
sudo /srv/ha-stack/scripts/backup.sh
```

### Check backup timer
```bash
systemctl status ha-backup.timer
systemctl list-timers | grep ha-backup
journalctl -u ha-backup.service -n 200 --no-pager
```

### Restore / Migrate to a new box

1. Install Docker + Compose on the new box.
2. Make the restic repository accessible (mount NAS/USB).
3. Copy repo scripts to `/srv/ha-stack`:
   ```bash
   sudo bash bootstrap.sh --ref <tag>
   ```
4. Answer **Yes** to "restore from backup" in the wizard.

The wizard restores `config/` + `backup/`, restarts Postgres, re-imports the latest SQL dump, then restarts HA and Caddy.

---

## Troubleshooting

### Whiptail affiche `^[[C` / impossible de naviguer (flèches)

C’est un symptôme que le script est lancé **sans TTY** (souvent via `curl | sudo bash`, cron, ou un terminal qui ne fournit pas `/dev/tty`).

Solutions :
- Utiliser la méthode recommandée : télécharger puis exécuter `bootstrap.sh`.
- Si tu passes par SSH, forcer un TTY : `ssh -t user@box 'sudo bash /srv/ha-stack/scripts/install.sh'`.

### HTTPS certificate not generated
- DNS not pointing to your public IP → check `A`/`AAAA` records.
- Port 443 (or 80) closed → forward on your router, or use UPnP.
- CGNAT at your ISP → no inbound connection possible.
- Check Caddy logs: `docker logs ha-caddy --tail 200`

### Home Assistant 400 error / proxy not detected
Check `/srv/ha-stack/config/configuration.yaml`:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <docker-bridge-subnet>
```
Then: `docker restart homeassistant`

---

## Tests (reproductibles via Docker)

Les tests (Bats + ShellCheck) s'exécutent dans un conteneur Docker, pour garantir que toutes les dépendances sont installées.

```bash
cd /srv/ha-stack
bash tests/run-tests.sh
```

Ce script va :
- builder une image Debian (Bookworm) avec `bats` et `shellcheck`
- lancer `shellcheck` sur `scripts/*.sh`
- lancer `bats` sur `tests/*.bats`

---

## Security / Secrets

| Secret | Location | Permissions |
|--------|----------|-------------|
| DB passwords, domain, ACME email | `/srv/ha-stack/.env` | `chmod 600`, root |
| NAS SMB credentials | `/etc/samba/creds-ha-nas` | `chmod 600`, root |
| Restic password | `/srv/ha-stack/restic/password` | `chmod 600` |

Never commit: `.env`, `config/`, `postgres/`, `backup/`, `caddy/`, SMB credentials, restic repos.
A `.gitignore` is provided.

---

## Licence
MIT
