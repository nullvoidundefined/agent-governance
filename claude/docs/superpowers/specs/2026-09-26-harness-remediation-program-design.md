# Harness remediation program

**Ticket:** IAN-427
**Status:** draft, awaiting owner review
**Date:** 2026-09-26
**Sources:** the process and rule-system audit, `docs/audits/2026-09-26-process-and-rules.md` (IAN-419, PR #147), and a comparison of this harness against community harnesses supplied by the owner on 2026-09-26.

## Goal

Turn the audit's 15 findings, its Low list, its autonomy proposal, and three items from the community-harness comparison into one ordered program, so the work lands in a planned sequence instead of as a series of reactive fixes. The owner's goal, set on 2026-09-26, is much more autonomy and parallelism without losing reliability, and every ordering decision below is judged against it.

This spec is a program spec. It fixes each sub-project's scope, dependencies, merge path, and one acceptance line. It does not design any sub-project: every row marked Complex gets its own design spec, with its own adversarial spec review, when that row starts.

The three items taken from the comparison are:

1. A prompt-injection scan of tool output. No hook reads what `WebFetch` or an MCP tool returns today; the only PostToolUse hooks watch `Bash`, `Write`, `Edit`, and the task tools.
2. Enabling the operating-system sandbox, which `claude/settings.json` ships configured but disabled (`sandbox.enabled: false`).
3. Evaluating Rulesync, which generates Claude, Cursor, and Codex configuration from one source, against this repository's own `translate/` exporters. This overlaps the audit's Finding 3, which recommends generating `codex/` and `cursor/` at sync time instead of committing them.

The comparison's other three items (behavioral tests for skills, a skill-activation hook, context-file linting) are out of scope; see Non-goals.

## Domain vocabulary

- Program - this ordered set of sub-projects, tracked by IAN-427 - chosen over: "roadmap" because a roadmap implies dates, and this spec orders work by dependency rather than by calendar.
- Wave - a group of rows that share a purpose and may run in parallel once their dependencies land - chosen over: "phase" because phases imply that nothing in the next one starts before the previous one ends, and several rows here overlap waves.
- Row - one sub-project in the program table, which becomes one ticket and usually one PR - chosen over: "task" because R-213 and R-502 already use "task" for session-level work items.
- Security class - a PR whose diff the security-surface detector (`hooks/security-surface.sh`, #142) flags, or that changes a gate's allow or deny behavior, the sandbox, or the injection scan - chosen over: "sensitive PR" because the detector is the mechanical test and the second half names the harness-specific cases the detector's patterns do not cover.
- Freeze - the audit's rule that no new gate or rule lands until the correctness, unattended-safety, and parallelism rows do - chosen over: "moratorium" because the 2026-09-18 audit already used "freeze" for the same idea.
- Provisional setting - a process change recorded in a slice plan or the handoff and tried for a fixed period before it becomes rule text, per Finding 4 - chosen over: "experiment" because IAN-121 already uses "experiment" for a measurement with a verdict rather than a trial of a setting.
- Injection scan - the PostToolUse hook that inspects `WebFetch` and MCP tool results for text addressed to the agent - chosen over: "injection guard" because a PostToolUse hook runs after the model has the content, so it can flag and warn but cannot prevent delivery.

## Program table

| Row | Sub-project | Covers | Tier | Merge path | Depends on |
|---|---|---|---|---|---|
| 0 | Merge the audit | PR #147 | n/a | owner | none |
| 1 | Correctness pass | F1, F2, F10 | Standard | on green | 0 |
| 2a | Shared gate preamble | F6 | Complex | owner | 1 |
| 2b | Sandbox enablement | comparison item 2 | Standard | owner | 2a |
| 3a | Blob-hash integrity check | F3 step 1 | Complex | owner | 2a |
| 3b | Ports spike | comparison item 3, F3 step 2 | Investigation | on green | 1 |
| 3c | Ports build | the 3b verdict | Complex | on green | 3a, 3b |
| 3d | Per-worktree fixture lock | autonomy prerequisite 5 | Standard | on green | 2a |
| 4 | Injection scan | comparison item 1 | Complex | owner | 2a, 3a |
| 5a | Handoff and injection diet | F5 | Standard | on green | 1 |
| 5b | Rule and memory consolidation | F8, F9, F11 | Standard | on green | 1, 3c |
| 6a | Provisional-state mechanism | F4 | Standard | on green | 1 |
| 6b | Override path and advisory telemetry | F7 | Complex | owner | 2a |
| 6c | Fix-after-merge metric | F14 | Standard | on green | none |
| 6d | Autonomy trial | the audit's autonomy proposal | n/a | n/a | 6a, 6c, 3c, 3d |
| 7a | Enforcer-tag and manifest reconciliation | F12, Low list | Standard | on green | 3c |
| 7b | Bash hook chain consolidation | F13 | Complex | owner | 2a, 3c |
| 7c | Audit hygiene | F15 | Standard | on green | 0 |

"On green" means the PR merges on green CI plus a passed R-517 review, without an owner stop. "Owner" means the owner reads and merges. A row marked "on green" still goes to the owner when its PR falls in the security class (see Merge policy).

## Rows

Each row states its scope and the one condition that makes it done. Anything a row does not name is out of that row's scope.

### Wave 1: correctness

**Row 0, merge the audit.** The owner reads and merges PR #147 so every later row cites the audit on `main`. Done when `docs/audits/2026-09-26-process-and-rules.md` is on `main`.

**Row 1, correctness pass.** Land R-109 as a norm line, a Spec, and manifest entries for `push-semgrep-gate` and `push-eslint-gate` (F1). Write the trivial-tier merge path once in R-514's Spec as an explicit exception, matching `task-cleanup` and `task-start` (F2). Rename the R-517 section to `## Pre-merge review` with the gate accepting both names for one release, drop the Copilot clauses, rewrite R-211's autonomy clause to defer to the slice plan's merge mode, and define Gate 0 or stop using it (F10). Done when `grep` finds R-109 in `CLAUDE.md`, `reference.md`, and `manifest.json`, R-514 and both skills state the same trivial path, and `git-workflow-guard.sh` fixtures pass for both section names.

### Wave 2: unattended safety

**Row 2a, shared gate preamble.** One `gate-preamble.sh`, sourced by every PreToolUse and Stop gate, that normalizes `HOME`, denies when `jq` is missing, and installs an EXIT trap that emits a deny when the gate dies before printing a decision. One generic fixture runs every PreToolUse and Stop gate under `env -u HOME` and without `jq` on `PATH`, each with a known-deny payload. Done when that fixture passes for every registered gate, and the four gates and `verification-gate.sh` named in F6 deny instead of aborting.

**Row 2b, sandbox enablement.** Follow the procedure in `claude/enforce/README.md` ("Sandbox configuration (B-2)"): add the `sandbox.credentials` block (or `filesystem.denyRead` entries) covering the same paths as the `Read` deny rows, verify the key shape against the vendored schema, then set `sandbox.enabled: true`. Decide `failIfUnavailable` explicitly: `true` for unattended and cloud sessions, since `false` degrades to no sandbox silently. Done when an interpreter read of a fixture secret file (`python3 -c "open('<fixture>/.env')"`, in a throwaway `/tmp` tree per R-103) fails under the sandbox, both fixture suites pass with the sandbox on, and `git push` still works through the `excludedCommands` carve-out. The "honest gap" paragraph and the vector table in `claude/enforce/README.md` are updated in the same PR.

Row 2b depends on 2a only so that a sandbox-induced gate failure denies rather than allows.

### Wave 3: parallelism

**Row 3a, blob-hash integrity check.** Replace the checked-in `hook-hashes.txt` with a comparison against the git blob hashes of the commit recorded in `.sync-source`, then delete `hook-hashes.txt`. Done when `hook-integrity-check` detects a modified hook in a fixture, and two branches that each edit a different hook merge without a conflict.

**Row 3b, ports spike.** A 90-minute timeboxed investigation. Run Rulesync against this repository's rules and skills and compare its Codex and Cursor output with what `translate/` produces today, covering hook adapters, port maps, and agent rendering, which are the parts Rulesync is least likely to cover. The deliverable is a written verdict in `docs/audits/`, choosing one of: adopt Rulesync, adopt it for part of the output, or keep `translate/` and generate at sync time (F3 step 2). Done when the verdict is committed with the evidence behind it. Any dependency the verdict proposes goes through R-331.

**Row 3c, ports build.** Implement the 3b verdict. Whichever option wins, `codex/` and `cursor/` stop being committed and are generated at sync time, with CI keeping `--check`. Done when `codex/` and `cursor/` are gitignored, `sync.sh` generates them, and CI's port check passes.

**Row 3d, per-worktree fixture lock.** Replace the machine-wide flock in `run-fixture-shards.sh` (IAN-348, IAN-359) with a lock scoped per worktree plus a machine-wide concurrency limit of about half the cores, and leave the full suite to CI. Done when two worktrees run their affected shards at the same time without one waiting on the other, and a third run beyond the concurrency limit queues.

### Wave 4: untrusted input

**Row 4, injection scan.** A PostToolUse hook with the matcher `WebFetch|mcp__.*` that inspects the tool result for text addressed to the agent: instructions to run commands, claims of user or system authority, requests to ignore rules, and hidden or encoded text. Its own design spec settles four questions:

1. The detector: deterministic patterns only, a model-based classifier, or patterns first with a classifier on a hit. Any third-party classifier goes through R-331.
2. The action on a hit. A PostToolUse hook cannot withdraw content the model already has, so the options are a warning through `additionalContext`, a `decision: block` reason that stops the turn, or both, by severity.
3. Which MCP servers are trusted and skipped, and where that list lives.
4. The latency budget per call.

It sources the row 2a preamble, so a crash fails toward a warning, never toward silence. Done when a fixture set of injected pages and MCP payloads is flagged, a fixture set of ordinary documentation pages is not, and the hook's false-positive rate over one week of real `WebFetch` results is recorded in the PR.

### Wave 5: context diet

**Row 5a, handoff and injection diet.** Truncate the SessionStart injection at 8 KB with a pointer to the rest, make `handoff-check` deny over R-602's cap, and generate the handoff's pending list from Linear at write time (F5). Done when a fresh session's pre-turn context is measured and recorded in the PR, and it is at least 5k tokens below the audit's 17k measurement.

**Row 5b, rule and memory consolidation.** Cut the eight long norm lines to one sentence each (F8), delete the duplicate global-memory files and resolve the three conflicts (F9), and merge the overlapping rule pairs (F11). Done when `CLAUDE.md` is at least 5 KB smaller, every removed rule ID resolves to its surviving rule in `reference.md`, and the manifest fixture passes. This row waits for 3c so the rule edits do not regenerate committed ports.

### Wave 6: measure, then trial

**Row 6a, provisional-state mechanism.** Define where a provisional setting is recorded (the slice plan or the handoff), how long it runs, and what promotes it to rule text or retires it (F4). Done when `build-by-slice-require-review` and `PROTOCOL.md` describe the mechanism, and the autonomy trial (6d) is recorded through it.

**Row 6b, override path and advisory telemetry.** Build `CLAUDE_GATE_OVERRIDE="R-NNN: <reason>"`, honored by the gates and logged as decision `override`; make every advisory hook log `advise`; write the 30-day retirement scan that fills `retirement_candidates.md`; fix or delete `single-file-folder-reminder`; archive the six unused audit agents and give the other three a `docs/audits/` write boundary (F7). Done when a fixture shows an override allowing a denied call and appearing in the fire log, and the retirement scan produces a file from a fixture log. This is a security-class row because an override weakens every gate it touches.

**Row 6c, fix-after-merge metric.** A script that computes the fix-after-merge rate per product PR from git: a fix commit touching a file changed by a PR merged in the previous 7 days counts against that PR (F14). It reports weekly beside the ship log. Done when the script runs against one product repository and its output is checked by hand against that repository's history. The same PR either makes `human_speedup` required at close or deletes the field.

**Row 6d, autonomy trial.** Run the audit's risk-tiered merge authority, the daily digest, and queue-driven dispatch for two weeks as a provisional setting (6a). The trial ends early when the fix-after-merge rate (6c) rises above its pre-trial baseline by more than 5 percentage points. At the end, promote it to rule text or retire it, recorded through 6a. This program's own merge policy (below) already runs the first part of the trial.

### Wave 7: hygiene

**Row 7a, enforcer-tag and manifest reconciliation.** Generate the `CLAUDE.md` enforcer tags from `manifest.json` or add a fixture that diffs the two, and add a doctor check that every manifest ID resolves to exactly one rule definition (F12). Fold in the Low list: move dated history to `PROTOCOL.md`, record R-333's status, fix the stale README counts and R-001's contradictory steps, mark `security-surface.sh` as staged, pin local Semgrep and Ruff, and close the `R-NNN:` subject bypass. Done when the new fixture and doctor check pass and each Low item is fixed or ticketed.

**Row 7b, Bash hook chain consolidation.** Put the push-only hooks behind one push dispatcher, route every commit and push detector through `shell-command-scan.sh`, and extract repository identity and the exempt-list check into shared helpers (F13). Done when a plain `ls` spawns fewer hook processes than today's 26, measured and recorded in the PR, and every moved detector's existing fixtures pass unchanged. This is a security-class row because it rewrites how gates detect the commands they guard.

**Row 7c, audit hygiene.** Each audit opens with the prior audits' open items and their status, a recurring strategic finding gets a dated ticket or an explicit "won't do", and no new audit is commissioned while more than three earlier High findings are open without a ticket (F15). Done when the audit role files and `rulebook/audits.md` carry these three rules.

## Acceptance criteria

This spec ships no code. The program is complete when each row's done condition, stated in full under Rows, holds on `main`. Each criterion becomes that row's own B-lines, run as RED then GREEN slices, in the row's design spec (Complex) or slice plan (Standard).

- B-1: Row 1's done condition holds.
- B-2: Row 2a's done condition holds.
- B-3: Row 2b's done condition holds.
- B-4: Row 3a's done condition holds.
- B-5: Row 3b's verdict is committed.
- B-6: Row 3c's done condition holds.
- B-7: Row 3d's done condition holds.
- B-8: Row 4's done condition holds.
- B-9: Row 5a's done condition holds.
- B-10: Row 5b's done condition holds.
- B-11: Row 6a's done condition holds.
- B-12: Row 6b's done condition holds.
- B-13: Row 6c's done condition holds.
- B-14: Row 6d ends with a recorded promote or retire decision.
- B-15: Rows 7a, 7b, and 7c's done conditions hold.

## Ordering rules

1. A row starts only when every row it depends on has merged to `main`, verified with `git log main` rather than the PR badge.
2. Rows with no dependency between them may run in parallel, each in its own worktree.
3. The freeze: no new gate, hook, or rule lands outside rows 2a, 4, and 6b, and no advisory hook becomes blocking outside row 5a's `handoff-check` change, until row 3c merges. A defect found in the meantime is fixed in place, not by adding a gate.
4. When a row's design spec changes another row's scope, this spec is amended in the same PR, and the change is recorded under Amendments below.

## Merge policy

This program runs the audit's risk-tiered merge authority on itself, which is the first part of the autonomy trial.

- Each row's slice plan records its `**Merge mode:**` line at Gate 1, as R-514 requires. A row marked "on green" records the merge-on-green opt-in; a row marked "owner" records the default.
- A PR in the security class goes to the owner whatever its row says. The session runs the security-surface detector on the PR range before merging, and a hit changes that PR's merge path to owner.
- Every PR still gets the R-517 review, and a security-class range also gets the R-109 security review on the strongest model.
- Nothing here changes R-514's text. The per-row merge mode is the mechanism R-514 already provides.

## Ticketing

- One Linear ticket per row, opened when the row starts, not in advance, so the backlog does not fill with tickets whose scope a later row changes.
- Each ticket is related to IAN-427 and names its row number in the description.
- IAN-427 closes when this spec is approved and merged. The program's progress is read from the row tickets rather than from IAN-427.

## Invariants

- No row weakens an existing gate's deny behavior without being in the security class.
- Every row that adds or changes a hook ships its fixture in the same PR (R-516).
- No row depends on a committed `codex/` or `cursor/` file after row 3c.

## Failure modes

- **The spike finds no winner.** Row 3b's verdict defaults to keeping `translate/` and generating at sync time, which is the audit's own recommendation, so row 3c is never blocked on the spike.
- **The sandbox breaks the harness.** `sandbox.enabled: false` is the full rollback and `excludedCommands` is the per-command one. Row 2b reverts in one commit.
- **The injection scan's false-positive rate is too high.** The action falls back to warning only, and the rate is recorded for a later decision.
- **The trial raises fix-after-merge.** Row 6d ends early and the merge policy for later rows returns to owner merges.
- **A row grows past its scope.** The session stops, records the growth as a finding (R-214), and amends this spec rather than widening the row silently.

## Non-goals

- Behavioral tests for skills, a skill-activation hook, and context-file linting, the comparison's items 4 to 6. They add harness surface, and this program's goal is to reduce upkeep. Each can be raised again after row 6d.
- Community orchestrators (SuperClaude, gstack, Claude Code PM) and Ralph loops.
- Container-per-agent isolation (Container Use and similar). Row 2b enables the native sandbox only; a container or VM per agent is a separate decision after the trial.
- Designing any row in detail. Complex rows get their own design specs.

## Dependencies

- PR #147 merged (row 0).
- The security-surface detector from #142, which the merge policy uses.
- The R-109 security reviewer from #143 and PR #144.

## Amendments

None yet.
