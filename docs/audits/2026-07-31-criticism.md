# Criticism Audit: the Claude harness as a project (2026-07-31)

- **Date:** 2026-07-31
- **Scope:** `~/.claude` treated as a product, not as configuration. 76 rules in `CLAUDE.md` plus 17 in `rulebook/`, 9 stack convention files, 30 hook scripts, 5 push gates, `enforce/manifest.json` and its 28 fixture tests, the audit machinery, the memory system, `PROTOCOL.md`, `README.md`, `SETUP.md`, `ISSUES.md`, `docs/audits/`, `docs/session-handoff/`, and 30 days of commit history.
- **Excluded:** `projects/`, `sessions/`, `shell-snapshots/`, `history.jsonl`, `telemetry/` contents, cache and daemon dirs, client project directories, and every credential file (R-805). One project memory file was counted, never read.
- **Method:** verify before criticize. Every finding below was checked against the current working tree during this run. The `enforce/` suite was executed (28 tests, all green). `hooks/session-start.sh` was executed and its emitted context inspected. Toolchain presence was probed with `command -v`. Manifest cardinality, rule counts, enforcement distribution, and commit churn were computed, not estimated.
- **Severity:** P0-P3 per R-802. P0/P1 belong to the current effort; P2/P3 route to `ISSUES.md`.

---

## The Brutal Truth

This system has spent thirty days and fifty-three commits hardening itself, and the one artifact that would tell it whether any of that hardening changes an outcome has recorded nothing new since 2026-06-05 and contains exactly one rule's worth of data across its entire history. Its most-advertised enforcement tier, the push-time LLM judge that is the sole enforcer for the three naming rules R-315/R-316/R-317, cannot execute on this machine because `ANTHROPIC_API_KEY` is not in the environment, and seven green stub tests conceal that. Two of the five push gates are unconditional no-ops because `golangci-lint`, `go`, and `rubocop` are not installed and no Go or Ruby project is in evidence. The handoff document that R-601 and R-602 spend real effort producing at every session end is never loaded, because `session-start.sh` searches `docs/audits/` while R-602 writes to `docs/session-handoff/`. Each of those is invisible from inside the discipline that produced them, because the discipline measures conformance to itself and nothing in it measures whether conformance produces outcomes. The rules are good. The hooks are well written. The tests are real. The evidence base is not there, and without it every decision to add another tier is a guess wearing the costume of a process.

---

## What's Actually Good

Stated first and kept short, because padding it would be its own theater.

- **The enforcement layer is real, not decorative.** 28 fixture tests, executed during this audit, all green in 24 seconds. `enforce/tests/eslint.test.sh` drives a real ESLint out of `enforce/node_modules`. The engineering audit executed `push-ruff-gate.sh` against a live `uvx ruff`. That is not a mocked suite end to end.
- **Registration closure is perfect and was verified both directions.** Every `hooks/*.sh` on disk appears in `settings.json`; every hook path in `settings.json` exists on disk; all 30 carry the execute bit. Zero drift. Most systems of this size leak an orphaned script within a month.
- **The `[manual]` / `[judge]` / `[hook:...]` annotation in `CLAUDE.md` is honest labeling.** Naming the enforcer on every rule line is unusual discipline. It is what made P1-4 below computable in one command instead of a week of reading.
- **`ISSUES.md` records tradeoffs against itself.** The entry admitting `golangci-enforce.yml` is v1-schema and unvalidated was written by the same session that shipped it. Systems this invested in their own correctness usually stop writing that sentence down.
- **The engineering audit ran the code instead of reading it.** Executing `structure-gate.sh` against the layout `CLAUDE-PYTHON.md` documents, rather than against the shipped fixtures, is what surfaced its P1-1. That is the correct instinct and it is rare.
- **The security audit that landed today is the strongest artifact in `docs/audits/`.** Threat model first, two P0s, every finding pasting code with `file:line`, and it explicitly declined to score the judge's fail-open as a finding because the tradeoff is documented. That is the discipline R-804 asks for, actually executed.

---

## P0 findings

### P0-1: the LLM judge tier has never been able to run, so R-315/R-316/R-317 have no enforcement at all

**Evidence.**

`hooks/llm-rule-judge.sh:31-34`:

```bash
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "llm-rule-judge: ANTHROPIC_API_KEY unset, skipping semantic gate" >&2
    exit 0
  fi
```

`ANTHROPIC_API_KEY` is absent from the process environment of Bash-tool subprocesses in this session, which is the environment hook processes receive. Inheritance is confirmed by the presence of `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, and `CLAUDE_PID` in the same environment. `grep -c ANTHROPIC_API_KEY` returns 0 against both `~/.zshrc` and `~/.zprofile`. Nothing in `hooks/` or `enforce/` sources `~/.claude/.env`; the only script that reads it is `hooks/ntfy-notify.sh:8`, and it reads `NTFY_TOPIC`.

`enforce/manifest.json:40-42`:

```json
    { "id": "R-315", "tier": "llm-judge", "enforcer": "hook:llm-rule-judge", "severity": "error", "autofix": false },
    { "id": "R-316", "tier": "llm-judge", "enforcer": "hook:llm-rule-judge", "severity": "error", "autofix": false },
    { "id": "R-317", "tier": "llm-judge", "enforcer": "hook:llm-rule-judge", "severity": "error", "autofix": false },
