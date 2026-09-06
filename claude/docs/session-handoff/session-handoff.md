# Session Handoff: 2026-09-06 TDD harness assessment and slice-loop enforcement (steps 1 to 6)

## 1. Last commit

- Step 6 (test-quality ESLint rules, no-cycle, catch discipline) is the newest commit on `claude/tdd-harness-llm-code-fuf9rh`; before it `0420d3b` (spec template, step 5), `62bd02b` (role agents and the dispatch rewrite, step 4), `0b6c1f7` (SubagentStop, step 3), `0d96c35` (tdd.sh, step 2), `d116dbb` (protected-path guard, step 1), `4189a9c` and `3f2ba92` (the assessment and its nine decisions). No PR opened.

## 2. Production state

- Branch is green locally: 46 enforcement fixtures, 12 hook fixtures, run against this checkout through a fake `$HOME` with a git identity. CI has not run on the branch yet (it runs on `pull_request` and `main`).
- Nothing is live in Ian's `~/.claude` until the branch merges and is pulled. After the pull: `npm ci --prefix enforce` (the lockfile now carries `vitest` 5.0.0, pinned exact, as a devDependency for the live `tdd.sh` fixture), then `hooks/hook-integrity-check.sh` should be silent (the manifest was regenerated three times on the branch).
- The judge key is still pending (decision 9); R-401 anti-patterns 2, 4, 6, 7 are critic-only until it lands.

## 3. What shipped

- **Assessment (`docs/audits/2026-09-06-tdd-harness.md`):** current state, gap analysis (C-1 to C-4 critical), target workflow, concrete changes, agent-role design, guardrails, a worked example, the minimal plan, and the nine decisions asked one at a time.
- **Step 1, `hooks/protected-path-guard.sh` (R-410, R-411, R-412):** PreToolUse on Bash and Write|Edit. Denies writes to the gate inputs (`.claude/verify.sh`, `.enforce.json`, `.enforce-baseline.json`, `.claude/tdd-lock.json`); asks on test-runner configs and the `package.json` test/typecheck scripts; reads the slice lock (phase `open` denies production writes, `red`/`green` deny every test-tree write plus locked fixtures and the spec); reads `agent_type` against `enforce/role-policy.json` (test-author writes tests only, implementer never tests/fixtures/specs, slice-critic and spec-conformance-review nothing). Bash is judged by redirections, `tee`, and the operands of mutating verbs. Fixture: 60 cases.
- **Step 2, `enforce/tdd.sh` (R-412):** `open`, `red`, `green`, `close`, `status`. RED accepted only for assertion or missing-module failures with the rest of the suite green; records baseline and sha256 per file. GREEN checks hashes against the lock and the RED commit, then requires every named test to pass, none skipped, outside count at or above baseline. Vitest and Jest only. Fixture drives the bundled Vitest against a throwaway project.
- **Step 3, `SubagentStop`:** `verification-gate.sh` registered on it; skips roles whose policy entry is `deny: ["any"]`. Six new fixture cases.
- **Step 4, roles and the skill:** `agents/test-author.md` (Opus, writes tests only), `agents/implementer.md` (Sonnet, never writes tests, returns `DISPUTE:`), `agents/slice-critic.md` (Opus, read-only, seven questions, candidate tests as prose). `skills/tdd-gated-dispatch/SKILL.md` rewritten as the open/RED/commit/GREEN/REFACTOR/commit/REVIEW/close loop with the three dispatch prompts and the single-session Standard variant; R-705 rewritten and R-707 added in `rulebook/agents.md`; `task-start` tiers route through it; `feature-create` and `task-cleanup` no longer scaffold `test.skip` placeholders.
- **Step 5, spec shape:** `prompts/spec-template.md`; `spec-glossary-check.sh` names whichever of `## Domain vocabulary`, `## Acceptance criteria`, `## Non-goals` a design doc lacks; `spec-grounding` adds the headings to an external spec.
- **Step 6, ESLint:** `enforce/rules/no-self-mock.mjs` (R-401 items 1 and 5) and `behavior-assertion-required.mjs` (item 3) in test trees; `import-x/no-cycle` with the parsers, extensions, and TS resolver settings it needs (it reports nothing without them); the R-344 catch rules widened to every `src/services` and `src/clients` tree. Fixture `test-quality-rules.test.sh` drives the real ESLint.
- Rule text: R-410 to R-412 norm lines and Spec blocks, R-509, R-401, R-303, R-344, R-330 updated; manifest rows for each; `enforce/README.md` sections; README layout; PROTOCOL "What changed on 2026-09-06" and Appendix A origin.

## 4. Pending

**Ian, before anything else (both are one-command checks on the real build):**

1. Confirm `agent_type` reaches a `PreToolUse` command hook: add a scratch hook that logs `jq -r '.agent_type // "none"'` and dispatch one subagent. If absent, R-411 falls back to lock-only and the agent files in step 4 need their own `hooks:` block.
2. Confirm the Stop contract on the installed build still honors `{decision: "block", reason}` and `stop_hook_active` for `SubagentStop`; the current hooks reference excerpt shows `continueConversation` instead. A mismatch fails open silently.

**Then:**

3. Open the PR for the branch (`gh pr create` asks; R-514 keeps the merge with Ian) and let CI run the 58 fixtures; the ratchet step will report nothing to baseline for this repo.
4. First real slice on a Vitest project: `tdd.sh open`, dispatch `test-author`, commit, dispatch `implementer`, `tdd.sh green`, dispatch `slice-critic`. Expect the first surprises in `tdd.sh red`'s failure classification and in the guard's Bash target extraction; both have fixtures to extend.
5. After that run, `node ~/.claude/enforce/ratchet.mjs --update` on any backend repo with an existing baseline: `no-cycle`, the widened catch rules, and the test-quality rules add counts that must be locked in before the ratchet gate can pass there.

**Deferred by decision:** pytest, go test, and RSpec runners in `tdd.sh` (Vitest first); mutation testing on changed files; the dependency-addition guard; the judge-tier extension.

## 5. Next-session tasks, with files to read

- Read `skills/tdd-gated-dispatch/SKILL.md` before the first slice; it is the operating procedure, and `docs/audits/2026-09-06-tdd-harness.md` is the rationale.
- Read `hooks/protected-path-guard.sh` header and `enforce/tdd.sh` header before touching either; both state what they do not see (an interpreter writing from its own source) and why the GREEN hash check exists.
- `enforce/role-policy.json` is the single place roles and path patterns live; a new role is a new key, and `tdd.sh red` validates test paths against the same `tests` pattern.
- When adding an enforcer, R-516 binds: manifest row plus fixture; `hook-integrity-check.sh --update` now also covers `enforce/*.sh` and `role-policy.json`.
