# build-fast: a speed-first build skill with risk lanes (IAN-401)

Ticket: IAN-401. Branch: `feat/build-fast-skill`. Tier: complex.

## Problem

Every build today runs one fixed ceremony that task-start picks by size, not by risk. A small, safe change in an interview or a critical bug fix still pays for a spec, an adversarial spec review, per-behaviour lock cycles, mid-build bookkeeping, sequential review and CI, a turn-per-question cadence, and a strong, slow model writing every line. The measured median `human_speedup` on product tickets is about 3x (n=13), while governance-heavy work overran badly (IAN-381: 240 minutes estimated, about 20 hours actual). The owner wants a build skill whose goal is time to a working, merged change, and which spends strong-model time on review only, at the one point where it adds almost no wall time.

## Decisions (owner, 2026-09-26 and 2026-09-27)

1. The skill is named `build-fast` and runs only on explicit opt-in: the owner says "build fast" or invokes `/build-fast`. Every other build keeps today's process, unchanged.
2. Speed is the goal. Reliability comes from the cheap deterministic gates (lint, affected tests, push-semgrep-gate, secret scan, CI) and from one strong review after the build, not from extra agent passes.
3. No bug or issue hunting by default. The only review pass is one batched review of the whole diff at the R-517 checkpoint, plus an approach review before the build only when the owner asks for one in the opening batch.
4. No yak-shaving. An off-path blocker is avoided by taking a different path to the requested change and ticketing the blocker (`finding.sh`, R-214); nothing noticed in passing is investigated inline. Avoiding a blocker never means patching over it: a symptom-masking workaround still needs the owner's acceptance first (R-204).
5. Routing around a blocker never means bypassing a gate (R-203, R-204, R-405). A gate that is itself the blocker stops the run and goes to the owner.
6. Security is not a hunt: a range that touches a security control still gets the R-109 security review on the strongest model, and a security finding is never answered away; only the owner waives one.
7. The lane is predicted before the first edit from the declared scope, then classified mechanically on the committed head after every commit that precedes a review, and the classification the merge relies on is the one taken on the PR's head commit.
8. The fast lane keeps the `tdd.sh` lock but runs one slice for the whole change.
9. Owner-selected optimizations: no spec in the fast lane; every question asked up front in the opening batch; the R-517 review runs in parallel with CI; one paperwork commit, with reminder-only hooks muted in the fast lane.
10. Approach: a skill plus one classifier script (approach 1 of 3); the reminder muting ships as a second PR.
11. Escalation (owner answer to spec-review finding 2): when a fast change classifies `guarded` after the code is written, keep the code and tests, and add what the guarded lane still can: the R-109 security review when the detector hit, and an owner merge. No retroactive spec or separate test author.
12. The harness's own merge confirmation stays. "Merge on green" means the session issues `gh pr merge` without waiting for the owner to read the PR; `git-workflow-guard.sh` still asks the owner to confirm that merge (R-514), and this spec does not change the guard.
13. The build runs on the fastest model, Haiku 4.5, not the most thorough one: the skill's frontmatter sets `model: haiku`, which holds for the turn the skill runs in. IAN-474 evaluates this choice after 3 to 5 real runs.
14. The strongest model reviews after the build: the R-517 reviewer runs on the model `enforce/security-review-model.json` names (`securityReviewModel`), in parallel with CI, so its time overlaps CI instead of adding to the run. A before-the-build approach review on the same model runs only when the owner opts in through the opening batch. No review runs during the build.
15. Two lanes, not three. With every build on Haiku and every R-517 review on the strongest model, the checked lane the ticket sketched no longer differs from the fast lane, so it is dropped, together with the diff-size thresholds that selected it.

## Domain vocabulary

