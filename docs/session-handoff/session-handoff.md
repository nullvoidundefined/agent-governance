# Session Handoff: 2026-09-17 source-neutral sync planning

## 1. Last commit

- Current branch: `main`. Run `git log -1 --oneline` first; the expected tip subject is `docs: update handoff for source-neutral sync`. NOT pushed by Codex in this turn.
- New planning commit in this session: `bb64ffe` `docs: spec source-neutral governance sync`, adding `claude/docs/superpowers/specs/2026-09-17-source-neutral-governance-sync-design.md`.
- Prior handoff context below still describes the unmerged `claude/hygiene-audit-2026-09-17` workstream and should be treated as inherited state, not as the current branch tip.

## 2. Production state

- Both fixture suites fully green post-remediation: 53 enforce + 15 hooks = 68 fixtures (two added this session). `~/.claude` synced from the branch tip via `./sync.sh`, so the live harness runs the branch's hooks; if the branch is discarded instead of merged, re-run `./sync.sh` from `main`.
- `model-switch-guard.sh` is LIVE for the first time: registered under `PreModelSwitch` (a real event, verified against the current hooks docs; the repo's prior "not a real event" claim was wrong), warning via `systemMessage` on up-ladder switches.
- `codex-test-author-guard.sh` now exempts `agent_type` test-author; R-907 is scoped to inline authoring (user decision this session).

## 3. What shipped

- **Source-neutral sync spec**: `claude/docs/superpowers/specs/2026-09-17-source-neutral-governance-sync-design.md` defines the replacement for the Claude-as-source assumption. It treats `claude/`, `codex/`, and `cursor/` as peer edit surfaces, introduces a neutral governance model with per-surface importers/exporters, and uses the existing Codex translator as the compatibility baseline to generalize. Key criteria: `--from claude` preserves current Codex output byte-for-byte; `--from codex` round-trips importable Codex edits back to Claude and forward to Cursor; Cursor may start as legacy/gap-reporting; generated and hand-authored ownership is explicit; sibling edit conflicts block writes.
- **Inherited hygiene-audit context**: prior branch work fixed repo hygiene, PreModelSwitch/R-903 contradictions, task-start/cost docs, codex/cursor README drift, naming cleanup, fixture counts, and audit pointer docs. Read the prior commits if resuming that branch.

## 4. Pending (by urgency)

- **User, now (P0-2, unchanged from 2026-09-16)**: rotate the GitHub PAT and purge the transcripts listed in `claude/ISSUES.md` PENDING USER ACTION. ~10 minutes.
- **Claude Code handoff from 2026-09-17 current-practice config audit**: review and implement the following as a new discrete workstream, with the web-research basis in the user's Codex thread. Priority order:
  - P1: add Claude Code sandboxing to `claude/settings.json` so Bash subprocesses inherit filesystem and network boundaries. Current config blocks secret reads through `Read(...)` deny rules but has broad Bash allows (`npm`, `pnpm`, `gh`, `git`, `find`, `sed`) and no `sandbox` block; official docs and security-heavy community configs treat permissions plus sandboxing as defense in depth.
  - P1: keep the existing PAT rotation/transcript purge as the first remediation. It is already tracked in `claude/ISSUES.md`; do not let lower-risk harness work displace known leaked credential cleanup.
  - P2: add settings schema validation. `claude/settings.json` lacks `$schema`, and `claude/ISSUES.md` already tracks the missing full key-level lint. Use the published Claude Code settings schema, then add a fixture or documented `claude doctor` verification path that tolerates newly documented keys when the schema lags.
  - P2: add a `statusLine` so sessions show context usage, model, branch, dirty state, elapsed time, and cost. Claude's current best-practices docs name context saturation as the main performance constraint; this config currently has no visible context/cost HUD.
  - P2: prune or demote always-loaded root instructions. `claude/CLAUDE.md` is disciplined and under the cap, but it is still dense; move repeatable procedures into skills, path-scoped rules, or hooks where possible, leaving the root file as an index plus non-negotiables.
  - P3: make modern hardening defaults explicit where they match this operator's threat model: `enableAllProjectMcpServers: false`, subagent depth/concurrency bounds, telemetry preferences, cleanup retention, and any plugin marketplace trust decisions. Add only keys supported by the installed Claude Code version and record deliberate omissions.
- **User decision**: merge `claude/hygiene-audit-2026-09-17` (squash per R-512, or merge preserving the 16 per-finding commits; the user chooses), then push.
- **Next design/implementation decision**: source-neutral sync supersedes the current `claude/`-as-source posture for future propagation work. Existing `translate/codex.mjs` should not be deleted; it becomes the byte-parity compatibility baseline until `translate/governance-sync.mjs --from claude` can prove the same Codex output.
- New ISSUES.md P2: decide resurrect-versus-retire for the codex/cursor port pipeline (~60 stale "GENERATED by build.mjs" headers, PORT-STATUS at 42 hooks vs the current 49, frozen `.claude-port.json` hashes).
- P3 findings deliberately not fixed: `-guard` suffix does not distinguish ask-only from deny-capable hooks; "guard" used generically in enforce/README prose; `audits/` stub layer removable only after grepping downstream repos for `claude/audits/` path references; optional modernizations from the best-practices review (@-file imports in CLAUDE.md, `paths:` frontmatter on stack-scoped skills, `effort`/`permissionMode` on audit agents).
- Unexplained once (second anomaly of this class in this repo): a python heredoc write to `skills/structure-conventions/SKILL.md` printed success but left the file untouched (mtime unmoved); the identical retry worked. Writes were read-back-verified afterward. If it recurs, suspect the same parallel-session interference logged 2026-09-16.

## 5. Next session: read first

- `git log --oneline main..claude/hygiene-audit-2026-09-17` (the 16 per-finding commits).
- `claude/ISSUES.md` Open section (PAT rotation, port-pipeline decision).
- `claude/docs/superpowers/specs/2026-09-17-source-neutral-governance-sync-design.md`, `translate/codex.mjs`, `translate/codex-port-map.json`, `codex/README.md`, and `cursor/README.md` before touching translator or propagation architecture.
- `claude/settings.json`, `claude/CLAUDE.md`, `claude/enforce/README.md`, and the official Claude Code docs for sandboxing, settings, hooks, and best practices before starting the current-practice config-audit workstream.
- `claude/rulebook/cost.md` R-907 and `claude/hooks/codex-test-author-guard.sh` (the new inline-only scoping) if doing TDD slice work.
