# The Operating Protocol

**Version:** 2026-06-05
**Scope:** Global (applies across every project under Claude Code)
**Status:** Derived from lessons shipped across multiple production projects. Each layer below was added in response to a specific failure.

## Abstract

The protocol is a chain of interlocking safety layers, not a rulebook. Each layer assumes the next will catch what it misses; no layer is individually sufficient.

**Why interlocking.** Behavioral rules fail silently under pressure. Audits catch what rules miss but fire only on cadence. Tests catch what audits miss but only for code under test. Hooks catch what tests cannot reach, mechanically, at the tool-call layer. Process sequences them so every unit of work passes through all layers at least once. Lifecycle handles the edges. Memory carries lessons so the chain does not rebuild itself every session.

**Mechanical vs prose.** Six of the eleven layers (Memory loading, Skills, Hooks, Session lifecycle, Secret handling, Destructive-action guards) are mechanically enforced: scripts and auto-loaders run whether the session remembers to invoke them or not. Five (Rules, Audits, Tests, Process, Git hygiene) are prose: definitions, conventions, and cadences that depend on the session honoring them. The interlocking-chain framing describes the design goal, not a uniform property. The framework's intent is to migrate prose layers down to mechanical ones as enforcement paths get wired; the criticism audit at `docs/audits/2026-04-08-criticism.md` tracks which prose rules are still honor-system.

**How it functions.** Before action: memory loads prior lessons, skills provide structured capabilities, rules constrain output, the brainstorming hard-gate prevents code without a design. During action: tests prove behavior before commit, hooks block banned patterns at the tool layer, process routes each step through review. After action: audits critique antagonistically from autonomous advisor roles (three standing, the rest fired on signal), verification demands evidence before claims, monitoring polls every deploy surface. Across sessions: handoff docs capture state, git status checks catch cross-session drift, memory carries the protocol forward.

**Why it grows.** No layer is pre-emptive. Every layer earned its place: a specific failure happened, the class was named, the missing layer was identified and added. The discipline is not "follow the rules"; it is "add the next layer the next time a failure teaches you where one is missing."

**What makes it work.** The chain. A "never put secrets on argv" behavioral rule failed silently; a mechanical hook catching argv secret patterns cannot fail the same way. A runbook-vs-code drift shipped to staging; an audit section now scans for it pre-merge. Eleven classes of failure have happened; eleven layers exist. The twelfth class will produce the twelfth layer.

## Framing

This document is not a rulebook you follow to avoid mistakes. It is a **failure-mode catalog**: each layer names a way the system has been burned, and the mechanism that now catches that burn before it reaches production. The discipline is not "follow the rules"; the discipline is "build the next layer the next time a failure teaches you where one is missing."

The original development strategy was "give Claude a task, tell it to do the task, let it run unsupervised with no guardrails." That strategy failed across approximately two weeks of real use. The protocol below is the scaffolding of guardrails, recursive processes, antagonistic checks, and self-evaluations that replaced it. The goal is not to constrain Claude. The goal is to make Claude a reliable application-building machine by catching every class of failure the unrestricted version demonstrated.

## The Eleven Layers

The protocol is a layered safety system, not a list of rules. Each layer catches a different failure mode the prior layer misses. When a new failure class is discovered, a new layer (or a new check within an existing layer) is added; old layers are never weakened.

### Layer 1: Memory (persistent state across sessions)

Four memory types stored in per-project directories with a `MEMORY.md` index. `global-memory/INDEX.md` is auto-loaded by the `SessionStart` hook. Per-project `MEMORY.md` files are read on demand by Claude when the task references prior work, when the user explicitly asks to recall, or when relevance becomes obvious; they are not auto-injected by the runtime.

- **user**: role, goals, preferences, knowledge. How to collaborate with this specific person.
- **feedback**: guidance the user has given about how to approach work, in both corrective and confirmatory form. Captures why, not just what.
- **project**: ongoing work, goals, bugs, incidents. State that changes fast and is not derivable from current code.
- **reference**: pointers to external systems (Linear, Slack, Grafana) so Claude knows where to look for up-to-date information.

