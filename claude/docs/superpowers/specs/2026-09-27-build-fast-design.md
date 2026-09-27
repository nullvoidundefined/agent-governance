# build-fast: a speed-first build skill with risk lanes (IAN-401)

Ticket: IAN-401. Branch: `feat/build-fast-skill`. Tier: complex.

## Problem

Every build today runs one fixed ceremony that task-start picks by size, not by risk. A small, safe change in an interview or a critical bug fix still pays for a spec, an adversarial spec review, per-behaviour lock cycles, mid-build bookkeeping, sequential review and CI, and a turn-per-question cadence. The measured median `human_speedup` on product tickets is about 3x (n=13), while governance-heavy work overran badly (IAN-381: 240 minutes estimated, about 20 hours actual). The owner wants a build skill whose goal is time to a working, merged change, and which spends agent time on review only where the change's risk calls for it.

## Decisions (owner, 2026-09-26 and 2026-09-27)

1. The skill is named `build-fast` and runs only on explicit opt-in: the owner says "build fast" or invokes `/build-fast`. Every other build keeps today's process.
2. Speed is the goal. Reliability comes from the cheap deterministic gates (lint, affected tests, push-semgrep-gate, secret scan, CI), not from extra agent passes.
3. No bug or issue hunting by default. The only review pass is one batched review of the whole diff at the R-517 checkpoint, unless the owner asks for more.
4. No yak-shaving. Off-path blockers are routed around and ticketed; nothing noticed in passing is investigated inline.
5. Routing around a blocker never means bypassing a gate (R-203, R-204, R-405). A gate that is itself the blocker stops the run and goes to the owner.
6. Security is not a hunt: a range that touches a security control still gets the R-109 security review on the strongest model, in every lane.
7. The lane is chosen mechanically by a script from the security-surface detector and the diff size, and re-checked on the final diff before merge.
8. The fast lane keeps the `tdd.sh` lock but runs one slice for the whole change.
9. Owner-selected optimizations: no spec in the fast lane; every question asked once, up front; the R-517 review runs in parallel with CI; one paperwork commit at the end, with reminder-only hooks muted.
10. Approach: a skill plus one classifier script (approach 1 of 3); the reminder muting ships as a second PR.

## Domain vocabulary

- lane - the risk class a build-fast change runs under: `fast`, `checked`, or `guarded` - chosen over: tier, mode because tier already names task-start's Trivial to Saga classes and mode already names the merge mode.
- fast lane - no spec, one lock slice, one `sonnet` R-517 review in parallel with CI, merge per the chosen merge mode - chosen over: light because the owner's word for the goal is fast.
- checked lane - the fast lane with the R-517 review on `opus` and one fix round - chosen over: standard because Standard is a task-start tier.
- guarded lane - today's Complex process: spec, spec review, `test-author` and implementer agents, strongest-model R-109 review, owner merge - chosen over: full because guarded names why the ceremony exists.
- lane classifier - `build-lane.sh`, the script that prints a lane and its reason for a commit range - chosen over: risk scorer because it outputs a class, not a score.
- opening batch - the one set of option-tile questions asked at the start of a build-fast run, after which the run does not stop to ask again except under decision 5 or a destructive action - chosen over: intake because batch names the R-211 exception it relies on.
- paperwork commit - the single commit at the end carrying the PR body source, product-doc rows, and handoff - chosen over: bookkeeping commit because the owner's request used paperwork.
- reminder-only hook - a hook that never blocks and only adds `additionalContext` text: `clean-code-reminder.sh`, `observability-reminder.sh`, `new-file-header-reminder.sh`, `dockerfile-reminder.sh`, `flat-directory-reminder.sh`, `single-file-folder-reminder.sh` - chosen over: advisory hook because the files are already named `*-reminder.sh`.

## Behavior

### B-1: the lane classifier

`claude/skills/build-fast/scripts/build-lane.sh classify <base> [<head>]` prints one line, `<lane> <reason>`, and exits 0.