- lane - the risk class a build-fast change runs under: `fast` or `guarded` - chosen over: tier, mode because tier already names task-start's Trivial to Saga classes and mode already names the merge mode.
- fast lane - no spec, one lock slice written on Haiku, one strongest-model R-517 review in parallel with CI - chosen over: light because the owner's word for the goal is fast.
- guarded lane - today's Complex process when predicted before the first edit; the escalation additions of decision 11 when classified after it - chosen over: full because guarded names why the ceremony exists.
- approach review - an opt-in review, before the first edit, of the planned approach and file list by the strongest model - chosen over: plan review because build-fast writes no plan document.
- lane prediction - the lane `build-lane.sh predict` derives from the declared scope before any code exists - chosen over: estimate because it is a class, not a number.
- lane classification - the lane `build-lane.sh classify` derives from a committed range - chosen over: scoring because it outputs a class, not a score.
- lane override - an owner-chosen lane recorded on the ledger and applied to every later prediction and classification - chosen over: forced lane because the owner's ticket word was override.
- lane rules - `claude/skills/build-fast/lane-rules.json`, the guarded path patterns - chosen over: risk config because it holds only lane rules.
- opening batch - the option-tile questions asked before the first edit of a build-fast run, after which the run stops only for the stop conditions in B-4 - chosen over: intake because batch names the R-211 exception it relies on.
- paperwork commit - the single commit carrying the PR body source, product-doc rows, and handoff, made before the push the review reads - chosen over: bookkeeping commit because the owner's request used paperwork.
- reminder-only hook - a hook that never blocks and only adds `additionalContext` text: `clean-code-reminder.sh`, `observability-reminder.sh`, `new-file-header-reminder.sh`, `dockerfile-reminder.sh`, `flat-directory-reminder.sh`, `single-file-folder-reminder.sh` - chosen over: advisory hook because the files are already named `*-reminder.sh`.

## Lane and tier matrix

task-start still classifies and tickets every build-fast task; the lane decides the process.

| Lane | When set | Ledger tier | Spec | Build model and test author | R-517 reviewer | R-109 review | Merge |
|---|---|---|---|---|---|---|---|
| fast | predicted or classified | `standard` | none | Haiku, the session under the lock | `securityReviewModel`, parallel with CI | when the detector hit and the owner lowered the lane | per the opening batch's merge mode |
| guarded, predicted | before the first edit | `complex` | yes | per task-start Complex (`test-author` agent) | per task-start Complex | when the detector hits | owner |
| guarded, escalated | after the code exists | stays `standard` | none (decision 11) | already written on Haiku | `securityReviewModel`, parallel with CI | when the detector hit | owner |

A predicted guarded lane hands the whole task to task-start's Complex process; build-fast stops governing it, and only the ticket's lane record remains.

## Behavior

### B-1: lane rules

`lane-rules.json` holds `{"guardedPaths": [<ERE>...]}`, matched case-insensitively against each changed repository-relative path. Initial patterns: migrations `(^|/)(migrations?|alembic|db/migrate)/`, `\.sql$`; concurrency `(^|/)(workers?|queues?|jobs?|locks?)/`, `(mutex|semaphore|concurren|transaction)`; money `(billing|payment|invoice|checkout|stripe|money)`.

The file is invalid, and every prediction and classification prints `guarded config-failure: <why>`, when it is missing, is not JSON, lacks `guardedPaths`, holds an empty list or a non-string entry, or holds a pattern `grep -E` rejects.

### B-2: the lane classifier

`claude/skills/build-fast/scripts/build-lane.sh` has two commands. Both print one line, `<lane> <reason>`, and exit 0; any failure prints a guarded line and exits 0 (fail closed). Written for Bash 3.2, like `security-surface.sh`.

`predict <glob>...` expands each declared scope glob against `git ls-files` and also tests the glob text itself, and prints `guarded security-surface: predicted <pattern>` when any result matches a `paths` regex in `enforce/security-surface.json`, `guarded path: predicted <pattern>` when any matches a `guardedPaths` pattern, else `fast predicted`. The shared reason prefixes let the override rules below treat a prediction and a classification alike.

`classify [--base <oid>] [--head <oid>]` resolves the range, then decides:

1. Range: head defaults to `HEAD`, resolved to a commit ID. Base defaults to the merge base of head with `refs/remotes/origin/<baseRefName>` when `gh pr view --json baseRefName` names the branch's PR, else with `refs/remotes/origin/HEAD`'s target; it fetches that ref first. Local `main` is never used. A range that cannot be resolved prints `guarded range-failure: <why>`.
2. Security: it calls `list_security_surface_hits` (sourced from `hooks/security-surface.sh`) under a deadline of `CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS` (default 30), in its own process group with `SECURITY_SURFACE_WORK_ROOT` set to a directory it owns, killing the group and removing the directory on timeout, as `git-workflow-guard.sh` does (copied, not extracted, so the guard stays untouched). Return 2 or a timeout prints `guarded detector-failure: <why>`; any hit line prints `guarded security-surface: <first hit>`.
3. Paths: a changed path matching `guardedPaths` prints `guarded path: <path>`.
4. Otherwise `fast clear: <files> files`.