Global memory at `~/.claude/global-memory/` carries cross-project lessons. Writes happen during work, never post-hoc. Memory never stores secrets, ephemeral state, or information trivially derivable from the current code (git history, file paths, architecture).

Memories are accessed when relevant, when the user references prior-conversation work, or when the user explicitly asks to check or recall. Stale memories are recognized and updated rather than trusted blindly.

### Layer 2: Skills (capabilities, not prose)

The Superpowers framework provides specialized skills for the high-risk or high-leverage tasks that Claude does often:

- `brainstorming`: HARD-GATE against any implementation action before a design has been presented and the user has approved it. Asks questions one at a time, proposes 2-3 approaches, presents design in sections, writes a spec doc.
- `writing-plans`: bite-sized task structure (2-5 minute steps), exact file paths, complete code in every step, no placeholders, test-first patterns, frequent commits. Every task has a complexity tag.
- `executing-plans`: inline execution of a plan with checkpoints for review.
- `subagent-driven-development`: dispatch a fresh subagent per task plus a reviewer for plans with 5+ independent tasks.
- `dispatching-parallel-agents`: canary-first rule (run one to validate the pattern before fanning out N).
- `systematic-debugging`: structured debugging before proposing any fix.
- `test-driven-development`: write the test before the implementation, confirm it fails, implement, confirm it passes.
- `verification-before-completion`: require evidence (command outputs, file contents) before claiming work is done.
- `requesting-code-review` and `receiving-code-review`: structured review with technical rigor, not performative agreement.
- `using-git-worktrees`: isolated workspaces for feature work.
- `finishing-a-development-branch`: explicit skill for completing and integrating work.

Skills are invoked via the `Skill` tool at the start of any task that matches their description. Skipping a skill that applies requires explicit user override. The brainstorming HARD-GATE in particular is absolute: no implementation action of any kind until the user has seen and approved a design.

### Layer 3: Rules (must / must not)

Rules are layered at three scopes:

- **Global**: `~/.claude/CLAUDE.md`. Applies to every project.
- **Project category**: `~/Desktop/code/personal/.claude/CLAUDE.md` and similar. Applies to a group of related projects.
- **Project-specific**: `<project>/CLAUDE.md`. Applies to one repo.

Convention files (`~/.claude/CLAUDE-BACKEND.md`, `CLAUDE-FRONTEND.md`, `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md`, `CLOUD-DEPLOYMENT.md`, `KNOWN-ISSUES.md`) are read on demand when the task touches that layer, never preloaded. This keeps context lean and forces Claude to consult conventions deliberately rather than passively.

Output hygiene rules (universal):

- **No em dashes (U+2014) anywhere.** Not in responses, code, comments, commit messages, markdown, docs, subagent prompts, test fixtures, audit reports. The em dash is the single most recognizable AI writing tell; the user requires clean, AI-tell-free output and considers any em dash a violation of trust. Substitute: period, comma, semicolon, colon, parentheses, or line break.
- **No token streaming in any AI output.** No SSE, no chunked text, no typewriter animations, no fake streaming. AI output is an artifact, not a conversation. The streaming transport is the most recognizable AI tell in the product UX; clean, AI-tell-free output requires its absence.
- **Default to the truth.** When marketing copy and backend behavior disagree, the default fix is to change reality to match the claim, not the claim to match reality. Trust is the primary go-to-market asset; shipping a claim the product does not honor erodes it irreversibly.

Commit-subject conventions:

- `feat:` for new user-facing functionality
- `fix:` for bug fixes that have a reproducing test
- `chore:` for infra, config, build-system, non-code-logic changes that cannot be verified by a unit test
- `docs:` for documentation-only changes
- `test:` for test-only changes
- `refactor:` for code restructuring with no behavior change

