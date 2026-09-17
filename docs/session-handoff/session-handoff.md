# Session Handoff: 2026-09-17 Claude config audit handoff

## 1. Last commit

- Current branch: `claude/codex-translator`. Run `git log -1 --oneline` first; the tip commit is the docs-only commit `docs: add Claude config audit handoff`, which adds the 2026-09-17 current-practice Claude Code config audit findings to the handoff so Claude Code can pick up the remediation work. NOT merged, NOT pushed.
- Prior handoff context below still describes the unmerged `claude/hygiene-audit-2026-09-17` workstream and should be treated as inherited state, not as the current branch tip.

## 2. Production state

- Both fixture suites fully green post-remediation: 53 enforce + 15 hooks = 68 fixtures (two added this session). `~/.claude` synced from the branch tip via `./sync.sh`, so the live harness runs the branch's hooks; if the branch is discarded instead of merged, re-run `./sync.sh` from `main`.
- `model-switch-guard.sh` is LIVE for the first time: registered under `PreModelSwitch` (a real event, verified against the current hooks docs; the repo's prior "not a real event" claim was wrong), warning via `systemMessage` on up-ladder switches.
- `codex-test-author-guard.sh` now exempts `agent_type` test-author; R-907 is scoped to inline authoring (user decision this session).

## 3. What shipped (one commit per finding)

- **Audit**: 5 subagents reviewed dead code, layer necessity, naming, README/setup drift, and current-docs best practices; ~30 findings, all P0-P2 fixed this session. No dangling references existed; layers all judged load-bearing.
- **Contradictions**: R-907 scoped to inline with guard exemption + fixture (RED then GREEN); PreModelSwitch activation (settings.json, manifest R-903 entry, cost.md, ISSUES.md); task-start made canonical for the R-901/R-903 tables (cost.md now points, its 3-tier table with nonexistent role names removed); pre-monorepo `~/.claude`-as-repo phrasing retired from R-001/R-106/R-511/R-514/R-601 in reference.md and CLAUDE.md (R-001 step 4 now checks `git -C "$(cat ~/.claude/.sync-source)" status -s`).
- **Dead code**: nested `claude/.github/` deleted; 5 shipped specs deleted per cleanup-specs-plans (2026-09-12 monorepo spec kept, it is referenced by sync.sh and root README); codex/cursor READMEs rewritten off the retired `build.mjs` pipeline.
- **Docs**: claude/README counts corrected (9 eslint rules, 72 rules/119 lines, 68 fixtures, 50 hook registrations across 8 events), `audits/` consistently described as pointer stubs with `agents/audit-*.md` canonical (README + rulebook/audits.md), docs/ tree and bootstrap and the already-shipped consolidation section rewritten to monorepo reality; structure-conventions "what stayed" list replaced by its generating rule; build-cheatsheets got a fixture + tooling-hook convention note in enforce/README.
- **Naming**: `single-file-folder-gate` renamed `-reminder` (only non-blocking -gate; codex/cursor hooks.json adapters updated, they invoke hooks by name); `eslint:lexicon-naming` tag aligned to `naming-lexicon` file with the tag convention documented in enforce/README; `secret-scan.test.sh` added for the R-102 pattern-deny path with manifest notes naming which fixture covers which slice; three camelCase enforce/ files kebab-cased with all imports/callers swept.

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
- New ISSUES.md P2: decide resurrect-versus-retire for the codex/cursor port pipeline (~60 stale "GENERATED by build.mjs" headers, PORT-STATUS at 42 hooks vs the current 49, frozen `.claude-port.json` hashes).
- P3 findings deliberately not fixed: `-guard` suffix does not distinguish ask-only from deny-capable hooks; "guard" used generically in enforce/README prose; `audits/` stub layer removable only after grepping downstream repos for `claude/audits/` path references; optional modernizations from the best-practices review (@-file imports in CLAUDE.md, `paths:` frontmatter on stack-scoped skills, `effort`/`permissionMode` on audit agents).
- Unexplained once (second anomaly of this class in this repo): a python heredoc write to `skills/structure-conventions/SKILL.md` printed success but left the file untouched (mtime unmoved); the identical retry worked. Writes were read-back-verified afterward. If it recurs, suspect the same parallel-session interference logged 2026-09-16.

## 5. Next session: read first

- `git log --oneline main..claude/hygiene-audit-2026-09-17` (the 16 per-finding commits).
- `claude/ISSUES.md` Open section (PAT rotation, port-pipeline decision).
- `claude/settings.json`, `claude/CLAUDE.md`, `claude/enforce/README.md`, and the official Claude Code docs for sandboxing, settings, hooks, and best practices before starting the current-practice config-audit workstream.
- `claude/rulebook/cost.md` R-907 and `claude/hooks/codex-test-author-guard.sh` (the new inline-only scoping) if doing TDD slice work.