Override: both commands read `laneOverride` from the ledger when it names the current branch. An override that raises the lane replaces it and appends `; override from <detected>`. An override that lowers it replaces it only when the detected reason is `security-surface` or `path`, and appends `; override from <detected>`, plus `; r109-required` when the detected reason is `security-surface`. A `config-failure`, `range-failure`, or `detector-failure` is never lowered.

### B-3: the ledger fields

`task-tier.sh set` accepts `--lane <fast|guarded>`, `--lane-override <fast|guarded>`, and `--merge-mode <owner|green>`, and writes `lane`, `laneOverride`, and `mergeMode`. An unknown value for any is refused with a non-zero exit. A later `set` keeps each field it does not restate only when the existing ledger names the same branch and the same ticket; a different branch or ticket drops all three, so a new task never inherits them. `task-tier.sh summary` prints the lane and merge mode when present. The existing `ticket` and `scope` handling is unchanged. `task-tier.sh clear` (task-cleanup's last step) removes them with the ledger. The ledger's `startedAt` reset on every `set` is a separate bug (IAN-472); the build's timing comes from the R-503 session-start record.

### B-4: the skill flow

`claude/skills/build-fast/SKILL.md` carries `model: haiku` in its frontmatter and states these steps in order, and the hard rules of decisions 2 to 6 as imperatives:

1. **Opening batch.** Before any edit, ask every fork: the change as understood, the merge mode (`owner`, the default, or `green`), whether to run an approach review, any lane override, and any ambiguity, as option tiles, four per `AskUserQuestion` call and as many calls as the forks need, all before the first edit.
2. **Setup.** Run task-start's setup subset: search the tracker by branch, open or advance the ticket (R-605), create the branch (a worktree when a parallel session is active, R-501), then `build-lane.sh predict <scope globs>` and `task-tier.sh set <tier per the matrix> "<reason>" --ticket <KEY> --scope <globs, docs paths included> --lane <predicted> --merge-mode <m> [--lane-override <o>]`. A guarded prediction hands off to task-start's Complex process here.
3. **Approach review, only when opted in.** Dispatch the read-only `pr-reviewer` agent on `securityReviewModel` with the request, a plan of at most ten lines, and the file list; adjust the approach for each finding before the first edit. Skip this step otherwise.
4. **Build.** One `tdd.sh` slice for the whole change, on Haiku: open, failing tests, red, implement, green, close. No review of any kind runs during this step.
5. **Paperwork commit.** PR body source, product-doc rows, handoff.
6. **Classify** the committed head with `build-lane.sh classify` and record the lane. A guarded result applies decision 11: record `--lane guarded --merge-mode owner`, and turn on reminders again.
7. **Security review when required.** When the classification's reason is `security-surface` or carries `r109-required`, run the security-reviewer agent on the range, record its artefact with `enforce/security-review-record.sh`, and commit it, all before the push in step 8, so the head the R-517 review and CI read already carries it. Then classify again.
8. **Push, then review in parallel with CI.** Advance the ticket to `in-review`. Start the R-517 review in the background on the pushed head, as the read-only `pr-reviewer` agent on `securityReviewModel`, at the same time CI runs.
9. **One fix round.** Fix each finding test-first, or answer it with a reason in the PR. After the fix commits, classify again (step 6), rerun step 7 if it now applies, push, and rerun the R-517 review on the new head in parallel with the new CI run.
10. **Stop conditions.** Stop, leave the PR unmerged, and hand it to the owner when the rerun review raises a new finding, a security finding is unfixed (only the owner waives one, R-109), CI is red after the fix round, a gate blocks (decision 5), a change would widen the declared scope (R-212), a workaround would mask a symptom (R-204), or an action is destructive. Every other mid-run choice inside the declared scope that the tests pin (a name, an internal structure) is made without stopping and listed in the PR body. A run resumed in a later turn invokes the skill again, so the frontmatter model applies again.
11. **Merge** per the recorded merge mode: `owner` hands the PR over with the findings and their dispositions; `green` issues `gh pr merge` once CI is green and the review passed, and the guard's R-514 confirmation still asks the owner (decision 12). Verify the merge landed on `main`.
12. **Close** through `/ticket-lifecycle`'s close: `completed_at`, `actual_minutes`, `rework_count`, and `estimate_ratio` in one update, the lane, merge mode, and build model in the transition comment (R-606, and IAN-474's evidence), then task-cleanup.

