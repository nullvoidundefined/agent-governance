# Session Handoff: 2026-09-17 R-003 synced harness, then the local-main reconciliation

## 1. Last commit

- PR #5 (R-003, `harness-sync.sh`, the repo-setup harness item, checksum copy in `sync.sh`) squash-merged to `main` as `7b489d1`.
- Branch `claude/intelligent-wozniak-gvgw7m`, restarted from `7b489d1`, carries one merge commit: `origin/reconcile/local-main` (the maintainer's 15 local `main` commits that never reached GitHub: `doctor.sh`, the session-safety hardening with the status-line HUD and resume drift detection, R-907, the parked cross-model and source-neutral sync specs, issue entries) merged onto the merged `main`. Three conflicts resolved: `claude/ISSUES.md` (union, cursor item combined), `claude/README.md` (counts refreshed, both hook descriptions kept), `hook-hashes.txt` (regenerated). Squash merge per R-512 once green and authorized (R-514).
- The maintainer's old local `main` is preserved as `backup/local-main-2026-09-17` on their machine and as `origin/reconcile/local-main`.

## 2. Production state

- Both fixture suites green on this tree (85 fixtures: the new `harness-sync.test.sh` and the extended `repo-setup.test.sh` included), `node translate/codex.mjs --check` current, `hook-hashes.txt` regenerated (188 entries), `shellcheck --severity=error` clean over the new and changed scripts.
- `sync.sh` now passes `--checksum` to rsync: a live file edited to the same size within the same second as the tracked one was skipped by the size-and-mtime quick check, which the fixture exposed as a race.
- The live `~/.claude` on the maintainer's machine still predates PR #3 and this PR until `./sync.sh` runs there once; after that, `harness-sync.sh` re-syncs drift at every SessionStart on its own.
- In this container nothing was synced into the session's own `~/.claude`; the hook was exercised only against sandbox checkouts and fake homes.

## 3. Session metrics

- Commits this session: 6
- Files changed: 33
- Rework commits (file touched by 2+ commits): 0
- Velocity flag: NORMAL

## 4. What shipped

- **R-003** norm line, Spec, and advisory manifest entry `hook:harness-sync`: every session runs under the synced harness; a session that cannot reach a checkout says so once and treats every rule as manual.
- **`hooks/harness-sync.sh`**: SessionStart, first in the group in `claude/settings.json` and in both ports; compares every tracked `claude/` file against the live tree, runs `./sync.sh` when any is absent or differs, installs `rsync` (apt) and the enforce dependencies (npm) in a remote container, emits `additionalContext`, exits 0 on every path.
- **Repo-level `.claude/settings.json`** in agent-governance runs the hook with `$CLAUDE_PROJECT_DIR`, so a cloud session on this repository bootstraps its harness before anything else loads; `.claude/worktrees/` is gitignored.
- **`repo-setup` `harness` item**: `--harness-repo <url>` (default: origin of the `.sync-source` checkout); writes `.claude/hooks/harness-bootstrap.sh` from a template and registers it in `.claude/settings.json`, merging with `jq` when the file exists; the SKILL.md baseline table and commit step name the two files.
- **Docs**: `enforce/README.md` section on the synced harness, `claude/README.md` session-start paragraph and hooks tree, root `README.md` sentence.

## 5. Pending

- **User, now (P0-2, unchanged since 2026-09-16)**: rotate the GitHub PAT and purge the transcripts named under PENDING USER ACTION in `claude/ISSUES.md`.
- **User, now**: authorize the squash merge of PR #5 when `enforce` is green, then `./sync.sh` on the maintainer's machine once; from then on the hook keeps `~/.claude` current.
- **User, then**: `bash ~/.claude/skills/repo-setup/scripts/setup.sh nullvoidundefined/agent-governance --check --ci-context fixtures`, and apply what it reports; the `harness` row reports `OK` here because the repo-level settings run `harness-sync.sh` directly. Needs an admin `gh` token.
- **User, one command**: delete the four renamed leftovers from the live tree (`~/.claude/enforce/eslintOptions.mjs`, `renderLexiconSpec.mjs`, `resolveOutgoingBase.sh`, `~/.claude/hooks/single-file-folder-gate.sh`); `sync.sh` never deletes.
- **User, before the ticket skill can do anything**: pick a tracker and copy `claude/TICKET-TRACKER.template.json` to `~/.claude/TICKET-TRACKER.json` (no ticket key exists for this session's work; the degraded path of R-605).
- **Next session, once a tracker exists**: dry-run `open` on a real task and check the field mapping against the live database before it writes for real; the first few tasks fall back to the R-906 heuristic because `estimate <tier>` quotes no number from history below five comparable closed tickets.
- **Audit residue, all in `claude/ISSUES.md`**: the 2026-09-17 engineering audit's P2 and P3 items, none blocking; read P2-1 first (a positional argument to `translate/codex.mjs` is silently ignored and `--write` then prunes the real tree), then the note that `translate/*.mjs` cannot be hashed, since it sits outside the surface `sync.sh` copies.
- **Deferred by design**: the mechanical tier for R-605 and R-606; a hook can only read a local signal, and the only candidate is a per-branch link file whose shape depends on the tracker chosen (recorded in the spec's Non-goals).
- **P2**: the rest of the cursor port item in `claude/ISSUES.md` (rules, agents, commands, `PORT-STATUS.md`); the skills half is done, and the decision is recorded there: a one-directional `translate/cursor.mjs` exporter harvested from the parked source-neutral sync spec.
- **P3**: audit X-4 (which skills announce at start) is undecided; `/skill-doctor` has not been run; `$ARGUMENTS` substitution inside the protocol skill's `` ! `` block is unverified on the real build.

## 6. Next session: read first

- `claude/hooks/harness-sync.sh` header and `claude/rulebook/reference.md` under R-003 before touching SessionStart or `sync.sh`.
- `git log --oneline 3138809..HEAD` (one commit per finding).
- `claude/skills/repo-setup/SKILL.md` before applying it anywhere; the `harness` row, `--harness-repo`, and `--ci-context`.
- `docs/audits/2026-09-17-skills.md`, the Implementation status section, for the audit follow-ups still open.
