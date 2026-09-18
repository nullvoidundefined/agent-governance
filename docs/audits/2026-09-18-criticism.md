# Criticism audit: the harness is an impressive control plane with no outcome case

Date: 2026-09-18

## The Brutal Truth

This repository has built a sophisticated system for governing agents, but it has not built the evidence needed to show that the system makes agents better. It can prove that many hooks are registered, generated ports are current, fixtures exercise selected command shapes, and rules sometimes fire. It cannot prove that governed sessions ship fewer defects, leak fewer secrets, require less rework, or outperform an ungoverned baseline. Worse, its telemetry mixes real interventions with fixture traffic, its current local suites are red during normal harness use, and its cross-tool status reports often equate an event mapping with effective prevention. The project is at risk of becoming meta-system performance art: 109 governance commits in 30 days, 101 tests, 101 manifest entries, three tool ports, and no credible before-and-after behavioral result.

Overall rule-layer health: **Significant**. The design is not fatally misleading because limitations are often documented and several controls demonstrably deny bad actions. It is significantly unhealthy because its strongest strategic claim, improved agent behavior, is unmeasured.

## Coverage

| Surface | Treatment | Result |
|---|---|---|
| Claude source rules, hooks, fixtures, CI, issue ledger | Read and selectively executed | Both fixture suites executed. Three fixtures failed. |
| Codex generator, adapter status, and current audit | Read; generator check executed | Generator current. Prior live deny probes accepted as evidence, with limits below. |
| Cursor generator, adapter status | Read; generator check executed | Generator current. No live Cursor session was executed in this audit. |
| Git history, last 30 days | Counted and sampled | 109 commits, all sampled work is governance product work. |
| Installed Claude telemetry | Read only | 1,011 raw rows; recent fixture pollution confirmed. |
| Current sibling audits | Read | Only `2026-09-18-codex-rule-coverage.md` existed during this audit. |
| Remote CI and branch protection | **UNVERIFIED** | No network or GitHub control-plane query was used. |
| Real downstream projects | Not covered | The audit had access only to this harness repository. |

## What's Actually Good

The repository has three properties worth preserving. First, `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` both passed during this audit, so the checked-in generated trees match their current renderers. Second, the port status documents name real gaps instead of claiming perfect parity, including missing task events and post-compaction behavior. Third, many hook headers state their fail-open boundaries explicitly. These are real engineering strengths because they make disagreement testable.

## What's Broken

### Significant: the effectiveness telemetry is polluted and measures interventions, not outcomes

The logger records only a rule, hook, decision, and repository basename:

> `printf '%s|%s|%s|%s|%s\n' ... "${1:-unknown}" ... "$(basename "$(git rev-parse --show-toplevel ...)")"`  
> `claude/hooks/log-rule-fire.sh:16-22`

The rollup discards even the hook and repository, grouping only by rule and decision:

> `awk -F'|' '{ key = $2 " " $4; count[key]++ }'`  
> `claude/hooks/session-end.sh:118-123`

The live installed log contained 1,011 rows during this audit. Its recent tail included `R-999|llm-rule-judge|ask|tmp.6kqc1kL4dd` and repeated R-315/R-324 rows from the same temporary fixture repository. The suite runners set `CLAUDE_FIRE_LOG=/dev/null` at `claude/enforce/tests/run-tests.sh:4-5` and `claude/hooks/tests/run-tests.sh:5-6`, but running a fixture directly does not. The durable rollup cannot distinguish that test traffic from real work.

Even clean fire counts would measure friction, not value. `session-metrics.sh` measures commits, files changed, and files revisited at `claude/hooks/session-metrics.sh:20-31`; it never measures escaped defects, accepted false positives, time-to-completion, or user outcomes. The issue ledger already admits that no false-block measurement exists at `claude/ISSUES.md:15`.

**Direction:** Separate fixture and production event streams at the logger, preserve session and repository class through aggregation, and attach an adjudicated outcome to a sampled set of blocks. Run a controlled evaluation on the same tasks with and without the harness. **To confirm:** whether transcript history can identify retry success, user override, and later defect for each decision without collecting sensitive content.

**What would make me wrong:** a reproducible evaluation showing statistically meaningful reductions in defects or unsafe actions, with false-positive rate and task-time cost reported, would overturn this finding.

### Significant: the current test signal is red and two fixtures are not isolated from normal harness state

This audit ran both checked-in suite runners. `parallel-session-check.test.sh`, `push-ruff-gate.test.sh`, and `post-compact-rules.test.sh` failed.

The post-compaction fixture claims there is no ledger without changing to a ledger-free repository:

