# Process and rule-system audit, and a path to more autonomy

Date: 2026-09-26
Ticket: IAN-419

## Scope and lens

This audit covers the owner's development process across the four active repositories and the agent-governance harness itself: the 91 norm lines in `claude/CLAUDE.md`, `claude/rulebook/`, `claude/enforce/`, the 72 files in `claude/hooks/`, the 18 skills, the 15 agents, `claude/global-memory/`, and the git and Linear history from 2026-09-12 to 2026-09-26. Three read-only reviewers covered the rule system, the enforcement machinery, and the process history. The dispatcher re-ran the load-bearing checks before writing: the R-109 grep, the handoff size, and the unset-`HOME` probe of `protected-path-guard.sh`.

The owner set the lens on 2026-09-26: much more autonomy and parallelism, as long as reliability does not drop. Every finding below is therefore judged on two questions. Does it make the harness less reliable? And does it stand between the owner and running more agents with fewer stops? Under R-802 this audit declares findings and never acts on them. Each recommendation is a direction for separately ticketed work. The report keeps to 15 findings, following the IAN-284 proposal.

## Verdict

A cleanup pass is warranted, and it should be medium-sized rather than a rewrite. The mechanical skeleton is sound:

- Every hook, ESLint, and CI tag in `CLAUDE.md` resolves to a real file.
- Every one of the 91 norm lines has exactly one Spec in `reference.md`.
- All 56 registered hooks exist.
- Fixtures cover 127 of the 129 manifest rules.
- The bash 3.2 floor now has its own CI job.

The mess sits in four places:

1. **Correctness drift.** A gate cites a rule that does not exist, and two surfaces disagree on how trivial PRs merge.
2. **Context bloat.** About 17k tokens load before the first user turn.
3. **Duplication.** The same rules are restated across norm lines, `reference.md`, skills, and global memory.
4. **A structural tax that grew instead of shrinking.** Most of that tax is the same machinery that makes parallel branches conflict.

On the autonomy question, the largest obstacles are not the human gates themselves. They are:

- merge conflicts in checked-in generated files;
- a machine-wide lock that serializes verification across sessions;
- a fail-open class of hooks;
- no outcome metric that could justify removing a human gate safely.

Fix those, and the owner can widen merge-on-green with evidence rather than by fiat. The attempt on 2026-09-24 did the reverse and was reverted after 11 hours.

## IAN-121 verdict (due today)

- **Harness fix share: inconclusive at 29%.** The ticket's definition counts fix-type conventional commits among harness first-parent commits, pooled over UTC 2026-09-19 to 2026-09-25. That gives 19 of 65 commits, or 29.2%. The figure sits between the 25% "one-time debt" threshold and the 36% "structural" threshold, which is the ticket's own inconclusive branch. A reconstruction of the baseline with the same method gives 37%, against the ticket's recorded 36%, so the method is sound.
- **Harness share: 75%, down from 85%.** This is 78 of 104 merged PRs across agent-governance, ian-greenough-developer, voyager-2, and doppelscript. It overstates the true share, because template-fastapi-nuxt and job-triage also had product work that was not counted.
- **Sensitivity.** Seven commits in the window use non-conventional subjects (four of them `R-NNN:`), so the definition counts them as non-fixes. If all seven were fixes, the share would be 40%. The measurement depends on commit-subject discipline that `commit-message-guard` does not enforce for those subjects.
- **Composition leans structural.** Commits touching `claude/enforce/hook-hashes.txt` rose from 56% of the baseline window to 66%. Commits touching generated `codex/` or `cursor/` output rose from 35% to 45%. All eight fixes on 2026-09-24 repaired harness machinery, five of them machinery added that same week.
- **Recommendation.** Post "inconclusive, composition structural" on IAN-121 and proceed to the distribution redesign (Finding 3). Only 2 of the 7 promised daily snapshots were posted, which Finding 14 addresses.

## Open items from prior audits

