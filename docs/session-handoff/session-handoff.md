# Session Handoff: 2026-09-17 skills audit, remediation, and merge of main

## 1. Last commit

- Branch `claude/intelligent-wozniak-gvgw7m`, last commit before the merge of `origin/main` (`6bc9b24`, the ticket-lifecycle workstream) is `10e88e3` fix(skills): repo-setup accepts an existing workflow and takes the required check name as --ci-context. The merge commit and a port regeneration follow it. PR #3 is open against `main`; squash merge per R-512 once CI is green.
- The branch history was rewritten once: the commit that introduced `feedback-tool.test.sh` carried a fake `postgres://user:<password>@host` literal that GitGuardian flagged, so that commit was amended and the branch force-pushed. No real credential was ever involved.

## 2. Production state

- Both fixture suites green on the merged tree (67 enforce fixtures, 16 hook fixtures), `node translate/codex.mjs --check` current, `hook-hashes.txt` regenerated under main's wider contract (fixtures and npm manifests are hashed too, 183 entries).
- The Codex `.gitignore` is now generated from the planned tree (main's change), so the hand-written allowlist lines this branch added were replaced by the renderer's output; skill support files are planned, so they are allowlisted automatically.
- `./sync.sh` ran in this container only into throwaway targets (rsync installed with apt): every skill script arrives executable and both new hooks arrive. The live `~/.claude` on the maintainer's machine is untouched until `./sync.sh` runs there.
- `repo-setup --check` has not run against this repository: the container has no `gh`. Running it here needs the maintainer's admin token on a machine with `gh`.

## 3. Session metrics

- Commits this session: 33 on the branch plus the merge
- Files changed: 150 before the merge
- Rework commits (file touched by 2+ commits): 41 (the skill files, their two port copies, the port manifest, and the hash manifest were each touched by several per-skill commits by design)
- Velocity flag: NORMAL

## 4. What shipped

- **Audit** `docs/audits/2026-09-17-skills.md`: all 15 skills, two P1 cross-cutting findings, per-skill P2/P3 findings, 13 ranked script candidates, an implementation-status section.
- **Guards**: `enforce/tests/skills-lint.test.sh`; `hooks/handoff-check.sh` (R-602 at write time, manifest entry, CLAUDE.md bracket); `spec-glossary-check.sh` extended to slice plans.
- **Skill scripts, each with a fixture**: feature-create `scaffold.sh` (now with `--ticket`, writing the `**Ticket:**` line and the `Refs:` trailer main's R-605 asks for), spec-grounding `check.sh`, `tdd.sh validate <role>`, task-start `task-tier.sh`, task-cleanup `scan.sh`, `hooks/session-metrics.sh`, bug-hunt `dangling-refs.sh`, cleanup-specs-plans `inventory.sh`, documentation-create `prose-flags.sh`, protocol `section.sh`, resolve-user-feedback `feedback.mjs`, repo-setup `setup.sh` with `--ci-context`.
- **Merge of main**: ticket-lifecycle integration folded into the rewritten feature-create, task-cleanup, and task-start; `hook-integrity-check.sh` keeps main's floors and refusal messages plus this branch's `skills/*/scripts/*` coverage; README counts refreshed (17 skills, 51 hooks, 83 fixtures).
- **Cursor**: all 17 skill copies re-cloned with a "Cloned from" header; `cursor/hooks.json` registers `handoff-check`.

## 5. Pending

- **User, now (P0-2, unchanged since 2026-09-16)**: rotate the GitHub PAT and purge the transcripts named under PENDING USER ACTION in `claude/ISSUES.md`.
- **User, now**: squash-merge PR #3 when the `enforce` check is green, then `./sync.sh` on the maintainer's machine. Editing any fixture now needs `hooks/hook-integrity-check.sh --update` in the same commit (main's contract).
- **User, then**: `bash ~/.claude/skills/repo-setup/scripts/setup.sh nullvoidundefined/agent-governance --check --ci-context fixtures`, and apply what it reports; closes 2026-09-16 P1-2 (no branch protection). Needs an admin `gh` token.
- **User, one command**: delete the four renamed leftovers from the live tree (`~/.claude/enforce/eslintOptions.mjs`, `renderLexiconSpec.mjs`, `resolveOutgoingBase.sh`, `~/.claude/hooks/single-file-folder-gate.sh`); `sync.sh` never deletes.
- **User, before the ticket skill can do anything**: pick a tracker and copy `claude/TICKET-TRACKER.template.json` to `~/.claude/TICKET-TRACKER.json` (no ticket key exists for this session's work; the degraded path of R-605).
- **Decision**: whether cloud sessions should run `sync.sh` into the container's `~/.claude` at SessionStart (rsync installs with apt there); see the session's closing message.
- **P2**: the rest of the cursor port item in `claude/ISSUES.md` (rules, agents, commands, `PORT-STATUS.md`); the skills half is done.
- **P3**: audit X-4 (which skills announce at start) is undecided; `/skill-doctor` has not been run; `$ARGUMENTS` substitution inside the protocol skill's `` ! `` block is unverified on the real build (an empty argument prints the whole file, the old behaviour).

## 6. Next session: read first

- `docs/audits/2026-09-17-skills.md`, the Implementation status section last, then `docs/audits/2026-09-17-engineering.md` from main.
- `git log --oneline 2cd9219..HEAD` (one commit per finding or script, then the merge).
- `claude/enforce/tests/skills-lint.test.sh` before editing any skill, and `claude/enforce/tests/hook-hashes-closure.test.sh` before editing any hook or fixture.
- `claude/skills/repo-setup/SKILL.md` before applying it anywhere; read the two rulesets' shape, `--required-reviews`, and `--ci-context`.
