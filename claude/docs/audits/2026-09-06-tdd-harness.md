# TDD Harness Assessment: role-separated RED/GREEN/REFACTOR/REVIEW for LLM-generated code (2026-09-06)

## Scope and method

`~/.claude` on branch `claude/tdd-harness-llm-code-fuf9rh` at `0fc3aed` (`feat(rules): R-351 Dockerize every deployable artifact from its first commit (#15)`), working tree clean.

Read in full: `CLAUDE.md`, `rulebook/` (reference, agents, audits, cost), `rules/session-types.md`, `settings.json`, `enforce/` (manifest, README, ESLint config, `lint.mjs`, `ratchet.mjs`, `judge-prompt.md`, the fixture runner and the content-gate, verification-gate, judge, and fix-commit fixtures), every hook this assessment names, all 14 skills, `agents/spec-conformance-review.md`, `agents/audit-criticism.md`, `prompts/subagent-branch-setup.md`, `PROTOCOL.md`, `README.md`, `ISSUES.md`, the 2026-07-31 engineering-harness and criticism audits, the 2026-09-04 configuration audit (agent-hook section), the R-330 and R-351 design specs, the fire and miss logs, and the current handoff. The `superpowers` plugin skills the harness delegates to (`test-driven-development`, `subagent-driven-development`, `writing-plans`) are not in this checkout and were not read; their behavior is taken from `README.md` and `PROTOCOL.md` claims and is marked where it matters.

Question asked of every mechanism: if the implementing model is wrong, or is optimizing for green, what stops it. Findings distinguish what a hook denies from what a skill asks for.

---

## 1. Current-state assessment

### How the harness works today

Three tiers of rule text, one mapping, one runtime:

