# Session Handoff: 2026-09-17 R-003 synced harness, harness-sync hook, repo-setup bootstrap

## 1. Last commit

- Branch `claude/intelligent-wozniak-gvgw7m`, restarted from `3138809` (the squash of PR #3, the skills audit) after that PR merged. Six commits follow it: `6436141` fix(sync) checksum copy, `b9fcb4a` feat(hooks) harness-sync, `d2a746c` docs(rules) R-003, `a0ba085` feat(repo-setup) harness item, then a fix so the harness repository itself reports `harness OK`, and this handoff. PR #5 is open against `main`; squash merge per R-512 once the `enforce` check is green and the user authorizes it (R-514).
- The branch was force-pushed with lease once, because its pre-merge history diverged from the remote after the restart; nothing unmerged was dropped.

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
- **P2**: the rest of the cursor port item in `claude/ISSUES.md` (rules, agents, commands, `PORT-STATUS.md`); the skills half is done.
- **P3**: audit X-4 (which skills announce at start) is undecided; `/skill-doctor` has not been run; `$ARGUMENTS` substitution inside the protocol skill's `` ! `` block is unverified on the real build.

## 6. Next session: read first

- `claude/hooks/harness-sync.sh` header and `claude/rulebook/reference.md` under R-003 before touching SessionStart or `sync.sh`.
- `git log --oneline 3138809..HEAD` (one commit per finding).
- `claude/skills/repo-setup/SKILL.md` before applying it anywhere; the `harness` row, `--harness-repo`, and `--ci-context`.
- `docs/audits/2026-09-17-skills.md`, the Implementation status section, for the audit follow-ups still open.
