# Issues

Deferred P2/P3 work for the `~/.claude` rule system, per R-802/R-601. One line per item; delete on resolution.

## Open

### Accepted risks (deliberate, revisit on incident)
- ACCEPTED (2026-08-01, Ian): the lenient Bash allow list is restored; `bash -c`/interpreter entries bypass the deny and ask patterns (2026-07-31 security audit P0-2). Strict variant preserved in `enforce/strict-permissions.json`; revisit if an incident or shared-machine use changes the calculus.
- NOTE (2026-08-01): pre-rewrite commit SHAs cited in older audit reports and log entries no longer resolve; git history was rewritten on 2026-08-01 (see Resolved). GitHub may serve old objects from caches or forks for a while; request GC via support if that matters.
- PENDING USER ACTION (2026-08-01): judge tier is fully wired to the keychain (`claude-judge-api-key`); it activates the moment the rotated key is stored via `security add-generic-password -a "$USER" -s claude-judge-api-key -w` in a terminal outside any session.

### From the 2026-07-31 full-harness audits (P2/P3)
- P2 (security): `destructive-db-guard.sh` blanket `localhost` early-return misses SSH-tunneled remote DBs; argv-only scope. Known limitation; needs a design, not a patch.
- P2 (security): `ntfy-notify.sh` posts to an unauthenticated public ntfy topic; moved to HTTPS 2026-08-01, but topic auth and payload minimization remain open.
- P2 (engineering): no PreToolUse guard on `Read`/`Grep`/`Glob` for R-102 secret paths; the read side is honor-system.
- P2 (engineering): `enforce/` npm advisories (brace-expansion, js-yaml) and ESLint a major behind; `npm audit fix` applied 2026-08-01, ESLint major upgrade deferred.
- P2 (criticism): no false-block measurement exists; the new fire log records fires, not wrongly-blocked work. Add a `[false-block]` marker convention to memory entries.
- P2 (criticism): `global-memory/` and `rulebook/` carry redundant, drifting copies of collaboration rules (`PROTOCOL.md:33` vs `INDEX.md`); consolidate to one source.
- P2 (criticism): `settings.json` has no schema validation; a typo silently drops a hook registration. hook-integrity + enforcement-guard cover parts; a settings lint remains open.
- P3 (criticism): no ID-closure guard for R-7xx/8xx/9xx rule references.
- P3 (engineering): `commit-message-guard` false-positive class on verification commands containing `git commit` text; single instance.
- P3 (2026-07-31 Ruby/Go parity): `enforce/golangci-enforce.yml` is written against the golangci-lint v1 schema and could not be validated locally (no Go toolchain); validate and migrate to the v2 schema if needed on the first real Go project. The gate fails open on unparseable output either way.
- P2 (2026-07-31 engineering audit): commit 266d05e is an unpaired `fix:` touching only `enforce/eslint.config.mjs` with no test; single instance, R-403 pattern note.
- P3 (2026-07-31 engineering audit): `structure-gate.sh` applies the TS-only R-314 nested-`__tests__` deny message to Python test filenames; untested edge, low likelihood.
- P3 (2026-07-31 engineering audit): `push-ruff-gate.sh` and `push-eslint-gate.sh` split the changed-file list with `xargs`, mishandling a space-containing path; pre-existing pattern shared by both gates.
- P3 (2026-07-03 engineering audit): session-lifecycle and notifier hooks (`session-start.sh`, `pre-compact.sh`, `ntfy-notify.sh`) have no fixture tests; they are environment-heavy (session payloads, network) and need harness design before testing is honest rather than performative.
- P3 (2026-07-03 engineering audit): `Enforcement: judge` is the template token for llm-judge-tier rules; R-320/R-322 additionally name their advisory reminder hooks. Reviewed and kept as-is: the bare token is template-conformant, and the suffixes carry real information. Recorded here so the style question does not resurface as a finding.

## Resolved

- 2026-08-01: published git history rewritten with git-filter-repo to purge the two R-106 breaches (a local home path and a client-identifying name); verified zero occurrences in a fresh clone of origin. Pre-rewrite SHAs no longer resolve.
- 2026-08-01: full-harness audit remediation. Security P0s: push gates no longer execute target-repo code (f47ca92); interpreter allow-list escape closed (acef36d), then deliberately reverted to lenient by Ian (f6c8d88, see Accepted risks). Engineering P0: plaintext API keys purged from all transcripts and history.jsonl (rotation Ian-side). Criticism P0s: inert judge tier now warns at session start with severity lookup fixed (e91142f); mechanical fire telemetry replaces the dead hand-typed log (7bdaec2). P1s: handoff loading fixed with SHA verification, chained add+commit guard bypass closed, redact-output semantics honest, hook hash integrity guard, publish guard fails closed, pre-compact contradictions removed, pre-push now runs both suites (252910e).
- 2026-07-31: structure-gate never fired for Python's app/-rooted layout (P1); R-516 guard and manifest test blind to ruff:* enforcers (P1); hook-latency chain missing push-ruff-gate (P2) -> fixed with fixture tests in the post-audit commit.
- 2026-07-03: agents/ audit-role files cited pre-renumber rule IDs (P1) -> migrated in 9c01327.
- 2026-07-03: ten guard-enforced rules missing manifest entries, closure unchecked (P1) -> closure test + entries in 77a8512.
- 2026-07-03: phantom R-503 manifest enforcer; R-505 subject format enforced but not codified (P2) -> 7ffaffc.
- 2026-07-03: seven blocking/advisory guards untested (P2) -> fixture tests + hooks/tests runner in d9a7bd8.