```

Those three IDs appear nowhere else in the manifest. `CLAUDE.md:64-66` marks all three `[judge]`. The judge is their only enforcer, and the judge exits at line 33 on every push.

**Precedence resolved.** The fail-open behavior is a deliberate, documented tradeoff (`hooks/llm-rule-judge.sh:5-8`: "Fails OPEN ... a flaky model must not block legitimate work"). The tradeoff is not the finding and is not criticized. The finding is that the fail-open branch appears to be the only branch that has ever executed, that nothing surfaces this to the operator except a stderr line inside a hook process, and that `CLAUDE.md` presents three rules as mechanically enforced when they are honor-system.

**Compounding.** `enforce/tests/llm-rule-judge.test.sh:18-49` drives seven cases exclusively through the `CLAUDE_JUDGE_CMD` stub seam. The live path at `hooks/llm-rule-judge.sh:36-40` (the `curl` to `api.anthropic.com`, the Haiku response, the brace-balancing `awk` extractor written specifically to survive Haiku appending trailing prose) is executed by no test. The suite reports `ok llm-rule-judge.test.sh`. Green signal, dead tier, and the parser most likely to break in production is the one with zero real-output coverage.

**Direction.** Decide whether the judge is a shipped control or an aspiration, and make `CLAUDE.md` say the true thing either way. If it is a control, it needs a startup-visible signal when the key is missing, because a stderr line inside a `PreToolUse` hook is not a signal an operator sees. *To confirm: whether the key is present in the Claude Code parent process but stripped from Bash-tool subprocesses (add a temporary `[ -n "${ANTHROPIC_API_KEY:-}" ] && echo present >&2` to a scratch copy of a registered hook and push once); and grep any retained session stderr for the literal string `skipping semantic gate`. If the key is present in the hook environment and absent only from the Bash tool, this drops to P2 and the finding becomes "the tier has never had a live-output test."*

---

### P0-2: the system's only effectiveness instrument records one rule and has been silent for eight weeks

**Evidence.**

`global-memory/rule_fires.md` contains 13 data lines. Twelve are R-207 (em dash). The thirteenth is a retrospective consolidation of 36 further R-207 occurrences. No other rule ID appears anywhere in the file. The newest entry is dated 2026-06-05.

`global-memory/rule_misses.md` contains exactly one data line: a retrospective consolidation of 45 R-102 occurrences, dated `2026-04-08..2026-06-05`.

`git log -1 -- global-memory/rule_fires.md` and the same for `rule_misses.md` both return `39f78f0` (2026-07-03), a bulk renumber refactor. No content change in 28 days. The working tree was clean at the start of this audit, so nothing was appended and left uncommitted.

Over the same window the system tripled: hooks went from 9 tracked shell scripts on 2026-06-04 to 38 on 2026-07-31 (`git ls-tree -r --name-only <sha> hooks/ | grep -c '\.sh$'`), and `CLAUDE.md` rules went from 46 to 76.

**Why the instrument is not an instrument.** `hooks/session-end.sh:70-95` does not observe hook denials. It greps `~/.claude/projects/*/memory/*.md` for lines a human or Claude manually typed with the prefix `fired: R-NNN ` or `miss: R-NNN `, and copies them into the global logs. Exactly one project memory file currently carries such a line. The loop is: a manual rule (R-603) requiring manual logging, enforced by a hook that copies manual logs. There is no automatic observation anywhere in the system of a gate actually firing.

**A second-order inconsistency in the same file.** The eleven R-207 lines are byte-identical after date stripping (verified: `sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' | sort | uniq -c` reports `11` for a single signature). `hooks/session-end.sh:80-83` dedupes on exactly that stripped signature with `grep -qFx`, so those eleven could not all have been written by the current hook. Either the dedupe is broken, or the entries were hand-written and the file's own header claim ("Hook-written entries ... appended by `~/.claude/hooks/session-end.sh`") is false. Both readings are bad in the same direction: the log is not the mechanical record it presents itself as.

**Why P0.** Every subsequent decision in this repo (add a stack tier, add a gate, add a rule, keep a manual rule) is made without data, and this is the root cause of P1-1 and P2-2 below. A system whose stated principle is "the protocol is a failure-mode catalog" (`PROTOCOL.md:277`) and whose failure catalog contains one entry from June is not running on evidence.

**Direction.** The class of fix is automatic observation rather than better manual discipline: hooks that emit a deny already know they denied, and appending a single structured line at that moment costs nothing and requires no recall. *To confirm: whether Claude Code persists hook denial events in the session transcript schema under `projects/` (if it does, a read-only aggregator produces the missing 30-day dataset without touching a single hook); and whether the eleven duplicate R-207 lines predate the current dedupe logic, via `git log -p --follow global-memory/rule_fires.md`.*

---

## P1 findings

### P1-1: the Ruby and Go tiers ship against zero installed toolchain, zero visible project, and stub-only tests

**Evidence.** Four commits between 12:34 and 12:48 today: `39b5954` (2 convention files, 2 `rules/` symlinks, 286 insertions), `6386053` (7 hooks extended, 205 insertions), `3b328bd` (2 push gates, 2 configs, 2 manifest entries, 2 test files, 329 insertions), `71c044a` (rulebook analogs). Roughly 615 net insertions in fifteen minutes.

`command -v` during this audit: `go` MISSING, `gofmt` MISSING, `golangci-lint` MISSING, `rubocop` MISSING.

`hooks/push-golangci-gate.sh:36-41`:

```bash
elif command -v golangci-lint >/dev/null 2>&1; then
  GOLANGCI="golangci-lint"
else
  echo "push-golangci-gate: no golangci-lint on PATH, skipping the Go AST gate" >&2
  exit 0
fi
```

`hooks/push-rubocop-gate.sh:35-42` has the same shape with an added `Gemfile.lock` branch. Both gates are unconditional no-ops on this machine today.

`enforce/tests/push-golangci-gate.test.sh:4` states the design plainly: "golangci-lint is stubbed via `CLAUDE_GOLANGCI_CMD` (canned JSON), so the test exercises the gate's diff/filter/deny logic without a local install." `push-rubocop-gate.test.sh:4` says the same. Both tests therefore validate the diff-scoping and deny plumbing, which is copied verbatim from `push-eslint-gate.sh` and already proven, and validate nothing about `enforce/golangci-enforce.yml` or `enforce/rubocop-enforce.yml`, which is where the entire rule mapping lives.

**Precedence resolved.** `ISSUES.md:5` documents the Go half as a deliberate deferral: "written against the golangci-lint v1 schema and could not be validated locally (no Go toolchain); validate and migrate to the v2 schema if needed on the first real Go project." Per R-804(b) this is critiqued as a tradeoff, not reported as an oversight. The terms of the tradeoff: the harness permanently carries 2 gates, 2 configs, 2 convention files, 2 symlinks, 3 manifest entries, 2 test files, 2 new `settings.json` registrations, and 4 rulebook exception clauses, in exchange for enforcement value that is provably zero today and conditional on a project that does not appear anywhere in the observable surface. The bad half of the trade is not the carrying cost, which is modest. It is that `./enforce/tests/run-tests.sh` now prints `ok push-golangci-gate.test.sh`, which converts an admittedly unvalidated config into a green line in the signal the operator actually reads.

**Direction.** Either install one toolchain and validate one config for real, or mark the two stub-only gate tests in the runner output so a green line does not imply a validated config. *To confirm: whether any repository the operator works in contains a `go.mod` or a `Gemfile` (one `find` across the code directory settles it). If one exists, this drops to P3 and the correct action is installing the toolchain rather than annotating the tests.*

---

### P1-2: `session-start.sh` reads the wrong directory, so the handoff doc is never loaded and a 400-line audit report is injected in its place

**Evidence.** `CLAUDE.md:110` (R-602): "Write handoffs to `docs/session-handoff/session-handoff.md` (overwrite)". R-001 step (5) reads that file at session start.

`hooks/session-start.sh:46-52`:

```bash
HANDOFF=""
if [ -d "docs/audits" ]; then
  HANDOFF=$(ls -1t docs/audits/*session-handoff*.md 2>/dev/null | head -1 || true)
  if [ -z "$HANDOFF" ]; then
    HANDOFF=$(ls -1t docs/audits/????-??-??-*.md 2>/dev/null | head -1 || true)
  fi
fi
```

The hook never looks at `docs/session-handoff/`. Both globs are rooted in `docs/audits/`.

Verified by execution during this audit. `echo '{}' | ./hooks/session-start.sh` emits, under the heading `## Most recent handoff doc (auto-loaded per R-001)`:

```
Path: docs/audits/2026-07-31-engineering.md
```

followed by the first 400 lines of that engineering audit. The real handoff at `docs/session-handoff/session-handoff.md` (4159 bytes, written 2026-07-31 03:34) does not appear in the emitted context at all.

**Impact.** Two costs, both paid every session. First, up to 400 lines of a stale audit report are injected as startup context and framed as prior-session continuity, in this repo and in every project that has a `docs/audits/` directory. That is a large, silent context tax levied by the same system that spent the 2026-07-29 session shrinking `CLAUDE.md` below 200 lines for context-adherence reasons (`PROTOCOL.md:266`). Second, the handoff document is a pure loss: R-601 and R-602 spend real effort at every session end producing an artifact that the loader cannot see. `hooks/session-start.sh:9-13` states the hook's whole purpose is to stop that read from being honor-system. It enforces the wrong file.

**Direction.** The fix class is aligning the glob with R-602's documented path, with the `docs/audits/` fallback either removed or explicitly relabeled as untrusted repo content rather than as the operator's handoff. *To confirm: `git log -p hooks/session-start.sh` for whether `docs/session-handoff/` postdates the hook (which would make this drift rather than an original error), and whether any project still keeps handoffs under `docs/audits/` and would regress.*

**Cross-reference.** The security audit quoted these exact lines as Finding 9 and treated the fallback glob purely as a prompt-injection vector. See "Where the Sibling Audits Are Wrong."

---

### P1-3: the manifest severity lookup is single-valued while manifest IDs are demonstrably multi-valued

**Evidence.** `hooks/llm-rule-judge.sh:60-63`:

```bash
  severity=$(jq -r --arg id "$rule_id" '.rules[] | select(.id==$id) | .severity // "error"' "$MANIFEST" 2>/dev/null || echo "error")
  if [ "$severity" = "error" ]; then
```

`jq` emits one line per matching entry. Computed cardinality of `enforce/manifest.json` today (`jq -r '.rules[].id' | sort | uniq -c`): R-329 appears 5 times, R-324 3 times, R-102 3 times, and R-320, R-322, R-326, R-327 twice each. Multi-entry IDs are not an edge case here; they are the standard growth pattern, produced eight times today alone by adding Python, Ruby, and Go analogs.

Today the bug is latent, and this was verified rather than assumed: all three error-severity judge rules (R-315, R-316, R-317) currently have exactly one manifest entry each. The two multi-entry judge rules (R-320, R-322) resolve to `warn\nwarn`, which fails the `= "error"` comparison and lands on the warn branch, which is the intended outcome by accident.

The moment any of R-315/R-316/R-317 gains a stack analog entry (the exact move that produced the five R-329 rows), `$severity` becomes `error\nerror`, the string comparison fails, and a blocking rule silently downgrades to a stderr line. No test covers a duplicate-ID judge rule, and `enforce/tests/manifest.test.sh` evidently does not assert ID uniqueness, since five R-329 rows pass it.

**Direction.** The fix class is making the lookup collapse multiple rows deterministically (highest severity wins) rather than comparing a possibly-multiline string. *To confirm: whether `enforce/tests/manifest.test.sh` asserts anything about ID cardinality, and whether any other consumer of the manifest (`hooks/enforcement-guard-check.sh`, `enforce/lint.mjs`) makes the same single-value assumption.*

---

### P1-4: 62 percent of the rulebook is honor-system, and the system has no mechanism to retire a manual rule that has never demonstrably fired

**Evidence.** `grep -cE '\[manual\]' CLAUDE.md` returns 40 of 76. `rulebook/agents.md`, `audits.md`, and `cost.md` carry 15 `Enforcement: manual` of 17 rules. That is 55 of 93 rules, 59 percent. Adding R-315/R-316/R-317, which are labeled `[judge]` but are effectively manual per P0-1, gives 58 of 93, or 62 percent.

The rules carrying the highest per-session process cost are concentrated in the manual half: R-503 (announce each task's percentage share, capture a start timestamp, report cumulative percentage at every completion, report total elapsed at the end), R-501, R-905, R-906, R-702, R-706, and R-705's seven-step pre-dispatch checklist with a five-question sub-checklist.

Per P0-2 there is no record of any of them ever firing. R-503 in particular generates per-task percentage output for an audience of exactly one person, who is the same person who wrote R-503.

`hooks/session-start.sh:66` reads `~/.claude/global-memory/retirement_candidates.md` "written into ... by a prior session." That file does not exist. The retirement half of the promotion/retirement ladder the `README.md` advertises has produced zero candidates.

**Precedence resolved.** `[manual]` labeling is deliberate and honest, and `PROTOCOL.md:277-281` explicitly frames rule growth as a feature. This finding does not argue that manual rules are wrong. It argues that a growth ladder with no working retirement rung and no fire data is a ratchet, and that a 93-rule ratchet running against published instruction-adherence limits is the failure mode the 2026-07-29 restructure was specifically built to fight.

**Direction.** The fix class is a periodic retirement pass with a falsifiable criterion, run against the fire data that P0-2 must first restore. Until the fire data exists, a retirement pass would be guesswork wearing the same costume. Sequence P0-2 first. *To confirm: whether a retirement scan has ever been run (search commit history for `retirement_candidates`), and pick five manual rules at random and search the last 30 days of commits and handoffs for any evidence one of them altered a decision.*

---

### P1-5: `PROTOCOL.md`, the file `CLAUDE.md` names as the source of rationale and history, records none of the last three stack tiers

**Evidence.** `CLAUDE.md:3`: "Rationale and history: `PROTOCOL.md`."

`grep -ci python PROTOCOL.md` returns 0. `grep -ci 'ruby\|golang' PROTOCOL.md` returns 0. The newest dated section is `## What changed on 2026-07-29` at line 265, followed at line 271 by `## What changed on 2026-07-27`, out of chronological order.

Since the 2026-07-29 entry: 11 commits, 3 stack tracks (Python, Ruby, Go), 3 new push gates, 2 new convention files, 3 new `rules/` symlinks, 9 new manifest entries. `PROTOCOL.md` records none of it. The eleven-layer model it presents does not mention that the AST tier now spans four languages.

`README.md` is stale in the same direction and quantifiably so: it claims "26 hook scripts" (actual: 30 `.sh` plus `clean-code-scan.mjs`), "6 convention files" (actual: 9 `CLAUDE-*.md` plus `CLOUD-DEPLOYMENT.md`), and "29 global-memory files" (actual: 30). It has one mention of Python and zero of Ruby, Go, `ruff`, `rubocop`, or `golangci`.

R-508 requires the `README.md` update in the same commit as a structure change. `git show --stat` for `39b5954`, `6386053`, `3b328bd`, and `71c044a` shows none of the four touched `README.md` or `PROTOCOL.md`. Adding two language tracks, two convention files, two push gates, and two symlinks is a structure change by any reading of R-508.

**Why this matters more than a documentation nit.** `PROTOCOL.md` is not a marketing document. It is the file the `/protocol` skill loads for "reviewing rule origin," and it is the only place the rationale for a layer exists. A layer whose rationale was never written down is a layer no future session can evaluate for retirement, which is precisely the mechanism P1-4 says is missing.

**Direction.** The fix class is a single "what changed on 2026-07-31" entry covering all three stack tiers, plus recomputing the three counts in `README.md` from the tree rather than by hand. *To confirm: whether the out-of-order `07-29` before `07-27` ordering at `PROTOCOL.md:265,271` is deliberate (a newest-first convention with an addendum) or an editing artifact, since the fix differs.*

---

## P2 findings (route to `ISSUES.md`)

### P2-1: three of the five push-gate test files mock the component that carries the rule semantics

`enforce/tests/push-golangci-gate.test.sh`, `enforce/tests/push-rubocop-gate.test.sh`, and `enforce/tests/llm-rule-judge.test.sh` drive their hooks exclusively through `CLAUDE_GOLANGCI_CMD`, `CLAUDE_RUBOCOP_CMD`, and `CLAUDE_JUDGE_CMD` stubs emitting canned JSON. The stub seams are good design and the tests genuinely cover diff scoping and deny shape. What none of them cover is whether the config file maps the rule correctly, which is the only part unique to each gate. `push-eslint-gate` and `push-ruff-gate` are materially better: real ESLint out of `enforce/node_modules`, and a live `uvx ruff` run recorded in the engineering audit's method section.

**Direction.** A live-binary variant is already proven feasible for two of five; the same pattern extends to RuboCop through a temporary `GEM_HOME`. *To confirm: whether `enforce/tests/eslint.test.sh` runs the bundled binary rather than a stub (it appears to), which sets the reference pattern to copy.*

### P2-2: nothing anywhere measures the false-block cost of the enforcement stack

15 hooks are registered on `PreToolUse(Bash)` alone (`settings.json`), plus 4 on `Write|Edit`, plus 4 on `SessionStart`. The only measured property of the whole stack is latency: `enforce/tests/hook-latency.test.sh` with `BUDGET_MULTIPLIER=6` and a 250ms floor. No hook writes a denial record; a grep across `hooks/*.sh` for logging turns up header comments and stderr notes only.

That false blocks occur is not speculative. `docs/session-handoff/session-handoff.md` section 3 records "Fixed a real false-block: `fix-commit-requires-test.sh` now recognizes `tests/`, `test_*.py`, `*_test.py`, `conftest.py`." That was found by hitting it, not by a metric.

The consequence is structural: the system cannot rank any gate by how often it blocks correct work, so it can never justify removing one, so gate count only grows. The cheapest property to measure is measured; the expensive one is not.

**Direction.** *To confirm: whether Claude Code persists hook denial events in the transcript schema under `projects/`; if so, a read-only aggregator produces a 30-day false-block dataset with no new instrumentation.*

### P2-3: `global-memory` duplicates rules that `CLAUDE.md` already carries, and the drift has already started

`global-memory/INDEX.md` restates R-209 (`feedback_no_fluff`), R-208 (`feedback_no_empty_praise`), R-513 (`feedback_pr_constant_value_check`), R-903 (`feedback_model_routing`, self-labeled "**Canonical**"), and R-501/R-506/R-509/R-510 (`lesson_inline_execution_efficiency` items L1/L6/L3/L4). `feedback_default_sonnet_proactive_switch.md` is self-labeled "**HARD RULE**" and competes with `feedback_model_routing.md`'s "**Canonical**" claim on the same subject.

The drift is already observable. `PROTOCOL.md:33` states "`global-memory/INDEX.md` is auto-loaded by the `SessionStart` hook." `global-memory/INDEX.md`, under "How to use," states "These files are NOT auto-loaded by Claude Code. The memory system is project-scoped." `hooks/session-start.sh:39-42` settles it in favor of `PROTOCOL.md`; the INDEX's own usage instructions are stale and tell a future reader to do manual work the hook already does.

The cost compounds with P1-2: all 30 memory files are concatenated into `additionalContext` at every session start, a meaningful share duplicating rules already in the always-loaded `CLAUDE.md`, in a system that capped `CLAUDE.md` at 200 lines specifically to protect the context budget.

**Direction.** Pick one canonical location per rule and reduce the other to a pointer. *To confirm: measure the token size of `session-start.sh`'s emitted `additionalContext` against `CLAUDE.md`; if the injected memory index rivals the rule file it partly duplicates, the 200-line cap is being defeated by the hook that was built to support it.*

### P2-4: `settings.json` is a single unvalidated point of failure for all 30 hooks

Every hook registration lives in one JSON file. No test asserts it parses; `enforce/tests/enforcement-guard-check.test.sh` references it but contains no `jq -e` or `jq empty` parse assertion. A trailing comma introduced by any edit silently removes the entire hook layer at the next session start, which is exactly the class of silent-control-loss the security audit's Finding 7 raises from the integrity angle.

Steelmanned first: closure is currently perfect in both directions, verified during this audit. That state is worth locking in with a test rather than leaving to care.

**Direction.** *To confirm: whether `hooks/enforcement-guard-check.sh` fails loudly or silently against a malformed `settings.json` (feed it a copy with a trailing comma), and whether Claude Code surfaces a parse error at startup or drops hooks quietly.*

---

## P3 findings (route to `ISSUES.md`)

### P3-1: the R-7xx/R-8xx/R-9xx block has no ID-closure guard

`enforce/tests/claude-md-lint.test.sh:24-35` enforces bidirectional ID closure between `CLAUDE.md` and `rulebook/reference.md` only. The 17 rules in `rulebook/agents.md`, `audits.md`, and `cost.md` have no equivalent check and no norm/Spec split to keep in sync. Of those 17, only R-801 and R-904 appear in the manifest, so R-516's registration discipline is effectively unapplied to the entire agent, audit, and cost blocks. *To confirm: whether the exclusion was deliberate in the 2026-07-29 restructure design (`docs/superpowers/specs/2026-07-03-global-rules-restructure-design.md`).*

### P3-2: `README.md` count claims are stale

"26 hook scripts" against 30, "6 convention files" against 9, "29 global-memory files" against 30. Recorded separately from P1-5 because the fix is mechanical: generate the counts rather than assert them.

---

## Lies the Team Tells Itself

1. **"The suite is green, so the gates work."** Three of five push-gate test files never invoke the tool they gate (P2-1). Two of the five gates cannot execute at all on this machine (P1-1). The judge tier cannot execute at all, anywhere, without a key that is not set (P0-1). Green measures the shell plumbing, which was copied from a proven gate, and says nothing about the configs, which are the new part.

2. **"Every layer earned its place the hard way."** `PROTOCOL.md:281` says exactly this. The evidence file for "earned" contains one rule and stops on 2026-06-05 (P0-2). Layers 1 through 6 plausibly earned it. The Ruby and Go tiers, shipped fifteen minutes apart against no toolchain and no project, earned it in the way that a smoke detector installed in a house that has not been built earns its place.

3. **"The rules are enforced."** 62 percent are honor-system once P0-1 is accounted for (P1-4). The `[manual]` tag is honest, which makes this less a lie than a thing the system knows and has not priced. The unpriced part: nothing retires a manual rule, `retirement_candidates.md` has never been written, and rule count went 42 to 76 in nine weeks.

4. **"The handoff protocol closes the loop between sessions."** The loader reads the wrong directory and delivers a stale engineering audit instead (P1-2). Every handoff since `docs/session-handoff/` was created has been written and never read by the mechanism built to read it.

5. **"Adding a stack tier is cheap because the pattern is established."** The pattern being established is exactly why it is not cheap. Each new tier adds manifest rows for existing IDs, and the manifest consumer at `hooks/llm-rule-judge.sh:60` assumes one row per ID (P1-3). Cheap-to-add is how a latent single-value assumption becomes a silently downgraded blocking rule.

6. **"The moat is the discipline."** The discipline is real and it is not a moat, because nothing here is defended against the only competitor that matters: the operator's own future attention. Every control in this system degrades to honor-system the moment the operator stops caring, and the two mechanisms that would notice degradation (the fire log and the retirement scan) are both dead.

---

## Theater Check

**Confidence theater.** The strongest instance in the system is `enforce/tests/llm-rule-judge.test.sh`: seven passing cases over a stub, covering a tier that cannot execute, gating three rules that have no other enforcer. This is the precise pattern the criticism role names as "LLM-consumer tests that never see a real model output," and the parser it fails to cover (`hooks/llm-rule-judge.sh:41-56`, hand-written brace-balancing `awk` built specifically to survive Haiku's trailing prose) is the single most likely thing in the file to break against real output. Second instance: `push-golangci-gate.test.sh` and `push-rubocop-gate.test.sh`, whose own headers state they run "without a local install," feeding `ok` lines into a runner whose output is the operator's only summary signal.

**Metrics theater.** `global-memory/rule_fires.md` is presented as the effectiveness record of a 93-rule system and contains one rule (P0-2). `hooks/session-end.sh:120-127` computes a velocity flag from commit count, thresholded at 40 and 80, in a repository whose entire product is rules; commit count there measures how much the operator edited their own process, which is the exact activity-not-outcome substitution the role definition names. Meanwhile `hook-latency.test.sh` measures the cheapest property (6ms per event) with real rigor, and nothing measures the expensive one (P2-2).

**Process theater.** R-503's percentage-of-total announcements at every task boundary, for a single-operator system, with no record of the output ever being consulted. R-905 and R-906 in the same category. The sharpest single instance is the handoff document (P1-2): an artifact produced under two rules at every session end, delivered to a loader that reads a different directory. That is process generating an output with a demonstrated consumer count of zero.

**Security theater.** Deferred to the 2026-07-31 security audit, which named the `settings.json` allow-list problem more precisely than this audit would have: `Bash(bash *)` and `Bash(sh *)` grant an unprompted shell that nullifies every deny and ask entry in the same file. That finding is accepted, not duplicated.

---

## Is It Actually Running?

Every row verified during this audit run, not recalled from a prior one.

| Component | The claim | Verified this run |
|---|---|---|
| `enforce/` test suite | green | **YES.** Executed. 28 tests, `ALL ENFORCEMENT TESTS PASS`, 24s. |
| Hook registration closure | all hooks wired | **YES.** Both directions checked. Zero orphans, zero dangling paths, all 30 executable. |
| `push-eslint-gate` | active | **YES.** ESLint present in `enforce/node_modules`; `eslint.test.sh` drives the real binary. |
| `push-ruff-gate` | active via `uvx` | **LIKELY.** `uvx` on PATH; no standalone `ruff`. Engineering audit records executing it against a live binary. |
| `push-rubocop-gate` | active | **NO.** `rubocop` absent from PATH. No-op on every push today. |
| `push-golangci-gate` | active | **NO.** `go`, `gofmt`, and `golangci-lint` all absent. No-op on every push today. |
| `llm-rule-judge`, error tier | enforces R-315/316/317 | **NO.** `ANTHROPIC_API_KEY` absent from the hook environment. Exits at line 33. |
| `session-start.sh` handoff load | loads the handoff per R-001 | **NO.** Executed; emits `docs/audits/2026-07-31-engineering.md`. Real handoff never read. |
| `session-end.sh` fire/miss routing | closes the R-603 loop | **NO.** Zero content changes in 28 days; source is manual transcription, not observation. |
| `global-memory/INDEX.md` injection | auto-loaded at session start | **YES.** Executed the hook and observed the content in `additionalContext`. |
| `retirement_candidates.md` | written by a prior retirement scan | **NO.** File does not exist. |
| lefthook / `core.hooksPath` (R-107) | expected lefthook path | **NOT APPLICABLE HERE.** No lefthook binary, no config, `core.hooksPath` unset, `.git/hooks` samples only. R-107 governs project repos, not `~/.claude`. Recorded for completeness, not a finding. |

---

## Process-vs-Outcome Balance

53 commits in the last 30 days, all of them serving the harness. Churn by top-level path: `enforce/` 93 file-touches, `hooks/` 68, `rules/` 19, `CLAUDE.md` 15, `docs/` 11, `agents/` 10, `settings.json` 9, `global-memory/` 9.

Concentration is extreme: 41 of 53 commits land on four days (07-03: 12, 07-04: 9, 07-29: 9, 07-31: 11), and each of those four is a restructure day. Today's sequence is the tightest example of the shape: Python tier shipped, engineering audit dispatched at the Python tier, audit P1s closed, handoff written, Ruby and Go tiers shipped, then three audits of the harness. That is a closed loop in which the process's output is more process, evaluated by an audit of the process.

The honest framing, since product repositories are out of scope and cannot be counted from here: within the observable surface, the harness spent 53 commits on itself in 30 days, and its own instrumentation records zero evidence that any of it changed an outcome in a product repository (P0-2).

**This is not yet meta-system performance art, and the distinction matters.** The enforcement layer is genuinely mechanical, 28 fixture tests genuinely run, the ESLint and ruff gates genuinely fire, and the security audit that landed today found two real P0s that only exist because the system is real enough to have an attack surface. That is not performance. But the ratio is at the edge, the loop closed today, and the one measurement that would distinguish "process that earns its keep" from "process that generates audits about itself" is the one this audit found dead.

**Recommendation, escalated rather than decided.** A moratorium on new tiers, new gates, and new rules until P0-2 is closed and one 30-day window produces fire data. Adding a fifth language tier before the fire log can say whether the first four ever blocked anything is a decision made without instruments. This belongs to the operator, not to the audit.

---

## If I Were Competing Against This

Not applicable in the commercial sense; the harness has no market, no users beyond one, and no unit economics beyond the operator's time and the Haiku calls the judge would make if it could make them. The competitive question that does apply: what would a simpler system do better?

A ten-rule system with five hooks and a real fire log would beat this on the only axis that matters, because it would know which of its five hooks earned its place. This system has 93 rules, 30 hooks, and 5 gates, and can name exactly one rule that has ever demonstrably fired. The advantage of a small system is not smallness; it is that its evidence base is achievable. That is the sense in which the growth is the vulnerability.

---

## Where the Sibling Audits Are Wrong

Two sibling audits exist for today. Both were read in full.

**`docs/audits/2026-07-31-engineering.md`** (scoped to `enforce/` and `hooks/` at HEAD `833cdaa`).

Method is the strongest part and deserves saying: it ran the real `ruff`, it ran `structure-gate.sh` against the layout `CLAUDE-PYTHON.md` documents rather than against the shipped fixtures (which is what surfaced its P1-1, a case where the entire Python stack bypassed the gate), and it deregistered a hook from a `settings.json` copy to test the meta-guard's own coverage. That is executed verification, not read verification.

Its blind spot is the structural one for its role: it audited whether the gates are correctly implemented and never asked whether they can execute. Its P0 section reads "None. No credential leak, no red suite, no hook missing its execute bit, no unregistered manifest enforcer for the `hook:`/`eslint:` tiers." The qualifier "for the `hook:`/`eslint:` tiers" excludes the `llm-judge` tier by construction, and the judge is in scope: it is `hooks/*.sh`, it is registered in `settings.json`, and it is the sole enforcer for three error-severity rules. The audit read `llm-rule-judge.sh` (it cites the file), saw `ok llm-rule-judge.test.sh` in a green suite, and moved on. **P0-1 above is the finding it should have made.** The Ruby and Go tiers postdate its HEAD, so P1-1 is not its miss.

**`docs/audits/2026-07-31-security.md`** (whole-harness threat model, 2 P0s, 16 findings).

This is the best report in `docs/audits/`. It is accepted in full and not re-litigated. Two corrections, both about the boundary between latent and present-tense risk.

First, and this is the sharper one: **Finding 9 quotes `hooks/session-start.sh:46-63` verbatim, the exact lines that contain P1-2, and does not notice the hook reads the wrong directory.** It analyzes the fallback glob `docs/audits/????-??-??-*.md` as a prompt-injection vector, which it is, and never asks the functional question of whether the hook loads the file R-602 tells it to load. It even observes that "R-001 step (5) already requires verifying its SHA against `git log`, which is a provenance check the hook does not perform," which is one step from noticing the hook is not reading R-602's file at all. This is the structural blind spot for the security role: the question asked is "what can an attacker put here," never "does this control do the thing the rule says it does."

Second, **Finding 8 is correct as a latent risk and false as a present-tense claim.** It states that "on every `git push` in every repository, the complete added and modified source of the outgoing diff, across five languages, is transmitted to `api.anthropic.com`." That does not happen today, because `ANTHROPIC_API_KEY` is unset and the hook exits at line 33 (P0-1). The finding correctly identifies the missing exemption block and the missing disclosure, and both fixes are right. The correction is to its remediation ordering: the disclosure gap is not an active confidentiality exposure, it is a gap that becomes one on the day the key is set. That is a different urgency, and it interacts directly with P0-1, because the natural fix for P0-1 (set the key) is the event that makes Finding 8 live. **Those two must be sequenced together.**

Third, and shared by both: **neither audit opened `global-memory/rule_fires.md`.** Neither asked what the evidence base for the system is. That is the gap this role exists to cover, and it is P0-2.

---

## The Hard Prioritization

Five things, in order, before this system is shown to anyone or grown by one more rule.

1. **Settle P0-1: does the judge run?** Three error-severity rules and the entire semantic tier hang on one environment variable that is not set. Either it is a control, in which case it needs a startup-visible failure signal and a live-output test, or it is an aspiration, in which case `CLAUDE.md` must stop marking R-315/R-316/R-317 as `[judge]`. Sequence with security Finding 8: setting the key is what makes that finding live. First because everything downstream in the enforcement story is false while this is unresolved.

2. **Fix `session-start.sh`'s handoff path (P1-2).** Smallest fix on this list, largest immediate return: it stops a 400-line stale audit from being injected as trusted continuity at every session start, and it makes every handoff written since `docs/session-handoff/` was created actually reachable. It also partly closes the security audit's Finding 9 by removing the reason the `docs/audits/` fallback exists.

3. **Restore or replace the fire/miss instrument (P0-2).** This is the root cause of P1-1, P1-4, and P2-2, and no defensible decision about rule growth or gate retirement can be made until it produces data. Manual discipline has been tried for two months and produced one rule's worth of entries. The class of fix is automatic emission at the moment a hook denies, since the hook already knows.

4. **Freeze new tiers until an existing gate blocks a real violation (P1-1).** Two of five gates are no-ops on this machine, two of five gate tests never invoke the tool they gate, and the fire log cannot name a single gate that has ever blocked anything. Adding a sixth is a decision made without instruments. This is the escalation item: it is a moratorium on the operator's own favorite activity, and that call belongs to the operator.

5. **Fix the manifest severity lookup (P1-3).** Cheapest of the five and the one that silently degrades a blocking rule to a stderr line the next time the standard growth move is applied to a naming rule. Twenty minutes and a fixture, against a failure mode that produces no error message when it fires.

---

## What Would Make Me Wrong

Stated per finding, as the specific evidence that would overturn it.

- **P0-1.** `ANTHROPIC_API_KEY` present in the hook process environment but stripped from Bash-tool subprocesses. Test: add `[ -n "${ANTHROPIC_API_KEY:-}" ] && echo present >&2` to a scratch copy of a registered hook and trigger it. Present means this drops to P2 (no live-output test) rather than P0 (dead tier).
- **P0-2.** Fire and miss data existing somewhere outside `global-memory/`. A denial log under `telemetry/`, a counter in the transcript schema, or a project memory file with recent `fired:` lines for rules other than R-207 would overturn the "no evidence base" claim entirely. Nothing found during this audit, but the private runtime directories were deliberately not read, so this is the finding most exposed to my own scope limit.
- **P1-1.** A `go.mod` or `Gemfile` in any repository the operator actively works in. One `find` settles it. Its existence moves this to P3 and makes the correct action "install the toolchain," not "annotate the tests."
- **P1-2.** A project that still keeps handoffs under `docs/audits/`, which would make the current glob correct for that project and this a partial rather than total miss. The emitted-path evidence from running the hook stands regardless for this repository.
- **P1-3.** A uniqueness assertion in `enforce/tests/manifest.test.sh` that would prevent a duplicate error-severity judge ID from ever landing. Five R-329 rows passing that suite is strong evidence against, but the assertion could be scoped to the judge tier specifically.
- **P1-4.** A retirement scan in commit history, or fire data showing manual rules firing. Both are blocked behind P0-2, which is why P0-2 sequences first.
- **P1-5.** Nothing would overturn this one. `grep -ci python PROTOCOL.md` returns 0 and `CLAUDE.md:3` names the file as the history of record. The only open question is whether the section ordering is deliberate, which changes the fix and not the finding.
- **The process-vs-outcome assessment.** Product commits in repositories outside this one during the same 30-day window would reframe the ratio entirely. That data is out of scope for this audit by construction, which is exactly why the finding is stated as "within the observable surface" rather than as a verdict. The operator can settle it in one command and should.