| Source | Item | Status |
|---|---|---|
| 2026-09-16 engineering P0-2 | Rotate the exposed PAT and purge transcripts | **Open for 10 days** (`claude/ISSUES.md:28`, owner action). This is the only open P0. |
| 2026-09-18 engineering #1, #3, #4 | R-501 parent-process survival; pinned Ruff contract; live Cursor deny probe | Open |
| 2026-09-18 criticism #1 | Behavioral benchmark | Open (IAN-288 in Todo) |
| 2026-09-18 criticism #4 | Clean telemetry, false-positive adjudication | Open (IAN-275, IAN-276, IAN-280 in Todo) |
| 2026-09-18 criticism #5 | Freeze new governance features | **Not followed.** Seven new gates or rule blocks were added since (#78, #83, #118, #124, #137, #140, #141), plus a detector and a reviewer agent (#142, #143). |
| 2026-09-19 ECC P1 ports | Five ports | 1 of 5 done (IAN-141). IAN-140, IAN-142, IAN-143, IAN-144 in Backlog. |
| 2026-09-19 maintenance tax | Hash manifest, generated ports, copy sync; override log and retirement rule | Open; see Findings 3 and 7 |

## Findings

### 1. High: R-109 is a phantom rule that a live gate enforces

- **The citation.** `claude/hooks/push-semgrep-gate.sh` cites R-109 14 times, including in its deny text. So do `agents/security-reviewer.md`, `prompts/security-review-prompt.md`, `claude/README.md`, and the root `README.md`.
- **The gap.** R-109 is in none of `claude/CLAUDE.md`, `claude/rulebook/reference.md`, or `claude/enforce/manifest.json`.
- **The requirement it breaks.** The security-first design spec (`claude/docs/superpowers/specs/2026-09-25-security-first-gate-design.md`, criterion B-17) requires R-109 to exist in all three.
- **A related R-516 violation.** `push-semgrep-gate` and `push-eslint-gate` are wired in `settings.json` but have no manifest entry.

A blocking deny that points an agent at a rule it cannot look up is a reliability defect, because the agent cannot tell whether the deny is legitimate.

*Recommendation:* land R-109 as a norm line, a Spec, and manifest entries for both push gates, before the security program continues to its Part 5.

### 2. High: the trivial-tier merge path contradicts itself

- **The rule.** `reference.md:723` (R-514) says a trivial PR merges on green "under the same merge authorization as any PR".
- **The skills.** `skills/task-cleanup/SKILL.md:107` says a trivial tier "merge[s] on green CI" with no authorization step, and line 215 calls it "the standing exception". `skills/task-start/SKILL.md:198` agrees with the skill, not the rule. Both are mirrored into `codex/` and `cursor/`.