`fix:` commits require a paired test (enforced at the commit-msg hook layer); if a change cannot be verified by a unit test, the subject must be `chore:` or `docs:`.

### Layer 4: Audits (antagonistic self-evaluation)

Autonomous advisor roles, each with its own canonical file at `~/.claude/audits/<role>.md`, each with a protective disposition and advisory autonomy to declare findings as blockers independent of perceived scope. Roles split into three standing roles (run pre-launch and on signal) and on-request roles (run only when their specific signal is present, per R-402).

**Standing roles:**

- **Engineering (CTO)**: tech debt, operational gaps, broken tests, unshipped E2E, missing CI, unmaintainable architecture. Includes a **Credential Exposure Scan** (git history, working tree, Claude Code JSONL transcripts across ALL projects, shell history, vendor CLI config files, with ERE patterns for every common credential format and a P0 rotation-then-purge remediation) and a **Runbook-vs-Code Drift Scan** (compares `docs/runbooks/**` against code comments and config conventions; any contradiction is a latent incident).
- **Security (CISO)**: breach, data loss, auth bypasses, prompt injection, dependency CVEs, credential leakage.
- **Criticism (Devil's Advocate)**: fatal strategic flaws, unsustainable unit economics, organizational self-deception, moat delusion.

**On-request roles** (fire only on their matching signal, R-402):

- **UX (CXO)**: broken flows, accessibility violations, unconfirmed destructive actions, untested user stories, cognitive load.
- **Design (CDO)**: style drift, brand erosion, design-system violations, visual inconsistency.
- **Marketing (CMO)**: positioning confusion, weak conversion copy, banned-word violations, missing trust signals.
- **Financial (CFO)**: unsustainable cost structure, missing spending caps, margin violations, unaudited paid services. Cost-discipline lens includes a Kill / Keep / Defer matrix and a marginal-cost test for every new paid line item.
- **Legal / Compliance**: missing legal documents, unsubstantiated marketing claims, regulatory action risk.
- **Customer**: a plain-language walkthrough as an actual customer (not a UX expert): marketing site, signup, first session, first paid action, reporting friction, confusion, trust breaks, and delight. Counterpart to the UX audit, not a replacement.

Each role is an intelligent autonomous agent with documented advisory autonomy (what it can declare independently) and escalation boundaries (when it surfaces rather than decides). Dispositions default to protective and critical; never suppress a category of findings because it "feels out of scope."

Audit history is dated: `docs/audits/YYYY-MM-DD-<role>.md`, never overwritten. Every audit run produces new dated files alongside the old ones so history is preserved. Findings are triaged by severity (P0 / P1 / P2 / P3) and effort (S / M / L). P0 and P1 findings are fixed in the current effort (test-first). P2 and P3 findings are logged to `ISSUES.md` or `TODO_BEFORE_LAUNCH.md` as rolling logs.

Audits run on signal, not on a fixed cadence (R-400, R-402). Pre-launch runs the three standing roles. A specific risk signal runs the matching role only. 5-plus commits on a single surface runs Engineering only, scoped to that surface. On-request roles fire only when their specific signal is present. There are no reactive multi-role sweeps; a reactive full sweep is the single most expensive action the harness can take. Verify the signal condition before running any audit (R-502).

### Layer 5: Tests (earned confidence, not claimed)

Test discipline is exhaustive because test theater is the class of failure most likely to ship invisibly:

- **Test-first for every bug.** Write a test that reproduces the failure. Run it. Confirm it FAILS. Fix the code. Run the test. Confirm it PASSES. Run the full verification chain. Only then commit and deploy. Never claim a fix without a failing-then-passing test.
- **Concrete-value tests for business logic.** Any function computing a price, credit cost, token estimate, margin, or business-visible number must have at least one unit test with a mechanical `expect(fn(concreteInput)).toBe(concreteExpectedValue)` assertion plus a comment explaining the rationale.
- **30-minute rule.** If two `fix:` commits touch the same file within 30 minutes, stop. The original fix did not understand the full scope. Write a reproducing test before the third attempt.
- **No confidence theater.** Nine anti-patterns are banned: self-mock (mocking the module under test), mocking the dependency that IS the thing being tested, mock-call assertions without behavior assertions, snapshot-only tests with no behavioral assertion, mocking the integration boundary the test claims to cross, tautological assertions, loose-shape assertions as the sole assertion, suppressed or skipped tests (now banned outright, see next item), always-failing tests that persist across sessions.
- **No suppressed tests.** `test.fixme`, `test.skip`, `it.skip`, `xit`, and `xtest` are banned outright (R-216). A test that cannot pass is deleted, not deferred, and re-added when the underlying capability exists. This supersedes the earlier allowance for skipped tests carrying a context comment and triage ID.
- **LLM output tests cannot mock the SDK as their sole coverage.** Every LLM consumer (parser, validator, formatter) must have at least one test using a real captured model response committed as a fixture, not a hand-written mock shaped like the expected output.
- **User story ↔ E2E coverage.** Every documented user story must have at least one E2E test. Target 100% coverage.
- **Mocked vs real API split.** E2E tests mock outbound third-party APIs deterministically. A separate small "real-API smoke" suite hits the real endpoints nightly, gated behind an env flag, to prove live wiring still works without burning quota in the fast local loop.
- **Pre-push fast lane + CI full suite.** Pre-push git hook runs a ~30-second fast lane (smoke + auth + one happy-path journey). CI runs the full E2E suite on every push and blocks merge on failure. Both layers are required; either alone is insufficient.
- **Pre-commit hooks lint and format staged files only.** Never full-repo in pre-commit (too much friction). Full-repo sweeps live in pre-push and CI.

### Layer 6: Hooks (enforcement at the tool layer)

Hooks are mechanical enforcement that runs before Claude's behavioral rules have a chance to apply. Current hooks:

- **PreToolUse Bash secret scan** (`~/.claude/hooks/secret-scan.sh`): scans every Bash command for known secret patterns (Anthropic, Stripe, GitHub, Vercel, Resend, Render, Slack, AWS, SendGrid, Google API, SSH private keys) and blocks the call with a clear error if any pattern matches. Wired via `~/.claude/settings.json` PreToolUse hook with matcher=Bash. Length thresholds are calibrated so placeholders like `whsec_REDACTED` and `sk-ant-api03-...` do not trip the hook.
- **Pre-commit hook (lefthook)**: runs format-check and lint on staged files only.
- **Pre-push hook**: runs format + lint + build + test on the full repo. This is the last local gate before code leaves the machine.
- **Commit-msg hook (fix-commit-gate)**: enforces the rule that `fix:` commits include at least one test file. Commits that violate this rule are blocked with an explanation.
- **PreToolUse em-dash block** (`no-em-dash.sh`): blocks any tool call that would write a U+2014 em dash (R-001), the single most recognizable AI writing tell.
- **PostToolUse output redaction** (`redact-output.sh`): redacts tokens, keys, cookies to `[REDACTED]` and PII to `[PII]` in tool output before it reaches the transcript (R-101, R-104).
- **Conflict-marker block** (`conflict-markers.sh`): blocks commits containing unresolved merge-conflict markers (R-211).
- **Migration-defaults guard** (`migration-defaults-guard.sh`): enforces migration default conventions (bare strings for constants, `pgm.func()` for SQL expressions, no nested quotes) (R-214).
- **Destructive-DB guard** (`destructive-db-guard.sh`): PreToolUse deny/ask on destructive and remote-write database operations. See Layer 11.

Hooks are non-negotiable without explicit user override. The Bash secret-scan hook specifically exists because a behavioral rule ("never put secrets on command lines") was insufficient to prevent a plaintext Anthropic production API key from landing in shell history, tool-call transcripts, and argv space. A behavioral rule that fails silently is worse than a mechanical gate that fails loudly.

### Layer 7: Process (how work flows)

The canonical work sequence:

1. **Brainstorm** (required for any creative work): understand the idea, ask clarifying questions, propose approaches, present design, write a spec to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, get user approval before moving on.
2. **Plan**: turn the spec into a bite-sized implementation plan at `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` with test-first tasks, exact file paths, complete code in every step.
3. **Execute**: follow the plan task-by-task. Scale to task size: inline under 5 tasks, subagent-driven for 5+, complexity tags determine the review loop depth.
4. **Verify**: run tests, lint, format, build. Confirm every success claim with evidence.
5. **Commit**: one logical change per commit, conventional subjects, paired tests where required.
6. **Push**: trigger CI and deployment workflows.
7. **Monitor**: poll all four deploy surfaces (GitHub Actions, Railway, Vercel, production health endpoints) at ~20-30 second intervals for up to 5 minutes. Never claim a deploy is done because `git push` returned zero.

Model routing is part of process, not afterthought:

- **Opus** for hard tasks: complex refactors, security-sensitive logic, ambiguous design problems, strategic ambiguity.
- **Sonnet** for medium tasks: targeted features, well-scoped refactors, normal feature work, rubric-driven audits.
- **Haiku** for trivial tasks: file moves, doc edits, single-line config changes, formatting.

Never default to Opus because it is smarter. The cost delta is real, and the quality delta on simple tasks is negligible.

### Layer 8: Session lifecycle

Sessions have durable edges. Drift at the edges compounds across sessions.

**Session start**:

- Read global memory index (`~/.claude/global-memory/INDEX.md`) before any substantive work.
- Read project-level handoff docs (`docs/audits/*session-handoff*.md`, `docs/audits/*outstanding-todos*.md`, recent dated audits). Trust their ordered task lists over Claude's own instinct.
- Run `git status` on the project repo AND on `~/.claude`. Dirty state in either must be acknowledged and triaged (commit now, explicitly defer with reason, or fold into the session's task list). Silent ignore is banned.
- Read project-specific `CLAUDE.md` and any relevant convention files.

**Session wrap**:

- If outstanding tasks exist and the session is ending, offer a session handoff doc proactively. Do not wait for the user to ask.
- Commit and push any edits to `~/.claude` before wrapping up. The rules repo is not a diary; it is a cross-session source of truth.
- Dual-commit discipline: sessions that edited both a project repo AND `~/.claude` must commit to BOTH before the project push. The common failure mode is "commit project, forget `~/.claude`, leave drift."

Handoff docs follow a fixed format: last commit SHA, production state verified, what shipped grouped by topic, what is pending grouped by urgency, recommended next session with ordered task list, workflow reminders, companion docs. Aim for under 4KB of bullets unless the session genuinely shipped something that needs detailed context.

### Layer 9: Secret handling (universal rule)

The highest-cost failure class. Rules layered by preference:

1. **Preferred: dashboard-only.** Give the user the exact URL for the vendor dashboard where the value needs to be set. User clicks, pastes, saves. Claude verifies the variable is set (without retrieving the value) using read-only APIs that return names and metadata only.
2. **Acceptable fallback: stdin-fed CLI.** If the vendor CLI supports it. The value is loaded from a filesystem path the user controls (never embedded in the command), piped to the CLI, and never appears in argv.
3. **Banned: value on command line.** Never. The argv is persisted to shell history, tool-call transcripts, permission prompts, and process listings. This is the rule the Bash secret-scan hook mechanically enforces (Layer 6).
4. **Banned: value in chat responses.** Even partially. Never echo, even in commit messages, error messages, log lines, analytics events, or subagent prompts.
5. **Banned: value in files in the repo.** Even temporarily. Git hooks, crash dumps, editor autosaves, and cached indexes all create exposure windows.

On detection of a leak: **rotate first, purge second**. Rotation makes the leaked value worthless. Purging the surface where the leak was found is cleanup, not remediation. Rotate at the vendor dashboard, update the consumer via the dashboard, verify the variable is set, revoke the old value. Only then consider purging the persistence surface (git history, session transcripts, shell history, vendor CLI cache).

### Layer 10: Git hygiene

The history must stay honest so forensic reports are possible:

- **Never amend** a commit that has not been pushed. Create a new commit instead. Amending risks losing work and breaks the forensic trail.
- **Never skip hooks** without explicit authorization (`--no-verify` requires per-commit user permission).
- **Never force-push to main.** Warn the user if they request it.
- **Prefer dedicated tools** (Edit, Write, Glob, Grep, Read, TaskCreate) over Bash for file and task operations. Dedicated tools let the user review each action in the UI. Bash is reserved for system commands that require shell execution.
- **Commit bug IDs separately.** Never batch unrelated fixes in a single commit. One commit per triage ID. The exception is two adjacent IDs that share a single line of code; the commit subject must be explicit (`fix(B5, B12): ...`) with a body line-item per ID.
- **`style: format all files` commits are smoke.** Repeated format drift in a short window means a hook is failing silently. Investigate root cause before landing the drift fix. Never land a style-drift commit without a paired "hook verification" commit in the same session.
- **Production-asset build contracts require a dist-content smoke test.** Runtime-loaded assets that live outside the compiled TypeScript graph (JSON, YAML, SQL, markdown prompts) will not be copied to `dist/` by `tsc`. A build-smoke script must assert the file exists under `dist/` at the expected resolved path, and must run in CI and inside the Dockerfile build stage.

### Layer 11: Destructive-action guards (data-loss prevention)

The newest failure class: irreversible production data loss, distinct from secret leakage (Layer 9). Destructive database operations against production (`DROP DATABASE` / `DROP TABLE`, `TRUNCATE`, `DELETE FROM`, `pg_restore`, `migrate:down`) are hard-blocked at the tool-call layer by `destructive-db-guard.sh` (PreToolUse): Claude cannot run them, no confirmation is offered, a human must perform them manually. The same operations against staging or other remote databases, and any write (`UPDATE` / `INSERT` / `ALTER` / `CREATE`) against a managed or remote database, require explicit per-turn user confirmation. Local databases are exempt. Tests, builds, and scripts that internally wipe data are never run against a non-local `DATABASE_URL`. Codified as R-110. Like the secret-scan hook (Layer 6 / Layer 9), this layer exists because a behavioral rule against destructive operations fails silently under pressure; a mechanical PreToolUse deny cannot fail the same way.

### Layer 12 (and beyond)

New layers get added every time a new failure mode is discovered. The pattern:

1. Failure happens.
2. Identify the class of failure (not just the specific incident).
3. Identify the layer that should have caught it.
4. If the layer exists but failed, harden it.
5. If no layer exists, add a new one.
6. Document the failure-to-layer link in the commit message and in the relevant audit role file.
7. Future sessions are blocked from repeating that specific failure.

The current protocol has eleven layers because eleven classes of failure have been experienced. The next layer will be added when the twelfth class is experienced. The goal is not to pre-emptively anticipate every possible failure; the goal is to guarantee that every failure that DOES happen becomes a layer so it cannot happen twice.

## How the layers interact

- **Layer 1 (memory)** carries lessons across sessions so they are not re-learned.
- **Layer 2 (skills)** turns memory into action by providing structured capabilities for high-leverage tasks.
- **Layer 3 (rules)** constrains the action by specifying what must and must not happen.
- **Layer 4 (audits)** critiques the action antagonistically from multiple autonomous advisor perspectives.
- **Layer 5 (tests)** proves the action works via mechanical evidence.
- **Layer 6 (hooks)** enforces what the other layers assume, at the tool-call layer, mechanically.
- **Layer 7 (process)** sequences when each layer fires within a unit of work.
- **Layer 8 (lifecycle)** handles the edges of units of work (start, wrap, handoff).
- **Layer 9 (secrets)** is the universal backstop for the highest-cost class of failure.
- **Layer 10 (git)** keeps the history honest so forensic reports are possible.
- **Layer 11 (destructive-action guards)** is the universal backstop for irreversible data loss, the way Layer 9 backstops secret leakage.

Each layer is individually insufficient. The rules (Layer 3) assume the audits (Layer 4) will catch what the rules miss. The audits assume the tests (Layer 5) will catch what the audits miss. The tests assume the hooks (Layer 6) will catch what the tests cannot reach. The hooks assume the process (Layer 7) routes work through them. The process assumes the lifecycle (Layer 8) handles the edges. The lifecycle assumes the memory (Layer 1) carries the prior lessons forward. The chain is load-bearing end-to-end.

## What changed between 2026-04-01 and 2026-04-08

Six of the ten layers were in place at the start of this week. The week's incidents hardened the remaining four and added new sections to several existing ones:

- **Layer 6** gained the PreToolUse Bash secret-scan hook (2026-04-08, after a plaintext Anthropic production API key landed on a Railway CLI command line).
- **Layer 4** engineering audit gained the Credential Exposure Scan section (2026-04-08, same incident) and the Runbook-vs-Code Drift Scan section (2026-04-08, after `docs/runbooks/staging-provisioning.md` shipped a `NEXT_PUBLIC_API_URL` instruction that contradicted `next.config.ts` and caused a staging 401 incident).
- **Layer 8** gained three new session-lifecycle rules (2026-04-08, after an 11-file coordinated `~/.claude` batch from 2026-04-07 sat uncommitted for a day across multiple sessions before being noticed).
- **Layer 9** got the canonical memory file (`feedback_secret_handling.md`) codifying the secret-handling rule for future sessions.
- **Layer 3** gained the "default to the truth" rule (2026-04-07 FAQ consolidation brainstorm, after discovering a gap between marketing copy and backend behavior).

Every single addition was traceable to a specific failure. None of the layers were pre-emptive. All of them are responsive.

## What changed between 2026-04-08 and 2026-06-05

This revision reconciled the protocol with rule changes that had landed in `~/.claude/CLAUDE.md` and its Tier-2 files since the 2026-04-08 stamp:

- **Layer 11 added: destructive-action guards** (data-loss prevention), codified as R-110 and enforced by `destructive-db-guard.sh`. Irreversible production data loss is the eleventh failure class; production destructive DB operations are now hard-blocked at the tool layer.
- **Layer 4 audit model rewritten.** The eight-role, cadence-driven model (biweekly / monthly sweeps, full eight-role pre-launch sweep) was replaced by signal-driven audits with three standing roles (Engineering, Security, Criticism) and on-request roles (UX, Design, Marketing, Financial, Legal, Customer) per R-400 and R-402. A ninth role, Customer, was added.
- **Layer 5 gained the suppressed-test ban** (R-216): `test.fixme` / `skip` / `it.skip` / `xit` / `xtest` are banned outright, superseding the earlier skip-with-comment allowance.
- **Layer 6 hook inventory refreshed** to include the em-dash block, PostToolUse output redaction, conflict-marker block, migration-defaults guard, and the destructive-DB guard.
- **Layer 8 handoff cap corrected** from 8KB to 4KB to match R-302.

## The principle

The operating protocol is not a rulebook. It is a failure-mode catalog. The goal is not to follow the rules to avoid mistakes; the goal is to build the next layer the next time a failure teaches you where one is missing. Discipline is the habit of noticing the failure, naming the class, identifying the missing layer, and adding it immediately rather than hoping the next instance will be different.

The original development strategy, "give Claude a task, let it run unsupervised," was not wrong because Claude is untrustworthy. It was wrong because no system of any kind, human or machine, can produce consistent results without a layered safety structure around it. Every profession with high stakes (aviation, medicine, nuclear operations) has exactly this shape: a set of interlocking checks where each layer assumes the others will catch what it cannot. The protocol above is that structure, adapted to the specific failure modes Claude Code has demonstrated.

The protocol will keep growing. Every new layer earned its place the hard way.
