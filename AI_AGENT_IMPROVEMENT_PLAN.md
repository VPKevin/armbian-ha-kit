# AI Agent Improvement Plan - armbian-ha-kit

## Scope
This document is an engineering audit + improvement roadmap for maintainers and AI agents.
Objective: maximize reusability, consistency, and operational rigor while preserving project invariants from AGENTS.md.

## Project Snapshot
- Installer and lifecycle are Bash-first, wizard-driven (whiptail).
- Core orchestration: `bootstrap.sh` -> `scripts/install.sh` -> `scripts/lib/*.sh`.
- Runtime stack: Home Assistant (host network), PostgreSQL 16, optional Caddy profile.
- Backup strategy: PostgreSQL dump + Restic encrypted repositories + retention.
- Extra capabilities: NAS SMB target, USB target, restore wizard, uninstall wizard.

## Existing Features and Notable Behaviors
- Bootstrap via GitHub archive without requiring git (`bootstrap.sh`).
- Local-source bootstrap mode (`--source local` / `--local`).
- Compose source selection: default/local/url (`scripts/lib/compose.sh`).
- `.env` auto-completion from compose variable extraction (`scripts/lib/env.sh`).
- Caddy optional profile, domain/email capture (`scripts/lib/caddy.sh`).
- Restic password creation and repo initialization (`scripts/lib/restic.sh`).
- NAS/USB mount + fstab persistence + repo registration (`scripts/lib/backup_targets.sh`).
- Backup timer installation through systemd (`scripts/lib/systemd.sh`).
- Restore step wizard with back navigation (`scripts/lib/restic.sh`).
- Package install state tracking for uninstall safety (`scripts/lib/common.sh`, `scripts/lib/uninstall.sh`).

## Inconsistencies and Risks (Observed)

### Critical
1. `status_wizard` implementation is incomplete.
- File ends with placeholder `# ...existing code...` and does not render the actual status report body.
- Path: `scripts/lib/status.sh`.
- Impact: user-facing status action may appear functional but lacks expected output and diagnostics.

2. Backup script masks failures in key operations.
- `ui_run ... || true` is used for `pg_dump`, `restic backup`, and `restic forget`.
- Path: `scripts/backup.sh` lines around dump/restic execution.
- Impact: timer can report success while backups are incomplete or failed.

### High
3. Documentation advertises `--dry-run` in bootstrap, but option is not implemented.
- Mentioned in README, absent in argument parser and behavior.
- Paths: `README.md` and `bootstrap.sh`.
- Impact: broken expectation, unsafe testing assumptions.

4. Trusted proxy strategy is inconsistent between docs, AGENTS invariants, and code.
- AGENTS requires strict `trusted_proxies` in Home Assistant config.
- README troubleshooting still points to `configuration.yaml` strict proxy block.
- Code now avoids writing `http.trusted_proxies` and instead mutates compose env opportunistically.
- Paths: `AGENTS.md`, `README.md`, `scripts/lib/ha.sh`, `scripts/lib/compose.sh`, `config/configuration.yaml`.
- Impact: security model ambiguity and drift in operator behavior.

5. SMB credential path mismatch.
- AGENTS/README mention `/etc/samba/creds-ha-nas`.
- Code uses `/etc/samba/creds-ha`.
- Paths: `AGENTS.md`, `README.md`, `scripts/install.sh`.
- Impact: restore/reconfiguration confusion and operator error.

6. Restore flow does not implement the documented portable DB replay flow.
- AGENTS architecture says restore should include re-import latest SQL dump.
- Current `restore_wizard` performs restic restore only; no Postgres reset/import orchestration.
- Path: `scripts/lib/restic.sh`.
- Impact: migration may restore files but leave DB inconsistent/incomplete.

### Medium
7. `CONTEXT.md` is stale vs current code behavior (mentions trusted_proxies in `ha.sh` as if still managed in yaml).
- Path: `CONTEXT.md`.