### B-5: rule text

- R-211 (CLAUDE.md norm and reference.md Spec) gains: under build-fast, the forks are asked in the opening batch, several questions per tile call, before the first edit, and the run then stops only for B-4 step 10's conditions.
- R-514 gains: under build-fast, the merge mode the owner chose in the opening batch, recorded as `mergeMode` on the task-tier ledger for the PR's head branch and in the ticket's transition comment, stands in for a slice plan's `**Merge mode:**` line; the guard's confirmation still applies.
- R-517 gains: under build-fast, the reviewer runs on `securityReviewModel` without a separate owner opt-in, the owner's build-fast opt-in counting as that opt-in, and runs in parallel with CI on the pushed head.
- `task-start/SKILL.md` gains one paragraph: when the owner invokes build-fast, task-start classifies and tickets the task, and build-fast's lane and tier matrix decides the process and the build model.

### B-6: reminder-only hooks go quiet in the fast lane (PR 2)

A sourced helper, `hooks/build-lane-quiet.sh`, defines `is_reminder_quiet`, which returns 0 only when the checkout's `.claude/task-tier.json` parses, names the checked-out branch, and carries `lane` `fast`. Each reminder-only hook exits 0 with no output when it returns 0, and otherwise behaves exactly as today, its existing exemptions included. No blocking hook sources the helper.

## Acceptance criteria

1. B-1: for each invalid lane-rules case (missing file, not JSON, missing key, empty list, a non-string entry, a pattern `grep -E` rejects), `classify` and `predict` print `guarded config-failure`.
2. B-2 classify, on a fixture repository with a real `enforce/security-surface.json`: a README-only range prints `fast clear`; a `migrations/` path, a `workers/` path, and a `billing/` path each print `guarded path`; a range whose only security trigger is a content-pattern line prints `guarded security-surface`; with no Semgrep resolvable the detector's own failure prints `guarded detector-failure`; a fake Semgrep that sleeps past a one-second deadline prints `guarded detector-failure` and leaves no work directory; an unresolvable base prints `guarded range-failure`; an explicit `--head` and the default `HEAD` classify their own ranges.
3. B-2 range: with local `main` stale and `origin/main` current, the base is taken from `origin/main`.
4. B-2 override: a raise from fast to guarded prints `guarded ...; override from fast`; a lower of a security-surface range prints `fast ...; r109-required`; a lower of a detector failure still prints `guarded detector-failure`; an override on the ledger of another branch is ignored.
5. B-2 predict: scope `src/billing/**` prints `guarded path: predicted ...`; scope `README.md` prints `fast predicted`; a glob naming a path in `security-surface.json` `paths` (for example `src/auth/**`) prints `guarded security-surface: predicted ...`, and a lane override of `fast` on it prints `fast ...; r109-required`.
6. B-3: `set standard r --ticket T --lane fast --merge-mode green` writes both fields and `summary` prints them; `--lane checked`, `--lane-override x`, and `--merge-mode auto` exit non-zero; a later `set` with only `--lane guarded` on the same branch and ticket keeps `mergeMode`; a `set` naming another ticket or branch drops all three fields; the existing `ticket` and `scope` fields survive every case.
7. B-4 and B-5: the skill file carries `model: haiku` in its frontmatter and each step, stop condition, and hard rule, and the R-211, R-514, R-517, and task-start texts carry their clauses (prose fixture tests, as other skills have).
8. B-4 composition, as an integration fixture: with `mergeMode` `green` on the ledger, `git-workflow-guard.sh` on `gh pr merge` still emits its R-514 ask; with no lane on the ledger, `codex-test-author-guard.sh` and the reminder-only hooks behave as before this change (the non-opt-in build is unchanged).
9. B-6: with `lane` `fast` on a ledger naming the checked-out branch, each reminder-only hook prints nothing for an input that otherwise triggers it; it prints its reminder when the lane is `guarded`, when the ledger names another branch, when the ledger is malformed JSON, and when there is no ledger; its existing clean-file exemptions still hold; `protected-path-guard.sh` and `scope-widening-gate.sh` decide the same with and without a lane.

## Non-goals

