# Session Handoff: 2026-09-17 translator, doctor, permissions, and repo move (Claude session)

## 1. Last commit

- `e373713` `docs(issues): destructive-command-guard substring false positive on sandbox paths (R-203 incident)`, tip of `main`. Local `main` is 9 commits ahead of `origin/main` (last push ended at `2cd9219`); NOT pushed, awaiting the user's word per the batch-push preference.
- A parallel Codex session owns the primary checkout on branch `docs/public-harness-and-backlog` with six staged spec/handoff deletions and unstaged README/SETUP edits, restored exactly after an accidental commit bundling was unbundled; that session resumes it cleanly.

## 2. Production state

- Repo moved to `/Users/iangreenough/Desktop/code/personal/tools/agent-governance` (old `~/dev` deleted; `.sync-source` restamped; every path-coupled fixture decoupled to remote-identity checks).
- `~/.claude` synced from `main` at `41ea2ba`-era content; both fixture suites green (55 enforce + 15 hooks files); `claude/enforce/doctor.sh --root .` reports 0 fail (2 warns: accepted-unknown settings key, and the stale-live-hooks drift below).
- `translate/codex.mjs` regenerates `codex/` from `claude/` sources; `--check` gates CI and the tracked pre-push sample; PORT-STATUS counts are derived (47 of 50 registrations port).
- Permissions: `Bash(bash *)`/`Bash(sh *)` ask rules narrowed to the `-c` forms; 13 transcript-frequent allow entries added (two python3 interpreter exceptions and `./sync.sh` recorded in ISSUES.md).
- `model-switch-guard.sh` live on PreModelSwitch (systemMessage warns on up-ladder switches).

## 3. What shipped (all on `main`, squash-merged per feature)

- **Hygiene audit remediation** (`0dda163` + `50f0008`): ~30 findings across dead code, contradictions (R-907 scoping, PreModelSwitch activation, tier-table dedup, pre-monorepo topology), README counts and pointers, naming (gate/reminder rename, eslint tag convention, kebab-casing), plus `secret-scan.test.sh` and `build-cheatsheets.test.sh`.
- **Codex translator** (`8593356`): 9 reviewed tasks plus a fix wave; orphan detection, sound TOML escaping, port map as checked-in data, first honest regeneration of `codex/`.
- **Doctor** (`41ea2ba`): `claude/enforce/doctor.sh`, 37 fixture checks; offline schema validation (vendored SchemaStore schema + accepted-keys contract), hook wiring checks branching on verifier OUTPUT (a Critical always-pass loop was caught and fixed), environment probes, `--full` suites, `--release` gate pinning the PAT blocker (B-4) and escalating unevaluable checks; home paths redacted in output; mangled `-Users-<user>-` leak pattern added.
- **Docs/decisions**: source-neutral sync spec parked with a harvest note (`94de2b6`); username redaction in tracked files (`70852ef`); guard false-positive ISSUES entry (`e373713`); codex/cursor README rewrites; hardening spec cherry-picked to `main` (`2cd9219`).

## 4. Pending (by urgency)

- **User, first (P0-2, unchanged)**: rotate the GitHub PAT and purge the transcripts per `claude/ISSUES.md` PENDING USER ACTION (paths now redacted there; reconstruct locally per the note). The doctor's `release-blockers` check stays red until this closes. ~10 minutes.
- **User decision**: push `main` (9 commits; R-106 scan was clean at the last check, re-run at push).
- **Codex-session coordination**: its branch `docs/public-harness-and-backlog` holds staged deletions of five shipped/parked specs plus this handoff file and a README/SETUP restructure (RECIPES.md, docs/model-targets.md); review before it lands. Its cross-model-dialogue spec (`cde9b45`/`4bc8746`) is unreviewed. Its earlier config-audit workstream list is largely absorbed by the hardening spec (schema/doctor DONE; sandboxing and statusLine are Plan 2; prune/defaults are Plan 3).
- **Queued workstreams**: hardening Plan 2 (sandbox config, status-line script, resume drift: B-2/B-3/B-5/B-8) and Plan 3 (installer, capability matrix, override markers, docs tiers: B-7/B-9..B-12/B-14); the cursor-exporter harvest (`translate/cursor.mjs` + B-9 file classification) queued behind them per the parked spec's Status section.
- **Non-blocking maintenance**: prune stale renamed hook copies from live `~/.claude/hooks` (they draw the doctor's `hook-integrity` warn; deleting live files needs the user's go-ahead); repoint `hooks/install-git-hooks.sh` post-monorepo (filed in ISSUES.md); the full `--release` runtime is suite-dominated (9+ minutes in a cold worktree, acceptable for an operator command, worth a fast-mode thought if it grates); ISSUES.md P3s from today (guard substring false positive, port-pipeline cursor remainder).
- **Process lesson recorded** (project memory): five fixture defects this session originated in controller-written plan code (shell semantics, contract assumptions); plan code needs its own review pass before execution. A dispatched subagent evaded a denied guard once (audited benign); every dispatch now carries a denied-guard-is-a-hard-stop clause.

## 5. Next session: read first

- `git log --oneline origin/main..main` (the 9 unpushed commits).
- `claude/ISSUES.md` Open section (PAT, guard false positive, cursor remainder, installer repoint).
- `claude/docs/superpowers/specs/2026-09-17-claude-config-public-hardening-design.md` (Plans 2-3 come from its remaining criteria) and the parked source-neutral spec's Status section (harvest scope).
- `claude/enforce/README.md` Doctor section before touching doctor.sh.
