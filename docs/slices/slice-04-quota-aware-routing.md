# Slice 04: quota-aware routing between Claude and Codex

**Ticket:** IAN-603
**Merge mode:** merge on green (owner, Gate 1, 2026-10-02)
**Risk:** standard for PRs 1 to 5. They add a quota reader, a pace calculator, a router, and a hand-off summary. None of them touches auth, secrets, redaction, money, or concurrency, and none of them changes whether a gate runs. A PR that turns out to touch a security control is reclassified to high before it merges.
**Fuzzy controls:** none. Each threshold below is a number the owner set, not an allow or deny list.

## Goal

Keep both providers on pace to last their full weekly window, spending Codex's spare capacity first. Routing changes who does a step. It never changes whether a step happens: deterministic gates, evals, and human approvals stay as they are.

## Owner decisions (Gate 1, 2026-10-02)

1. **High-risk slices split by risk.** On a standard-risk slice, Codex owns the full loop: it writes the tests, runs them, and fixes until green. On a high-risk slice, Codex becomes the default test author, and the Claude `implementer` and `slice-critic` stay separate fresh contexts (R-707). The R-411 write-time role boundary has no `agent_type` under `codex exec`, so the implementer role does not move.
2. **The R-109 security review stays pinned to `securityReviewModel`.** When Claude wrote a security-touching PR, the router also sends the R-517 review to Codex, so the PR still gets a cross-model read.
3. **Burn rate.** Actual daily burn comes from the latest snapshot and the most recent earlier snapshot at least 12 hours older in the same window. When no such pair exists, it falls back to the window average: used percent divided by the days elapsed since the window opened. Under one hour into a window, the window average is too noisy to trust (a near-zero divisor), so the method reads `insufficient` and the ratio is null until an hour has passed.
4. **Exhaustion.** A bucket is near exhaustion when less than one day of quota is left at its current burn (remaining percent divided by burn is under 1 day) and its reset is further away than that, or when it is at 90 percent used or more. This revises the first answer, "projected to run out before reset". That condition is the same as a pace ratio above 1.0, so it would trip before the 1.2 shift (owner, 2026-10-02).

## Formulas

For each bucket:

- `daysLeft = (resetsAt - now) / 1 day`
- `dailyBudget = (100 - usedPct) / daysLeft`
- `paceRatio = burn / dailyBudget`
- A provider's pace ratio is the worst (highest) of its buckets. For example, Claude's ratio is the higher of its all-models bucket and its Fable bucket.

## Quota input

The CLIs expose quota as follows:

- **Claude Code** passes `rate_limits.seven_day.{used_percentage,resets_at}` to the status line command. This is the all-models weekly bucket. The installed CLI's schema was checked on 2026-10-02. PR 2 records it.
- **Fable-only bucket:** there is no status line field, so the owner enters it by hand.
- **Codex:** the CLI is not installed in the cloud container. No documented non-interactive usage read exists, so the owner enters it by hand.

The quota file is `~/.claude/quota.json`, which `CLAUDE_QUOTA_FILE` can override. It is untracked. `claude/quota.template.json` is the checked-in shape.

### PR 1: Quota file and pace calculator

- **Context:** this is the first PR of slice 04. No routing code exists yet.
- **Problem:** the router needs a per-provider pace ratio that it can trust, and today nothing in the harness reads quota.
- **Approach:** add `claude/enforce/quota-pace.sh` (bash and jq, bash 3.2 safe). It has two commands. `record <bucket> <usedPct> --resets-at <iso> [--provider p] [--at iso]` appends a snapshot atomically, and drops snapshots from an earlier window once the reset time moves. `report [--json]` prints, per bucket and per provider, the used percent, days left, daily budget, burn and its method, pace ratio, projected days left, and the exhausted and stale flags. ISO timestamps carry an offset (`+07:00`) or `Z`. `QUOTA_NOW` pins the clock for tests.
- **Contents:** `claude/enforce/quota-pace.sh`, `claude/quota.template.json`, `claude/enforce/tests/quota-pace.test.sh`, and this plan.
- **Acceptance:**
  - The owner's 2026-10-02 snapshot reproduces Claude at about 1.63, Fable at about 0.93, and Codex at about 0.53. Neither Claude (about 2.5 days left at its current burn) nor Codex is flagged exhausted. Cases with under one day left, or with 90 percent used, are flagged.
  - Trailing burn is used when two snapshots are 12 hours or more apart. Otherwise the method reads `window-average`.
  - A snapshot older than `QUOTA_STALE_HOURS` (default 24) is flagged stale. A reset time in the past is flagged `window-rolled` and gives no ratio.
  - A missing or malformed file exits nonzero with a message, never a silent zero.
- **Tests:** the session writes them alongside the code (lean tier).
- **Review focus:** the date parsing with offsets, the pair selection for trailing burn, and division by zero at 100 percent used.
- **Size:** about 4 files and 450 lines.