- No change to any blocking gate: `git-workflow-guard.sh`, `protected-path-guard.sh`, `codex-test-author-guard.sh`, `scope-widening-gate.sh`, and the push gates are untouched.
- No automatic trigger; build-fast never activates without the owner's opt-in.
- No lane-specific estimates; IAN-402 owns up-front estimates across the build skills.
- Fixing the ledger's `startedAt` reset; IAN-472 owns it.
- Choosing the build model on evidence; IAN-474 owns it.

## Risks

- A missing pattern puts a risky change in the fast lane. Mitigation: the prediction and every classification fail closed, the classification the merge relies on is taken on the PR head, R-109 applies in every lane, and the strongest model reviews every diff.
- Haiku writes more defects than a stronger model. Mitigation: the lock's tests, CI, the strongest-model review, one fix round, and the stop conditions; IAN-474 measures the cost.
- The opening batch misses a fork. Mitigation: B-4 step 10 stops for every fork that needs the owner, and the rest are listed in the PR body.

## Testing

Fixture tests under `claude/enforce/tests/` for the criteria above, registered in `enforce/manifest.json` (R-516). PR 1 carries B-1 to B-5 and criteria 1 to 8; PR 2 carries B-6 and criterion 9.

## Spec review

Reviewer: Codex (account default model), read-only, 2026-09-27. 19 findings; stack options all "keep current". The owner's later decisions 13 to 15 (Haiku build, strongest-model review after the build, two lanes) postdate the review and remove the checked lane its findings mention.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | Merge on green still hits the guard's R-514 prompt | Fixed: decision 12; the prompt stays and the spec no longer promises an unprompted merge |
| 2 | HIGH | Lane chosen only after implementation | Fixed: `predict` before the first edit (B-2, B-4 step 2); escalation per the owner's answer (decision 11) |
| 3 | HIGH | Classification precedes the paperwork commit | Fixed: B-4 steps 5 to 9 classify the committed head after paperwork and after every fix |
| 4 | HIGH | `main HEAD` may be stale or the wrong base | Fixed: B-2 range resolution from the PR's `origin/<baseRefName>`, never local `main`; criterion 3 |
| 5 | MEDIUM | `is_security_surface` hides detector failure | Fixed: B-2 uses `list_security_surface_hits` and its return 2 |
| 6 | MEDIUM | No detector deadline | Fixed: B-2 copies the guard's deadline, process-group kill, and cleanup; criterion 2 |
| 7 | HIGH | Security artefact must be at head before R-517 and CI | Fixed: B-4 step 7 commits the artefact before the push |
| 8 | HIGH | No terminal state after the fix round | Fixed: B-4 step 10 stop conditions |
| 9 | MEDIUM | Lane and tier precedence undefined | Fixed: lane and tier matrix; B-5 task-start paragraph |
| 10 | MEDIUM | Escalation keeps `green` and mutes reminders | Fixed: B-4 step 6 forces `owner` and reminders; B-6 mutes only the fast lane |
| 11 | MEDIUM | Lane rules schema undefined | Fixed: B-1 schema, initial patterns, validation; criterion 1 |
| 12 | MEDIUM | Override lifecycle undefined | Fixed: `laneOverride` on the ledger, applied on every call, failures never lowered |
| 13 | MEDIUM | Setup omits branch, worktree, scope | Fixed: B-4 step 2 |
| 14 | MEDIUM | Lane and merge mode leak to the next task | Fixed: B-3 keeps them only for the same branch and ticket; `clear` removes them |
| 15 | MEDIUM | Tracker lifecycle and timing incomplete | Fixed: B-4 steps 2, 8, 12 use the full lifecycle; timing from the R-503 record; the `startedAt` reset ticketed as IAN-472 |
| 16 | MEDIUM | Classifier criteria incomplete | Fixed: criteria 1 to 5 (size boundaries removed with the checked lane, decision 15) |
| 17 | MEDIUM | Ledger and reminder isolation untested | Fixed: criteria 6 and 9 |
| 18 | MEDIUM | Prose tests cannot prove composition | Fixed: criterion 8 integration fixture |
| 19 | MEDIUM | Silent decisions and question overflow | Fixed: decision 4 keeps R-204's acceptance; B-4 step 1 allows several calls; step 10 lists what stops |

Stack options (Bash classifier, reuse the detector, JSON and jq rules, the existing ledger, skill prose orchestration, a shared reminder helper, the existing fixture suite): all kept as the reviewer recommended; the shared helper is adopted as `build-lane-quiet.sh`.