> `OUT=$(echo ... | "$HOOK")`  
> `printf '%s' "$CTX" | grep -q 'Task ledger' && { echo "FAIL: ledger section emitted with no ledger on disk"; exit 1; }`  
> `claude/hooks/tests/post-compact-rules.test.sh:20-30`

Running the test from this repository while the mandatory task-start procedure has created `.claude/task-tier.json` makes that assertion false. The parallel-session failure has a different root cause: `claude/hooks/parallel-session-check.sh:39-46` runs a fallible `ps` pipeline inside a command substitution under `set -euo pipefail`; when the selected parent disappears, the hook exits before writing its isolated registry. The fixture's isolated lock directory showed that this was not contamination from another live session.

The Ruff test drives a real binary, but the hook chooses `uvx ruff` when no `ruff` binary exists at `claude/hooks/push-ruff-gate.sh:55-64`, suppresses all tool errors at line 81, then exits successfully when output is not parseable at lines 82-84. In this audit, that path printed `ruff produced no parseable output, skipping (fails open)` and the fixture failed.

**Direction:** Make every fixture establish its own current directory, home, runtime state, data bindings, and binary. Keep a separate live-tool compatibility job for Ruff. Do not let a network-backed `uvx` fallback masquerade as deterministic local enforcement. **To confirm:** reproduce the Ruff result with the pinned CI binary and separately with network disabled.

**What would make me wrong:** both suites passing from a real active session, a clean clone, and CI with no inherited home or session state would narrow this to a transient environment failure.

### Significant: cross-tool parity reports event reachability as enforcement parity

Cursor reports `47 of 53 hook registrations port` at `cursor/PORT-STATUS.md:5`, but Write/Edit guards are mapped to `afterFileEdit` as well as `preToolUse` at lines 29-36. An after-edit notification can observe a violation after the file has changed; it is not equivalent to Claude Code's pre-write denial. The document does not split preventive coverage from advisory or compensating coverage.

Codex is more honest about static-analysis limits. Its shell-write section says variable, substitution, glob, `eval`, interpreter, and unrecognized-tool writes are dropped at `codex/PORT-STATUS.md:88-100`. Yet the current coverage audit concludes that 89 of 101 entries are mechanically enforced. That number describes known event paths, not the fraction of real write actions caught. The denominator is manifest entries rather than attempted behavior, so it cannot answer the question users care about.

**Direction:** Replace a single ported count with three counts: preventively equivalent, detect-only or compensating, and manual/unobservable. Add live black-box mutation probes for each tool and operation family, including bypass shapes. **To confirm:** whether Cursor's `preToolUse` event reliably carries file-edit paths for native edits; if it does, the after-edit concern narrows to registrations relying exclusively on that event.

**What would make me wrong:** black-box tests showing every claimed preventive registration stops the side effect before it occurs on supported tool versions.

### Significant: the rule system has contradictory routing and stale canonical documentation

The criticism agent frontmatter says `model: opus` at `claude/agents/audit-criticism.md:6`. Its body says `Default to Sonnet` and to use Opus only for harder decisions at lines 12-14. The runtime frontmatter wins before the prose can advise the dispatcher, so the role is permanently routed to the expensive model unless an outer caller overrides it. This is a direct conflict, not a preference.

The Claude README says the port artifacts are frozen and tracked as an issue:

> `the surviving PORT-STATUS.md and .claude-port.json artifacts are frozen at the last build`  
> `claude/README.md:266`

That is now false. Both port READMEs describe active generators, both generator checks passed, and `cursor/PORT-STATUS.md` is generated. The supposedly explanatory document teaches an obsolete architecture.

**Direction:** Make model routing single-source and generated into frontmatter, then update the port section from the current exporter architecture. **To confirm:** dispatch the criticism agent without an explicit model and record the effective model rather than inferring precedence.

**What would make me wrong:** evidence that the agent runtime ignores frontmatter when the body carries a routing instruction. The README conflict cannot be overturned while the generator checks exist and pass.

### Significant: the paid judge is designed as a control but remains inert by default

The issue ledger says the judge activates only after a rotated key is manually stored at `claude/ISSUES.md:9`, and repeats that it is still inert at line 48. Rules tagged as judge-backed therefore remain advisory for a default install. A security or naming control that is architecturally present but operationally off is not enforcement.

**Direction:** Either remove judge-backed rules from the enforced numerator until a startup probe confirms a usable credential and one successful recent run, or provide a local deterministic replacement for the critical subset. **To confirm:** execute the judge's non-billable readiness path and inspect a current successful decision timestamp.

