# HA Stack (Armbian) — Home Assistant + PostgreSQL + Caddy + Backups

A **reproducible**, **migratable** Home Assistant installation on an ARM board
running Armbian + Docker, managed by an interactive wizard.

- Home Assistant in Docker (not HA OS / Supervised)
- Automated, encrypted backups to NAS (SMB) and/or USB via Restic
- HTTPS reverse proxy (Caddy + Let's Encrypt, auto-renew)
- No git required on the target machine — bootstrap installs everything

---

## Quick Start (one-liner install)

> ⚠️ **Security warning**: review the script before piping it into bash.
> See [bootstrap.sh](bootstrap.sh) in this repository.
> **Pin a version** for production use — replace `main` with a tag/SHA.

```bash
# Install latest (main branch) — review before running!
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo bash

# Pin a specific version (recommended for production):
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo bash -s -- v1.2.0

# Or use the BOOTSTRAP_REF environment variable:
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo BOOTSTRAP_REF=v1.2.0 bash
```

The bootstrap script:
1. Checks for root / sudo
2. Installs only `curl`, `ca-certificates`, and `tar` (no git needed)
3. Downloads this repository as a `.tar.gz` from GitHub
4. Extracts files into `/srv/ha-stack` **without overwriting** existing user data
   (`config/`, `postgres/`, `backup/`, `caddy/`, `.env`)
5. Launches the interactive install wizard (`scripts/install.sh`)

---

## Prerequisites

**On the Armbian box:**
- Docker and Docker Compose installed
- `whiptail` available (usually pre-installed)
- Root access (`sudo`)

**Network:**
- A public domain name pointing to your public IP (DNS A/AAAA record)
- Inbound TCP **443** open (and sometimes **80** for ACME challenge)
  - The wizard can attempt UPnP port mapping automatically

---

## Updating

Re-run bootstrap to pull the latest (or a pinned) version.
Existing user data and `.env` are preserved automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/VPKevin/armbian-ha-kit/main/bootstrap.sh \
  | sudo bash -s -- <new-ref>
```

Or, if the repo is already in `/srv/ha-stack`:

```bash
cd /srv/ha-stack && sudo docker compose pull && sudo docker compose up -d
```

---

## Access

| Location | URL |
|----------|-----|
| Local network | `http://<box-ip>:8123` |
| Internet (HTTPS) | `https://<your-domain>` |

---

## Backups

### Manual backup
```bash
sudo /srv/ha-stack/scripts/backup.sh
```

### Systemd timer (automatic, configured by wizard)
```bash
# Check status
systemctl status ha-backup.timer
systemctl list-timers | grep ha-backup

# View logs
journalctl -u ha-backup.service -n 200 --no-pager
```

Backup strategy:
- PostgreSQL `pg_dump` into `/srv/ha-stack/backup/` (no HA downtime)
- Restic encrypted snapshot of `config/` + `backup/`
- Retention: daily×7, weekly×10

---

## Restore / Migration

Move your installation to a new box or storage:

1. Install Docker + Compose on the new box
2. Mount or make accessible the NAS/USB Restic repository
3. Run bootstrap on the new box (see Quick Start above)
4. When the wizard asks *"restore from backup?"* — answer **Yes**
5. The wizard will:
   - Restore `config/` and `backup/` from Restic
   - Restart PostgreSQL and re-import the latest SQL dump
   - Start the full stack

> **Why SQL dump and not a binary restore?**
> SQL dumps are portable across PostgreSQL versions and avoid data-directory
> compatibility issues between machines.

---

## Troubleshooting

### HTTPS certificate not issued

| Cause | Fix |
|-------|-----|
| DNS not pointing to your IP | Check A/AAAA records |
| Port 443 not open | Forward TCP 443 on your router (or use UPnP wizard) |
| Port 80 needed by ACME | Forward TCP 80 temporarily |
| CGNAT (no inbound) | Contact ISP or use DNS-01 challenge |

```bash
# Test from outside:
curl -vk https://<your-domain>

# Caddy logs:
docker logs ha-caddy --tail 200
```

### Home Assistant 400 / proxy error

Check `/srv/ha-stack/config/configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <docker-bridge-subnet>   # set by wizard, e.g. 172.17.0.0/16
```

```bash
docker restart homeassistant
```

---

## Security

Sensitive files are **never committed** — see [.gitignore](.gitignore).
Copy [.env.example](.env.example) to `/srv/ha-stack/.env` and fill in values
before running the wizard manually.

| File | Permissions |
|------|-------------|
| `/srv/ha-stack/.env` | `600 root:root` |
| `/etc/samba/creds-ha-nas` | `600 root:root` |
| `/srv/ha-stack/restic/password` | `600 root:root` |

---

## For contributors / AI agents

See [AGENTS.md](AGENTS.md) for architecture details, invariants, and
maintenance instructions.

---

## Licence
MIT
