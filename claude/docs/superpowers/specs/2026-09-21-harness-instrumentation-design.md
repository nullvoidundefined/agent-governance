# Harness instrumentation and no-regret reduction

Ticket: IAN-268. Branch: `feat/harness-instrumentation`.

## Goal

The harness cannot currently prove or disprove its own value, because the one
instrument built for that purpose is contaminated by the harness's own test
suite. A falsifiable evaluation on 2026-09-21 found that 136 of 7,297 recorded
rule fires (1.9%) happened in a real product repository, that 743 of the rest
came from `tmp.*` fixture scratch directories, and that raw fire counts are not
distinct catches, since R-517 logged 2,459 fires across 73 distinct minutes.
Three of the four facets the evaluation named (adversary calibration, human-gate
placement, and durability) each end in a removal decision, and every one of
those decisions needs data the instrument does not currently produce.

This spec repairs the instrument, adds the two measurements that do not exist
at all (gate yield and adversary precision), and removes the checks that are
redundant or that bind to nothing. It deliberately does not act on the three
neglected facets; it makes them decidable.

## Domain vocabulary

The aggregate roots this work names, for R-334 and for all file, function, and
type naming below.

| Term | Meaning |
|---|---|
| **fire** | One enforcement decision emitted by a guard: the existing `rule-fires.log` line. The aggregate root of the telemetry side. |
| **repo class** | The category of the repository a fire happened in: `product`, `harness`, `fixture`, or `unknown`. A property of a fire. |
| **intent** | One distinct thing the agent tried to do, identified by a hash of the tool name and normalised tool input. Many fires share one intent; the intent is the unit a catch is counted in. |
| **decision** | One human answer to a gate: what was offered, what the human chose, and whether the next tool call changed. The aggregate root of the gate side. |
| **gate yield** | Per rule, the share of its decisions in which the human said no or changed course. The measure that separates a gate from ceremony. |
| **eval case** | One graded scenario under `evals/`, in the layout `claude plugin eval` reads. |
| **seeded defect** | A single planted defect of a known class inside an eval case's diff. |
| **control** | An eval case whose diff is correct, used to measure false positives. |
| **adversary** | An LLM reviewer graded by the eval suite: `slice-critic`, `spec-conformance-review`, or `judge-diff.sh`. |

Note that **fire** and **decision** are separate roots and never merge into one
record. A fire is what a guard did; a decision is what the human did about it.
A guard that denies produces a fire and no decision.

## Inputs

- `rule-fires.log` lines, currently `ts|rule|hook|decision|repo`, written by the
  `log_rule_fire` helper in `hooks/log-rule-fire.sh`.
- The SessionEnd hook payload, which carries `transcript_path` and `cwd`.
  Three hooks already read it (`session-end.sh`, `session-start.sh`,
  `task-state-tracker.sh`), so the shape is established.
- A per-machine `~/.claude/telemetry/repo-classes.txt`, one `<pattern> <class>`
  pair per line, gitignored because it names local paths (R-106).
- Eval case directories under `evals/`, each a git fixture repository plus a
  `case.yaml` and its graders.

## Outputs

- `rule-fires.log` lines gain two fields:
  `ts|rule|hook|decision|repo|repo_class|intent_id`.
- A new `~/.claude/telemetry/decisions.log`, one line per gate answered:
  `ts|rule|hook|offered|chose|changed_course|reason_given|repo_class`.
- `enforce/telemetry-rollup.sh` prints a table: per rule, distinct intents,
  product-repo share, and gate yield.
- `claude plugin eval --json` writes per-adversary recall, precision, and noise
  to `evals/results/`.

## Acceptance criteria

Ordered the way the implementation needs them. Each is one slice.

- B-1: A fixture that does not source `enforce/harness-root.sh` and does not set
  `CLAUDE_FIRE_LOG` itself fails a new static check, naming the file.
- B-2: `enforce/harness-root.sh` sets `CLAUDE_FIRE_LOG` to `/dev/null` only when
  it is unset, so `hooks/tests/log-rule-fire.test.sh` keeps its own path.