8. UPnP is exposed in UI flags but no concrete implementation found (no miniupnpc flow, no compatibility test sequence).
- Paths: `scripts/install.sh`, no dedicated UPnP lib implementation.
- Impact: feature appears present but operationally absent.

9. Systemd unit references wrapper with no trailing newline and minimal hardening.
- Path: `systemd/ha-backup.service`, `ha-backup.sh`.
- Impact: low functional risk, but quality/hardening can improve.

10. Local `config/configuration.yaml` in repo contains a real-looking DB password string.
- Path: `config/configuration.yaml`.
- Impact: potential secret hygiene confusion (even if non-production).

## Reusability and Architecture Upgrade Plan

### Phase 1 - Correctness and Contract Alignment (Immediate)
1. Fix `status_wizard` to produce complete, deterministic status output.
2. Make backup fail fast by default:
- Remove silent `|| true` on critical dump/backup/forget operations.
- Add explicit error summary and non-zero exit for systemd observability.
3. Align docs with implementation or implement missing features immediately:
- Either implement `--dry-run` in bootstrap or remove docs.
- Unify trusted proxy policy and update AGENTS + README + code accordingly.
- Unify SMB credential canonical path.
4. Implement restore end-to-end contract:
- Restore files from restic.
- Identify latest SQL dump.
- Recreate/restart postgres cleanly.
- Import SQL dump and verify recorder schema access.

### Phase 2 - Modularity and Reuse (Short Term)
1. Introduce a shared constants module (`scripts/lib/constants.sh`):
- Paths, filenames, service names, backup retention policy, credential locations.
2. Introduce a shared command wrapper module:
- `run_cmd`, `run_or_fail`, structured logs, dry-run compatibility.
3. Split business logic from UI prompts:
- Keep pure functions for operation logic.
- Keep `whi_*` only in thin interaction layer.
4. Replace ad-hoc compose file mutation with stable strategy:
- Template merge or yq-based patching with idempotent tests.

### Phase 3 - Test Rigor and CI (Short/Mid Term)
1. Add automated checks in CI:
- `shellcheck`, `shfmt -d`, `bash -n`, bats suites.
2. Add behavior tests for invariant flows:
- install without NAS/USB,
- NAS only,
- USB only,
- restore with DB replay,
- back/abort navigation scenarios from AGENTS.
3. Add fault-injection tests:
- unavailable repo,
- wrong restic password,
- mount failures,
- postgres container not running.

### Phase 4 - Operational Hardening (Mid Term)
1. Harden systemd service:
- explicit user/group, timeout, restart policy for timer job output handling.
2. Add backup health verification command:
- last dump age,
- last restic snapshot per repo,
- alert if SLA exceeded.
3. Add safe rollback and idempotency checks for fstab edits and compose updates.

## Target Reusability Principles
- Single source of truth for constants and paths.
- Pure function modules for core operations; UI as adapter layer.
- No silent failures on critical data operations.
- Every documented feature must have executable coverage.
- Every invariant in AGENTS must map to at least one automated test.

## Suggested File-Level Refactor Map
- `scripts/install.sh`: orchestration only, minimal logic.
- `scripts/lib/constants.sh`: path/env/service constants.
- `scripts/lib/ops_backup.sh`: dump/restic/retention operations.
- `scripts/lib/ops_restore.sh`: restore + DB replay operations.
- `scripts/lib/ops_mount.sh`: NAS/USB mount/fstab handling.
- `scripts/lib/ui_*`: isolated whiptail interaction modules.
- `tests/`: one bats file per operation domain + navigation contract tests.

## Definition of Done (Quality Gate)
- All critical/high inconsistencies above resolved.
- AGENTS, README, and code behavior are consistent.
- Full test suite runs in CI and locally.
- No secret-like values tracked in repository files intended as templates.
- Backup and restore flows are validated end-to-end on a disposable environment.

## Priority Execution Order
1. Status completeness + backup failure semantics.
2. Restore portability contract (SQL replay).
3. Documentation/contract alignment (`dry-run`, proxy, SMB path, UPnP truth).
4. Modularization and test expansion.
5. Operational hardening and observability.
