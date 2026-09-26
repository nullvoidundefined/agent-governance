# Harness remediation program

**Ticket:** IAN-427
**Status:** draft, spec review folded in, awaiting owner review
**Date:** 2026-09-26
**Sources:** the process and rule-system audit, `docs/audits/2026-09-26-process-and-rules.md` (IAN-419, PR #147), and a comparison of this harness against community harnesses supplied by the owner on 2026-09-26.

## Goal

Turn the audit's 15 findings, its Low list, its autonomy proposal, and three items from the community-harness comparison into one ordered program, so the work lands in a planned sequence instead of as a series of reactive fixes. The owner's goal, set on 2026-09-26, is much more autonomy and parallelism without losing reliability, and every ordering decision below is judged against it.

This spec is a program spec. It fixes each sub-project's scope, dependencies, merge path, and done condition. It does not design any sub-project: every row marked Complex gets its own design spec, with its own adversarial spec review, when that row starts.

The three items taken from the comparison are:

1. A prompt-injection scan of tool output. No hook reads what `WebFetch` or an MCP tool returns today; the only PostToolUse hooks watch `Bash`, `Write`, `Edit`, and the task tools.
2. Enabling the operating-system sandbox, which `claude/settings.json` ships configured but disabled (`sandbox.enabled: false`).
3. Evaluating Rulesync, which generates Claude, Cursor, and Codex configuration from one source, against this repository's own `translate/` exporters. This overlaps the audit's Finding 3, which recommends generating `codex/` and `cursor/` at sync time instead of committing them.

The comparison's other three items (behavioral tests for skills, a skill-activation hook, context-file linting) are out of scope; see Non-goals.

## Domain vocabulary

- Program - this ordered set of sub-projects, tracked by IAN-427 - chosen over: "roadmap" because a roadmap implies dates, and this spec orders work by dependency rather than by calendar.
- Wave - a group of rows that share a purpose and may run in parallel once their dependencies land - chosen over: "phase" because phases imply that nothing in the next one starts before the previous one ends, and several rows here overlap waves.
- Row - one sub-project in the program table, which becomes one ticket and usually one PR - chosen over: "task" because R-213 and R-502 already use "task" for session-level work items.
- Owner class - a PR the owner reads and merges whatever its row says: see Merge policy for the full list - chosen over: "security class" alone because the list also covers migrations and concurrency, which are not security controls.
- Freeze - the audit's rule that no new or tightened gate lands until the parallelism rows do; this spec's exact permitted set is under Ordering rules - chosen over: "moratorium" because the 2026-09-18 audit already used "freeze" for the same idea.
- Provisional setting - a process change recorded in a slice plan or the handoff and tried for a fixed period before it becomes rule text, per Finding 4 - chosen over: "experiment" because IAN-121 already uses "experiment" for a measurement with a verdict rather than a trial of a setting.
- Injection scan - the PostToolUse hook that inspects `WebFetch` and MCP tool results for text addressed to the agent - chosen over: "injection filter" because the hook's first job is detection; replacement is one of its actions.
- Quarantine - replacing a flagged tool result, before the model reads it, with a notice that names the matched pattern and the source, through `hookSpecificOutput.updatedToolOutput` - chosen over: "redact" because redaction removes a known secret value, while quarantine withholds untrusted text whose danger is its instructions.
- Owner-granted override - a one-rule, one-command exception to a gate's denial that is valid only when the owner granted it in chat in the current turn - chosen over: "bypass" because R-203 already uses "bypass" for what an agent must never do on its own.

## Program table

| Row | Sub-project | Covers | Tier | Merge path | Depends on |
|---|---|---|---|---|---|
| 0 | Merge the audit | PR #147 | n/a | owner | none |
| 1 | Correctness pass | F1, F2, F10 | Standard | on green | 0 |
| 2a | Shared gate preamble | F6 | Complex | owner | 1 |
| 2b | Sandbox enablement | comparison item 2 | Standard | owner | 2a |
| 3a | Integrity check against the installed revision | F3 step 1 | Complex | owner | 2a |
| 3b | Ports spike | comparison item 3, F3 step 2 | Investigation | on green | 1 |
| 3c | Ports build | the 3b verdict | Complex | on green | 3a, 3b |
| 3d | Per-worktree fixture lock | autonomy prerequisite 5 | Standard | on green | 2a |
| 4 | Injection scan | comparison item 1 | Complex | owner | 2a, 3a, 3c, 3d |
| 5a | Handoff and injection diet | F5 | Standard | owner | 1, 3c |
| 5b | Rule and memory consolidation | F8, F9, F11 | Standard | on green | 1, 3c |
| 6a | Provisional-state mechanism | F4 | Standard | on green | 1 |
| 6b | Owner-granted override and advisory telemetry | F7 | Complex | owner | 2a, 3c |
| 6c | Fix-after-merge metric | F14 | Standard | on green | none |
| 6d | Autonomy trial | the audit's autonomy proposal | n/a | n/a | 3c, 3d, 6a, 6b, 6c |
| 7a | Enforcer-tag and manifest reconciliation | F12, Low list | Standard | on green | 3c |
| 7b | Bash hook chain consolidation | F13 | Complex | owner | 2a, 3c |
| 7c | Audit hygiene | F15 | Standard | on green | 0 |

"On green" means the PR merges on green CI plus a passed R-517 review, without an owner stop. "Owner" means the owner reads and merges. A row marked "on green" still goes to the owner when its PR falls in the owner class (see Merge policy).

## Rows

Each row states its scope and its done condition. A done condition is conjunctive: every clause must hold. Anything a row does not name is out of that row's scope.

### Wave 1: correctness

**Row 0, merge the audit.** The owner reads and merges PR #147 so every later row cites the audit on `main`. Done when `docs/audits/2026-09-26-process-and-rules.md` is on `main`.

**Row 1, correctness pass.** Reconcile the norm lines and their Specs together, in one PR:

- F1: land R-109 as a norm line in `CLAUDE.md`, a Spec in `reference.md` stating what the security review covers and who runs it, and manifest entries for `push-semgrep-gate` and `push-eslint-gate`.
- F2: write the trivial-tier merge path once, as an explicit exception in both R-514's norm line and its Spec, matching `task-cleanup` and `task-start`.
- R-517's "only review before merge" clause names the R-109 security review as the one addition on a security-touching range.
- F10: rename the R-517 section to `## Pre-merge review`, with `git-workflow-guard.sh` accepting both names for one release; drop every Copilot clause (R-514, three skills, the memory file); rewrite R-211's autonomy clause to defer to the slice plan's merge mode; define Gate 0 as the spec-approval step or remove the term.

Done when: `grep` finds R-109 in `CLAUDE.md`, `reference.md`, and `manifest.json`, with manifest entries for both push gates; R-514's norm line, its Spec, `task-cleanup`, and `task-start` state the same trivial path; the manifest fixture passes; `git-workflow-guard.sh` fixtures pass for both section names; `grep -ri copilot` finds no instruction clause in rules, skills, or global memory; R-211's norm line names the merge mode; and "Gate 0" is either defined in `reference.md` or absent from rules and skills. The rule changes take effect when this row merges.

### Wave 2: unattended safety

**Row 2a, shared gate preamble.** One `gate-preamble.sh`, sourced by every PreToolUse, PostToolUse, and Stop gate, that normalizes `HOME`, denies when `jq` is missing, and installs a trap that emits the event's failure decision when the gate exits non-zero before printing a decision. A gate that exits 0 without output keeps meaning allow, because existing gates allow that way (`protected-path-guard.sh:38-42`, `verification-gate.sh:68-96`). The failure decision per event is: PreToolUse deny; Stop block; PostToolUse the hook's own declared failure action, which each PostToolUse gate must declare (row 4 declares quarantine).

Done when one generic fixture runs every registered gate three ways and each passes: a known-deny payload under `env -u HOME` and again without `jq` on `PATH` denies; a known-allow payload still allows silently; and a forced crash before any decision (a `false` injected after the preamble) produces the event's failure decision. The four gates and `verification-gate.sh` named in F6 are among those covered.

**Row 2b, sandbox enablement.** Follow the procedure in `claude/enforce/README.md` ("Sandbox configuration (B-2)"): add the `sandbox.credentials` block (or `filesystem.denyRead` entries) covering the same paths as the `Read` deny rows, verify the key shape against the vendored schema, then set `sandbox.enabled: true`. Set `failIfUnavailable: true`, because `false` degrades to no sandbox without a sign; an interactive host that cannot sandbox gets the documented rollback instead.

Done when, all in a fresh session with the sandbox on:

- an interpreter read (`python3 -c "open(...)"`) of a fixture file at each denied path class (an `.env*` file, and one representative path under each of `~/.aws`, `~/.ssh`, `~/.gnupg`) fails, using throwaway `/tmp` fixture trees and a sandboxed `HOME` per R-103;
- a commit in a scratch worktree succeeds, `./sync.sh` completes, and `git push` of a scratch branch succeeds through the `excludedCommands` carve-out, the three outage classes `claude/enforce/README.md:112,117-120` records;
- both fixture suites pass;
- a host without the sandbox primitive (simulated as the README describes) refuses to run rather than running unconfined.

The vector table and the "honest gap" paragraph in `claude/enforce/README.md` are updated in the same PR. Row 2b depends on 2a so that a sandbox-induced gate failure denies rather than allows.

### Wave 3: parallelism

**Row 3a, integrity check against the installed revision.** `.sync-source` holds a checkout path, not a commit (`sync.sh:175`, `hooks/harness-sync.sh:39-45`), so this row first makes `sync.sh` record the installed commit in a new `.sync-revision` file beside it, leaving the `.sync-source` contract unchanged. `hook-integrity-check` then compares the live files against the git blob hashes at that revision, and `hook-hashes.txt` is deleted. The check keeps the whole current surface of `hooks/hook-integrity-check.sh:9-40`: hooks, enforcement configuration, role policy, fixtures, dependency manifests, secret patterns, and skill scripts. When `.sync-revision` is absent or its commit is unreachable, it keeps today's missing-baseline warning (`hook-integrity-check.sh:56,87-96`).

Done when fixtures detect: a modified hook, a modified file from each other covered class, a deleted covered file, and an added file under a covered directory; the missing-revision case produces the existing warning; and two branches that each edit a different hook merge without a conflict.

**Row 3b, ports spike.** A 90-minute timeboxed investigation. Run Rulesync against this repository's rules and skills and compare its Codex and Cursor output with what `translate/` produces today, covering hook adapters, port maps, and agent rendering, which are the parts Rulesync is least likely to cover. The deliverable is a written verdict in `docs/audits/`, choosing one of: adopt Rulesync, adopt it for part of the output, or keep `translate/` and generate at sync time (F3 step 2). Adoption requires the spike to show a net reduction in maintained code and upkeep with every port contract preserved. Done when the verdict is committed with the evidence behind it. Any dependency the verdict proposes goes through R-331.

**Row 3c, ports build.** Implement the 3b verdict. First, move every hand-authored file in `codex/` and `cursor/` (the port maps mark them, for example the hook adapter and README at `translate/codex-port-map.json:24-26`) to a tracked source location the generator copies from. Then stop committing the generated output and generate it at sync time.

Done when: `codex/` and `cursor/` generated paths are gitignored and every hand-authored input remains tracked; a fresh clone plus `./sync.sh` produces a working port; and CI checks port contracts independently of the generator, with fixtures asserting the hook adapter's behavior, agent rendering, and each supported configuration key, not only that `--check` agrees with the output it just generated.

**Row 3d, per-worktree fixture lock.** Replace the machine-wide flock in `run-fixture-shards.sh` (IAN-348, IAN-359) with a lock scoped per worktree plus a machine-wide concurrency cap, configurable and defaulting to about half the cores, and leave the full suite to CI. Done when a fixture with the cap configured to 2 shows two worktrees running at once, a third queuing until one finishes, and a second run in the same worktree queuing behind the first; and a fixture shows the default cap derived from the core count. Related tickets IAN-429 (docs changes force the full suite) and IAN-430 (a gate timeout orphans the runner and its lock) are separate work that this row's author should read first.

### Wave 4: untrusted input

**Row 4, injection scan.** A PostToolUse hook with the matcher `WebFetch|mcp__.*` that inspects each tool result for text addressed to the agent: instructions to run commands, claims of user or system authority, requests to ignore rules, and hidden or encoded text. The owner decided its posture on 2026-09-26:

- **On a hit, quarantine.** The hook returns `hookSpecificOutput.updatedToolOutput` carrying a notice in place of the flagged content, naming the matched pattern and the source URL or server, so the owner can refetch deliberately. The official hooks documentation states that `updatedToolOutput` replaces "the tool's output before Claude sees it" for any tool.
- **On a scanner crash or timeout, fail closed.** The whole result is withheld with a notice that the scan did not complete. This is the PostToolUse failure action the row 2a preamble applies for this hook.

Its own design spec settles the remaining questions: the detector (deterministic patterns only, a model-based classifier, or patterns first with a classifier on a hit; any third-party classifier goes through R-331); which MCP servers are trusted and skipped and where that list lives; the latency budget per call; and whether to add `additionalContext` beside the quarantine notice. The spec must also pin the Claude Code version the behavior was verified on, because the documentation names no minimum version, and must state that the session transcript still records the raw result.

Done when:

- a runtime probe on the pinned version shows the model receives the quarantine notice and not the flagged text, for both a `WebFetch` result and an MCP result;
- a fixture set of injected pages and MCP payloads is quarantined, and a fixture set of ordinary documentation pages passes through unchanged;
- crash, missing-`jq`, and timeout fixtures each produce the withheld notice;
- the false-positive rate over one week of real `WebFetch` results is recorded in the PR.

IAN-432 (make `redact-output.sh` redact through the same field) shares this transport; whichever lands first writes the shared probe fixture.

### Wave 5: context diet

**Row 5a, handoff and injection diet.** Truncate the SessionStart injection at 8 KB with a pointer to the rest, and generate the handoff's pending list from Linear at write time (F5). Enforce R-602's cap before the write lands: `handoff-check` today runs after `Write` succeeds and ignores `Edit` (`claude/settings.json:354-370`, `hooks/handoff-check.sh:27-28,65-67`), so this row adds a PreToolUse check on `Write` and `Edit` to the handoff path that denies when the resulting file would exceed the cap. This is a new blocking gate, so the row is owner class and waits for the freeze to lift.

Done when:

- a fixture shows a SessionStart injection of an oversized handoff truncated at 8 KB with the pointer present;
- fixtures show an oversized `Write` and an oversized `Edit` to the handoff denied and an in-cap one allowed;
- a fixture shows the pending list generated from a stubbed tracker response;
- a fresh session's pre-turn context is measured before and after in the PR.

**Row 5b, rule and memory consolidation.** Cut the eight long norm lines to one sentence each (F8). Delete the five duplicate global-memory files and resolve the three conflicts by naming one routing source, scoping `feedback_deploy_at_end` to deploys, and settling the subagent-threshold lesson against `reference.md` (F9). Move R-211's canonical detail from memory into `reference.md` (F9). Merge the overlapping rule pairs and add one sentence to R-212 on how it behaves during an approved plan (F11).

Done when: `CLAUDE.md` is at least 5 KB smaller; the five duplicate memory files are gone and `INDEX.md` no longer lists them; each of the three conflicts has one surviving statement; R-211's detail is in `reference.md` and no memory file is its canonical source; R-212 carries the approved-plan sentence; every removed rule ID resolves to its surviving rule in `reference.md`; and the manifest fixture passes. This row waits for 3c so the rule edits do not regenerate committed ports.

### Wave 6: measure, then trial

**Row 6a, provisional-state mechanism.** Define where a provisional setting is recorded (the slice plan or the handoff), how long it runs, and what promotes it to rule text or retires it (F4). Done when `build-by-slice-require-review` and `PROTOCOL.md` describe the mechanism, and one representative provisional setting (the autonomy trial's definition, recorded but not started) is written through it.

**Row 6b, owner-granted override and advisory telemetry.** The override's authorization boundary, decided by the owner on 2026-09-26:

- An override is valid only when the owner grants it in chat in the current turn, using the "approved" grant R-203 already defines, for one named rule and one command, and it expires at the end of that turn. An agent-set variable or reason string alone never allows a denied call.
- These gates can never be overridden: the R-1xx secret and destructive-action gates, the security merge gate, the injection scan, and the preamble's failure decisions.
- Every honored override is logged as decision `override` with the rule, the command, and the grant.

The row also makes every advisory hook log `advise`, writes the 30-day retirement scan that fills `retirement_candidates.md` from fire and override counts, switches `single-file-folder-reminder` to `additionalContext` or deletes it and re-tags R-309 as manual, and archives the six unused audit agents while giving the remaining three a `docs/audits/` write boundary in `role-policy.json` (F7).

Done when fixtures show: an owner-granted override allowing one denied call and appearing in the fire log; an agent-set override without a grant still denied; an override attempted on a never-overridable gate denied; a grant expiring at turn end; every advisory hook in the manifest writing `advise`; the retirement scan selecting a rule with zero fires over 30 days and not selecting one with recent fires, from a fixture log; the reminder reaching the model or the hook removed with R-309 re-tagged; and an audit agent's write outside `docs/audits/` denied.

**Row 6c, fix-after-merge metric.** A script that computes the fix-after-merge rate per product PR from git: a fix commit touching a file changed by a PR merged in the previous 7 days counts against that PR (F14). Done when: a fixture repository with known history, including a fix on day 7 (counted) and day 8 (not counted), produces the expected attribution; the weekly report beside the ship log includes the rate; one real product repository's output is checked by hand against its history; and `human_speedup` is either required at ticket close or removed from the ticket template and `ticket-lifecycle`.

**Row 6d, autonomy trial.** Run the audit's three trial components for two weeks as the provisional setting 6a recorded: risk-tiered merge authority, the daily digest, and queue-driven dispatch into one worktree per ticket.

- **Eligibility.** The baseline is the fix-after-merge rate (6c) over the four weeks before the trial. Standard product work gets merge-on-green authority only when that baseline is under 10%, the audit's earned-autonomy condition.
- **Evidence.** At least 10 merged product PRs during the trial; fewer makes the result inconclusive.
- **Stop rule.** The trial ends early when, over at least 5 merged PRs, the rate exceeds the baseline by more than 5 percentage points.
- **Evaluation.** The final reading is taken 7 days after the trial ends, so late fixes count. The outcome is one of promote, retire, or inconclusive, recorded through 6a.

This program's own risk-tiered merges before 6d are a plan-authorized merge policy under R-514, not trial data.

### Wave 7: hygiene

**Row 7a, enforcer-tag and manifest reconciliation.** Generate the `CLAUDE.md` enforcer tags from `manifest.json` or add a fixture that diffs the two, and add a doctor check that every manifest ID resolves to exactly one rule definition (F12). Fold in the Low list: move dated history to `PROTOCOL.md`, record R-333's status, fix the stale README counts and R-001's contradictory steps, mark `security-surface.sh` as staged until it has a caller, pin local Semgrep and Ruff to CI's versions, and close the `R-NNN:` subject bypass. Done when the new fixture and doctor check pass and each of the seven Low items is fixed or has a ticket.

**Row 7b, Bash hook chain consolidation.** Put every push-only hook behind one push dispatcher, route every commit and push detector through `shell-command-scan.sh`, and extract repository identity and the exempt-list check into shared helpers (F13). Done when: `grep` finds no commit or push detection regex outside `shell-command-scan.sh`; every hook that computed repository identity or checked the exempt list uses the shared helpers; the push-only hooks are registered only through the dispatcher; every moved detector's existing fixtures pass unchanged plus a `bash -c` and an `eval` fixture each; and the hook-process count for a plain `ls` is measured before and after in the PR. This is owner class because it rewrites how gates detect the commands they guard.

**Row 7c, audit hygiene.** Each audit opens with the prior audits' open items and their status, a recurring strategic finding gets a dated ticket or an explicit "won't do", and no new audit is commissioned while more than three earlier High findings are open without a ticket (F15). Done when the audit role files and `rulebook/audits.md` carry these three rules.

## Acceptance criteria

This spec ships no code. The program is complete when each row's done condition, stated in full under Rows, holds on `main`. Each criterion becomes that row's own B-lines, run as RED then GREEN slices, in the row's design spec (Complex) or slice plan (Standard).

- B-1: Row 1's done condition holds, every clause.
- B-2: Row 2a's done condition holds, all three fixture paths.
- B-3: Row 2b's done condition holds, all four clauses.
- B-4: Row 3a's done condition holds.
- B-5: Row 3b's verdict is committed with its evidence.
- B-6: Row 3c's done condition holds.
- B-7: Row 3d's done condition holds.
- B-8: Row 4's done condition holds, the runtime probe included.
- B-9: Row 5a's done condition holds, each mechanism by its own fixture.
- B-10: Row 5b's done condition holds.
- B-11: Row 6a's done condition holds.
- B-12: Row 6b's done condition holds, every fixture listed.
- B-13: Row 6c's done condition holds.
- B-14: Row 6d ends with a promote, retire, or inconclusive decision recorded through 6a, with evidence that each of the three components operated during the trial. A trial that never ran leaves B-14 unmet.
- B-15: Rows 7a, 7b, and 7c's done conditions hold.

## Ordering rules

1. A row starts only when every row it depends on has merged to `main`, verified with `git log main` rather than the PR badge.
2. Rows with no dependency between them may run in parallel, each in its own worktree.
3. The freeze. Until row 3c merges, only rows 1, 2a, 2b, 3a, 3b, 3d, 6a, 6c, and 7c may land. Rows that add or tighten a gate (4, 5a, 6b, 7b) wait for 3c, as do the rule rewrites (5b, 7a). A defect found in the meantime is fixed in place, not by adding a gate. This departs from the audit in two recorded ways: row 1 lands new rule text (R-109) before the freeze lifts, because it formalizes a gate that already runs; and row 2b enables the sandbox before the freeze lifts, by the owner's decision of 2026-09-26, because it turns on existing configuration rather than adding a gate.
4. When a row's design spec would change another row's scope, the change goes to the owner as a question before any implementation, per R-212. Once approved, this spec is amended in the same PR and the change is recorded under Amendments.

## Merge policy

This program merges on a risk-tiered basis, using the mechanism R-514 already provides as row 1 reconciles it.

- Each row's slice plan records its `**Merge mode:**` line at Gate 1. A row marked "on green" records the merge-on-green opt-in; a row marked "owner" records the default.
- A PR in the owner class goes to the owner whatever its row says. The owner class is: any range the security-surface detector flags; any range on which the detector errors, since the detector treats its own failure as a hit (`hooks/security-surface.sh:30-39`); any change to authentication, money, migrations, or concurrency (the audit's named class); and any change to a gate's allow or deny behavior, the sandbox, the injection scan, or the override.
- The session runs the detector on the PR range before merging, and a hit or an error changes that PR's merge path to owner.
- Every PR gets the R-517 review, and a range the detector flags also gets the R-109 security review on the strongest model. Lock, signal, and process-lifetime diffs (row 3d) get an opus or Codex R-517 review.

## Ticketing

- On the owner's approval of this spec, one Backlog ticket is opened per row (owner decision, 2026-09-26, following R-214), each related to IAN-427, naming its row number, and carrying its dependencies as Linear blockers so the blocker graph shows which rows can start.
- Each ticket moves to `in-progress` when its row starts.
- IAN-427 closes when this spec is approved and merged and the row tickets exist. The program's progress is read from the row tickets.

## Invariants

- No row weakens an existing gate's deny behavior unless its PR is in the owner class.
- Every row that adds or changes a hook ships its fixture in the same PR (R-516).
- No row depends on a committed `codex/` or `cursor/` generated file after row 3c.

## Failure modes

- **The spike finds no winner.** Row 3b's verdict defaults to keeping `translate/` and generating at sync time, which is the audit's own recommendation, so row 3c is never blocked on the spike.
- **The sandbox breaks the harness.** `sandbox.enabled: false` is the full rollback and `excludedCommands` is the per-command one. Row 2b reverts in one commit.
- **The installed Claude Code version does not honor `updatedToolOutput`.** Row 4's runtime probe fails, the row stops, and the owner chooses between pinning a newer version and a warning-only fallback.
- **The injection scan's false-positive rate is too high.** Its design spec tunes the detector; the fail-closed posture stays unless the owner changes it.
- **The trial raises fix-after-merge.** Row 6d ends early under its stop rule and later rows return to owner merges.
- **A row grows past its scope.** The session stops, records the growth as a finding (R-214), and asks the owner before widening the row (ordering rule 4).

## Non-goals

- Behavioral tests for skills, a skill-activation hook, and context-file linting, the comparison's items 4 to 6. They add harness surface, and this program's goal is to reduce upkeep. Each can be raised again after row 6d.
- Community orchestrators (SuperClaude, gstack, Claude Code PM) and Ralph loops.
- Container-per-agent isolation (Container Use and similar). Row 2b enables the native sandbox only.
- Designing any row in detail. Complex rows get their own design specs.
- The three defects found while writing this spec, which are separate tickets: IAN-429, IAN-430, and IAN-432.

## Dependencies

- PR #147 merged (row 0).
- The security-surface detector from #142, which the merge policy uses.
- The R-109 security reviewer from #143 and PR #144.

## Spec review

- Reviewer: Codex (OpenAI Codex CLI, account default model `gpt-6-astra`), read-only, 2026-09-26. Prompt: `prompts/codex-spec-review-prompt.md`, with the audit as the parity reference.
- The HIGH finding on hook semantics was verified against the official Claude Code hooks documentation before it was accepted.
- Owner decisions taken during the review: quarantine with fail-closed for row 4, owner-granted scoped overrides for row 6b, and row tickets opened on approval.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | Row 4 assumed PostToolUse cannot change delivered output; `updatedToolOutput` replaces it | Fixed: row 4 quarantines through `updatedToolOutput` and requires a runtime probe on a pinned version. The README's wrong statement and `redact-output.sh` are IAN-432 |
| 2 | HIGH | Warning-only failure was justified by the false premise; 2a and 4 disagreed | Fixed: owner chose fail-closed; 2a defines a failure action per event |
| 3 | MEDIUM | B-2 did not prove the crash handler and could break silent allows | Fixed: three-way fixture; a silent exit 0 keeps meaning allow |
| 4 | MEDIUM | Sandbox criteria missed worktree commits, sync, deny-path coverage, unavailable hosts | Fixed: four-clause done condition |
| 5 | HIGH | `.sync-source` is a path, not a commit | Fixed: row 3a records `.sync-revision` and defines the missing case |
| 6 | HIGH | Integrity replacement could drop most of today's coverage | Fixed: the full surface and missing-baseline behavior are preserved and tested |
| 7 | HIGH | Ignoring `codex/` could drop hand-authored files | Fixed: row 3c relocates hand-authored inputs first |
| 8 | MEDIUM | CI `--check` would only agree with itself | Fixed: fresh-clone generation plus independent contract fixtures |
| 9 | MEDIUM | 6a and 6d formed a completion cycle | Fixed: 6a completes with the trial recorded but not started |
| 10 | HIGH | Trial omitted the override prerequisite; program merges counted as trial | Fixed: 6b added to 6d's dependencies; program merges are not trial data |
| 11 | MEDIUM | No eligibility, baseline, minimum evidence, or lag | Fixed: row 6d's four clauses |
| 12 | MEDIUM | B-14 could pass without the trial running | Fixed: per-component evidence; a trial that never ran leaves B-14 unmet |
| 13 | HIGH | Override was a self-service bypass | Fixed: owner-granted, one rule and one command, turn-scoped, with a never-overridable list |
| 14 | HIGH | `handoff-check` runs after the write and ignores `Edit` | Fixed: a PreToolUse check on `Write` and `Edit` |
| 15 | MEDIUM | B-1 could pass with work missing | Fixed: conjunctive done condition |
| 16 | MEDIUM | B-9 measured an aggregate | Fixed: one fixture per mechanism; the measurement stays as a report |
| 17 | MEDIUM | 5b omitted the R-211 move and the R-212 sentence | Fixed: both added, with per-item evidence |
| 18 | MEDIUM | B-12 left most of 6b optional | Fixed: one fixture per deliverable |
| 19 | MEDIUM | B-13 missed reporting and the field decision | Fixed: boundary fixture, report integration, and field decision |
| 20 | MEDIUM | 7b could finish partially | Fixed: complete migration evidence |
| 21 | MEDIUM | Freeze conflicted with the table and the audit | Fixed: one permitted set; departures recorded |
| 22 | MEDIUM | R-514 and R-517 reconciliation incomplete | Fixed: row 1 reconciles norm lines and Specs together, including the R-109 exception |
| 23 | MEDIUM | Deferred tickets conflicted with R-214 | Fixed: owner chose tickets on approval |
| 24 | MEDIUM | Amendments substituted for approval | Fixed: ordering rule 4 requires the owner's answer first |
| 25 | MEDIUM | B-7 hard-coded a machine-dependent scenario | Fixed: a configured cap of 2 plus a default-derivation fixture |
| 26 | MEDIUM | Owner routing narrower than the audit's class | Fixed: the owner class names the audit's categories and detector errors |

Stack and build-versus-buy options. Codex recommended keeping the current choice for nine of ten components: the Bash preamble, the native sandbox, git blob integrity, local fixture scheduling, the local override and telemetry, the git-derived metric, the existing tracker and worktrees for the trial, and the existing scanner for consolidation. For ports it recommended keeping `translate/` provisionally with the spike retained, which is row 3b. For the injection scan it recommended the native `updatedToolOutput` transport with the detector left open, which is now row 4. No dependency is added by this spec.

## Amendments

None yet.