- B-3: Running any single fixture directly, outside the shard runners, appends
  no line to the real `$HOME/.claude/telemetry/rule-fires.log`.
- B-4: A fire line carries a `repo_class` field resolved from
  `repo-classes.txt`, and an unmatched repository resolves to `unknown` rather
  than to a guess.
- B-5: A fire line carries an `intent_id`, and two fires from the same tool call
  share it while two fires from different tool inputs do not.
- B-6: `log_rule_fire` called with no intent payload still writes a well-formed
  line, with `intent_id` empty, so no existing caller breaks.
- B-7: `enforce/telemetry-rollup.sh` reports, per rule, the count of distinct
  `intent_id` values rather than the count of lines.
- B-8: The rollup reports each rule's product-repo share, and a rule that has
  never fired in a `product` repository is listed as such.
- B-9: Each of the nine advisory reminder hooks emits a fire with decision
  `remind` when it fires, and emits nothing when it does not.
- B-10: `hooks/decision-log.sh` parses a SessionEnd transcript and writes one
  `decisions.log` line per gate that asked, recording what the human chose.
- B-11: `decision-log.sh` exits 0 and writes nothing when the transcript is
  absent, unreadable, or unparseable, matching the fail-open posture of every
  reminder hook.
- B-12: The rollup computes gate yield per rule from `decisions.log`, and a rule
  with no decisions reports `n/a` rather than zero.
- B-13: Every rule carrying both an `ast` row and an `llm-judge` row has a
  `note` on each row stating which half that enforcer decides, asserted by a
  fixture over `manifest.json`.

  This replaces the deletion this criterion originally specified. The R-517
  review of #109 established that the premise was false: the manifest records
  that R-325's judge row decides "never destructure a method off its object", a
  type question the AST rule deliberately excludes, and that R-316's and
  R-317's ESLint coverage is active only in repositories declaring a naming key
  in `.enforce.json`, with R-317 covering the decidable half alone. Deleting
  those three rows would have removed enforcement, not redundancy, against an
  invariant of this spec that Phase 1 only deletes and tightens. The judge's
  surface therefore stays at five rules. The durable fix is the fixture above,
  which makes the split explicit so a future reader cannot mistake partial
  overlap for duplication the way the 2026-09-21 evaluation did.
- B-14: A new `enforce/rules/r334-aggregate-root.mjs` flags a schema, model, or
  module name whose leading noun is absent from the spec's
  `## Domain vocabulary`, and passes a name whose leading noun is present. A
  repository with no glossary disables the rule rather than flagging every
  name, matching `judge-diff.sh`, which already drops R-334 from the judged set
  when `collect_project_vocabulary` returns nothing.
- B-15: A report under `docs/audits/` with more than 15 findings or more than
  3,000 words fails a fixture, naming the count.
- B-16: R-517's Spec states the two-round cap and names redesign, not a further
  review, as the response to a third round; `git-workflow-guard.sh` asks (never
  denies) on a merge whose Codex review section records three or more rounds,
  and its message names the cap.
- B-17: `git-workflow-guard.sh` denies a merge whose pull request body's Codex
  review section lacks a `reviewer`, a `model`, or a `range` line, and denies
  one whose `range` does not contain the pull request's head commit.
- B-18: A fixture cross-checks every `permissions.ask` pattern against the
  commands the hooks already answer with `ask`, and fails on any pattern covered
  by both unless `enforce/ask-duplication-allowlist.txt` records that pattern
  with a one-line reason.
- B-19: `claude plugin eval` run against this repository executes the eval
  suite and writes per-case scores, with at least one seeded-defect case and
  one control passing their graders.
- B-20: A seeded-defect case's grader fails when the adversary's output does not
  name the planted defect, and a control's grader fails when the adversary
  reports any finding.
- B-21: A workflow runs the eval suite with `--threshold 0.8` on any change to
  `claude/agents/*.md`, `claude/enforce/judge-prompt.md`, or
  `claude/prompts/*.md`, and fails the pull request below the threshold.
