# Hardening PR 6: backup before migration

Plan: hardening control 5 (backup before migration), approved by the owner
2026-10-04 with the other five PRs. Sibling specs:
`docs/specs/2026-10-04-harness-hardening.md` (B-17: agent migrations against
production are already denied).

**Risk:** high (destructive data operations and migrations).

## Goal

No migration reaches a shared database without a restorable snapshot taken
moments before it, and the snapshot is known to restore. Agents already cannot
migrate production (B-17); this PR gives the human path a wrapper that refuses
to migrate without a fresh snapshot, routes agent migrations against preview
and testing targets through the same wrapper, and adds a scheduled restore
drill.

## Threat model

- **Attack to stop:** a migration (agent-run against preview/testing, or
  human-run against production) destroys data and no recent snapshot exists,
  or the snapshot exists but does not restore.
- **Ceiling:** a human running raw migration commands bypasses the wrapper; a
  hook cannot prove a snapshot is fresh for commands outside it. The control
  is partly procedural, and the docs say so.

## The wrapper

`claude/enforce/db-migrate-safe.sh --provider <pg|neon|rds> --target <name>
[provider options] -- <migration command...>`

- `pg`: `pg_dump --format=custom` of the database named by the environment
  variable given in `--url-env <VAR>` (the variable's name, never its value, is
  on the command line) to `--backup-dir` (default
  `${MIGRATE_BACKUP_DIR:-$HOME/.local/state/agent-migrations/backups}`), file
  `<target>-<UTC timestamp>.dump`, mode 0600; then `pg_restore --list` on the
  file must succeed.
- `neon`: `neonctl branches create --project-id <id> --parent <branch>
  --name pre-migrate-<UTC timestamp>`; the new branch id is the snapshot id.
- `rds`: `aws rds create-db-snapshot --db-instance-identifier <id>
  --db-snapshot-identifier pre-migrate-<target>-<UTC timestamp>`, then
  `aws rds wait db-snapshot-available` for it.

## Acceptance criteria

- M-1: the wrapper takes the snapshot first and runs the migration command
  only when the snapshot step (and, for `pg`, the `pg_restore --list` check)
  exits 0. Any snapshot failure exits nonzero with a message naming the
  provider step that failed, and the migration command never starts.
- M-2: it appends one JSON line per run to
  `${MIGRATE_LOG_DIR:-$HOME/.local/state/agent-migrations}/migrations.jsonl`:
  `ts`, `provider`, `target`, `snapshot` (path, branch id or snapshot id),
  `command` (the migration argv joined, redacted like the audit log),
  `snapshot_status`, `migration_status`. The line is written even when the
  snapshot fails.
- M-3: it never prints or logs a connection string, password or token; the
  `pg` provider reads the URL from the named variable only.
- M-4: bad usage (unknown provider, missing `--target`, no `--` and command,
  `--url-env` naming an unset variable) exits 2 with usage and runs nothing.
- M-5: the infra guard routes agent migrations (the B-17 migration commands)
  against a target marked `preview` or `testing` in `.enforce.json`: run bare,
  they deny with a message giving the wrapper form; run as the wrapper's
  command, they pass. Against production they deny either way (B-17
  unchanged). Against a local target nothing changes.
- M-6: the unknown-wrapper ask (B-18) does not fire for
  `db-migrate-safe.sh` itself; its migration command after `--` is judged as
  if run directly, except for M-5's pass.
- M-7: a workflow template
  `claude/templates/restore-drill.yml` (a GitHub Actions workflow, weekly
  schedule plus manual dispatch) restores the latest snapshot into a
  throwaway Postgres service container and runs a row-count smoke query; it
  pins every action by full commit SHA and holds no secret values (secrets
  by `${{ secrets.NAME }}` only). A test checks it parses as YAML, pins
  actions, and has the schedule and the smoke step.
- M-8: `rules/CLOUD-DEPLOYMENT.md` and `rules/stacks/DATABASE.md` name the
  wrapper as the only production migration command and point at the restore
  drill template (regenerated with `node translate/all.mjs --write`).
- M-9: provider calls are tested with stub `pg_dump`, `pg_restore`,
  `neonctl` and `aws` executables on `PATH`; no test touches a real database
  or cloud account.
- M-10: guard corpus rows for M-5 and M-6 run through the Codex and Cursor
  adapters with the same decisions; every existing row keeps its decision.

## Non-goals

- More providers (PlanetScale, Supabase, Cloud SQL) until a product needs one.
- Running the restore drill from this repo; it is a template for product repos.