**What would make me wrong:** a current, real judge decision in each supported tool, with the billed model and failure policy recorded.

### Worth addressing: safe monotonic sync guarantees live rot

The sync script intentionally never deletes tracked files removed from source:

> `nothing already sitting in a live directory is ever removed by it, even a tracked file removed from the source stays behind until cleaned up by hand`  
> `sync.sh:14-25`

That choice prevented a destructive incident, but the cost is not hypothetical. Four orphaned installed files already require manual deletion, and the integrity checker remains noisy until then (`claude/ISSUES.md:42`). A safety mechanism that permanently accumulates obsolete executable hooks creates ambiguity about what actually runs.

**Direction:** Add a generated ownership manifest and move only previously owned, now-removed paths into a quarantine directory. Never delete unknown live state. **To confirm:** whether the three tools ignore orphaned unregistered hooks or discover any by directory convention.

## What's Weak

- The harness is optimized for preventing known command shapes. It is much weaker at showing that prevented actions were genuinely harmful rather than stylistically disfavored.
- Rule-fire telemetry stopped producing committed durable rows after 2026-09-10 even though the repository has intense activity through 2026-09-18. That may be a commit workflow gap rather than a runtime gap, but either interpretation makes the checked-in effectiveness record stale.
- The only durable miss entry is a retrospective R-102 incident in `claude/global-memory/rule_misses.md:7`. One miss class is not a credible learning loop for a system of this size.

## What's Missing

- A benchmark corpus of representative agent tasks with adjudicated expected outcomes.
- Precision, recall, false-block rate, override rate, and time-cost measurements per gate.
- Versioned compatibility claims for Claude Code, Codex, and Cursor, backed by live black-box probes.
- An adoption boundary stating who this is for. The current process burden is tailored to one highly disciplined maintainer, not validated for a team or a casual user.
- A retirement mechanism driven by outcome evidence. Rules can accumulate fires, but no data says which rules are net harmful.

## Lies the Team Tells Itself

1. **"A ported hook is the same control on another tool."** Event mapping proves reachability, not equivalent timing, payload, or denial semantics.
2. **"A fire is evidence that a rule earned its place."** A fire may be a fixture, a false positive, a style preference, or a prevented defect. The current schema cannot tell which.
3. **"A green fixture suite proves the harness works in use."** The suite was red when run from a correctly classified active audit session because fixtures leaked ambient state.
4. **"The process is self-correcting."** The miss log has one incident class, false blocks have no structured channel, and stale installed files require manual cleanup.
5. **"More governance artifacts imply better governance."** They imply more surface area. Benefit requires outcome evidence.

## The User's Experience, Honestly

Installation presents a large up-front trust demand. The user must sync hundreds of files into three live configuration homes, accept dozens of hooks, install dependencies, configure a paid judge credential, and learn a rule vocabulary exceeding one hundred manifest entries. When the system blocks, the user often receives a rule ID and a workflow demand, but the system cannot say how often that demand prevented a real defect. When it fails, it can fail open, emit an advisory after the edit, or generate a false red suite because a task ledger exists. The expert maintainer can debug those distinctions. A new user will experience them as arbitrary ceremony and disable the harness.

## The Business Model Problem

There is no declared commercial model, so revenue-versus-cost analysis is impossible. The cost structure is still real: paid model calls for the judge, context consumed by always-on rules and reinjection, CI minutes for 101 fixtures, and developer time across 109 recent commits. No file prices those costs against avoided incidents. The judge is currently inert, which avoids spend by also delivering no judge value.

Direction: publish a per-session cost report covering tokens, judge calls, CI time, hook latency, and human override time, then compare it with adjudicated incidents avoided. **To confirm:** the intended distribution model and whether users bear their own provider costs.

## If I Were Competing Against This

I would ship a smaller harness with ten high-value controls, black-box compatibility tests, and a public benchmark showing defect reduction and false-positive rate. I would let this project win on rule count while I won on trust. The easiest attack is not technical bypass; it is showing that my tool produces the same or better outcomes with a fraction of the cognitive and operational cost.

## Theater Check

- **Security theater:** the paid judge is wired but inactive without a manually installed credential. A real version reports readiness and recent successful enforcement.
- **Confidence theater:** the manifest, fixtures, and port counts demonstrate internal consistency but not real-action coverage. The current red, ambient-state-sensitive fixtures make the gap concrete.
- **Process theater:** 109 governance commits in 30 days with no controlled behavioral result is **meta-system performance art**. This repository is itself a governance product, so zero application features is not the criticism. The criticism is that product work overwhelmingly expands machinery without validating its promised outcome.
- **Metrics theater:** commit count, files changed, files revisited, and rule fires are activity metrics. None establishes quality, safety, or speed.