- `guarded` when `is_security_surface` (sourced from `hooks/security-surface.sh`) returns 0 for the range, or when a changed path matches the migration or concurrency patterns in `claude/skills/build-fast/lane-rules.json`.
- `checked` otherwise, when the range adds plus deletes more than 400 lines, or changes more than 15 files (both thresholds read from `lane-rules.json`).
- `fast` otherwise.
- Fails closed: when the detector returns 2, the patterns file is unreadable, or git cannot read the range, it prints `guarded detector-failure: <why>` and exits 0.
- An owner override (`--lane <lane>`) may raise the lane freely. It may lower it, but a range the detector marks as a security surface still requires the R-109 review; the override line records `override` in the reason.

### B-2: the lane on the ledger

`task-tier.sh set` accepts `--lane <fast|checked|guarded>` and writes `lane` into `.claude/task-tier.json`; `task-tier.sh summary` prints it; a reclassification without `--lane` keeps the recorded lane. An unknown lane value is refused.

### B-3: the skill flow

`claude/skills/build-fast/SKILL.md` states, in order:

1. The opening batch: the requested change as understood, the merge mode (owner merges by default, or merge on green), and any other fork, all as option tiles in one `AskUserQuestion` call (at most four questions, per the tool).
2. Ticket: open or advance it in one direct tracker call (R-605), and `task-tier.sh set <tier> ... --ticket <KEY> --lane <lane>` with the lane from `build-lane.sh classify main` run against the planned paths once the first commit exists, and `fast` before it.
3. Fast and checked lanes: one `tdd.sh` slice for the whole change (open, failing tests, red, implement, green, close); no spec, no spec review. Guarded lane: hand off to task-start's Complex process unchanged.
4. Push, then start the R-517 review in the background at the same time CI runs; the review's model follows the lane (`sonnet` fast, `opus` checked, the R-517 rules for guarded).
5. One fix round for review findings, test-first; re-review only when a fix changed behaviour.
6. Re-run `build-lane.sh classify` on the final range; when the lane rose, apply the higher lane's review before merge.
7. The paperwork commit, then merge per the opening batch's merge mode (R-514).
8. Close the ticket with `actual_minutes` and the lane in the transition comment (R-606).

It also states the hard rules from decisions 3 to 6 verbatim in imperative form.

### B-4: the R-211 exception

`claude/CLAUDE.md` R-211 and its reference.md Spec gain one clause: under build-fast, the forks are asked once in the opening batch, several questions in one tile call, and the run then continues without stopping to ask. Every other session keeps one question per turn.

### B-5: reminder-only hooks go quiet under a lane (PR 2)

Each reminder-only hook exits 0 with no output when the current checkout's `.claude/task-tier.json` names the checked-out branch and carries a `lane`. No blocking hook reads `lane`.

## Acceptance criteria

1. B-1: a fixture repo range touching only a README classifies `fast`; one with 401 changed lines classifies `checked`; one touching a path the security-surface config lists classifies `guarded`; one touching `migrations/` classifies `guarded`; a range where the detector is forced to fail classifies `guarded detector-failure`.
2. B-1: `--lane fast` on a security-surface range prints `fast override` and the reason names the R-109 requirement.
3. B-2: `task-tier.sh set standard r --lane checked` writes `"lane":"checked"`; `--lane quick` exits non-zero; a later `set` without `--lane` on the same branch keeps `checked`.
4. B-3 and B-4: the skill file and R-211 text contain each step and rule above (checked by a text fixture test, as other skills' prose tests do).
5. B-5: with a lane on the ledger, each reminder-only hook prints nothing for an input that otherwise triggers it; without a lane it prints its reminder; `protected-path-guard.sh` and `scope-widening-gate.sh` behave the same with and without a lane.

## Non-goals

- No change to any blocking gate, the merge guard, or the R-517 and R-109 requirements.
- No automatic trigger; build-fast never activates without the owner's opt-in.
- No lane-specific estimates; IAN-402 owns up-front estimates across the build skills.

## Risks

- A mis-set threshold puts a risky change in the fast lane. Mitigation: the detector fails closed, the lane is re-checked on the final diff, and R-109 applies in every lane.
- The opening batch misses a fork that appears mid-build. Mitigation: decision 5 and destructive actions still stop the run; any other fork takes the option that keeps scope smallest and is reported in the PR body.

## Testing

Fixture tests under `claude/enforce/tests/` for B-1, B-2, B-4 text, and B-5, registered in `enforce/manifest.json` (R-516). Delivery: PR 1 carries B-1 to B-4; PR 2 carries B-5.