- B-22: The suite emits a recall, a precision, and a noise number for each of
  the three graded adversaries, recorded as the baseline in the pull request.
- B-23: The SessionStart handoff block is a fixed short pointer carrying the
  path, the SHA, the line count, and the instruction to read the file, never
  the document body, so it cannot exceed the harness's inline limit and cannot
  be persisted to a preview.
- B-24: A fixture asserts that block stays under 512 bytes and
  contains the path and the SHA, so a future addition cannot reintroduce the
  truncation.
- B-25: `decision-log.sh` sets `reason_given` to `yes` or `no` for each gate
  firing the human approved over, and `telemetry-rollup.sh` reports per rule an
  override count alongside the gate yield, split by that flag. The field is a
  boolean and never the reason's text, because the Security section forbids
  writing transcript free text into the log.
- B-26: No guard gains a skip flag, a bypass token, or an override argument. The
  override record is derived from decisions already made, proved by a fixture
  asserting that no hook reads an override environment variable or file.

## Invariants

- Every fire line written after B-5 has exactly seven pipe-separated fields.
  Lines written before it have five, and both readers accept either: a
  five-field line reads as `repo_class=unknown` with no intent. The invariant
  is that a line never has a count other than five or seven, so a reader never
  has to guess.
- `log_rule_fire` never fails, never blocks, and never slows its caller. Every
  addition here stays inside the existing `{ ... } 2>/dev/null || true` wrapper.
- No telemetry line ever contains a secret, a credential, or an absolute local
  path (R-104, R-106). `intent_id` is a hash precisely so the tool input itself
  never lands in the log.
- The decision log is derived, never authoritative. Deleting it loses history
  and breaks nothing.
- Phase 1 only deletes and tightens. No criterion above adds a rule to
  `CLAUDE.md`, per the rule-addition freeze on IAN-268.

## Failure modes

| Trigger | Outcome | Retry |
|---|---|---|
| `repo-classes.txt` missing | Every fire resolves `repo_class` to `unknown`; the rollup says the file is absent rather than reporting a 0% product share. | Yes, create the file. |
| Transcript format changes under `decision-log.sh` | The parser matches nothing, writes nothing, exits 0. Gate yield goes stale rather than wrong. A fixture with a captured transcript catches the drift at CI. | Yes. |
| Transcript is very large | The parser reads it streaming with a byte cap, in the manner `judge-diff.sh` caps its diff, and records that it truncated. | Yes. |
| `ANTHROPIC_API_KEY` absent in CI | The eval workflow passes with a notice, matching `judge-diff.sh`'s fail-open posture. The deterministic gates stay the hard guarantee. | Yes. |
| An eval case's fixture repository fails to build | That case scores zero and the run reports which case, rather than the whole suite erroring out. | Yes. |
| Two sessions append to the log at once | Lines stay whole, because each is a single `printf` under the append-only open the helper already uses. | Not needed. |
| The handoff file is missing or unreadable at SessionStart | The pointer block says so in those words, which is the "absent" branch R-001 already handles. It never prints a partial body, because a partial body is the state that has no branch. | Yes. |
| A human approves over a gate and gives no reason | The decision is recorded with an empty reason and the rollup counts it as an unexplained override. An unexplained override is data too: a rule with many of them is a rule people route around without being able to say why. | Not needed. |

## State transitions

None. Both logs are append-only; neither the fire nor the decision has a
lifecycle beyond being written.

## Non-goals

- **Plugin packaging.** Not in this spec. `claude plugin eval` is invoked
  against a path target. The migration is Facet 4 work (gap D3) and has its
  own ticket.
- **Acting on the three neglected facets.** No gate is moved or removed here,
  no adversary is deleted, no rule is retired. This spec produces the evidence
  those decisions need. Deciding without the evidence is the failure mode that
  produced 121 rule IDs.