## Is It Actually Running?

| Component | Claim | Audit result |
|---|---|---|
| Codex generator | Generated tree is current | Verified by `node translate/codex.mjs --check`. |
| Cursor generator | Generated tree is current | Verified by `node translate/cursor.mjs --check`. |
| Local git pre-push | Installed | Verified `.git/config` points to `.git/hooks` and `.git/hooks/pre-push` exists. Effect on linked worktrees remains an open issue. |
| Claude fixture suites | Green | False in this audit. Three fixtures failed. |
| GitHub CI | Runs and is required | **UNVERIFIED**. Workflow YAML exists; remote required-check state and latest run were not observed. |
| Codex denies | Honors adapter deny | Accepted from the current Codex coverage audit's live side-effect probe. Not repeated here. |
| Cursor denies | Equivalent to Claude | **UNVERIFIED**. No live Cursor session was run. |
| LLM judge | Active | **UNVERIFIED / documented inert** pending credential setup. |
| Fire telemetry | Measures real enforcement | Running, but polluted by fixture events and unsuitable for effectiveness claims. |
| Sync freshness | Installed trees received the current payload | Verified by a successful root-session `./sync.sh`; read-only comparison also showed expected runtime-only state and known source-deleted residue. Monotonic sync retains source-deleted files by design. |

## Process-vs-Outcome Balance

The last 30 days contain 109 commits. The sampled log is entirely harness code, rules, hooks, audits, tests, ports, documentation, and remediation. Since this repository is the product, that count is not inherently waste. The imbalance is between 109 construction commits and zero checked-in controlled evaluations of agent outcomes. Put a moratorium on new rules, roles, hooks, and workflow layers until the existing system completes a benchmark across Claude, Codex, and Cursor and reports quality, safety, time, and false-positive results.

## Where the Sibling Audits Are Wrong

### `2026-09-18-codex-rule-coverage.md`

The audit did valuable live probes and correctly rejected its initial nine-entry hypothesis. Its blind spot is the denominator. “89 of 101 manifest entries” treats a registered, dispatchable enforcer as mechanically enforced even when real behavior can use a command shape outside the adapter's static recognizer. It measures rule-entry reachability, not action coverage. Its own source later documents unrecognized shell-write families, which means the headline is precise about the manifest and easy to misread as precise about protection.

No other 2026-09-18 sibling audit existed when this report was written.

## The Rules That Run Claude

- **Gaps:** no outcome evaluation rule, no false-positive adjudication workflow, no tool-version compatibility matrix, and no safe cleanup path for owned stale files.
- **Conflicts:** criticism model routing conflicts between `claude/agents/audit-criticism.md:6` and lines 12-14. The README's frozen-port architecture at `claude/README.md:266` conflicts with the active exporters and passing checks.
- **Waste:** activity metrics and fire rollups consume implementation attention while remaining unable to answer whether behavior improved.
- **Redundancy:** governance claims are repeated across README, port status, audit reports, issue ledgers, generated AGENTS files, and global memory. The stale port paragraph shows the resulting drift.
- **Dead rules:** judge-backed rules are dead as mechanical enforcement until the credential exists. Manual rules remain honor-system by definition and lack retirement evidence.
- **Thoroughness:** Claude has the richest runtime contract. Codex and Cursor have documented gaps, but the status format obscures whether a mapping is preventive, post-hoc, or merely advisory.

## The Hard Prioritization

1. Build and publish a controlled behavioral benchmark. Without it, every other claim is internal plumbing.
2. Repair test isolation and make the full suite green from an active governed session, a clean clone, and CI.
3. Replace the ported/not-ported binary with preventive, detect-only, and manual coverage backed by live probes.
4. Clean the telemetry boundary, add false-positive adjudication, and stop treating rule fires as value.
5. Freeze new governance features until the first four produce evidence that the existing system earns its cost.

## What Would Make Me Wrong

- **No outcome case:** a preregistered benchmark showing material defect or risk reduction at acceptable time and false-positive cost.
- **Red suite and fixture leakage:** repeatable green runs across active sessions, clean clones, and CI with hermetic state.
- **Parity overclaim:** live black-box prevention tests for every claimed equivalent operation on named tool versions.
- **Routing and documentation conflict:** one generated canonical routing source and current architecture documentation, plus an effective-model probe.
- **Inert judge:** a current successful real decision and readiness signal in all claimed supported runtimes.

No evidence can make activity metrics alone prove outcomes. They must be replaced or paired with outcome measurements.
