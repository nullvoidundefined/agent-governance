# Governance pruning proposal

**Ticket:** IAN-568
**Status:** Draft for owner decision. No rule, hook, or skill changes until the owner approves.
**Date:** 2026-10-02

## Summary

The harness spends most of its cost on rules that have never caught a product defect, and almost none of that cost goes to the rules that guard irreversible harm. Three findings drive the proposal:

1. **The real-defect catches all came from reviews and tests, not from gates.** Only three rules have a recorded catch of a real defect: R-109 (security review found seven path-escape holes in `sync.sh`), R-517 (the pre-merge review found the unscrubbed-PII HIGH in voyager PR #16), and R-401 (a fixture test against a captured response caught a parser that would have returned null in production). In each case the practice the rule mandates found the defect; the hook that polices the practice did not.
2. **The TDD lock has the most real denials and the most rework of any rule, and no recorded product catch.** It produced two better test assertions. It also cost voyager IAN-82 slice 04 PR 2 three manual lock deletions and 5 h 18 min of idle time waiting for the owner. Once the lock stopped blocking, the other three slices of that PR took 6, 5, and about 13 minutes each.
3. **The telemetry cannot be used to rank rules until fixture runs stop writing into it.** R-517's 8,663 denials and R-512's 3,239 are 99% and 98% fixture-test bursts, at up to 168 fires a minute. Voyager's real counts are R-517: 1 and R-512: 0.

The proposal keeps 14 rules mandatory and always loaded, keeps 7 more mandatory but delivered only by their hook, makes most of the rest defaults the agent may skip with a one-line reason, and deletes 15 rules and two of the PL incident rules. It also breaks seven interlocks with changes of one to ten lines each. The expected saving on a clean standard-risk PR is about 60 to 110 agent minutes of the current 100 to 170 minutes of harness overhead, plus the owner waits the DISPUTE loop creates. The saving in always-loaded context is about 5,500 tokens per session and per subagent.

## Design principle: process time never exceeds work time

The owner set the governing rule of thumb on 2026-10-02: process time should never exceed the time spent on the actual work, a ratio of 1:1 at most. The owner restated it concretely: "30 minutes of work should involve no more than 30 minutes of review." Review here covers every process step the work triggers: tickets, gates, reviews, fix rounds, PR bookkeeping, and handoffs. The ratio actually measured on recent PRs is far worse than that budget:

| PR | Elapsed | Feature work (estimated) | Process to work |
|---|---|---|---|
| Voyager IAN-82 PR 1 (#16), about 900 lines | about 22 h | about 1.5 h (14 slices at the clean pace of about 6 minutes, plus the code itself) | about 10-15:1 |
| Voyager IAN-82 PR 2, about 250 lines | about 6 h active, plus 5 h 18 min waiting on the owner | about 50 min (S1 27 min, S2 to S4 24 min) | about 7:1 active, about 13:1 with the wait |

Even a PR where no interlock fires is over budget: the cost model below puts it at about 100 to 170 agent minutes of process against 25 to 40 minutes of feature work, about 4:1. Interlocks then multiply that into the 10-20:1 range. Every class and cut below is judged against that budget. A process step earns its place only when it fits inside the budget or carries a recorded catch that justifies exceeding it, which today is true only of the security review on security-touching ranges.

## Why this proposal exists

On 2026-10-02 the owner said the governance process "has actually become a nightmare." The evidence came from a single day. Voyager-2 IAN-82 slice 04 PR 2 took about six hours to produce about 250 lines of production code. A migration that should have taken an hour took about two hours of TDD-lock DISPUTE rounds, and in that time the owner deleted `.claude/tdd-lock.json` by hand twice. About another hour went into reshaping tests until `tdd.sh red` classified their failures as assertions, and thirty minutes went into a black-versus-ruff formatter mismatch that broke the lock's test hash. PR 1 of the same slice took 22 hours for 900 lines across 8 rework rounds. The owner has already moved Voyager's standard-risk slices to a lean standard tier: no TDD lock, tests written alongside the code, one sonnet review per PR, and the full process only for security, money, and concurrency. This proposal asks whether that lean tier should become the harness default everywhere, and what else should go with it.

## Method

1. **Inventory.** Every rule in `~/.claude/CLAUDE.md` (R-001 to R-608), the path-scoped `rules/` and `CLAUDE-*.md` convention files, the PL1 to PL20 incident rules in global memory, and the process skills were listed with their enforcer and their size.
2. **Value.** `~/.claude/telemetry/rule-fires.log` (20,312 lines, 2026-09-15 to 2026-10-02) was aggregated per rule. A fire was counted as fixture noise when its repository field was `unknown`, `repo`, `codex-pipeline`, or a `tmp.*` directory, or when the same rule fired five or more times from the same repository within one minute. Every count below is reported both raw and with noise removed. Catches were then searched for in global memory (`rule_fires.md`, `rule_misses.md`, every `lesson_*` and `feedback_*` file), `PROTOCOL.md`, the agent-governance git log, every project memory directory, and the voyager PR bodies and handoffs. `~/.claude/KNOWN-ISSUES.md` and `production/ISSUES.md` do not exist on disk, so they contributed nothing.
3. **Interlocks.** `enforce/tdd.sh`, `hooks/protected-path-guard.sh`, `hooks/verification-gate.sh`, `hooks/git-workflow-guard.sh`, `enforce/security-surface.json`, `hooks/log-rule-fire.sh`, and the dispatch and cleanup skills were read against the three voyager transcripts that cover IAN-81 PR 3 and IAN-82 PRs 1 and 2.
4. **Classification.** Each rule received one class:
   - **KEEP-MANDATORY** when it guards something irreversible (secrets, production data, destructive commands, publishing, security review) or has a recorded real catch.
   - **DEFAULT** when it is good practice with no recorded catch: the agent follows it unless it states a one-line reason to skip it.
   - **DELETE** when it is duplicated, superseded, or has no recorded value and a recorded cost.

   Each kept rule also receives a delivery mode. **Loaded** means its norm line stays in the always-loaded `CLAUDE.md`. **Hook** means a hook enforces it and its norm text leaves the always-loaded file, because the hook's own message tells the agent the rule at the moment it matters. **Skill** or **path** means the text moves to an on-demand skill or a path-scoped convention file.

### Limits of the evidence

- **No data is not no value.** Thirty-eight hooks never write to the telemetry log, including `secret-scan`, `destructive-command-guard`, `destructive-db-guard`, `global-repo-push-guard`, and `hookspath-drift-check`. R-101 to R-108 and R-203 therefore show no fires by construction. They stay mandatory on the irreversibility criterion, not on evidence.
- **Catches are under-recorded.** A gate that quietly makes the agent do the right thing leaves no record. The proposal treats "no recorded catch after two weeks of heavy use" as weak evidence against a rule, and pairs each cut with the risk it accepts.
- **The noise filter is a heuristic.** The real-session product count is an upper bound, because deleted worktrees cannot be traced back to their parent repository.

## Findings

### Where the time goes on a standard-risk PR

The interlocks report modelled one clean standard-risk PR of about four slices under the current harness. The model is anchored on measured numbers: a full-suite `tdd.sh` run takes about 95 seconds, clean slices took 5 to 13 minutes, the handoff PR #18 took 50 minutes, and the PR #15 base-merge re-check took 9 minutes.

| Step | Agent minutes | Driver |
|---|---|---|
| Ticket open, `task-tier.sh set` per branch | 4-7 | R-605 fields, search, ledger gate |
| TDD lock per slice (open, red, RED commit, green, commit, close) | 20-32 for 4 slices | two full-suite runs and two pre-commit runs per slice; about one refused `red` per two slices |
| Commit guards (R-505, R-506, R-214) | 1-3 | retries and owner clicks |
| Push gates, mostly product docs (R-607, R-608) | 10-20 | the push is denied until four docs change |
| PR body | 8-12 | the PR body is the PR document |
| R-517 review, fixes as full slices, second round, `## Codex review` section | 25-60 | head-pinned range; every fix is a TDD slice |
| Bookkeeping commits before the review | 5-10 | the review must run last |
| Ticket close with eight measured fields | 5 | R-606 |
| Handoff and its own PR (amortized) | 15-50 | R-602; R-109 false positive on the path |
| Verification gate at each turn end | about 1.5 per turn | R-509 |
| **Total harness overhead** | **about 100-170** | against 25-40 minutes of feature work |

Each interlock that fires adds to that total: the DISPUTE loop (I1) adds 15 to 30 agent minutes plus the owner's latency, which was 5 to 10 hours on 10-01 and 10-02. The formatter re-hash (I2) adds 5 to 10, the RED classifier (I3) 5 to 15, a moved review range (I6) 10 to 60, and the security detector's false positive (I7) about 30.

### Which rules have caught anything

| Evidence class | Rules |
|---|---|
| Recorded real-defect catch, by the practice | R-109 security review, R-517 pre-merge review, R-401 behaviour-asserting tests |
| Recorded test-quality catch, no product defect | R-410 (the DISPUTE produced a better assertion; a locked test contradicting the spec was surfaced) |
| Recorded catch of agent misbehaviour, no product defect | R-203 (two guard evasions found after the fact, both triggered by guard false positives) |
| Conformance-only: fires, no recorded catch | about 30 rules, including R-105, R-207, R-212 to R-214, R-305, R-313, R-330, R-403, R-411, R-412, R-505 to R-518, R-605, R-607, R-608, R-907 |
| No data | about 40 rules, including every manual conduct rule and every hook that does not log |

### Top friction by real (noise-removed) denials

| Rank | Rule | Real denials or blocks | Notes |
|---|---|---|---|
| 1 | TDD lock (R-410, R-411, R-412) | 331 | plus the IAN-420 re-hash, three classifier fixes, the IAN-481 rename evasion |
| 2 | R-509 verification gate | 320 | spurious blocks on transient failures; the `expected-red` bypass exists and is never called |
| 3 | R-605 ticket at start | 140 | the gate was silently off between PR #78 and #80 and nothing broke |
| 4 | R-907 test-author separation | 421 asks | each ask is an owner click |
| 5 | R-109 security gate | 40 | semgrep-absent fails closed; `session` substring flags every handoff; 13- and 8-round reviews |
| 6 | R-505 commit subject | 72 | heredoc false positives |
| 7 | R-517 / R-512 merge guards | 50 / 55 | all for missing PR-body sections or the wrong merge flag |

### The harness has caused incidents of its own

- The first `sync.sh` run with `--delete` wiped a live workspace, the Codex config, and a 696 KB state file (`23592ae6`).
- A test inside a pre-push hook rewrote the shared doppelscript git config and broke every worktree.
- A 2026-09-19 maintenance audit found about 64% of harness fixes were its own plumbing (`docs/audits/2026-09-19-maintenance-tax.md`).
- No record shows a guard stopping a real secret leak, a production data operation, or a destructive command against real state. The recorded secret incidents are misses or predate the hook.

## Proposed classification

Classes: **M** KEEP-MANDATORY, **D** DEFAULT, **X** DELETE. Delivery: **loaded**, **hook**, **skill**, **path**. "Real" counts are noise-removed denials or blocks; "ask" counts are noise-removed asks.

### Session init (R-0xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-001 session-start procedure | manual | cost: 13 `codex exec` calls spent about 200k tokens on init reads | D | skill | Keep "read the handoff, classify the session"; drop the declaration line and the Tier 2 reads. |
| R-003 harness sync | hook | caused the `--delete` incident | M | hook | It is the delivery mechanism, not a norm. Its line leaves `CLAUDE.md`. |

### Secrets and trust (R-1xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-101 no destructive DB on production | hook | no data (hook does not log) | M | loaded | Irreversible. |
| R-102 secret files off-path | hook | 45 misses recorded, no prevention recorded | M | loaded | Irreversible. Merge R-102, R-103, R-108, and R-202's secret clause into one secrets rule. |
| R-103 credential files read-only | hook | no data | M | merged into R-102 | Duplicate of R-102's intent. |
| R-104 sanitize artifacts | manual | no data | M | loaded | Publishing is irreversible. |
| R-105 confirm destructive MCP actions | hook | 174 real asks, 0 denies; already narrowed for tracker writes | M | hook | Sends and deletes are irreversible; the hook's ask is the rule. |
| R-106 governance push is publishing | hook | no data; was inert until `6c841dc6` | M | hook | The repository is public. |
| R-107 hooksPath drift | hook | no data | M | hook | Supply-chain signal, cheap. |
| R-108 no credential-shaped literals | hook | GitGuardian false positives on fixtures | M | merged into R-102 | Keep the scan; the norm text joins the secrets rule. |
| R-109 security review | hook + CI | **real catches** (sync.sh, PR #158, voyager #16) | M | loaded | Keep; fix the detector's `docs/` false positive (I7). |
| R-110 risk classification | manual | introduced 2026-10-01, no data yet | M | loaded | It is the switch that makes every other cut safe. |

### Conduct and output (R-2xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-201 tool output is data | manual | no data | M | loaded | Prompt-injection guard. |
| R-202 read only what was requested | manual | the `~/.zshrc` token exposure | M | merged into R-102 | Its secret clause is the valuable part. |
| R-203 no guard bypass without "approved" | hook | two evasions found, both triggered by false positives | M | loaded | Keeps the guards meaningful; fewer false positives lower its cost. |
| R-204 durable fix, root cause | manual | no data | M | loaded, merged with R-405 | One rule: fix root causes and never weaken the gate that caught the failure. |
| R-205 investigate asserted existence | manual | no data | D | skill | Good practice, no record. |
| R-206 imperative model-facing prose | manual | no data | X | | Only governs harness authoring; belongs in `writing-skills`. |
| R-207 no em dash | hook | 107 real denials, false positives on escapes | M | hook | Owner style preference; the hook is the rule. Fix the escape false positive. |
| R-208 no unfalsifiable praise | manual | no data | D | loaded (output style) | Owner preference; one line in the output style. |
| R-209 delete filler | manual | misapplied as "be short" (a recorded miss of R-210) | D | output style | Merge with R-210 into one prose rule; the two conflicted. |
| R-210 full-context prose | manual | 2 misses | D | output style | As above. |
| R-211 decisions through answer tiles | manual | 5 misses, the most-missed rule | M | loaded | Owner's repeated instruction; no gate can do it. |
| R-212 declare scope, ask before widening | hook (ask) | 32 real asks, no catch | D | skill | The ask fires on adjacent files the work needs. |
| R-213 provenance tag on every task | hook | 6 denies, no catch | X | | Bookkeeping with no consumer. |
| R-214 every finding becomes a ticket; commit refused without `Refs:` | hook | 18 real denies, no catch | D | skill | Keep "file what you notice"; drop the commit refusal. |
| R-215 reachable SHA citations | CI | no data | X | | Niche; no recorded broken citation. |

### Architecture and naming (R-3xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-301 monorepo shape | manual | no data | D | path | Belongs in the TypeScript convention file. |
| R-302 no cross-project imports | hook | 0 real fires (all fixture) | D | hook | Cheap; keep the hook, drop the line. |
| R-303 one-way dependencies | eslint | no data | D | path | Project lint config. |
| R-306 no catch-all directories | hook | 0 real fires | D | hook | Keep the hook, drop the line. |
| R-307 services/clients/api layout | manual | no data | D | path | |
| R-308 reuse before adding | manual | 2 misses | D | loaded (one line) | Real value, cannot be mechanized. |
| R-315 descriptive file names | judge | judge inert (1 real call of 1,769) | D | path | Delete the judge enforcement. |
| R-316 verb + noun function names | eslint, judge | 5 asks | D | path | |
| R-317 descriptive variable names | eslint, judge | no data | D | path | |
| R-318 one responsibility per file | manual | no data | D | path | |
| R-320 file header comments | eslint, hook | no data | D | path | |
| R-322 orchestrator or atomic, about 10 lines | hook reminder | false positives on handler factories | X | | A size heuristic presented as a law; R-318 covers the intent. |
| R-325 destructure | eslint | no data | D | path | Lint config. |
| R-330 domain vocabulary before code | hook | 2 real denies | D | skill | Useful at spec time; the gate is not. |
| R-331 justify new dependency | hook (ask) | 4 real asks | D | hook | Cheap supply-chain ask; keep the hook. |
| R-332 comments stay true | manual | no data | D | path | |
| R-334 aggregate-root naming | judge | 1 real deny | D | path | |
| R-341 to R-346 observability | reminder hooks | no data | D | path (`CLAUDE-OBSERVABILITY.md`) | Already duplicated there. |
| R-351 dockerize every artifact | reminder hook | no data | D | path | |
| R-361 no N+1 queries | eslint, ruff | no data | D | path (`CLAUDE-DATABASE.md`) | |
| R-362 one transaction for atomic writes | eslint, judge | no data | D | path | High-risk slices (concurrency) get the full process anyway. |
| R-363 atomic read-modify-write | judge | no data | D | path | As above. |
| R-364 bounded reads | judge | no data | D | path | |
| R-365 no SQL built from input | judge | no data | M | path | SQL injection is a security control; R-109 covers the review. |
| Structure-conventions skill rules (R-304, R-305, R-309 to R-314, R-319, R-321, R-323, R-324, R-326 to R-329) | hooks | R-311, R-312, R-324 100% fixture; R-319 false positive on Next.js | D | skill | Keep the skill; turn the 100%-fixture gates into warnings. |
| golangci-ast, rubocop-ast gates | push hooks | 0 real fires; no Go or Ruby projects | X | | Speculative until a real project exists. |

### Testing and quality (R-4xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-401 tests that fail when wrong | hook, eslint | **real catch** (Haiku parser) | M | loaded | Keep. |
| R-403 bug fixes test-first | hook | 50 real denies, the one claimed catch is unspecific | D | loaded (one line) | Keep the practice; the hook becomes a warning. |
| R-404 reproduce locally before deploy | manual | no data | D | skill | |
| R-405 never weaken the protection | hook | 1 real deny | M | merged into R-204 | |
| R-406 negative-input tests | manual | catches attributed to review | D | loaded under R-109 | Mandatory on high-risk slices only. |
| R-408 lint staged files only in pre-commit | manual | no data | X | | Tooling advice, not a rule. |
| R-409 diagnose repeated formatting cleanups | manual | no data | X | | Replaced by the I2 fix. |
| R-410 never write gate inputs or locked tests | hook | 68 real denies; test-quality catches only; IAN-420 | D (M on high-risk) | hook | Lock applies to high-risk slices only. |
| R-411 subagent role boundaries | hook | 175 real denies, no catch; the IAN-481 evasion | D (M on high-risk) | hook | Roles exist only on high-risk slices. |
| R-412 slices under the TDD lock | hook | 88 real denies, no catch | D (M on high-risk) | skill | Standard-risk slices use the lean tier. |

### Git and process (R-5xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-501 parallel-session check | hook (warn) | 108 real warnings | D | hook | Cheap warning. |
| R-502 tasks for workstreams | manual | no data | X | | Harness behaviour already covers it. |
| R-503 % share and timestamps | hook, manual | 2 misses | X | | No consumer; the ticket records the start time. |
| R-504 commit after every task | hook | no data | D | skill | |
| R-505 conventional commit subjects | hook | 72 real denies, false positives | D | hook | Keep the hook; fix the heredoc false positive. |
| R-506 one-sentence commit bodies | hook (ask) | 109 real asks, no catch | X | | Each ask is an owner click for a style preference. |
| R-507 no conflict markers | hook | only recorded fire is a false positive | M | hook | Cheap, and a committed marker breaks the build. |
| R-508 README with the feature | hook | no data | D | skill | Folds into the product-docs default. |
| R-509 no turn ends on a red suite | hook | 320 real blocks, no recorded defect | D | hook | Keep; wire `expected-red` (I5). |
| R-510 trust pre-commit hooks | manual | no data | X | | Advice. |
| R-511 big refactors on their own branch | hook | no data | X | | R-512's one-PR-one-scope covers it. |
| R-512 squash merge, one PR per slice | hook | 55 real denies (wrong flag) | D | hook | |
| R-513 grep tests for a changed constant | hook (ask) | 13 real asks | D | hook | |
| R-514 merge confirmation | hook (ask) | 242 real asks; "exists for understanding, not correctness" | M on security ranges, D otherwise | hook | Owner reads security-touching PRs; others follow the slice plan's merge mode. |
| R-515 resolve addressed threads | manual | over-resolution incident | D | skill | Copilot review is retired. |
| R-516 register rules in the manifest | hook | 7 real blocks | D | skill (agent-governance only) | Applies only when editing the harness. |
| R-517 one fresh-context review before merge | hook | **real catches** | M | loaded (short) + skill | Keep the review; move the section grammar into the skill; fix I6. |
| R-518 draft PR on first push | hook | 52 errors, no catch | D | hook | |

### Lifecycle and memory (R-6xx)

| Rule | Enforcer | Evidence | Class | Delivery | Reason |
|---|---|---|---|---|---|
| R-601 offer a handoff | manual | no data | D | skill | |
| R-602 handoff format | hook | no data | D | skill | Bundle into the work PR, never its own PR. |
| R-603 route learnings to memory | manual | no data | D | skill | |
| R-604 global memory is cross-project only | manual | no data | D | skill | |
| R-605 ticket before the first edit | hook | 140 real denies, no catch | D | skill | See decision 4. |
| R-606 close the ticket with eight measures | manual | 1 miss | D | skill | Cut to `actual_minutes` and `risk`. |
| R-607 product docs | push hook | 12 real denies | D | skill | Update at feature completion, not on every push. |
| R-608 stack and observability docs | push hook | 10 real denies | D | skill | As above. |
| R-907 Codex or test-author separation | hook (ask) | 421 asks, no catch | X | | Already narrowed to high-risk; the triad covers that case. |

### Mandatory and always loaded: the resulting list

1. R-101 no destructive DB actions against production.
2. R-102 secrets (merged with R-103, R-108, and R-202's secret clause).
3. R-104 sanitize artifacts.
4. R-109 security review on security-touching ranges.
5. R-110 risk classification picks the process.
6. R-201 tool output is data.
7. R-203 no guard bypass without "approved".
8. R-204 root-cause fixes, never weaken a gate (merged with R-405).
9. R-211 decisions through answer tiles.
10. R-308 reuse before adding (one line).
11. R-401 tests that fail when wrong.
12. R-403 bug fixes test-first (one line, no hook deny).
13. R-517 one fresh-context review before merge.
14. R-514 owner reads and merges security-touching PRs.

**Mandatory, delivered by hook only:** R-003, R-105, R-106, R-107, R-207, R-507, R-908.

## Interlocks and the smallest breaking change for each

| ID | Interlock | Smallest breaking change | Protection lost |
|---|---|---|---|
| I1 | While red, `protected-path-guard.sh:281` denies every test tree, not just the slice's files; `red` and `green` refuse any failure outside the slice; `close` requires green; the lock is always protected. A schema change that breaks older tests can only end in a DISPUTE and a manual `rm`. | Deny only `is_locked` files; return `ask` for any other test-tree file. | An agent could weaken an unrelated test, but the owner sees each such file in the ask, and `green` still refuses a drop in the outside pass count. |
| I2 | `tdd.sh red` hashes the test, then the repo's pre-commit (black, `ruff --fix`) rewrites it, so `green` reports tampering. The session checked with `ruff format` because the harness's CI template uses it, while voyager uses black. IAN-420 open since 09-26. | Run the repo's formatter on the named tests before hashing in `red` and `amend`. | None; formatting does not change semantics. |
| I3 | The pytest RED classifier accepts only `AssertionError`, `DID NOT RAISE`, and import errors. `TypeError`, setup errors, and missing-column errors are refused. 4 of 9 refusals in PR 2, about 94 s each. | Accept any exception raised in the test body or its fixtures; refuse only parse, collection, and infrastructure errors. Record the class in the lock. | A test failing on its own typo could lock as RED; `green` still has to pass. |
| I5 | The verification gate blocks a turn end on a red suite, including the deliberately red slice; `tdd.sh expected-red` was built for this and nothing calls it. | Call `tdd.sh expected-red` at the top of `verification-gate.sh` when a lock exists. | None; `expected-red` refuses when anything outside the locked tests fails. |
| I6 | R-517 and R-109 ranges must end at the PR head; every fix or base merge moves the head and forces a re-review. | Allow the range to end at an ancestor of the head when every later commit is a base merge or a commit listed as `fixed <sha>` in the findings table. | Fix commits merge without a second read; CI still runs. |
| I7 | `security-surface.json` path patterns are unanchored substrings (`session`, `token`); the per-session handoff path matches `session`. | Exclude `^docs/` and `*.md` from the path patterns; content patterns still apply. | Prose about security controls no longer triggers a review. |
| I8 | The separate RED commit runs the formatter (which causes I2), while the commit anchor it exists for is off because voyager gitignores the lock. | One commit per slice when the lock is untracked. | None. |
| I9 | `log-rule-fire.sh` writes to the live log unless `CLAUDE_FIRE_LOG=/dev/null`; only the shard runner sets it. | Skip logging when the repository resolves to `unknown` or sits under `$TMPDIR`; add a session ID and a reason field. | None. |

`feat/tdd-dispute-reopen` (IAN-565) addresses I1 with a new `disputing` phase and an approval-recording hook. It holds a spec and a slice plan, no code, and is rated high risk. The I1 one-line ask gets most of its value now; this proposal recommends dropping IAN-565 if the I1 change lands.

## Expected per-PR time saving

For a clean standard-risk PR of about four slices:

| Change | Minutes saved |
|---|---|
| No TDD lock on standard-risk slices (lean tier) | 15-25, plus I2 and I3 when they fire (10-25) |
| Product docs at feature completion, not on every push | 5-15 |
| R-517 section grammar into the skill, plus the I6 tail rule | 10-30 |
| Handoff bundled into the work PR, plus the I7 exclusion | 15-40 amortized |
| Ticket and commit-guard trims (R-213, R-214 refusal, R-506, R-606 fields) | 5-10 |
| **Total** | **about 60-110 of the current 100-170** |

Those cuts leave about 40 to 60 minutes of process against 25 to 40 minutes of work, a ratio of about 1.5:1, which still breaks the 1:1 budget. Four further cuts bring a clean standard-risk PR inside it:

| Further cut | Minutes saved | What changes |
|---|---|---|
| Review fixes on standard-risk PRs land as ordinary commits with a test, not as full TDD slices; a second review round runs only when round one found a HIGH | 10-20 | R-517 skill text; the I6 tail rule makes the fix commits mergeable without a re-review |
| The PR body for a standard-risk PR is a short template (summary, testing, review findings and dispositions); the decisions and reflection sections are required only on high-risk PRs | 4-8 | R-517 and `task-cleanup` skill text |
| The handoff is written once per session, at session end, and only when work is left open; never per PR | 3-10 | R-601, R-602 |
| The ticket carries title, tier, branch, `started_at`, `actual_minutes`, and `risk`; `estimate_ratio`, `human_speedup`, `findings_by_round`, and `escaped_bugs` become optional | 2-4 | R-605, R-606, `ticket-lifecycle` |

With all of them, the modelled process for a clean standard-risk PR is about 20 to 35 minutes against 25 to 40 minutes of work, inside the 1:1 budget. High-risk PRs keep the lock, the triad, and the security review, and under the current mechanics they exceed 1:1: voyager PR #16 spent most of its 22 hours in review rounds and critic rounds. The owner's rule allows exceeding the budget only where cutting would lose something of significant value. The evidence identifies exactly one such place. On security-touching code, later review rounds kept finding real holes: the `sync.sh` release-file validation (PR #159) needed seven rounds and found one real path-escape hole in each. Outside security, later rounds did not pay: the PR #16 reflection records that rounds 3 and later produced only LOWs, and the per-slice critic rounds there have no recorded catch. The recommendation is therefore:

- **Everything is held to 1:1, high-risk PRs included:** the lock, the triad, the general R-517 review, fix rounds, and bookkeeping.
- **One exception:** the R-109 security review on a security-touching range may run past the budget for as long as each round still finds a MEDIUM or higher security finding. It stops at the first round that finds nothing above LOW.

Decision 8 confirms or rejects that exception.

The largest single saving is not in that table: removing the DISPUTE loop (I1 for high-risk slices, no lock at all for standard ones) removes the owner from the critical path, which cost 5 to 10 hours of wall time on 10-01 and 10-02.

Always-loaded context: `CLAUDE.md` is 30,085 bytes (about 7,500 tokens), loaded into every session and every subagent. Fourteen loaded rules at one line each come to roughly 2,000 tokens, a saving of about 5,500 tokens per context.

## Risks of each cut

| Cut | Risk accepted | Mitigation |
|---|---|---|
| No TDD lock on standard-risk slices | Tests written alongside the code may be shaped to pass rather than to fail when wrong. | R-401 stays mandatory; the R-517 reviewer checks test strength; `escaped_bugs` on the ticket measures it, and `report risk` compares tiers after ten tickets. |
| Collateral test files become an ask (I1) | An agent could weaken an older test to reach green. | Each file is shown to the owner; `green` refuses a drop in the outside pass count. |
| Wider RED classifier (I3) | A test broken by its own typo locks as RED. | `green` must still pass; the class is recorded. |
| Review range may end before fix commits (I6) | A fix commit introduces a new defect that no reviewer reads. | Only commits named in the findings table qualify; CI still runs. |
| Docs excluded from the security detector (I7) | A security-relevant config written as Markdown is not reviewed. | Content patterns still apply; executable config is not `.md`. |
| Ticket gate becomes a default | Some work goes untracked and estimates lose samples. | The ticket opens at PR time at the latest; the gate was off for two PRs with no harm. |
| Product-docs gate becomes a default | Feature lists drift from the code. | `task-cleanup` updates them at feature completion. |
| R-506, R-213, R-503, R-907 deleted | Commit bodies and task lists get less uniform. | No consumer of that uniformity was found. |
| Norm text of hook-enforced rules leaves `CLAUDE.md` | The agent learns the rule only when the hook fires, which can cost one retry. | The rule is still enforced; one retry is cheaper than 5,500 tokens in every context. |
| golangci and rubocop gates deleted | A future Go or Ruby project starts without them. | `add-stack-track` re-adds them with a real project. |

## Inventory: process skills, convention files, and PL1 to PL20

### Context cost

| Source | When loaded | Size |
|---|---|---|
| `CLAUDE.md` (92 rules, norm lines about 6,900 tokens) | every session and subagent | 30 KB |
| SessionStart output (global-memory `INDEX.md` plus the handoff) | every session | 14 KB |
| `i-have-adhd` skill (flag file present) | every session | 7.2 KB |
| `using-superpowers` skill | every session | 3.6 KB |
| **Always loaded, total** | | **about 74 KB, about 18,400 tokens** |
| `rules/python.md` (`CLAUDE-PYTHON.md`) | any `*.py` edit | 61 KB, about 15,300 tokens |
| `rules/observability.md` | server edits | 15 KB |
| Process skills: `task-start` 29.5 KB, `task-cleanup` 22.7 KB, `tdd-gated-dispatch` 21.3 KB, `ticket-lifecycle` 16.3 KB, `build-by-slice-require-review` 14.5 KB | per task | about 104 KB together |

A Voyager session that edits Python and Vue carries roughly 43,000 tokens of governance text before any work starts. Seventy-one hooks are registered across 10 events. A single Bash call spawns 22 PreToolUse hooks, whose median spawn-and-exit times sum to about 570 ms; whether Claude Code runs them in parallel was not verified.

Additional proposals from the inventory:

- **Trim `CLAUDE-PYTHON.md` to the rules a linter cannot check.** At 15,300 tokens it is the largest single context cost after the always-loaded set. Rules ruff, mypy, or black already enforce are restated there. (DEFAULT, path)
- **Merge `task-start` and `task-cleanup` into one short checklist each for the standard tier** under the 1:1 budget, keeping the long forms for high-risk work. (DEFAULT, skill)
- **Add a `--fixture` guard to `log-rule-fire.sh`** (I9) before any future pruning is decided by fire counts.

### Rules outside `CLAUDE.md`

| Rules | Where | Class | Reason |
|---|---|---|---|
| R-407 build-smoke for runtime assets | structure-conventions | D | |
| R-701, R-702 dispatch prompt contents, worktree first | `rulebook/agents.md` | D | Useful; on-demand only. |
| R-703 canary agent first, R-704 inline under 5 tasks, R-706 50-tool-call cap | `rulebook/agents.md` | D | |
| R-705 implementation gated on a proven RED | `rulebook/agents.md` | D (M on high-risk) | Follows decision 2. |
| R-707 fresh-context roles on high-risk slices only | `rulebook/agents.md` | D (M on high-risk) | Follows decision 2. |
| R-801 to R-805, R-904 audit rules | `rulebook/audits.md` | D | On-demand; audits are owner-invoked. |
| R-901 tier tags, R-902 inline flow, R-903 model routing | `rulebook/cost.md` | D | |
| R-905 retrospectives only after real incidents | `rulebook/cost.md` | D | Consistent with the 1:1 budget. |
| R-906 divide estimates by 3-5x and recalibrate | `rulebook/cost.md` | X | Its inputs (`estimate_ratio`) become optional; no consumer acted on it. |
| R-907 test-author separation | as above | X | Listed in the R-6xx table. |
| R-908 warn before metered Codex calls | hook (advisory) | M | Money; delivered by the hook only. |
| R-999 | log key only | n/a | Stops appearing once I9 lands. |

### PL1 to PL20 (global memory, description line loaded every session)

| PL | Class | Reason |
|---|---|---|
| PL1 DB handlers need real-Postgres integration tests | D | Duplicated by the project `CLAUDE.md` testing section; keep there. |
| PL2, PL19 sweep the codebase after a destructive migration or removing a plan system | D | No R-rule covers it; move into `CLAUDE-DATABASE.md`. |
| PL3, PL20 each user flow has an E2E test; "test passes" is not "feature works" | D | Partly duplicated by R-401 and R-607. |
| PL4 never tell audits what to suppress | X | Duplicated by `feedback_audit_autonomy.md` and R-802, R-804. |
| PL5 to PL9 Next.js, Vercel, and pnpm specifics | D | Move into `CLAUDE-FRONTEND-NEXT.md`; out of scope for Python stacks. |
| PL10 third recurrence gets an issue number and an ISSUES.md rule | X | Superseded by R-214 and R-603; `production/ISSUES.md` does not exist. |
| PL11 kill ports before local E2E | D | Move into `CLAUDE-FRONTEND.md`'s Playwright section. |
| PL12 Playwright projects: chromium, webkit, mobile-safari | D | As above. |
| PL13 set `gh variable` for each `vars.X` a workflow uses | D | Move into `CLOUD-DEPLOYMENT.md`. |
| PL14 grep a regenerated lockfile | D | Fold into R-331. |
| PL15 exercise changed endpoints after a migration deploy | D | Move into `CLAUDE-DATABASE.md`. |
| PL16 to PL18 confirm dialogs for paid actions, AI job costing, pricing comments | D | Product-specific; move into the convention file for apps with billing. |

The PL file then stops being a separate always-indexed memory: each surviving PL lives in the convention file for its stack, loaded only when that stack is touched.

## Decisions needed from the owner

Each is asked through an answer tile, one per turn, and recorded here with the answer.

1. Sequencing: land the interlock fixes (I1, I2, I3, I5, I7, I9) as one PR first, or wait for the whole pruning. **Answer (2026-10-02): wait for the full pruning; every change lands as one planned change after all decisions are made.**
2. TDD lock scope: high-risk slices only, delete it everywhere, or keep it everywhere with the fixes. **Answer (2026-10-02): high-risk slices only. Standard-risk slices use the lean tier; high-risk slices keep the lock and the triad with I1, I2, I3, I5, and I8 fixed.**
3. Hook-only delivery: remove the norm text of hook-enforced rules from `CLAUDE.md`. **Answer (2026-10-02): yes. Hook-enforced rules keep firing and leave the always-loaded file; the hook's message carries the rule.**
4. Ticket timing: before the first edit (gate), at PR open (default), or optional below Complex.
5. Product docs: gate on push, update at feature completion, or drop.
6. The DELETE list: approve as a batch or rule by rule.
7. IAN-565 (`feat/tdd-dispute-reopen`): drop it if I1 lands, or keep it.
8. The 1:1 budget (owner principle, 2026-10-02: process never exceeds work unless cutting loses something of significant value): approve the four further cuts, and confirm the single exception, the R-109 security review running past budget while each round still finds MEDIUM or higher.