**Scope added during review (2026-10-03):** six R-109 security review rounds were run because the security-surface detector flagged the word `rate_limits`. They added a writer lock and stricter input validation. The lock is a pid symlink that is broken only when its owner process is dead. Its accepted residuals are documented in the `lockQuotaFile` header. `record` also gained `--window-days` and `--source`, because PR 2 needs `--source`. PR 1 grew from about 450 lines to about 1,100 as a result. A provider's `paceRatio` is null, and `ratioComplete` is false, whenever one of its current buckets has no ratio.

### PR 2: Status line records the Claude weekly snapshot

- **Context:** PR 1 has merged, so `quota-pace.sh record` exists.
- **Problem:** entering Claude's all-models percentage by hand goes stale, even though Claude Code already passes that number to the status line.
- **Approach:** `status-line.sh` reads `rate_limits.seven_day.{used_percentage,resets_at}` and runs `quota-pace.sh record claude` in the background, at most once every 30 minutes (`QUOTA_RECORD_MIN_MINUTES`). A newer snapshot entered by hand wins. Every failure path still prints the line and exits 0. The line also shows `7d N%`.
- **Contents:** `claude/status-line.sh`, its fixture, `quota-pace.sh` (with `--source`, and a no-op when the newer snapshot came from the owner), and the integrity manifest.
- **Tests:** status-line fixtures for a write, a throttled skip, a malformed field, and an unwritable file.
- **Review focus:** the status line must never block or fail, and the throttle needs to be right.
- **Size:** about 4 files and 150 lines.
- **Owner decisions (2026-10-03):** (a) security-surface detector hits caused only by the word `rate_limits` are waived for PRs 2 to 5. (b) Review loops on review-added code are capped by the 1:1 budget, and the session asks the owner rather than starting another round.

### PR 3: Router and decision log

- **Context:** PRs 1 and 2 have merged, so pace ratios are available.
- **Problem:** nothing decides which provider takes a step, and nothing records why.
- **Approach:** `claude/enforce/route.sh <step> --risk <high|standard> [--author <provider>] [--security]` prints a provider and a reason, and appends one JSONL line (timestamp, step, inputs, ratios, decision, reason) to `~/.claude/routing-log.jsonl`. Role defaults: Claude takes spec, architecture, final review, and anything the owner interrogates. Codex takes the standard-risk test loop, routine implementation, and the high-risk test author. A routable step moves off a provider whose pace ratio is above 1.2 when the other provider is lower. When a provider is near exhaustion, only steps that need it stay on it. Reviewers are always the other provider from the author. The R-109 security review is always `securityReviewModel`. Pinned steps (the security review, the high-risk implementer and critic, Gate 1, merges) never move. The output is never "skip".
- **Contents:** `route.sh`, a step table (`route-steps.json`), and the fixture.
- **Tests:** a fixture table covering every step under the owner's current snapshot, the 1.2 threshold on both sides, exhaustion, cross-model review, the security pin, missing quota (fall back to role defaults with that reason logged), and one log line per call.
- **Review focus:** no input can produce "skip" or move a pinned step, and the reviewer is never the same provider as the author.
- **Size:** about 4 files and 400 lines.

### PR 4: Hand-off summary

- **Context:** the router can now send consecutive steps to different providers.
- **Problem:** a hand-off that pastes raw logs or full diffs spends the receiving provider's quota on noise.
- **Approach:** `claude/enforce/handoff-summary.sh [--base <ref>] [--test-log <file>]` prints a structured block: status, branch and head, failing test names parsed from vitest, jest, pytest, and `*.test.sh` output, and `git diff --stat` totals. It never prints raw log lines or hunks. A gate that requires the raw text (`verification-gate.sh`, the pasted diff in R-517) keeps it unchanged.
- **Contents:** the script, its fixture, and sample logs.
- **Tests:** each runner's failure output yields only the test names, and a green run yields `status: green`.
- **Review focus:** that no raw line leaks through, and the parser on mixed output.
- **Size:** about 3 files and 250 lines.

### PR 5: Wire the router into the skills

- **Context:** the router and the summary exist but nothing calls them. The 2026-10-03 recovery retired `task-start`, `task-cleanup`, `codex-pr-review-prompt.md`, and `rulebook/`, so the wiring targets what replaced them.
- **Approach:** `tdd-gated-dispatch` gains a step 0 that asks `route.sh implement` who implements; the test author is always the other provider, which keeps the owner's cross-model rule (2026-10-03) whatever the router picks. When the router picks Codex and Codex is unavailable, Claude implements and a fresh-context `test-author` writes the tests. The review step asks `route.sh review --author <implementer>` and falls back to `pr-reviewer` when Codex is unavailable. The test-author-to-implementer hand-off uses `handoff-summary.sh`; the reviewer still gets the full diff. This changes the standard-risk default implementer from Claude to Codex, per owner decision 1. `CLAUDE.md` "Models and cost" names the router. Then `node translate/codex.mjs --write` and `node translate/cursor.mjs --write`. No gate, review, or approval is removed.
- **Tests:** the port `--check` runs. The rule-text fixture the first plan named is dropped: `PROTOCOL.md` records prose-grep fixtures as cost without catches, and the router's own tests (PR 3) already assert that no input yields "skip" or moves a pinned step.
- **Size:** 3 files and about 20 lines, plus the generated output.
