# Session Handoff: 2026-09-20 to 2026-09-23, nine sessions, ending with the subagent fanout against the CI gaps

Nine sessions wrote here across 2026-09-20 to 09-23. This merges them; detail is on each ticket.

**Over R-602's 8 KB by about 18.6 KiB, deliberately, and the overage grows every session it survives.** That limit assumes one session per handoff. Everything historical here is already one line apiece and pushed onto its ticket; what remains is the pending list, the production warnings and the next-session rules, and cutting those to satisfy a size check trades the document's purpose for its metric. The earlier attempt to obey the cap is the direct cause of this session's worst finding: compressing four sessions into 8179 bytes silently dropped a retraction, and only an adversarial review caught it. Filed as IAN-266; **IAN-260 is the actual fix**, giving each session its own uncapped file behind a capped index, at which point this note goes away.

## Newest: IAN-381 security-first governance, 2026-09-25 to 09-26

This session's own handoff sits here, above the older multi-session notes below. It follows R-602's six sections and supersedes the older notes only where they conflict.

**1. Last commit.** `db7f483` feat(hooks): merge gate requires a current strongest-model Security review on security-touching PRs (IAN-381) (#145). The owner squash-merged it on 2026-09-26, pinned to the reviewed head. It was verified on `origin/main` by reading the merged files, not by trusting the PR badge.

**2. Production state.**
- `main` carries six of IAN-381's eight parts:
  - Part 1: convention fixes (#139)
  - Part 2: the Semgrep push gate (#141)
  - Part 3: the security-surface detector (#142)
  - Part 4: the security-reviewer agent (#143)
  - Part 6: the R-109 rule (#144, `e57c337`)
  - Part 5: the R-109 merge gate (#145)
- Run `./sync.sh` from a `main` checkout so the live `~/.claude` picks up the gate. This session did not run it after the #145 merge.
- **The gate takes effect on the next security-touching merge.** Before merging one, record the review artefact with `bash enforce/security-review-record.sh <artefact path>`. Run it in the same turn the security reviewer returns, then merge with `--match-head-commit <full 40-char sha>`. gh rejects the short sha.

**3. Session metrics.**
- About 30 working hours over two days.
- Rework: #145 took five Fable review rounds and six fix slices (B-9c, B-10b, B-10c, B-10e, B-10f).
- **Velocity flag:** the review loop on #145 ran long. Each round found a real forgery path, so every round was a genuine finding, not churn.

**4. What shipped.** Everything is under IAN-381, and the ticket carries the full table.
- **#145 merge gate.** On a security-touching PR, the merge is denied unless all of these hold:
  - a single `## Security review` section, on `securityReviewModel`, whose range head equals the PR head
  - a findings table where every artefact finding has a row
  - no open or downgraded rows
  - `fixed <sha>` commits that fall inside the range
  - waivers routed to the owner's permission prompt
  - an artefact whose blob matches the ledger entry recorded at review time
  - a local `origin/<base>` equal to `baseRefOid`
  - a merge pinned with `--match-head-commit`
- **Ledger.** It lives at `~/.claude/security-review-ledger/<sha256 of host/owner/repo>.json`, and the first record for a head wins. protected-path-guard denies writes, deletes, and moves aimed at it, including `~`, `$HOME`, and `${HOME}` spellings.
- **The detector has a deadline** and fails closed.
- **Also shipped:** #144 merged after main was merged into it (conflict in task-cleanup step 1, resolved to keep both intents), with a round-4 review.

**5. Pending, by urgency.**
- **HIGH:**
  - IAN-381 Part 7: a reusable `.github/workflows/security.yml` (Semgrep plus CodeQL), wired into the templates. About 3 hours.
  - IAN-381 Part 5b: the gate requires green Semgrep and CodeQL checks and an insecure-value test in the diff, and the dispatcher uses one variable for both the Agent `model` and `{{MODEL}}`. This depends on Part 7's check names. About 3 hours.
- **HIGH:** IAN-456 covers guard command-parsing evasions, all owner-waived for #145: `cd`-follow, ancestor delete, a `HOME=` prefix, and `${HOME:-}` or command-substitution forms. It is Complex; build the parser first. About 3 hours.
- **HIGH:** IAN-425 needs a review record that agents cannot reach, signed or held by CI. This is the accepted residual for a deliberately forging agent. About 4 hours.
- **MEDIUM:** IAN-381 Part 8: sweep `production/` and `templates/` for the #27 CORS class and file tickets. About 2 hours.
- **MEDIUM:** IAN-426: protected-path-guard reads `2>/dev/null` as a write target. About 45 minutes.
- **Later:**
  - IAN-402: three build skills (`build-slice-require-review`, `build-standard`, `build-fast`) with up-front estimates. It now includes the in-PR test checkpoint (owner decision 2026-09-26): RED is pushed alone for review, then the implementation.
  - IAN-401 (`build-fast`), IAN-382 (question-card Stop hook), IAN-394, IAN-395, IAN-399 (`tdd.sh release`).
- **Close IAN-381** with actuals once Parts 5b, 7, and 8 land.

**6. Next session.**
- Start with Part 7, then 5b.
- Read, in order:
  1. `claude/docs/superpowers/specs/2026-09-25-security-first-gate-design.md` (B-9, B-13 to B-17)
  2. `claude/hooks/git-workflow-guard.sh` (`read_security_review_verdict` and its helpers)
  3. `claude/agents/security-reviewer.md`
  4. `claude/prompts/security-review-prompt.md`
- **Subagents stall often.** The watchdog killed them at 600s. Give each one a narrow brief and plain one-command Bash calls, with no heredocs and no `2>`.
- **Other sessions share one test lock.** `run-fixture-shards` holds a machine-wide lock, so a parallel session's full run blocks this session's pre-stop test check for up to 8 minutes.
- **Stale worktrees can go:** `r109-rule-ian381` and `merge-gate-ian381` both hold merged branches.

## 1. Last commit

`6a4188c` chore(skills): make merge-on-green an opt-in chosen per slice (IAN-352). PR #132 squash-merged 2026-09-24 at 11:21:48Z with all four checks green, verified by reading the changed files at `origin/main` rather than the PR badge, and synced into the live `~/.claude`, `~/.cursor` and `~/.codex`. This supersedes every entry below as the newest commit on `main`. Only this SHA is cited for that change: the branch's own six commits are unreachable after the squash merge, which is what `doc-sha-reachability` is for.

`c982b18` fix(enforce): stop push-eslint-gate denying clean diffs on import-x vue parse warnings (IAN-332). PR #122 squash-merged 2026-09-24 with all four checks green, verified on `main`, and synced into `~/.claude`. This supersedes the entries below as the newest commit on `main`.

`102d281` fix(hooks): walk a written path by expansion, not a process per component (IAN-183). PR #104 merged 2026-09-22 with all checks green; IAN-183, IAN-262 and IAN-301 closed. Superseded the entry below, which was current when the PR-triage session wrote this file.

- `main` is at `021c8fa`, `fix(hooks): replace mapfile so the scope guards run under bash 3.2 (#105)`. Today's merges: `#89` to `#93`, `#95`, `#96`, `#98`, `#102`, `#99`, `#103`, `#105`.
- `./sync.sh` ran from a worktree on `main` at `021c8fa`, so the live `~/.claude` carries the guard repair; both guards were re-verified firing against `~/.claude` itself.
- Open: `#94` (IAN-173 spec), `#97` (IAN-184, two HIGH), `#107` and `#108` (dependabot, untouched), plus two in rework below. Merged 09-23: `#101` (IAN-254), `#113` (the IAN-260 spec), `#114` (IAN-260 slice 1).
- **Three agent PRs are open, all drafts, none reviewed.** `#115` (IAN-307, macOS CI, green on both jobs), `#118` (IAN-308, doc SHA reachability) and `#119` (IAN-286, R-517 artefact). All three agents finished and fixed every review finding; what each still needs is a FRESH Codex review of its CURRENT state, because the review sections in their bodies describe earlier trees. `#119`'s own new gate correctly denies merging `#119`, verified against live `gh`, which is the cheapest proof it works.
- **Two files conflict between ANY two PRs that touch the same class of thing, so those PRs cannot be parallelised.** `claude/enforce/hook-hashes.txt` is regenerated by any hook change, and `codex/.claude-port.json` and `cursor/.claude-port.json` are generated from the WHOLE rule set, so any two PRs touching rule text collide there no matter which rules each one touched. `#116` rescoped R-001, `#118` added R-215 and `#119` rewrote R-517: three disjoint rules, two guaranteed conflicts. Land rule-touching and hook-touching PRs **one at a time**, and resolve by regenerating (`node translate/codex.mjs --write`, `node translate/cursor.mjs --write`, `hook-integrity-check.sh --update`), never by hand-merging: a hand-resolved generated file is how a port drifts from the rules it mirrors, and `--check` is what catches that.
- **`#118` cost three CI rounds on one platform difference.** Its fixture built a bare remote without `--initial-branch`, so HEAD followed `init.defaultBranch`: `main` in the owner's config, `master` on the runner. The clone found no such ref, produced an empty working tree, the copy of the check into it failed, and the pre-push hook exited 0 in silence while two assertions believed they were testing it. A line in a user's gitconfig decided whether the test tested anything. Fixed in `b6cd414`; the class is IAN-325. This is exactly what `#115`'s macOS job surfaces earlier.
- **`#100` was closed, not merged**, at 19:31:55Z by another session or the owner, so IAN-218's branch `claude/harness-open-source-value-4mivg8` is pushed with no PR again. Reopen or re-PR it if that work is still wanted.
- `#100` and `#101` were siblings forked at `7b72052`, not a stack: they shared six commits and both rewrote this file. With `#100` closed, `#101` carries that history alone.

## 2. Production state

- **The two scope gates are enforcing again** (`#105`, IAN-267, which is canonical; IAN-265 and IAN-271 are the same bug filed by two other sessions). `mapfile` is gone from both hooks; `enforce/tests/bash32-builtin-floor.test.sh` holds the floor for the class across `claude/hooks`, `codex/hooks` and `cursor/hooks`. They were dead for about two and a half hours, from `#96` at 16:59:51Z to `#105` at 19:31:43Z.
- **ubuntu CI can be fully green on a guard that has stopped guarding, and only a macOS job says so.** Proved on CI, not argued: a probe branch put `LAST_SCOPE_GLOB="${SCOPE[-1]}"` (a bash 4.2 negative index, matched by no pattern in the floor fixture's list) into `scope-widening-gate.sh`. Every ubuntu check passed. The macOS job failed both `bash32-builtin-floor` and `scope-widening-gate`. `shellcheck --severity=error` was clean on it too. `${arr[-1]}`, `declare -g` and `${v@Q}` all abort a `set -u` hook into the same silence `mapfile` did. The grep layer catches only what somebody thought to list; the real floor catches what nobody did. `#115` (IAN-307) adds that job.
- **macOS is this harness's native platform, not the exotic one.** Both suites pass on it unmodified (104/104 enforcement, 22/22 hook) because it is written and run here daily. No BSD-versus-GNU fixture divergences exist; ubuntu was the only platform CI covered and the only one nothing runs on. Do not budget for a porting effort that is not there.
- **A bash 4 construct does not always abort a hook**, which bounds what that fixture can promise. A parse error (`;;&`) kills the hook before it writes anything and the fixture's behavioural anchors catch it; an expansion error does not, so `${v^^}` prints "bad substitution", fails one command, and execution continues with a wrong value. The `mapfile` break was fatal only because it left `SCOPE` unset and the next line read it under `set -u`.
- **R-334 amended** (IAN-175): word order fixed, separator follows the engine's case convention. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156) when every reverse-closure line names a test file the red command named. `expected-red` answers the same read-only; `green` does not.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. IAN-188 closed on that evidence.
- **Do not sync from `fix/gate-expected-red` until `#97`'s H-1 and H-2 are fixed**: that build widens R-509, so a phase-`red` turn can end on a failing typecheck, lint or port check.
- **`~/.claude/.sync-source` now points at `agent-governance-main`, a detached checkout at `origin/main` (`c982b18`)**, rewritten by the IAN-332 session's `./sync.sh` on 2026-09-24. Keep syncing from that checkout after `git -C <it> switch --detach origin/main`; the earlier sources (`epic-poitras-097aba`, then `unruffled-gates-6647a2` on the since-merged `chore/scope-r001-to-interactive-sessions`) were feature branches. The primary checkout is still stale, on `fix/ticket-gate-exemption-telemetry` at `d426098`. Check `git -C "$(cat ~/.claude/.sync-source)" log -1` before syncing.
- **The push ESLint gate now decides on lint.mjs's exit status and stdout, not stderr** (IAN-332). Before `c982b18`, any `.ts` file importing a `<script setup lang="ts">` component with TypeScript-only syntax denied the push with import-x parse warnings and no violation. Those SFCs were also silently missing from `no-cycle`'s import graph, so R-303 was unenforced across them until this fix.
- **Codex quota is restored**, so R-517 has its primary reviewer again; the Claude subagent is the fallback only. Codex still exits 0 while printing an error: a first invocation on 2026-09-23 exited 0 having produced no review at all, because `gpt-5.1-codex-max` is not available on a ChatGPT account. Read the log, never the exit status, and do not pass `--model`.
- `hook-latency.test.sh` passed the gate session (308ms vs 348ms), failed the README session (344ms vs 324ms) and failed this one at 450ms vs 378ms. The budget floats with load because it is six times a bare-spawn control measured per run, but the cause is not load: `#104` measured it as three hooks resolving a written file's directory one component at a time, spawning a `dirname` or `basename` per level, and its fix gives ten consecutive runs at 199 to 225ms. While red it blocks `tdd.sh red` for any slice whose tests sit in `claude/enforce/tests/`, because a RED cannot be certified while that suite is red. Do not widen it (R-204).
- `#101` merged on 09-23, folding the IAN-218 session record in rather than overwriting it. `#100` stays closed unmerged, and whether IAN-218's branch returns as a PR is still an owner decision.
- **`doc-sha-reachability` reports 73 unreachable citations across 10 documents** once `#118` lands (IAN-322 decides pin-or-mark for each). Three are already pinned: `keep/ian260-migration-r605-audit`, `keep/ian260-migration-r605-corrected`, `keep/ian260-migration-ian184-gate`. IAN-260's migration slice MUST read from those tags, not the bare SHAs.
- **CI clones at depth 1**, so any fixture asking about real repository history cannot run there and declines rather than passing blind (IAN-323). Worth knowing before writing another history-dependent fixture and reading its green as coverage.
- Storage branches, not work: `park/b3-gate-expected-red-fixture` (superseded), `docs/capability-assessment` at `43232f5` (unpushed, owner's R-106 call), `fix/tdd-red-commit-anchor` (empty).

- **A gate that depends on a gitignored per-machine file is off by default on every fresh checkout.** The R-605 ticket gate was disabled for a whole session because `~/.claude/TICKET-TRACKER.json` was absent, then activated the moment that file was written and refused a commit after four had landed. That tracker config was written in an ephemeral container and never reached the laptop: copy the `linear` block from the template and fill in team and project locally, or R-605 stays disabled there.

- **The owner merges each slice PR again, unless the slice plan opts out** (IAN-352, owner directive 2026-09-24). IAN-333 had made the session's own merge on green CI the default; the owner's judgement is that this removed them from the loop by default in a skill named require-review, and that a Claude subagent's review is not a substitute for their own read of the diff. `build-by-slice-require-review` now asks once per slice at Gate 1 which mode applies, owner-merges listed first, and the answer is recorded on a plan-level `**Merge mode:**` line and in the ticket's Gate 1 transition comment. R-514's authorization follows that line: a plan that records nothing, or records the default, leaves every PR for the owner. The trivial tier is the one standing exception and is unchanged.
- **`spec-glossary-check.sh` now reads the slice plan's preamble for that line**, the lines above the first `### ` heading, anchored to the start of a line. It took three passes to get there, and the two discarded versions are the useful part: an unanchored `contains` over the whole document let the bolded phrase in a PR block's prose silence the reminder, and a line-anchored search over the whole document let a `**Merge mode:**` line inside a PR block do the same. A presence check for a formatted token is worth writing as a question about where the token is allowed to be, not whether it appears.
- **A bash `${var/pattern/repl}` whose pattern begins with `**` is a glob, not a literal.** Deriving a fixture plan with `${var/**Contents:**/...}` replaced everything from the start of the document to the first `Contents:`, and the mangled fixture still passed its assertion, so a case was green for the wrong reason until an unrelated finding forced a rewrite. Strip a line with `grep -v '^\*\*Label:\*\*'`, which takes a real regex, or write the document out in full. This is the same class as item 1 under Next session: the assertion passed, and passing said nothing.
- **A subagent reads the `CLAUDE.md` copy cached in its own prompt, not the file.** A reviewer raised a HIGH saying the project `CLAUDE.md` bullet had never been replaced, quoting the old text, more than an hour after the file on disk carried the new one. When a review finding rests on a file outside the diff, verify with a direct read before acting, and tell a reviewer to read such a path rather than trust its context.

## 3. Session metrics

Per-ticket actuals are on the tickets; these are the figures that change a future estimate.

- IAN-352: standard tier, 65 attributable minutes against a 45-minute estimate (ratio 1.44), rework 3, four R-517 review rounds. The calendar gap was 118 minutes; about 50 of those were waiting on fixture suites at a load average peaking near 134 with two other sessions' suites running, on the reviews, and on CI. **R-906:** the edits took about 15 minutes and everything else was overhead, so estimate a rule-text-plus-hook change in this repo at 70 minutes, read as 15 minutes of authoring against 55 of review, merge and verification. Three of the four review rounds existed only because each round's accepted findings moved the head and R-517 re-reviews the new range; two merges of `main` mid-PR cost two of them.
- IAN-332: standard tier, 10 active minutes against a 45-minute estimate (ratio 0.22, human_speedup 6.0), rework 0, one fresh Sonnet review with no findings. **R-906:** estimate a single-gate fix with a known reproduction at 15 to 20 minutes.
- PRs merged: 6 code plus handoffs, rework 6, velocity normal. The triage session merged `#98`, `#99` and `#105`, opened `#100`, `#101`, `#105` and `#106`, and closed `#100` unmerged. `#103` merged fifteen seconds before `#105` opened.
- Ratios: IAN-156 1.42 (scope discovery, not a wrong tier), IAN-175 2.17 (human_speedup 0.35, half the time in the gate loop), IAN-257 0.56 (human_speedup 4.29), IAN-267 0.60, IAN-259 0.50.
- **IAN-259's 0.50 is misleading**: the ticket was opened retroactively mid-work and never bounded the fold it is supposed to measure. Keep it out of the standard-tier baseline.
- **R-906:** IAN-257's 50-min estimate came from the standard/llm median, a sample dominated by gate-loop work. Estimate documentation-only standard tasks near 30.
- Adversarial reviews: 21 on the IAN-173 spec, then 6, 8, 9, 9, 10, 7 on `#92`, `#96`, `#97`, `#98`, `#102`, `#105`, and `#99`'s nine itemized plus about a dozen accepted content losses; a HIGH in each, and every one of those HIGHs passed CI clean.
- The audit session (35 min, 26 Linear writes) is **not comparable** to code velocity.

## 4. What shipped

Detail is on each ticket; these are one line apiece for traceability.

- **IAN-352 (#132).** Merge-on-green became an opt-in chosen per slice at Gate 1, with the owner's merge as the default again; R-514's norm line and Spec, the `task-cleanup` merge decision, the README's Gate 2 paragraph and the project-level `CLAUDE.md` were reconciled with it, `spec-glossary-check.sh` reminds when a slice plan records no mode, and its fixture went from 19 cases to 27.
- **IAN-332 (#122).** The ts/tsx/vue ESLint block hands import-x the TypeScript sub-parser for imported SFCs, and `push-eslint-gate.sh` judges exit status plus stdout while still failing closed on a crash; two new cases in `push-eslint-gate.test.sh`.
- **IAN-156 (#91).** `tdd.sh red` past manifest drift, so a test author here can reach a RED.
- **IAN-175 (#92).** The R-334 norm line and Spec, a 144-line fixture, both ports, the lock untracking.
- **R-212, R-213, R-214 (#96).** Scope declaration, provenance tags, findings-to-ticket, each with an enforcer, fixture and manifest row, plus the `chmod 000` fixture that asserted nothing as uid 0. Deferred: IAN-224, IAN-225. Two of these enforcers shipped dead on macOS and were repaired in `#105` (IAN-267).
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, 21 findings dispositioned.
- **IAN-184 B-3a and B-3b (#97, draft).** The gate asks `expected-red` after a check fails and releases on exit 0, failing closed. Nothing reached `main`.
- **R-605 audit (#98).** 86 commits since `6bc9b24`, 40 uncovered. The docs-versus-code split reproduces under no definition tried, so it and the IAN-226 to IAN-249 backfill are unverified; IAN-258 carries both. Backfilled tickets have no tier or estimate, so R-906 is unaffected.
- **The four-session fold (#98, #99).** Both merged after correcting the R-605 audit figures: 86 commits not 87, day rows 09-17 4/4 and 09-20 14/6, and a restored retraction the compression had dropped. `#99`'s review also caught the file recording a `main` its own merge list contradicted.
- **IAN-267 (#105).** The bash 3.2 guard repair, a class fixture covering nine bash 4 constructs across three hook trees, manifest rows, regenerated hashes.
- **IAN-260 (pushed, no PR).** Spec plus a 14-direction fixture for the per-session handoff split; 4 directions red awaiting the `handoff-check.sh` change.
- **IAN-257 (#102).** The root `README.md` rewritten 22 to 422 lines as adoption-facing landing copy: what the harness prevents, how a feature is built through the skills, the outer/inner split between `build-by-slice-require-review` and `tdd-gated-dispatch` with a comparison table, the layout, a limitations section. Contributor prose moved to the bottom, not deleted. Its R-517 review returned 10 findings, 2 HIGH, all fixed.
- **Withdrawn, do not re-open:** the claim that `#84` and `#88` violated R-605 (IAN-251 makes exemptions recordable), and the 09-18 gap, already closed by `ticket-at-start-gate` in `6f6ca63` (`#78`, IAN-149).
- **IAN-218 backlog capture (folded from #101).** `docs/tickets/2026-09-20-track-and-release-backlog.md`, sixteen work items over four workstreams, and a `linear` block in `claude/TICKET-TRACKER.template.json`. IAN-202 to IAN-217 opened; IAN-218 closed at 76 actual against 90, ratio 0.84, rework 1. That block had never existed in the template despite Linear being the live tracker since IAN-121, and its convention was reconstructible only by reading existing issues.
- **2026-09-23 fanout.** Merged `#113` (the IAN-260 spec), `#114` (IAN-260 slice 1: `handoff-check` reads the index and session files as two kinds, session files uncapped) and `#101` (IAN-254, folding the IAN-218 record in rather than overwriting it). Opened `#115` (IAN-307, macOS CI, green), `#118` (IAN-308 phase 1, doc SHA reachability, in rework) and `#119` (IAN-286, R-517 artefact, in rework), each built by a subagent in its own worktree.
- Tickets opened 09-23: IAN-307, IAN-308, IAN-317, IAN-322, IAN-323, IAN-324. Closed: IAN-254, IAN-259, IAN-260 slice 1, IAN-267. IAN-265 closed as a duplicate of IAN-267.
- **IAN-265, IAN-267 and IAN-271 are one bug**, fixed under IAN-267. Three sessions filed three tickets for the dead scope gates inside ten minutes, none seeing the others, because each was working from a handoff loaded before the others landed theirs. IAN-265 is closed as a duplicate; IAN-271 is now closed the same way, with its 40 wasted minutes recorded on it.
- **The harness evaluation and IAN-268 (#109, draft).** A falsifiable assessment against the harness's own telemetry: **136 of 7,297 recorded rule fires (1.9%) happened in a real product repository**, 743 came from `tmp.*` fixture directories, R-517 logged 2,459 fires across 73 distinct minutes, and the harness took 173 commits since 08-21 against roughly 81 across the three active product repos. Produced a 26-criterion spec, a 13-task plan (gitignored, local) and 16 tickets: IAN-275 to IAN-288 under IAN-268, plus IAN-289 and IAN-290 for the deferred facets. Owner decisions: instrument before acting, native `claude plugin eval` format now with plugin packaging later, adversary precision in CI with end-to-end ablation monthly.
- **IAN-183 follow-on (#110).** `#104` fixed the walk in `ticket-at-start-gate.sh`; its R-517 Codex review then found four equivalence divergences the expansion rewrite had introduced, two of which change which repository a path is judged against. The trailing-newline one was still live on `main` after `#104`, and is fixed here with PW-1 (names this hook if the walk returns) and PW-2 (pins the equivalence). `hook-latency` now passes after `./sync.sh`: Write chain 645ms against a 720ms budget, all three chains in budget.

## 5. Pending (by urgency)

1. **Review and land `#115`, `#118` and `#119`** (2 hours together). All three are finished and green or nearly so; each needs a fresh Codex review of its current state, which is the rule `#119` itself tightens. Both are in rework with a HIGH, both already have the findings sent to the agent that wrote them, both are pushed drafts. `#118`'s HIGH: the push gate reads the working tree instead of the pushed commits, and a first-push branch with no upstream exits 2, which the hook treats as allow. `#119`'s HIGH: the range check scans the line for any hex run matching the head, so `Range: <head sha>` alone passes and `<head>..<base>` passes with the head in the base position. **Each needs a FRESH review of the fixed state afterwards**, which is the rule `#119` is itself tightening.
2. **Review and land `#115`** (IAN-307, 30 min): the macOS job, green on both jobs, draft, no R-517 review yet. Decide the cost question first, below.
3. **IAN-260 slices 2 to 5** (4 hours): session-start load, rule text and procedures, task-state relocation, migration. Slice 5 reads from the `keep/` tags, not the bare SHAs.
4. **IAN-322** (90 min): decide pin-or-mark for each of the 73 unreachable citations, then promote `doc-sha-reachability` from reporting to gating.
5. **IAN-358** (60 min, new): the generated port manifests conflict on every merge of `main` into any rule-touching branch, since both sides regenerate them from the whole rule set. Item 5 under Next session is the current workaround, and this ticket is the proposal to remove the class instead: a `.gitattributes` merge driver that regenerates, dropping the manifests from version control, or a gate that refuses a hand-resolved generated file. Measured cost on IAN-352: two conflicted merges, two extra review rounds.
6. **IAN-323** (20 min): `fetch-depth: 0` on the fixtures job. Touches the same workflow file as `#115`; land `#115` first or fold it in.
7. **IAN-325** (30 min): three more fixtures build bare repositories without `--initial-branch`; audit each and assert a clone is non-empty before depending on it.
8. **IAN-317** (15 min): `${array[*]}` joins on the first character of `IFS` only, so the handoff hook's misses render as `a;b` rather than `a; b`.
9. **`#97`'s two HIGH findings** (60 to 90 min). The IAN-184 comment of 16:5xZ carries both verbatim with the intended fixes. H-1: `is_expected_red` never reads which check failed. H-2: `exit 0` in the checks loop skips the rest. M-1 to M-3 are owed too, and `#97` needs its `## Codex review` section.
10. **IAN-220** (120 min): `tdd.sh green` cannot anchor its hash check to a git object (the lock is gitignored) and `fix-commit-requires-test.sh` denies every bug-fix slice's implementation commit. Both need "the locked tests are committed at HEAD".
11. **IAN-172** (4 h, high): the employer work profile. Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, `claude/global-memory/` public behind only a `[manual]` rule.
12. **IAN-173** (2 h): the database engine-track split. Spec approved, three slices planned, nothing built.
13. **IAN-157** (3 h): `protected-path-guard` fired nine times on paths nobody was writing.
14. **IAN-258** (60 min): re-derive the R-605 audit figures and reconcile the backfill.
15. **IAN-261** (30 min): `SETUP.md` step 1, `AGENTS.md`, and `RECIPES.md` each describe this repository wrongly; `RECIPES.md` calls this file ignored when it is tracked. Also removes two caveats `ce44eda` added to `README.md`.
16. **IAN-250** (60 min): rewrite the criticism audit as a senior challenging a junior's assumptions; its closing argues for self-blame against the brief.
17. **IAN-251** (30 to 45 min): the four allow paths in `pr-ticket-ref-gate.sh` are bare `exit 0`, so an exemption is never recorded and reads later like a gate that never fired.
18. **IAN-252** (40 min): `tdd.sh close` should refuse while the lock path is tracked, reading git state rather than file existence.
19. Lower: **IAN-264** (10 min), **IAN-253** (R-512's bundle exception is dead here; corrected 2026-09-22, the block is the `main` **ruleset's** `allowed_merge_methods`, not the repository setting, which already allows rebase), **IAN-176** (20 min), **IAN-177** (15 min), **IAN-165** (45 min).
20. **No ticket yet:** `tdd.sh red` and `doctor.sh` both exit 0 while refusing or reporting a fail, so the printed verdict is the only truth. `pr-ticket-ref-gate.test.sh` prints a bare `true` mid-run. `#101` has no `docs/prs/` document, and `#100` had none when it was closed. Whether the fixture suite should run under bash 3.2 in CI, and whether hooks should fail closed on an internal fault rather than by each one's structure, are both open from IAN-267 and unticketed.

## 6. Next session

1. **An absence assertion cannot detect a fail-open, and this is the single most repeated failure of the week.** It appeared five separate times: `bash32-builtin-floor`'s first anchor checked only that the output lacked "command not found", and passed against a guard sabotaged into silence; `handoff-session-file-check`'s cap assertion could not tell "the hook exempted it" from "the hook never classified the path"; `#118`'s process-budget fixture measured only nonexistent objects, so adding a git call per resolved token left all 40 assertions green; `#119` had three assertions matching generic remedy text, so replacing every specific diagnostic with "missing field" left the suite green; and a session grep for `## Codex review` matched the sentence saying no review had run. Assert that the expected thing HAPPENS. Then break the implementation and watch the assertion go red, because a passing test tells you nothing about what it would do if the code were wrong.
2. **Green CI is not evidence a guard works.** ubuntu was fully green on a `scope-widening-gate` that had stopped guarding, and `shellcheck` was clean on the same construct. Only the real bash 3.2 floor caught it. `#115` adds that job.
3. **Re-read this file on `main` before opening any ticket.** Three sessions filed three tickets for one bug inside ten minutes on 09-20 because each trusted a handoff loaded before the others landed theirs. `git log origin/main -- docs/session-handoff/` costs seconds.
4. **Check `git worktree list` for a parallel session before starting** (R-501). Two sessions built the same fixture for the same bug; a commit once hung 16 minutes because two fixture suites ran at once and load hit 20 on 14 CPUs.
5. **Sequence by generated file, not by source file.** Disjoint source scopes are not enough: work out which generated artefacts each branch regenerates and serialise on those. Three of today's PRs had genuinely disjoint rule changes and still collided twice.
6. **Dispatching subagents worked, with one caveat.** Three agents in their own worktrees, with disjoint file scopes and their tickets named in the prompt, produced three PRs and no collisions. Each prompt carried this session's lessons as requirements, and each agent still shipped at least one assertion that could not fail, so the review is what caught them, not the brief. Give each agent its own worktree (the TDD lock is per-checkout), keep concurrency at about three (the fixture suite is CPU-heavy), and expect `hook-hashes.txt` to conflict between any two that touch hooks, so merge them one at a time.
7. **Re-read this file on `main` before opening any ticket**, not the copy injected at session start. Three sessions filed three tickets for one bug today because each trusted a handoff loaded before the others landed theirs. `git log origin/main -- docs/session-handoff/` costs seconds.
8. **Check `git worktree list` for a parallel session on the same work** before starting (R-501). Two sessions built the same fixture for the same bug today, and one of them is still uncommitted.
9. Rebase before starting and before merging: `main` moved twelve times today and handoffs collided here seven times, this file included.
10. **Run `doctor.sh --full` at session start, not at the end.** IAN-265 was found only because a documentation task happened to run the gate on its way out. A gate that emits nothing when broken is indistinguishable from one that ran and allowed.
11. **`git log HEAD..origin/main` after every fetch, not just `gh pr list`.** A squash-merge deletes the branch and closes the PR, so a branch-name grep and an open-PR listing both come back clean. That is exactly how `#105` was missed, and it cost 40 minutes.
12. **When a fixture passes in CI and fails locally, suspect the platform before the branch.** Twice today the answer was ubuntu-versus-macOS: IAN-267's `mapfile`, then `#104`'s own path-walk fixture failing at its own head while CI was green. `enforce.yml` runs only on `ubuntu-latest`; a macOS or bash 3.2 leg is the missing coverage and has no ticket because of the Linear limit.
13. **The IAN-268 order is IAN-275 first** (fixture telemetry isolation), then IAN-281 (the SessionStart handoff pointer, which fixes the truncated-read failure that cost this session its 40 minutes), then IAN-276 and IAN-277, then the IAN-288 spike before any Phase 2 work. The Phase 1 cuts (IAN-282 to IAN-287) are independent and can go in parallel.
14. **A test for a fail-open must assert the expected thing still happens**, never that an error string is absent. The first `bash32-builtin-floor.test.sh` anchor checked only that the output lacked "command not found", which an empty output satisfies, so it passed against a guard sabotaged into exactly the silence it existed to catch. The R-517 review found it; running the fixture did not, because a passing test says nothing about what it does when the code is wrong.
15. **CI passing is not evidence a guard works.** CI is ubuntu with bash 5; these hooks run on macOS with bash 3.2, the one configuration CI never exercises.
16. Read the IAN-184 thread before touching `#97`, and fix `#97` before syncing it anywhere.
17. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` here: the installed copy can predate the edit.
18. A decision in a PR document and not in an assertion is enforced by nothing. When a document states a bound, write the assertion in the same slice.
19. The hash manifest's `--update` writes to `$HOME/.claude` unless `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` is set. `protected-path-guard` reads shell text, not resolved paths: prefer the Write tool over a Bash heredoc.
20. Order work by dependency, not as the user listed it: the gate session opened IAN-220 first, then found every slice depends on the `test-author` subagent IAN-184 unblocks.
21. IAN-173 starts at slice 1, the invariants-test block, not at the files. B-2's line-coverage check reads `git show 48f3b5c:claude/CLAUDE-DATABASE.md`; pin that sha.
22. IAN-173's HIGH, easy to lose: `paths:` frontmatter globs are what auto-load a convention file and a dispatch table loads nothing, so the engine files take disjoint globs while the shared `**/migrations/**`, `**/src/database/**` and `**/src/repositories/**` stay on the base file alone, or every project loads both engines' rules.
23. The R-801 engineering-audit signal fires on every push and is accumulating: `claude/enforce` and `claude/hooks` are both well past the threshold since the 2026-09-18 audit. Advisory.
24. Cite `reference.md` by rule ID, never by line range: `#96` moved R-605 from 684 to 722, stale within hours.
25. When a command's output and a document in this repository disagree, the disagreement is the finding. Five errors in the README session came from believing `SETUP.md`, `AGENTS.md` or `RECIPES.md` over a command already run.
