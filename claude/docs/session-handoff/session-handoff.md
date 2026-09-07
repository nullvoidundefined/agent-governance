# Session Handoff: 2026-09-07 slice loop (PR #16) and dependency guard plus refactor mode (PR #17) merged

## 1. Last commit

- PR #17 (`feat(harness): R-331 dependency-add guard and tdd.sh open --refactor`) squash-merged to `main` on 2026-09-07, on top of PR #16 (`b908724`). `git log --oneline -2 main` shows both; no branch is open.

## 2. Production state

- Both PRs merged with CI green: 47 enforcement fixtures, 12 hook fixtures, run against this checkout through a fake `$HOME` with a git identity. CI has not run on the branch yet (it runs on `pull_request` and `main`).
- Nothing is live in Ian's `~/.claude` until the branch merges and is pulled. After the pull: `npm ci --prefix enforce` (the lockfile now carries `vitest` 5.0.0, pinned exact, as a devDependency for the live `tdd.sh` fixture), then `hooks/hook-integrity-check.sh` should be silent (the manifest was regenerated three times on the branch).
- The judge key is still pending (decision 9); R-401 anti-patterns 2, 4, 6, 7 are critic-only until it lands.

## 3. What shipped

- **PR #16 (merged):** the assessment, R-410 to R-412 with `hooks/protected-path-guard.sh` and `enforce/role-policy.json`, `enforce/tdd.sh`, the `SubagentStop` gate, the three role agents and the `tdd-gated-dispatch` rewrite (R-705, R-707), `prompts/spec-template.md` with the extended R-330 hook, and the test-quality, no-cycle, and catch-discipline ESLint rules.
- **PR #17 (merged):** R-331 `hooks/dependency-add-guard.sh` plus `hooks/dependency-add-scan.py` (asks when a manifest gains a dependency name; 30-case fixture); `tdd.sh open --refactor` (green suite as the contract, phase `refactor`, guard treats it like `red`; fixture cases in both suites).
- Decisions 10 to 16 recorded in the assessment's Decisions section.

## 4. Pending

**Ian, before anything else (both are one-command checks on the real build):**

1. Confirm `agent_type` reaches a `PreToolUse` command hook: add a scratch hook that logs `jq -r '.agent_type // "none"'` and dispatch one subagent. If absent, R-411 falls back to lock-only and the agent files in step 4 need their own `hooks:` block.
2. Confirm the Stop contract on the installed build still honors `{decision: "block", reason}` and `stop_hook_active` for `SubagentStop`; the current hooks reference excerpt shows `continueConversation` instead. A mismatch fails open silently.

**Then:**

3. Pull `main` and `npm ci --prefix enforce` (Vitest is in the lockfile since PR #16).
4. First real slice on a Vitest project: `tdd.sh open`, dispatch `test-author`, commit, dispatch `implementer`, `tdd.sh green`, dispatch `slice-critic`. Expect the first surprises in `tdd.sh red`'s failure classification, the guard's Bash target extraction, and the dependency guard's ask cadence; all three have fixtures to extend.
5. Re-baseline by hand (decision 15): `node ~/.claude/enforce/ratchet.mjs --update` once in each repo carrying `.enforce-baseline.json`, read the new `import-x/no-cycle`, `catchDiscipline/*`, and `testQuality/*` counts, commit.

**Deferred by decision:** pytest, go test, and RSpec runners in `tdd.sh` (decision 10); mutation testing on changed files (decision 11); the judge-tier extension (decision 9).

## 5. Next-session tasks, with files to read

- Read `skills/tdd-gated-dispatch/SKILL.md` before the first slice; it is the operating procedure, and `docs/audits/2026-09-06-tdd-harness.md` is the rationale.
- Read `hooks/protected-path-guard.sh` header and `enforce/tdd.sh` header before touching either; both state what they do not see (an interpreter writing from its own source) and why the GREEN hash check exists.
- `enforce/role-policy.json` is the single place roles and path patterns live; a new role is a new key, and `tdd.sh red` validates test paths against the same `tests` pattern.
- When adding an enforcer, R-516 binds: manifest row plus fixture; `hook-integrity-check.sh --update` now also covers `enforce/*.sh` and `role-policy.json`.
