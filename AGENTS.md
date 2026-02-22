# AGENTS.md — Developer & Agent Maintenance Guide

This file contains the technical invariants, architecture notes, and maintenance
instructions for contributors and AI coding agents working on **armbian-ha-kit**.
User-facing documentation lives in [README.md](README.md).

---

## Architecture (Docker stack)

Main services:

| Service | Image | Notes |
|---------|-------|-------|
| **homeassistant** | `ghcr.io/home-assistant/home-assistant:stable` | `network_mode: host` |
| **postgres** | `postgres:16` | External DB; enables live backups |
| **caddy** | `caddy:2` | Reverse proxy, auto-TLS (Let's Encrypt) |

`homeassistant` runs in `network_mode: host`, so Caddy (in bridge mode) speaks
to `127.0.0.1:8123`. The `trusted_proxies` setting **must** list the Docker
bridge subnet — detected at install time via
`docker network inspect bridge`.

---

## Installation path

Everything lives under `/srv/ha-stack`:

```
/srv/ha-stack/
  docker-compose.yml
  Caddyfile
  bootstrap.sh         ← download & bootstrap entry point
  .env                 ← created by wizard (chmod 600, root-only)
  config/              ← Home Assistant data  [never commit]
  postgres/            ← PostgreSQL data dir  [never commit]
  backup/              ← SQL dumps            [never commit]
  caddy/               ← Caddy runtime data   [never commit]
  restic/              ← password + repos.conf
  scripts/
    install.sh         ← interactive wizard
    backup.sh
  systemd/
    ha-backup.service
    ha-backup.timer
```

---

## Invariants (must always be true)

- Install wizard is `whiptail`-driven and runs end-to-end without internet except for Docker image pulls.
- Backups run without stopping HA — PostgreSQL dump (`pg_dump`) while running.
- Restic retention: `--keep-daily 7 --keep-weekly 10 --prune`.
- Restore uses SQL dump, **not** a binary copy of the Postgres data directory (portability & version-safety).
- Secrets are **root-only on disk**, never in the repo:
  - `/srv/ha-stack/.env` — chmod 600
  - `/etc/samba/creds-ha-nas` — chmod 600
  - `/srv/ha-stack/restic/password` — chmod 600

---

## Sensitive points

- **`trusted_proxies`**: detect Docker bridge subnet via
  `docker network inspect bridge`; write a **strict** CIDR, not `0.0.0.0/0`.
- **SMB credentials**: store in `/etc/samba/creds-ha-nas` chmod 600;
  fstab entries must be idempotent (no duplicate lines).
- **USB fstab**: use UUID, not device name; wizard selects partition via `lsblk`.
- **UPnP**: always test-map first; if test fails, show manual instructions.
- **bootstrap.sh idempotency**: never clobber `config/`, `postgres/`, `backup/`,
  `caddy/`, or `.env` when re-running bootstrap on an existing installation.

---

## Minimum tests after any change

1. `shellcheck` on every Bash script.
2. Wizard smoke-test on a VM/SBC (arm64):
   - no-NAS / no-USB mode
   - NAS (SMB) mode
   - USB mode
   - restore mode
3. Caddy certificate issuance (staging ACME is fine).
4. Backup timer: `systemctl status ha-backup.timer` + manual run.

---

## Roadmap / known improvements

- Auto-detect USB filesystem type and write the correct `fstab` `fstype`.
- DNS-01 support (Cloudflare / OVH) to avoid needing port 80.
- Strict 443-only mode when TLS-ALPN-01 is reliably validated.
- Optional Docker secrets / sops-age for stricter secret management.