This is residue of the 2026-09-24 reversal (#121, then #132). An agent following the skill merges without authorization, and one following the rule stops. That is exactly the ambiguity that costs autonomy, because a careful agent will stop and ask.

*Recommendation:* decide which is intended and write it once, in R-514's Spec. Given the owner's goal, the skill's version, merging trivial PRs on green, is the one to keep, stated explicitly as an exception in R-514.

### 3. High: the structural tax is unaddressed, and it is also the main parallelism bottleneck

None of the three sources named on 2026-09-19 has changed:

| Source | Status |
|---|---|
| `hook-hashes.txt` | Still checked in, 307 lines |
| `codex/` and `cursor/` | Still hold 175 generated tracked files |
| `sync.sh` | Unchanged since 2026-09-19 |

Of 67 commits since that date, 49 (73%) touch the hash manifest or the generated ports. For autonomy this matters more than the commit count suggests. Any two branches that each edit a hook, a rule, or a skill conflict in `hook-hashes.txt` and in the regenerated ports, which is what IAN-358 records. Parallel agents working on the harness therefore serialize at merge time, however many run at once.

*Recommendation:*

1. First, replace the checked-in manifest with a comparison against the git blob hashes of the commit recorded in `.sync-source`, then delete `hook-hashes.txt`. This is the smallest change with the largest effect.
2. Second, stop committing `codex/` and `cursor/`. Generate them at sync time, and keep CI's `--check`.

After both, parallel harness branches stop conflicting by construction.

### 4. High: process changes become mandatory rules the same day and are reversed within hours

| Change | Added | Reversed | Gap |
|---|---|---|---|
| Codex as the blocking reviewer (R-517) | #71, 09-19 | #121, 09-24 | 4.6 days |
| Merge-on-green as the default | #121, 09-24 07:01 | #132, 09-24 18:21 | 11 h 20 m |
| Tracker writes through background subagents | #121, 09-24 07:01 | #126, 09-24 14:50 | 7 h 49 m |
| R-517 reviewer mechanics | #71 | #119, #121, #128, #130 | 5 revisions in 5 days |
| R-512 bundle-PR exception | #70, 09-19 | Never worked (IAN-253: the ruleset blocks rebase-merge) | n/a |

Each change shipped as a multi-file PR (#71 and #121 touched 33 files each), and each one regenerated the ports and hashes of Finding 3. The reversals were sound decisions; #132's body names the problem precisely. The cost comes from trialing in rule text.

*Recommendation:* add a provisional state. A process change runs for two or three sessions as a slice-plan line or a handoff note, and becomes a rule only once it has survived that trial. For autonomy experiments in particular (the autonomy section below), this is the mechanism that lets the owner try more aggressive settings cheaply.

### 5. High: about 17k tokens load before the first turn, and half of it is an over-cap handoff

- **The measurement.** `hooks/session-start.sh` injects `global-memory/INDEX.md` (7,020 B) and the whole handoff, about 40,000 characters in all. `claude/CLAUDE.md` adds 26,948 B more. Every session and every compaction starts at about 17k tokens.
- **The cap.** The handoff is 32,976 B against R-602's 8 KB cap, and the `handoff-check` hook is advisory only.
- **Stale pending list.**
  - IAN-157 has been carried forward in 14 of the 15 handoff versions written since 09-20.
  - Pending items 1 and 2 ask to land #115, #118, and #119, all of which merged on 09-23.
  - The "last commit" names #132, eleven merges behind `main`.
- **What does work.** The lessons section is specific and useful.

For parallelism this is a direct cost: every dispatched subagent and every parallel session pays the same start-up bill.

*Recommendation:*

- Truncate the injection at 8 KB, with a pointer to the rest.
- Make `handoff-check` deny over the cap.
- Generate the pending list from Linear at write time instead of carrying it by hand.
- Keep only lessons and production warnings in the handoff.
- If the cap is not wanted, delete R-602's cap, because a rule that is openly overridden teaches agents that rules are negotiable.

### 6. High: a fail-open class remains in the gates

Four PreToolUse gates abort under `set -u` when `HOME` is unset, and print nothing, which the harness reads as an allow:

| Gate | Line |
|---|---|
| `protected-path-guard.sh` | 46 (re-verified: it denies a write to `.enforce.json` normally, and prints only "HOME: unbound variable" without `HOME`) |
| `structure-gate.sh` | 154 |
| `pr-ticket-ref-gate.sh` | 140 |
| `mcp-action-guard.sh` | 112 |

- **The Stop gate.** `verification-gate.sh:103` aborts the same way on Stop, letting a turn end on a red tree.
- **Latent cases.** At least eleven more gates expand a bare `$HOME` on paths the probe did not reach.
- **jq.** None of the 68 hooks check for `jq`. Without it, `destructive-command-guard` stops denying `git commit --no-verify`.
- **No crash handler.** No gate has an ERR or EXIT trap that emits a deny when the script dies.

Unset `HOME` and missing `jq` are uncommon on the owner's laptop. They are much more likely in the unattended cloud and scheduled sessions that more autonomy implies. This is the class behind #105 and #134, and the handoff records that this failure shape has appeared five separate times.

*Recommendation:*

- Add one shared `gate-preamble.sh`, sourced by every gate, that:
  - normalizes `HOME`;
  - denies when `jq` is missing;
  - installs an EXIT trap that emits a deny when no decision was printed.
- Add one generic fixture that runs every PreToolUse and Stop gate under `env -u HOME` with a known-deny payload.

This closes the class once instead of one incident at a time. It is a prerequisite for unattended runs.

### 7. Medium: no override path, and the retirement pipeline is half built

- **No override path.** No gate honors an override with a logged reason. The only escapes are whole-repository exemptions (`exempt-repos.txt`) and per-rule `.enforce.json` switches.
- **Retirement is read but never written.** `session-start.sh` displays `retirement_candidates.md`, but nothing writes that file.
- **Most reminders are invisible to telemetry.** 18 of the 25 hooks in the manifest's advisory tier never call `log_rule_fire`, so there is no evidence that R-322, R-341, R-345, R-346, R-351, R-320, and several others ever change anything.
- **One reminder cannot reach the model at all.** `single-file-folder-reminder.sh:77` writes to stderr on exit 0, which the model never sees.
- **Unused audit agents.** Six of the nine audit agents (customer, design, UX, financial, legal, marketing) have never produced a report. All nine carry Write and Bash with no `role-policy.json` boundary.

For autonomy, a false positive with no override path means an unattended agent either stops or finds a workaround, and both are bad.

*Recommendation:*

1. Build `CLAUDE_GATE_OVERRIDE="R-NNN: <reason>"`, honored by the gates and logged as decision `override`.
2. Make every advisory hook log `advise`.
3. Write the 30-day retirement scan that fills `retirement_candidates.md` from fire and override counts.
4. Switch `single-file-folder-reminder` to `additionalContext` so it reaches the model, or delete it and re-tag R-309 as manual, since it is that rule's only enforcer.
5. Archive the six unused audit agents, and give the remaining three a `docs/audits/` write boundary.

### 8. Medium: norm lines carry reference-level detail

- **The principle.** `CLAUDE.md:3` says the full Spec lives in `reference.md`.
- **The practice.** Eight norm lines (R-517, R-605, R-001, R-608, R-607, R-334, R-514, R-512) total 6,536 characters, which is 27% of all norm-line bytes. R-517 alone is 1,146 characters and describes the review-section grammar.
- **Where the weight sits.** Personal-workflow and bookkeeping rules are 28 of the 91 (31%), but about 45% of norm-line bytes.

*Recommendation:* cut each of the eight to one imperative sentence of about 150 characters that names the skill owning the procedure. This saves about 5 KB per session and removes the most common source of drift, which is amending the norm line and the Spec separately.

### 9. Medium: global memory duplicates the rules, and conflicts with them in places

**Pure duplicates.** These files are indexed in the always-injected `INDEX.md`, yet repeat existing rules:

- `feedback_no_fluff.md` repeats R-209;
- `feedback_no_empty_praise.md` repeats R-208;
- `feedback_pr_constant_value_check.md` repeats R-513;
- `feedback_no_tls_bypass.md` repeats R-405;
- `lesson_inline_execution_efficiency.md` repeats five rules.

**Conflicts:**

- **Model routing.** `feedback_model_routing.md` calls itself the canonical model-routing rule, while R-903 names `task-start` as the canonical routing surface.
- **Pushing.** `feedback_deploy_at_end.md` says never to push until told to, which conflicts with R-518's draft PR on first push.
- **Subagents.** `lesson_subagent_first_for_multi_file.md` defaults to subagents for more than five files, while `reference.md` records about 136k tokens for one subagent that opened one ticket (IAN-343) and 55k to 135k per reviewer run.

**Misplaced and dangling:**

- R-211's Spec delegates its canonical detail to a memory file.
- Two memory files reference files that do not exist.

*Recommendation:*

- Delete the pure duplicates.
- Pick one routing source.
- Scope `feedback_deploy_at_end` to deploys.
- Move R-211's detail into `reference.md`.

### 10. Medium: this week's reversals left stale text, including one that blocks autonomy

- **R-211 still says "work runs from PR to PR and slice to slice without ending a turn to ask".** This was #121's autonomy clause, and #132 did not revert it. It now contradicts the Gate 2 default, under which the owner reads and merges each PR.
- **Codex naming.**
  - The R-517 section is still titled `## Codex review` although the default reviewer is `pr-reviewer` on Sonnet.
  - `reference.md:748` still quotes "Codex reviews every PR before merge, blocking".
  - The `git-workflow-guard.sh` deny text frames Codex as the default.
- **Copilot.** R-514's norm line still ends with "never request Copilot review", as do three skills (task-start, task-cleanup, build-by-slice-require-review) and a now-moot memory file.
- **Gate 0.** "Gate 0" appears in voyager-2's PR descriptions (#4, #5) but is defined nowhere in this repository.

*Recommendation:*

- Rename the section to `## Pre-merge review`, with the gate accepting both names for one release.
- Drop the Copilot clauses.
- Rewrite R-211's clause to defer to the slice plan's merge mode. This is the sentence the autonomy section builds on.
- Define Gate 0 as the spec-approval step, or stop using the term.

### 11. Medium: overlapping rules govern the same moments

- **Adjacent work.** Discovered adjacent work falls under R-211, R-212, R-213, R-214, and `feedback_be_proactive.md`. R-211's approved-plan clause and R-212's ask-before-widening pull in opposite directions, and only the Scope text reconciles them.
- **Duplicate pairs.**
  - R-204 restates R-405.
  - R-705 restates R-412.
  - R-907 restates R-707.
  - R-904 restates R-801.
  - R-603 and R-604 are two halves of one rule.
- **TDD.** Test-first work is described in five places.

*Recommendation:* merge each pair, and add one sentence to R-212 on how it behaves during an approved plan. This removes about six rule IDs with no loss of coverage.

### 12. Medium: enforcer tags and the manifest disagree

- **Vocabulary.** Nine rules are tagged `judge` in `CLAUDE.md` and `ci:llm-rule-judge` in the manifest.
- **Missing enforcers.** The manifest lists enforcers the tags omit, for example `destructive-command-guard` for R-101, R-102, R-107, and R-203.
- **Inconsistent stack-linter tags.** Per-stack push linters appear on R-361 and R-362 but not on R-320, R-342, or R-344.
- **Spec disagreements.** `reference.md` marks R-203 as manual, while its tag names two hooks.
- **A mislabeled CI tag.** R-215's `[ci:doc-sha-reachability]` is not a CI job; it runs from the pre-push hook.
- **Scattered definitions.** Rule definitions live in four files, with stack suffixes such as `R-314 [ts]:`, so a plain `^R-NNN:` lookup in `reference.md` misses twelve manifest IDs that do resolve elsewhere. Every tooling check has to know this.

*Recommendation:* generate the `CLAUDE.md` tags from `manifest.json`, or add a fixture that diffs the two, and add a doctor check that every manifest ID resolves to exactly one rule definition, stack suffixes and the three rulebook files included.

### 13. Medium: the Bash hook chain is long, and parsing is duplicated

Every Bash tool call spawns 26 hook processes, about 720 ms of serial time on a plain `ls`, and 15 of the 23 PreToolUse Bash hooks act only on `git push`, `git commit`, or `gh pr`. Commands are parsed three different ways:

- the shared tokenizer, used by five hooks;
- `shell-command-segments.py`;
- an ad hoc splitter in `protected-path-guard.sh`.

In addition, 14 hooks detect commits and pushes with their own regex, so they can disagree with the tokenizer on `bash -c` or `eval` forms. There is also duplicated repo-identity code in 31 hooks.

At higher parallelism this latency multiplies across sessions.

*Recommendation:*

- Put the eleven push-only hooks behind one push dispatcher that parses `git push` once.
- Route every commit and push detector through `shell-command-scan.sh`.
- Extract repo identity and the exempt-list check into shared helpers.

### 14. Medium: the harness measures itself, not its outcomes

| Measurement | State |
|---|---|
| Rule-fire telemetry | Only 1.9% of 7,297 fires came from real product repositories |
| IAN-268 instrumentation program | Specified in #109; all 13 child tasks are Todo, including one that already shipped as #119 |
| `human_speedup` ticket field (#88) | Populated on 2 of about 20 tickets closed since |
| IAN-121 daily snapshots | 2 of 7 posted |
| Product-repo outcomes | Nothing measures escaped defects, reverts, or fix-after-merge commits |

The last row matters most for the owner's goal. Without an outcome metric, removing a human gate can only be justified by opinion. That is why #121 went in on a process-cost measurement and was reverted on a feeling about understanding eleven hours later.

*Recommendation:* add one cheap metric now, before any benchmark: fix-after-merge rate per product PR, measured from git. A fix commit touching a file changed by a PR merged in the previous 7 days counts against that PR. Report it weekly beside the ship log. Either require `human_speedup` at close or delete it.

### 15. Medium: audits repeat strategic findings without an owner or a date

There have been 17 audits since 2026-07-03, eight of them between 09-16 and 09-19. Engineering audits stay productive: each verifies the previous closures and finds new, reproducible defects. The strategic findings, however, recur without action:

| Finding | Where it has appeared |
|---|---|
| No outcome measurement | 07-31, 09-18, 09-19 |
| Contaminated telemetry | 07-31, 09-18, 09-21 |
| Fixture hermeticity | Four audits |

The freeze recommended on 09-18 was not followed.

*Recommendation:* each audit opens with the prior audits' open items and their status, as this one does. A recurring strategic finding gets a ticket with a date, or an explicit "won't do" with a reason. No new audit is commissioned while more than three High findings from earlier audits are open without a ticket.

## Smaller cleanups (Low)

- **Dated history in `reference.md`.** It carries 52 dates, 45 ticket references, and 18 "owner decision" clauses. The IAN-333 parenthetical appears six times. Move the history to `PROTOCOL.md` and keep one ticket pointer per Spec, which trims an estimated 15 to 20%.
- **R-333** was planned in the slice-02 plan but never landed or recorded as retired.
- **Stale counts.** `claude/README.md` gives outdated counts: rules through R-606, 32 memory files, nine ESLint rules, 17 skills.
- **Contradictory steps in R-001.** Its Spec step 5 says to read the handoff, while step 1 says to read it only when the injected block is absent.
- **Unwired helper.** `security-surface.sh` (#142) has no caller yet. Mark it as staged in the manifest until Part 5 of the security program wires it.
- **Unpinned local tools.** The local push gates fall back to unpinned `uvx semgrep` and `uvx ruff`, while CI pins both, so local and CI results can drift.
- **Subject format.** `R-NNN:` commit subjects bypass the conventional-subject check (R-505).

## Sound, no change needed

- Hook wiring is complete. The 16 unregistered files are sourced helpers or installers, and all but `security-surface.sh` have callers.
- Fixture coverage is broad: 144 enforce fixtures and 22 hook fixtures, with no fixture pointing at a deleted hook.
- The bash 3.2 floor has a CI job and a construct-ban fixture.
- `destructive-command-guard` fails closed when python3 is missing, and `push-semgrep-gate` when Semgrep is missing. Neither survives a missing `jq` (Finding 6).
- Read-only reviewers (`pr-reviewer`, `security-reviewer`, `slice-critic`, `spec-conformance-review`) have read-only tool lists consistent with R-411.
- The tracker-writes reversal and the R-517 to R-518 renumbering left no residue.

## A path to more autonomy and parallelism without losing reliability

This section is a proposal rather than a finding.

**What 2026-09-24 showed.** #121 removed the owner's merge to save about 60 minutes of ceremony per PR. #132 restored it 11 hours later, because the owner's read of each PR is how the owner keeps understanding the build. The gate exists for understanding, not for correctness. More autonomy therefore needs two separate substitutes: a reliability substitute that can be measured, and an understanding substitute that costs the owner minutes rather than hours.

**Prerequisites.** These make autonomy safe, and each is already a finding above:

1. **Close the fail-open class (Finding 6).** Unattended sessions are where it fires.
2. **Remove merge conflicts by construction (Finding 3).** Parallel branches then stop serializing on generated files.
3. **Add an override path with a logged reason (Finding 7).** An unattended agent can then proceed past a false positive instead of stalling or working around it.
4. **Measure fix-after-merge (Finding 14).** Autonomy can then be widened or narrowed on evidence.
5. **Scope the fixture run lock per worktree.** `run-fixture-shards.sh` takes one machine-wide flock (IAN-348, IAN-359), with a 1,200-second default wait. Two sessions verifying at once therefore queue. The lock exists because concurrent full runs starved the CPU. Recommend running only the affected shards per worktree under a lock with a concurrency limit of about half the cores, and leaving the full suite to CI.

**Risk-tiered merge authority.** This replaces the single default:

| Class | Merge | Why this is safe |
|---|---|---|
| Trivial, docs-only, tests-only, and harness changes outside the security surface | On green CI plus the R-517 review, no owner stop | CI and an independent reviewer already gate these, and a bad merge reverts in one commit |
| Standard product work | On green, **provided** the repository's fix-after-merge rate stayed under a threshold (for example 10%) over the last 4 weeks | This is the earned-autonomy ratchet: the metric widens or narrows the class automatically |
| Security surface (the #142 detector), money, auth, migrations, concurrency | Owner reads and merges | These are the changes whose failures are not cheap to revert |

**Understanding without the gate.** Replace the per-PR read with a daily digest: the ship log's feature breakdown, generated per day, with each merged PR's one-line outcome. The owner reviews it once, and flags any merge for a closer look or a revert. This keeps understanding current at the cost of minutes rather than a stop per PR.

**Parallel dispatch from the queue.** Once conflicts and the lock stop serializing work, run one worktree per ticket from the Linear backlog. A scheduled or dispatcher session:

- picks tickets whose specs are approved (Gate 0);
- runs each in its own worktree;
- leaves only the security class and anything the reviewer flags for the owner.

R-211's plan-scoped autonomy clause (Finding 10) becomes the rule that governs these runs.

**Run it as a trial.** Following Finding 4, run the first two weeks as a provisional setting recorded in slice plans, not as a rule. Promote it to a rule only if fix-after-merge stays flat.

## Suggested order

1. **Correctness:** Findings 1, 2, and 10. One PR, small.
2. **Unattended safety:** Finding 6, the shared gate preamble and generic fixture.
3. **Parallelism unblockers:** Finding 3, the blob-hash integrity check and then generate-at-sync, plus the per-worktree fixture lock from the autonomy section.
4. **Context diet:** Findings 5, 8, 9, and 11. The expected result is always-loaded context dropping from about 17k tokens to about 11k, with about six fewer rule IDs.
5. **Lifecycle and measurement:** Findings 7 and 14, then the autonomy trial.
6. **Hygiene:** Findings 12, 13, and 15, and the Low list.

Until steps 1 to 3 land, hold new rules and new gates. This is the 09-18 freeze, narrowed to the work that blocks the owner's stated goal.

## Not examined

- The product repositories' own code quality.
- The Codex and Cursor ports beyond their mirroring of stale text.
- `translate/` internals.
- The security program's Parts 5 to 8, which are not built yet.