- **An override that actually bypasses a guard.** B-25 records that a human
  approved over a firing and why; it grants nothing. R-203 reserves a bypass to
  the user's explicit word in the turn, and a mechanism the session can invoke
  itself would hand the model the switch that rule exists to withhold. Gap H5's
  measurement half is in scope here precisely because its enforcement half is
  not, and the record is the part that produces the false-positive data.
- **Making a gate's exit status honest.** `tdd.sh red` and `doctor.sh` both exit
  0 while refusing or reporting a failure, so the printed verdict is the only
  truth (session handoff, pending item 14). That is the same class this spec is
  about, a signal that goes silent or lies rather than going wrong, and it bit
  this program's own first session twice. It is a separate change to separate
  scripts and carries its own ticket rather than riding here.
- **The end-to-end ablation A/B.** Phase B is 4 to 6 `--ablation with-without`
  cases run monthly. It is specified in the plan and is not a criterion here.
- **Backfilling the existing log.** The clean series starts at the first line
  written after B-5 lands. The old log is kept and read with a date filter.
- **A new storage engine.** The pipe-delimited append-only file stays. It is
  greppable, it survives a crash, and `session-end.sh` already rolls it up.

## Dependencies

Reused (R-308), no new module where one exists:

- `hooks/log-rule-fire.sh`, extended in place.
- `enforce/harness-root.sh`, already sourced by 87 of 103 enforce fixtures.
- `hooks/session-end.sh`'s transcript-reading block, the pattern
  `decision-log.sh` follows.
- `enforce/run-fixture-shards.sh`, for registering the new fixtures.
- `enforce/eslint.config.mjs` and the nine existing custom rules under
  `enforce/rules/`, the pattern `r334-aggregate-root.mjs` follows.
- `enforce/manifest.json`, which gains an entry per new enforcer (R-516).

Third-party: none. The eval runner ships with the Claude Code CLI.

Migrations: the fire-line format change is additive; readers must tolerate a
line with five fields (historic) or seven (new). `telemetry-rollup.sh` handles
both and treats a five-field line as `repo_class=unknown`.

## Observability

- Every new script logs through the existing `log_rule_fire` helper rather than
  a second channel.
- `telemetry-rollup.sh` is the read surface and prints a plain table; it adds no
  daemon, no watcher, and no scheduled job.
- The eval workflow annotates the pull request with the per-adversary numbers so
  a prompt change's effect is visible in review rather than only in an artifact.

## Security

- `repo-classes.txt` is gitignored: it names local filesystem paths, which
  R-106 forbids on the public remote.
- `decision-log.sh` reads the transcript, which contains everything the session
  saw. It extracts only the rule id, the hook name, the decision, and a boolean,
  and it writes no free text from the transcript into the log. This is the one
  genuinely sensitive piece of this spec and its fixture asserts the negative:
  given a transcript containing a credential-shaped string, the produced log
  line contains no substring of it.
- The eval corpus contains no real repository content. Each case's fixture
  repository is generated in the case's own scratch directory.

## Assumption ledger

| Claim | Source | Verification | Status | Owner | Next action |
|---|---|---|---|---|---|
| `claude plugin eval` accepts a non-plugin path target and still runs its eval dir | `claude plugin eval --help`, read 2026-09-21 | Run it against this repo with one trivial case before building the corpus | unverified | implementer of B-19 | Make B-19 the first Phase 2 slice; if it fails, wrap the cases in a thin runner and keep the case format |
| The transcript's JSONL lines expose the permission decision for an `ask` | `session-end.sh` reads `transcript_path` and parses it per line | Inspect one real transcript for an ask-and-answer pair before writing the parser | unverified | implementer of B-10 | Make the inspection the first step of B-10; if the decision is absent, fall back to inferring it from whether the tool call followed |
| The nine advisory reminders can call `log_rule_fire` without exceeding the hook-latency budget | `enforce/tests/hook-latency.test.sh`, budget 6x a bare spawn | Run the latency fixture after B-9 | unverified | implementer of B-9 | Treat a budget failure as a signal to batch the writes, not to widen the budget (R-204) |
