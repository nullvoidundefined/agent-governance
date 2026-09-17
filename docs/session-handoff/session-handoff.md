# Session Handoff: 2026-09-17 skills audit and remediation

## 1. Last commit

- Branch `claude/intelligent-wozniak-gvgw7m`, tip `cbc0fd0` docs(audits): skills audit records what landed, and ISSUES.md narrows the cursor port item to the non-skill files. Pushed; no PR opened (the user has not asked for one). Base is `main` at `2cd9219`.

## 2. Production state

- Both fixture suites green through the fake-HOME runner used in this session (66 enforce fixtures, 16 hook fixtures), `node translate/codex.mjs --check` current, `hook-hashes.txt` regenerated (95 entries; the four stale camelCase and `single-file-folder-gate` entries dropped out).
- Not synced: this session ran in a cloud worktree, so `./sync.sh` has not been run on the maintainer's machine; the live `~/.claude` still carries the pre-audit skills until it is.
- Not applied to this repository itself: `repo-setup --check` has not been run here (needs the maintainer's admin `gh` token); the 2026-09-16 P1-2 finding that `main` has no branch protection stands.

## 3. Session metrics

- Commits this session: 32
- Files changed: 147
- Rework commits (file touched by 2+ commits): 41 (the skill files, their two port copies, the port manifest, and the hash manifest were each touched by several per-skill commits by design)
- Velocity flag: NORMAL

## 4. What shipped

- **Audit** `docs/audits/2026-09-17-skills.md`: all 15 skills, two P1 cross-cutting findings (Cursor skill drift, no skills lint), per-skill P2/P3 findings, 13 ranked script candidates, an implementation-status section.
- **Guards**: `enforce/tests/skills-lint.test.sh` (eight closure properties, proven on a sandboxed broken skill); `hooks/handoff-check.sh` (R-602 shape at write time, manifest entry, CLAUDE.md bracket); `spec-glossary-check.sh` extended to slice plans under `docs/slices/`.
- **Infrastructure**: `translate/codex.mjs` copies skill support files with mode; `hook-integrity-check.sh` hashes `skills/*/scripts/*`; both port `.gitignore` allowlists carry every script; `translate-codex.test.sh` no longer greps `\`` (red on GNU grep, green on BSD).
- **Skill scripts** (each with a fixture): feature-create `scaffold.sh`, spec-grounding `check.sh`, `tdd.sh validate <role>`, task-start `task-tier.sh` (re-injected by `post-compact-rules.sh`), task-cleanup `scan.sh`, `hooks/session-metrics.sh` (called by `session-end.sh`), bug-hunt `dangling-refs.sh`, cleanup-specs-plans `inventory.sh`, documentation-create `prose-flags.sh`, protocol `section.sh`, resolve-user-feedback `feedback.mjs`.
- **Text fixes**, one commit per skill: all-hands, bug-hunt, build-by-slice-require-review, cleanup-specs-plans, documentation-create, feature-create, gof, resolve-user-feedback, task-cleanup, task-start, tdd-gated-dispatch; `reference.md` R-602 gains the metrics section and the hook enforcer; four skills carry `disable-model-invocation: true`.
- **New skill** `repo-setup` (`scripts/setup.sh`, ten templates, stubbed-`gh` fixture): CI per stack, Dependabot, PR template, gitignore, `staging` branch, two rulesets, squash-only merges, alerts, secret scanning, Greptile check.
- **Cursor**: all 16 skill copies re-cloned with a "Cloned from" header; `cursor/hooks.json` registers `handoff-check`.

## 5. Pending

- **User, now**: review and merge the branch (squash per R-512, or keep the 33 per-finding commits), then `./sync.sh` so the live harness carries the new hooks and scripts. ~15 minutes to read the audit, seconds to sync.
- **User, then**: `bash ~/.claude/skills/repo-setup/scripts/setup.sh nullvoidundefined/agent-governance --check` on this repository and apply what it reports; this closes 2026-09-16 P1-2 (no branch protection). Needs an admin token. ~10 minutes.
- **P2**: the rest of the cursor port item in `claude/ISSUES.md` (rules, agents, commands, `PORT-STATUS.md`); the skills half is done.
- **P3**: X-4 in the audit (which skills announce at start) is undecided; the report proposes deciding it once in `PROTOCOL.md` Layer 2.
- **P3**: `/skill-doctor` has not been run; its numbers decide whether `all-hands` belongs in the always-loaded listing at all.
- **Verify on the real build**: `$ARGUMENTS` substitution inside the protocol skill's `` ! `` block (the script handles an empty argument by printing the whole file, so the failure mode is the old behaviour, not a broken skill).

## 6. Next session: read first

- `docs/audits/2026-09-17-skills.md`, the Implementation status section last.
- `git log --oneline 2cd9219..HEAD` (33 commits, one per finding or script).
- `claude/enforce/tests/skills-lint.test.sh` before editing any skill: it names what a skill edit must keep true.
- `claude/skills/repo-setup/SKILL.md` before applying it anywhere; read the two rulesets' shape and the `--required-reviews` note.