- `CLAUDE.md` carries one norm line per rule with its enforcer in brackets; `rulebook/reference.md` carries the Spec; `enforce/manifest.json` maps each mechanized rule to a tier (`regex`, `ast`, `llm-judge`, `advisory`) and an enforcer. `enforcement-guard-check.sh` and `settings-change-guard.sh` keep manifest and `settings.json` closed in both directions; `hook-integrity-check.sh` hashes the enforcement surface; `.github/workflows/enforce.yml` runs both fixture suites where `--no-verify` cannot reach.
- 44 hooks across `PreToolUse` (Bash, Write|Edit, MCP), `PostToolUse`, `SessionStart`, `Stop`, `ConfigChange`, `PreModelSwitch`. The ones that matter for this assessment: `content-gate.sh` (denies `.only`, untracked `.skip`, TLS/CORS/CSP/CSRF/bcrypt weakening on Write|Edit), `fix-commit-requires-test.sh` (denies a `fix:` commit whose staged set has no test file, chained `git add` included), `verification-gate.sh` (Stop hook: discovers and runs the project's test and typecheck commands when the tree is dirty, blocks the turn on red, memoizes a green tree), `constant-change-guard.sh` (asks at push when a removed constant value is still asserted in tests), the four push linters plus `llm-rule-judge.sh`, and `ratchet.mjs` (full-tree ESLint counts may only descend).
- Process is prose plus skills: `task-start` classifies Trivial/Standard/Complex/Saga and routes Standard to `superpowers:test-driven-development` inline, Complex and Saga to spec, plan, worktree, and `tdd-gated-dispatch` for subagents. `tdd-gated-dispatch` (R-705) has the primary agent write failing tests, commit them, record a baseline count, dispatch an implementer with "do not modify the pre-written test files", and validate on return. `agents/spec-conformance-review.md` is a fresh-context, read-only reviewer that checks a diff against a named spec and reports only explicit-requirement gaps. `spec-grounding` maps an external spec onto real paths; `feature-create` scaffolds user stories and a placeholder E2E; `task-cleanup` closes out.
- Specs are Markdown under `docs/superpowers/specs/*-design.md` with one required section, `## Domain vocabulary`, checked by an advisory hook (R-330).

### What it already does well

Stated with the evidence, since praise without it is the pattern the criticism role bans.

1. **The definition of correctness is already meant to live outside the implementer.** R-705 orders: write the failing tests, commit them, confirm FAIL not error, record the baseline, then dispatch. The dispatch template forbids test edits and stubbed implementations. `spec-conformance-review.md` refuses to run without a spec path and refuses to accept the diff's own framing. The design intent matches the requested philosophy; the gap is that all of it is prose (see below).
2. **The cheap-to-decide anti-cheats are mechanical and tested.** `content-gate.sh:48-58` denies `it.only` outright and `it.skip` without a triage ID; `:64-73` denies protection weakening. `fix-commit-requires-test.sh:95-105` unions the `git add` targets so the chained idiom cannot bypass it. `verification-gate.test.sh` proves eight invariants including "a red run is never memoized". These are behavior fixtures: JSON in, decision out.
3. **The harness defends itself.** Hash manifest over hooks, ESLint rules, and the lexicon; a `ConfigChange` guard that refuses a settings save dropping a registered hook; a manifest-closure fixture; CI as a required check; `destructive-command-guard.sh` denying `rm ~/.claude/hooks/*`, `core.hooksPath` writes, and `gh alias set`. Most harnesses can be disabled by the agent they constrain; this one makes that a visible act.
4. **Honest labeling and a working telemetry loop.** 40 of 59 `CLAUDE.md` rules say `[manual]`. `global-memory/rule_fires.md` now records mechanical fires: R-403 denied eight commits in one 2026-08-05 session, R-207 fires every session, R-513 asked twice on 2026-08-11. The 2026-07-31 criticism audit found this log dead; it is alive now, which is the precondition for retiring anything.
5. **Long-term drift is priced.** `ratchet.mjs` grandfathers debt and fails on a rising count, with the "same-rule swap nets to zero" limit stated in the file header rather than hidden.

### Where it is vulnerable, against the eight failure modes in the brief

**Role separation exists only in Complex and Saga, and even there the spec author, test author, and validator are one context.** `task-start` Standard tier (the common case: "add an endpoint, create a component, fix a multi-file bug") runs `superpowers:test-driven-development` inline: one agent, one context, writes the test and then the code. Correlated misunderstanding is the default outcome of that shape. In Complex and Saga, `tdd-gated-dispatch` separates the implementer, but the primary agent that wrote or grounded the spec also writes the tests and then judges the return. The only fresh-context role is `spec-conformance-review`, which is dispatched by hand, checks conformance only, and by its own binding list never reports a missing test unless the spec names it.

**Test mutation by the implementer is undefended mechanically.** Enumerating the brief's list against the hooks:

| Mutation | Today |
|---|---|
| Deleted test file (`git rm`, `rm`, `Write` of empty content) | nothing |
| Skipped test | `content-gate.sh` on Write|Edit only; a Bash heredoc bypasses it (`ISSUES.md`, 2026-08-21 P2) |
| Changed assertion or expected value | nothing |
| Weakened fixture (`__fixtures__/`, `testdata/`, `spec/factories/`) | nothing |
| Reduced coverage | no coverage tool anywhere in the conventions |
| Disabled integration or E2E case | `content-gate.sh` skip check only |
| Broad exception swallowing | `no-empty`, `no-swallowed-catch`, ruff `BLE001`/`S110`, golangci `errcheck`, RuboCop `Lint/SuppressedException`; scoped to server trees only (`eslint.config.mjs:136-144`) |
| Mock that bypasses the behavior under test | R-401 anti-patterns 1 to 7 are `[manual]`; the judge tier does not judge them and is inert anyway |
| Editing the harness's own gate inputs (`.claude/verify.sh`, `.enforce.json`, `.enforce-baseline.json`, `package.json` `test` script, `vitest.config.*`) | nothing; `verification-gate.sh:86` runs `.claude/verify.sh` first, so an implementer that writes `exit 0` there ends every turn green |

The dispatch prompt says "do not modify the pre-written test files"; nothing checks the hash of those files on return. `tdd-gated-dispatch`'s own "After sub-agent returns" checklist item "No test files were modified by the sub-agent" is a checkbox.

**RED is never verified mechanically.** "Confirm FAIL (not error)" is R-705 step 4 and a checklist line. No script runs the new test, classifies the failure (assertion versus import error versus syntax error versus "no tests found"), or records the result. The GREEN check therefore compares against a number the primary agent remembered, not a record.

**Subagent turns are not gated.** `verification-gate.sh` is registered on `Stop` only (`settings.json:315-327`). `SubagentStop` is not registered, so an implementer subagent returns on a red suite without any hook firing; the red is caught, if at all, when the primary session's turn ends with a dirty tree.

**False confidence: the harness cannot tell a happy-path suite from a thorough one.** Grepping every convention file and rule for the brief's list: retries, timeouts (R-346 advisory reminder on `clients/` only), partial failure, concurrency, idempotency, races, state transitions, rollback, and external-dependency failure appear nowhere as test requirements. R-406 (one negative-input test per handler) is `[manual]`. There is no coverage, mutation, property-based, contract, or failure-injection tooling in `enforce/`, and none is recommended by any `CLAUDE-*.md`. The only mechanical statement about test quality is "no skip, no only".

**Architectural entropy: structure is well covered, dependencies and duplication are not.** Directory vocabulary (R-304/R-305/R-306/R-311/R-312), test placement (R-313/R-314), one export per module (R-319), naming lexicon (R-316/R-317, opt-in), sort order and magic numbers are all mechanical. Not covered: import direction (R-303 is active only in repos declaring `importZones` in `.enforce.json`), circular imports (no `import-x/no-cycle`, no dependency-cruiser), new third-party dependencies (no guard on `package.json`/`pyproject.toml`/`go.mod` dependency additions), duplicated abstractions (R-308 `[manual]`), accidental exports (R-307 `[manual]`), one-responsibility (R-318/R-322 `[manual]` by design and correctly so).

**The judge tier is still inert.** `enforcement-guard-check.sh:56` warns at every session start; the handoff's step 4 is still pending. Every `[judge]` rule, and every R-401 anti-pattern beyond skip/only, is honor-system today. This assessment does not recommend widening the judge before it runs.

**Spec shape is unconstrained beyond the glossary.** `spec-conformance-review` grounds findings only on requirements it can mark explicit. A spec with prose paragraphs and no acceptance-criteria list produces fewer explicit requirements, so a loosely written spec weakens the one fresh-context check that exists. `feature-create` scaffolds `test.skip('placeholder ...')` E2E files, which PROTOCOL Layer 5 bans outright; `content-gate.sh` lets it through because the placeholder text carries a `US-SLUG-001` ID.

---

## 2. Gap analysis

### Critical

- **C-1. No mechanical lock on test, fixture, and spec files during implementation.** The implementer can edit, delete, or rewrite any test and every gate stays green. Nothing compares the returned test files to the committed RED state.
- **C-2. The verification gate's inputs are writable by the agent it gates.** `.claude/verify.sh` wins discovery; `package.json` `scripts.test` is what it runs; `.enforce-baseline.json` is what the ratchet compares to and `--update` absorbs a regression. None is protected.
- **C-3. No mechanical RED evidence.** The failing run is neither classified nor recorded, so GREEN has nothing authoritative to compare against.
- **C-4. `SubagentStop` is unregistered.** The role the workflow makes responsible for GREEN is the one role the turn-level gate never sees.

### High-value

- **H-1. Role-separated agent definitions with tool and path boundaries** (test author, implementer, critic), replacing the "primary agent does spec, tests, and validation" shape. Enforcement is the lock hook, not the prompt.
- **H-2. A minimal spec skeleton** (fixed Markdown headings, one numbered behavior per slice) so the test author and the conformance reviewer have explicit requirements to work from.
- **H-3. A per-slice, fresh-context critic** with a fixed question list and read-only tools, separate from `spec-conformance-review`, whose output is findings and candidate tests in prose, never written tests.
- **H-4. Two decidable test-quality lints** for the R-401 anti-patterns that are set membership rather than judgment: self-mock (a `vi.mock`/`jest.mock` whose specifier resolves to the module the test file is named for) and mock-only assertions (a test body whose only `expect` calls are `toHaveBeenCalled*`). Both run in the existing push gate.
- **H-5. Import-cycle and dependency-addition checks.** `import-x/no-cycle` is one line in `eslint.config.mjs` with the plugin already installed. A `PreToolUse` ask on a `dependencies` addition in a manifest file is one small hook.
- **H-6. Mutation testing on changed files, TypeScript `services/` only, advisory first.** R-401's own definition ("tests that fail when the implementation is wrong") is what a mutation score measures. Stryker's incremental mode scoped to the outgoing diff is affordable; whole-repo mutation in CI is not.

### Nice-to-have

- Property-based tests (`fast-check`, `hypothesis`) named in the conventions for pure functions with invariants (pricing, parsing, scoring). Guidance, not a gate.
- Failure-injection convention for `clients/`: one test per client that asserts behavior on timeout and on a 5xx, paired with the existing R-346 reminder.
- Judge-tier extension to R-401 anti-patterns 2, 4, 5, 6, 7 once the key is provisioned; the criticism audit's "do not widen an inert tier" caveat stands until then.
- Model diversity for the critic (frontmatter `model:` already supports it). Role separation is the value; model diversity is the garnish.
- Extending `fix-commit-requires-test.sh` to require a RED record for the staged test rather than any test file.

### Unnecessary or overengineering

- A machine-readable spec format (YAML, JSON schema, DSL). Fixed Markdown headings plus a heading lint give the reviewer everything a schema would, and the human keeps writing prose.
- An orchestration framework or workflow engine. The Agent tool, three agent files, two shell scripts, and one hook cover the loop.
- Coverage-percentage thresholds as a hard gate. They invite assertion-free tests, which is the failure mode R-401 exists to name.
- Full-suite mutation testing on every push, or across Python, Ruby, and Go where no project exists yet (the criticism audit's speculative-tier finding applies).
- Separate git identities, branches, or worktrees per role. One branch, ordered commits (`test:` then `feat:`), and the lock give the same audit trail.
- Requiring a different model per role. Fresh context is what breaks correlation; the model is secondary, as the brief says.

---

## 3. Recommended target workflow

One loop per behavioral slice; the spec enumerates the slices. Tier decides who runs each step, not whether it runs.

```
SPEC      human writes docs/specs/<slug>.md from the template; a planning agent may draft it;
          the human approves; from approval the spec is a locked path.

for each behavior B-n in the spec:

  RED     test-author agent (fresh context; Write/Edit limited to test trees by the lock hook)
          writes the test(s) for B-n only, runs `enforce/tdd.sh red <test paths>`:
            - the named tests fail with an assertion or missing-module failure
              (syntax error in the test, "no tests found", or a skip is rejected)
            - the rest of the suite is green; pass count recorded
            - test-file hashes recorded to .claude/tdd-lock.json
          commits `test(scope): B-n <behavior>` (lock file included)

  GREEN   implementer agent (fresh context; spec path + test paths + lock; Write/Edit to
          locked paths denied by the hook) writes the minimum, runs `enforce/tdd.sh green`:
            - every RED test id now passes
            - suite pass count >= recorded baseline
            - locked-file hashes unchanged since the RED commit
            - typecheck and lint pass
          commits `feat(scope): B-n <behavior>`
          on a contract dispute: writes nothing to tests, returns "DISPUTE: <test id>: <why>";
          the human decides, and any test change is a new RED by the test author

  REFACTOR implementer (same rules, lock still active) may restructure; `tdd.sh green` must
          stay green; ratchet must not rise; commits `refactor(scope): ...`

  REVIEW  critic agent (fresh context; read-only tools; receives spec path, diff range,
          test paths; never the implementer's transcript) answers the fixed question list
          and returns findings plus candidate tests as prose; the human triages; accepted
          candidates become B-n+1 and go back to RED

VERIFY    unchanged deterministic layer: verification-gate on Stop and SubagentStop, the
          four push linters, ratchet, CI; spec-conformance-review once per feature before merge
```

Tier mapping:

| Tier (task-start) | Who runs the steps |
|---|---|
| Trivial | no loop; existing rules only (R-403 for bugs) |
| Standard | one session, but the order is enforced: `tdd.sh red` and its commit before any production edit, lock active until `tdd.sh green` passes; critic optional |
| Complex | separate test-author and implementer agents; critic per slice; conformance review before merge |
| Saga | as Complex, plus a review checkpoint per stage (already in task-start) |

The Standard tier keeps the cost low: no extra agents, one script call at each end, and the lock hook makes "I wrote the test after the code" a denied tool call rather than a confession.

---

## 4. Concrete repository changes

New files:

- `hooks/protected-path-guard.sh` (PreToolUse `Bash` and `Write|Edit`). Two inputs decide a deny. (a) The lock: `.claude/tdd-lock.json` in the repo root, when present, lists locked paths; Write/Edit to one denies, and a Bash command naming one together with `rm`, `mv`, `git rm`, `sed -i`, `>`/`>>` redirection, or `tee` denies. (b) The role: the hook input carries `agent_type` when the call comes from a subagent (documented under "Common fields" in the hooks reference), and `enforce/role-policy.json` maps each role to the trees it may write: `test-author` writes only test and fixture trees, `implementer` writes anything except test trees, fixtures, specs, and the lock, `slice-critic` writes nothing. Always protected, lock or no lock, any role: `.claude/verify.sh`, `.claude/tdd-lock.json`, `.enforce.json`, `.enforce-baseline.json`; `package.json` `scripts.test`/`scripts.typecheck` edits and `vitest.config.*`, `jest.config.*`, `playwright.config.*`, `pytest.ini`, `[tool.pytest]` ask. Escape: the human deletes the lock outside the session or says "approved" in the turn (R-203 already words this). Registered globally rather than in each agent's `hooks:` frontmatter so `enforcement-guard-check.sh` and `settings-change-guard.sh` keep their closure over `settings.json`.
- `enforce/role-policy.json`: the role-to-writable-trees table above, data not code, in the `.enforce.json` style.
- `enforce/tdd.sh` with `red <test paths...>` and `green` subcommands. Stack detection copied from `verification-gate.sh:78-108`. `red`: runs only the named files, requires non-zero exit, classifies from output (Vitest/Jest: `AssertionError`, `Cannot find module`, `is not a function`; pytest: `AssertionError`, `ImportError`, `AttributeError`; Go: `--- FAIL`, `undefined:`; RSpec: `expected`, `NameError`), rejects `SyntaxError`, `No test files found`, `0 passed`, and any skip marker; runs the full suite excluding the named files and records the pass count; writes `.claude/tdd-lock.json` with `{slice, tests: [{path, sha256}], baseline, failureClass}`. `green`: reruns named files (must exit 0), reruns the suite (count >= baseline), recomputes hashes against the lock and against `git show <red-commit>:<path>`, prints a one-line verdict.
- `agents/test-author.md`, `agents/implementer.md`, `agents/slice-critic.md` (section 5 gives the shape).
- `prompts/spec-template.md`: the fixed headings (section 8 of the brief, trimmed to what the reviewer can check).
- `enforce/rules/no-self-mock.mjs`, `enforce/rules/behavior-assertion-required.mjs`; wired in a new test-tree block of `eslint.config.mjs` (the block at `:179-194` currently only turns rules off for tests).
- `enforce/tests/protected-path-guard.test.sh`, `enforce/tests/tdd-red-green.test.sh`, `enforce/tests/test-quality-rules.test.sh`.

Modified files:

- `settings.json`: register `protected-path-guard.sh` under PreToolUse `Bash` and `Write|Edit`; add a `SubagentStop` entry running `verification-gate.sh` with the same 660s timeout; register `dependency-add-guard.sh` if H-5 is taken.
- `hooks/verification-gate.sh`: accept `hook_event_name: SubagentStop` (it already reads `cwd` and `stop_hook_active`, so this is a comment change plus a fixture case).
- `enforce/manifest.json`: rows for the new rules (proposed IDs: R-410 locked tests and gate inputs, `regex`, `hook:protected-path-guard`, `error`; R-411 RED evidence, `regex`, `hook:protected-path-guard` reading the lock, `error`; R-401 rows for `eslint:no-self-mock` and `eslint:behavior-assertion-required`, `ast`, `error`).
- `CLAUDE.md`: two norm lines (R-410, R-411) in the R-4xx block; R-401's bracket gains the two ESLint enforcers. `claude-md-lint.test.sh` will demand matching Spec blocks in `rulebook/reference.md`.
- `rulebook/agents.md`: R-705 rewritten as the slice loop above; a new R-707 naming the three roles and their boundaries; the pre-dispatch checklist shrinks because `tdd.sh red` answers half of it.
- `skills/tdd-gated-dispatch/SKILL.md`: rewritten around `tdd.sh` and the three agents; the "Handling Test Modifications" section becomes "the hook denies it; the script proves it".
- `skills/task-start/SKILL.md`: the tier table above; Standard tier gains the `tdd.sh red` before-any-edit rule.
- `skills/feature-create/SKILL.md` and `skills/task-cleanup/SKILL.md`: drop the `test.skip` placeholder scaffold; the first user story's E2E is written as a real RED test or not at all.
- `hooks/spec-glossary-check.sh`: extend to warn when a design spec lacks `## Acceptance criteria` or `## Non-goals` (still advisory); rename to `spec-shape-check.sh` only if the manifest row is updated in the same commit (R-516).
- `enforce/eslint.config.mjs`: add `"import-x/no-cycle": "error"` to the base rules; widen the observability block's `files` to include `**/src/services/**` and `**/src/clients/**` so exception swallowing in business logic is caught, not only in handlers.
- `.github/workflows/enforce.yml`: no change for this repo; project repos get a `.github/workflows/verify.yml` template (test, typecheck, ratchet, optional `stryker --incremental` on `services/`) added to `CLOUD-DEPLOYMENT.md` as a reference, not a hook.

---

## 5. Agent-role design

Principle: the human owns the definition of correctness; every agent below is either producing evidence against that definition or generating code to satisfy it, never both.

| Role | Context | Reads | Writes | Model | Boundary enforced by |
|---|---|---|---|---|---|
| Spec author | human, optionally with a planning agent drafting from the template | anything | `docs/specs/<slug>.md` until approval | Opus for the draft | after approval the spec is a locked path |
| Test author | fresh subagent; input: spec path, slice id, test conventions file path | spec, existing tests, existing interfaces | test trees, fixtures, `.claude/tdd-lock.json` (via `tdd.sh red`) | Opus | `protected-path-guard.sh` reads `agent_type: test-author` from the hook input and denies any write outside the test and fixture trees in `role-policy.json` |
| Implementer | fresh subagent; input: spec path, test paths, lock path, branch block | everything | production paths only | Sonnet | same hook, `agent_type: implementer`: denies test trees, fixtures, specs, and every locked path; `tdd.sh green` proves hashes |
| Refactorer | the implementer role, second dispatch or same | everything | production paths only | Sonnet | same policy, ratchet |
| Critic | fresh subagent; input: spec path, diff range, test paths; never the implementer's transcript or rationale | everything, read-only | nothing | Opus | `disallowedTools: [Write, Edit, NotebookEdit]` in frontmatter (documented key) plus the hook's Bash branch denying redirection and `git` mutations for `agent_type: slice-critic` |
| Primary session | orchestrator | dispatch results | commits, dispatch prompts, nothing under `src/` or test trees in Complex/Saga | whatever is active | R-704 (inline under 5 tasks) already draws this line |

What the platform gives and does not give (checked against the current hooks and sub-agents references): agent frontmatter supports `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `isolation`, and its own `hooks:` block, but "tool restrictions in agent definitions work at the tool level only", so a path boundary is a hook's job. `Edit(<glob>)` and `Read(<glob>)` permission rules exist with gitignore syntax but apply to the whole session, not per agent. `SubagentStart` and `SubagentStop` are documented events. No environment variable names the running agent; `agent_type` in the hook input is the only documented handle, which is why the guard keys on it.

Routing note: this inverts the current `task-start` table, which puts Opus on planning and review and Sonnet on implementation. Under the brief's philosophy the expensive intelligence belongs on the definition of correctness (spec draft, tests, critique) and the cheap one on generation, because the generator is the role the harness assumes is wrong.

Critic question list (fixed, the agent answers each with evidence or "none found"):

1. Which spec requirements have no test that would fail if they were violated?
2. Which failure modes named in the spec (errors, timeouts, partial failure, invalid state) have no test?
3. Is any implementation branch reachable only by the exact inputs the tests use (overfit)?
4. Does any test mock the module under test, the boundary it claims to cross, or the database (R-401 items 1, 2, 5)?
5. Which new code paths bypass a layer (R-303), duplicate an existing service (R-308), or add a dependency the spec did not name?
6. Where does state change without a test for the transition, the concurrent case, or the retry?
7. Where is the code green but operationally unsafe (no timeout, swallowed error, unbounded input, missing request ID)?

Output: findings with `file:line` per R-804, then a "Candidate tests" list in prose. The critic writes no test, so it cannot satisfy its own finding.

`spec-conformance-review.md` stays as the once-per-feature check before merge. The critic runs per slice and is cheaper; the two do not overlap because the critic's list is about what is missing and the conformance reviewer's is about what is present and wrong.

---

## 6. Guardrails: preventing the implementer from weakening verification

Ordered by what the mechanism catches, with what remains honor-system named.

1. **The lock and the role policy.** `tdd.sh red` writes `.claude/tdd-lock.json` naming every test, fixture, and spec path for the slice with its hash. `protected-path-guard.sh` denies any Write, Edit, or Bash mutation of a locked path while the file exists, and independently denies any write outside the calling role's trees using the `agent_type` field the hook input carries in subagent context. In the main session (no `agent_type`) only the lock and the always-protected set apply, which is what the Standard tier needs. `tdd.sh green` recomputes the hashes against both the lock and the RED commit's git objects, so a bypass through an unusual shell form still fails at GREEN. Remaining gap: a determined agent can obfuscate a shell command past a regex; the harness already states this scope (`enforce/README.md:46`), and the GREEN hash check is the backstop that does not depend on the regex.
2. **Skip and only.** Existing `content-gate.sh`. Extend its Bash path for heredoc writes into test files (the open 2026-08-21 P2), or let the lock cover it: a locked test file cannot be rewritten by any tool.
3. **Deleted tests and reduced counts.** `tdd.sh green` requires every RED test id to pass by name and the full-suite pass count to be at or above the recorded baseline; deletion lowers the count and removes an id.
4. **Changed assertions, expected values, fixtures.** Hashes. Fixture directories (`__fixtures__/`, `__mocks__/`, `testdata/`, `spec/factories/`, `e2e/`) are included in the lock by default.
5. **Exception swallowing.** Existing ESLint, ruff, golangci, and RuboCop rules; widen the ESLint scope from server trees to any `services/` and `clients/` tree.
6. **Mocks that bypass the behavior.** `no-self-mock` (decidable: the mocked specifier resolves to the module the test file is named for or imports as its subject) and `behavior-assertion-required` (decidable: a test block with `toHaveBeenCalled*` and no other matcher). Anti-pattern 5 (repository test mocks the pool) is decidable in `__tests__/repositories/**`: deny `vi.mock` of a path matching `pool|db|database`. Anti-patterns 2, 4, 6, 7 stay with the judge when it runs, and with the critic's question 4 until then.
7. **Gate inputs.** `.claude/verify.sh`, `.enforce.json`, `.enforce-baseline.json`, and the lock are always-protected paths; `package.json` test/typecheck scripts and test-runner configs ask. `ratchet.mjs --update` moves to the ask list in `settings.json` (`Bash(node * ratchet.mjs --update*)`).
8. **Subagent turns.** `verification-gate.sh` on `SubagentStop`, so an implementer cannot return red.
9. **History.** `git commit --amend`, `rebase`, `reset --hard`, and force-push are already ask-gated, so the RED commit the GREEN check compares against cannot be quietly rewritten.
10. **Escalation instead of mutation.** The implementer's only sanctioned response to a test it believes wrong is a `DISPUTE:` return. The human decides; the test author makes the change as a new RED. The lock makes any other path a denied tool call rather than a judgment.

What stays honor-system after all of this: whether the tests the test author wrote are the right tests. That is the critic's job and the human's, and no hook can take it.

---

## 7. Example: `hooks/protected-path-guard.sh` through the loop

The representative module in this repository is a hook plus its fixture plus its manifest row. Dogfooding the guard itself shows the loop on the harness's own conventions.

**SPEC** (`docs/specs/protected-path-guard.md`, human-written, template headings):

- Goal: no tool call mutates a path listed in `.claude/tdd-lock.json` while the lock exists.
- Inputs: PreToolUse JSON for `Write`, `Edit`, `Bash`; the lock file at the repo root of `cwd`.
- Outputs: `permissionDecision: deny` with a reason naming the path and R-410; silence otherwise.
- Acceptance criteria: B-1 Write to a locked path denies. B-2 Edit to a locked path denies. B-3 Bash `rm`, `mv`, `git rm`, `sed -i`, and `>` redirection naming a locked path denies. B-4 Write to an unlocked path is silent. B-5 No lock file: silent for every path except the always-protected set. B-6 `.claude/verify.sh` and the lock file itself deny without a lock.
- Invariants: never blocks reads; never spawns Node; under 50ms per call.
- Failure modes: unparsable lock file denies every write under `.claude/` and warns (fail closed on the lock, fail open elsewhere).
- Non-goals: detecting obfuscated shell; `tdd.sh green` covers that by hash.
- Domain vocabulary: locked path, always-protected path, lock file.

**RED** (test author, fresh context): writes `enforce/tests/protected-path-guard.test.sh` with one `deny`/`allow` line per criterion, in the payload style `content-gate.test.sh:7-9` already uses. Runs `enforce/tdd.sh red enforce/tests/protected-path-guard.test.sh`. The run fails with `No such file or directory: hooks/protected-path-guard.sh`, classified as missing-module, which is the expected RED for a new unit. The suite baseline is 43 enforcement fixtures green. Commit `test(enforce): R-410 protected-path guard fixture`, lock lists the fixture.

**GREEN** (implementer, fresh context): receives the spec path, the fixture path, the lock. Writes the hook: parse stdin, resolve the repo root from `cwd`, load the lock with `jq`, match `file_path` or the Bash command against locked and always-protected paths, emit the deny shape `content-gate.sh:21-27` already uses. Attempts to "simplify B-3 by editing the fixture" and is denied by the guard it is writing, because the fixture is locked. Runs `tdd.sh green`: fixture passes, suite 44 green, hashes unchanged. Commit `feat(hooks): R-410 protected-path guard`.

**REFACTOR**: extract `is_locked_path` and `bash_mutates_path` as functions; source `log-rule-fire.sh` the way the sibling hooks do; run `tdd.sh green` again; `hook-integrity-check.sh --update`; commit `refactor(hooks): split the protected-path guard matchers`.

**REVIEW** (critic, fresh context, read-only): expected findings from the seven questions, each of which is a real edge for this hook: a symlinked repo root (`pwd -P` versus `git rev-parse`), `git -C <path> rm`, a heredoc `cat > locked.test.ts <<EOF`, a `tee` in a pipeline, a lock file with a relative path when `cwd` is a subdirectory, and whether the always-protected set should include `settings.json` (it should not; `settings-change-guard.sh` owns it). Each accepted finding is a new criterion B-7 onward and a new RED. The critic writes none of the tests.

Then the deterministic layer: manifest row, `claude-md-lint` demands the R-410 norm and Spec, `enforcement-guard-check` demands the registration, CI runs the fixture.

---

## 8. Minimal implementation plan

The smallest set that captures most of the value, in order, each shippable alone:

1. **`hooks/protected-path-guard.sh` + `enforce/role-policy.json` + `.claude/tdd-lock.json` convention + fixture + manifest row + `settings.json` registration.** Closes C-1 and C-2 and gives H-1 its enforcement. Roughly 140 lines of shell and a 50-line fixture (payloads with and without `agent_type`). The always-protected set is worth shipping even if nothing else on this list does.
2. **`enforce/tdd.sh red|green` + fixture.** Closes C-3 and gives step 1 its hashes. The stack-detection block is lifted from `verification-gate.sh`. Roughly 150 lines.
3. **`SubagentStop` registration of `verification-gate.sh`** plus one fixture case. Closes C-4. Ten lines.
4. **Three agent files and the `tdd-gated-dispatch` rewrite**, R-705 and R-707 in `rulebook/agents.md`, the `task-start` tier table, and the `feature-create`/`task-cleanup` placeholder removal. Prose, but prose whose boundaries steps 1 to 3 enforce.
5. **`prompts/spec-template.md`** and the two-heading extension of `spec-glossary-check.sh`.
6. **`import-x/no-cycle`, the widened observability scope, and the two test-quality ESLint rules** with fixtures.

Steps 1 to 3 are one branch and one PR under R-511. Steps 4 and 5 are a second. Step 6 is a third. Deferred until a real TypeScript project exercises the loop: mutation testing on changed files, the dependency-addition guard, the judge-tier extension, and any Python, Ruby, or Go analog of `tdd.sh`'s failure classification beyond the pytest and go test patterns named above.

Not built, by decision: a spec schema, an orchestrator, coverage thresholds, per-role branches, and model diversity requirements. The loop above is three agent files, one hook, one script, one settings entry, and rule text.

---

## Verified clean (no finding)

- `content-gate.sh` R-401 and R-405 checks fire on Write and Edit for every source extension and are covered by 22 fixture cases, positive and negative.
- `fix-commit-requires-test.sh` handles the chained `git add && git commit` form and heredoc subjects; both are fixture-covered.
- `verification-gate.sh` never memoizes a red tree and short-circuits on `stop_hook_active`; fixture cases 3, 4, and 8.
- Manifest and settings closure hold in both directions at HEAD; `hook-hashes.txt` is current.
- `spec-conformance-review.md` is genuinely read-only by frontmatter and states its Bash restriction as binding.
- The fixture suite in this repo tests behavior (payload in, decision out) rather than implementation structure; the three environment-sidestepping fixtures are already filed in `ISSUES.md` (2026-08-21 P2) and are not re-reported.

## What would make this assessment wrong

- If `superpowers:subagent-driven-development` already dispatches a separate test-writing agent per task with a hash check on return, H-1 and part of C-1 shrink to "wire it into `task-start` Standard tier". The plugin is not in this checkout; read `skills/subagent-driven-development/SKILL.md` in the installed plugin to settle it.
- The hooks reference documents `agent_id` and `agent_type` as common fields present in subagent context; the design above depends on that field reaching a `PreToolUse` command hook for `Write`, `Edit`, and `Bash`. Confirm on the real build before step 1 lands: register a scratch hook that logs `jq -r '.agent_type // "none"'` and dispatch one subagent. If the field is absent, the role boundary falls back to the lock plus each agent's own `hooks:` frontmatter block (also documented), at the cost of the settings closure guards not seeing those registrations.
- The `verification-gate.sh` output shape (`{decision: "block", reason}` and the `stop_hook_active` input field) is the shape the fixture proves the hook emits, and the harness has relied on it since 2026-09-04; the current hooks reference excerpt read for this assessment shows `continueConversation` and `additionalContext` instead. Confirm the Stop contract on the installed build before adding the `SubagentStop` registration, since a shape mismatch would fail open silently.
- If a real project already runs coverage or mutation tooling outside `~/.claude`, H-6 is a wiring task rather than an addition.

## Decisions (2026-09-06, Ian, asked one at a time)

1. First stack: TypeScript on Vitest; `tdd.sh` classifies Vitest output first, other runners follow when a project exists.
2. Plans carry complete code (`writing-plans` default): the test author receives the spec path and the task's behavior line only, never the plan's code blocks; the `tdd-gated-dispatch` rewrite strips code fences from what it hands the test author.
3. Standard tier is enforced: `tdd.sh red` before any production edit, the lock active until `tdd.sh green`, in a single session.
4. Claude Code is 2.1.251 or later: the guard keys on `agent_type`, with lock-only behavior when the field is absent (main session).
5. Routing: test author and critic on Opus, implementer on Sonnet, for Complex and Saga; Standard stays on the active model.
6. Specs come both through `brainstorming` and from outside via `spec-grounding`: the template lives in `prompts/spec-template.md`, the glossary hook checks the extra headings under `docs/superpowers/specs/`, and `spec-grounding` adds them when it rewrites an external spec.
7. Disputes: the human arbitrates, always; a `DISPUTE:` return stops the session with the test, the claim, and the spec line; any change is a new RED by the test author.
8. Gate inputs are rare edits: deny `.claude/verify.sh`, `.enforce.json`, `.enforce-baseline.json`, and the lock; ask on `package.json` test scripts and runner configs.
9. Judge key still pending: R-401 anti-patterns 2, 4, 6, 7 are labelled critic-only in the rule text; self-mock and mock-only assertions become ESLint rules regardless.

Superpowers stays as the process skeleton; `skills/tdd-gated-dispatch/SKILL.md` is rewritten as the integration point between `writing-plans` and `subagent-driven-development` rather than a new skill, and no Superpowers skill is forked into this repo.
