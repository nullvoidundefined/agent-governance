# Release gate repair: a suite that is green for the right reasons

Date: 2026-09-18. Status: approved in brainstorming, awaiting implementation plan.

## Goal

Make both fixture suites pass, on a developer machine during a normally classified task, on a clean clone, and in CI, for reasons that are true rather than incidental. Two external audits on 2026-09-18 found the suites red in ordinary use, and every other claim the harness makes rests on a suite whose result can be trusted.

This spec covers the release gate only. The telemetry boundary, the preventive-versus-advisory parity model, and the controlled outcome benchmark are the other workstreams those audits identified; each gets its own spec and plan. They are named here only where they constrain a decision.

## Background: what the audits found, and what is already fixed

Both audits ran the suites and found three failures. Two are closed already and are recorded here so the plan does not re-solve them.

`post-compact-rules.test.sh` asserted that no task ledger section is emitted while running the hook in whatever directory the suite happened to sit in. The hook resolves the ledger from that directory's git root, so the case passed only while the harness itself carried no `.claude/task-tier.json`, and failed the moment a session classified its own work, which R-001 requires. Fixed on 2026-09-18 by giving the negative case its own ledger-free repository.

The Codex shell-write gap, where a file written by redirection reached the gates with no path, is closed with a corrected premise: `protected-path-guard` already carried its own redirection extractor and is registered on the Bash matcher, so R-410 was never open. What was bypassed were the gates registered only on `Write|Edit`, which is R-306, R-313, R-314, R-328 and R-331.

Two failures remain, and two documentation defects travel with them.

## Acceptance criteria

- B-1: `parallel-session-check.sh` writes its registry entry on every SessionStart, including when the process it selected for liveness has already exited. A fixture supplies a PID that is guaranteed dead and asserts the registry entry exists.
- B-2: Session identity in that registry is the host-provided `session_id`. Two sessions sharing a worktree are detected as parallel by identity, not by process ancestry, and a recycled PID never produces a false warning.
- B-3: A session whose entry is in the registry and whose process is gone is treated as finished, not as a parallel session.
- B-4: The pinned Ruff version is declared in exactly one tracked file. CI, the push hook, and the fixture all read that file, and a fixture asserts the three agree.
- B-5: With the pinned Ruff absent, `push-ruff-gate.sh` exits 0, names the pinned version it wanted, and states plainly that Python linting did not run. A fixture asserts that message and that exit status.
- B-6: With the pinned Ruff present, the gate's behaviour cases run against the real binary. With it absent, those cases skip and report as skipped rather than passing.
- B-7: Both suites pass from a correctly classified session with a live `.claude/task-tier.json`, and in CI.
- B-8: `claude/agents/audit-criticism.md` states one model, in one place.
- B-9: `claude/README.md` describes the current exporter architecture. No sentence claims the port artifacts are frozen.

## Non-goals

- Changing the fail-open posture of any gate. B-5 makes the existing posture legible; it does not make Ruff's absence a blocking condition. That decision was taken deliberately and can be revisited on evidence.
- Making Ruff an install prerequisite or bundling it. Rejected because it turns a missing lint tool into a hard stop on every machine that touches Python.
- Fetching Ruff on demand at push time. Rejected because a network dependency on the push path is enforcement that only looks local, which both audits named.
- Any change to the telemetry schema, the parity counts, or the benchmark. Separate workstreams.

## B-1 through B-3: session identity

### The defect

`claude/hooks/parallel-session-check.sh` enables `set -euo pipefail` at line 11. It then walks the process tree for a plausible session PID and reads that process's start time:

```bash
started_at() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'; }
MY_PID=$(session_pid)
MY_START=$(started_at "$MY_PID")
```

`ps` has its stderr suppressed but not its exit status, and it is the first stage of a pipeline under `pipefail`. If the selected PID exits between selection and inspection, the substitution fails and the hook exits at that line, before the registry write near line 63. R-501's protection against two sessions editing one worktree becomes a silent no-op under exactly the process churn it exists to tolerate. The engineering audit reproduced this with an isolated lock directory, which rules out contamination from a real session.

### The design

Identity moves to the `session_id` the host already sends. The hook reads its payload today for `.cwd`, so the field costs nothing to collect, and both Claude Code and Codex were observed delivering it during the 2026-09-18 live probes.

A registry entry becomes three fields: the session id, the PID, and the start time when it could be read. The id answers "is this the same session", the PID answers "is it still running", and the start time remains only as a guard against a recycled PID being mistaken for a live session. Reading the start time becomes an explicit fallible probe whose failure yields an empty value and never aborts registration, because an absent start time no longer decides identity.

Liveness keeps its current meaning: an entry whose PID is gone is a finished session and is dropped. An entry whose PID is live but whose start time disagrees with the record is a different process wearing a recycled number, and is also dropped. An entry whose start time was never recorded falls back to the PID liveness check alone, which is weaker but strictly better than today's behaviour of not registering at all.

A session with no `session_id` in its payload keeps the current PID-based identity. That path is the compatibility fallback, and the fixture covers it so it cannot rot unnoticed.

### Testing

The current fixture depends on timing, which is why a synthetic run passes while the full runner fails. The replacement supplies the failure directly: a PID chosen to be dead, so the start-time probe fails deterministically on every platform, and the assertion is that the registry entry exists anyway. Additional cases cover two sessions with distinct ids on one worktree warning as parallel, a dead entry being dropped, a live PID with a mismatched start time being dropped, and a payload without a session id taking the fallback.

## B-4 through B-6: one Ruff contract

### The defect

`.github/workflows/enforce.yml` installs `ruff==0.16.6`. The repository declares no Python runtime, and `push-ruff-gate.test.sh` binds no `CLAUDE_RUFF_CMD`, so the fixture drives whatever Ruff the machine happens to have, or none. The hook prefers `$CLAUDE_RUFF_CMD`, then a `ruff` binary, then `uvx ruff`, and exits 0 when output is not parseable. The same commit therefore enforces differently on different machines, and the local suite is red for a reason that has nothing to do with the code under test.

### The design

The pinned version moves into one tracked file, `claude/enforce/tool-versions.txt`, as a `name=version` line. Three readers consume it: the CI workflow installs exactly that version, the push hook names it when reporting a skip, and a fixture asserts that the workflow and the hook agree with the file. A version bump becomes a one-line change that CI proves consistent, rather than a workflow edit that silently diverges from what developers run.

The hook's resolution order keeps `$CLAUDE_RUFF_CMD` first, so fixtures and CI can bind a specific binary. The `uvx` fallback is removed: it is the network-backed path that makes a local gate look deterministic while depending on a download, and with the skip message made explicit there is nothing left for it to buy.

The skip message changes from a bare note to a statement of consequence: which version was expected, that Python linting did not run for this push, and how to install it. The exit status stays 0.

The fixture splits in two. The behaviour cases require the pinned binary and are skipped, reported as skipped, when it is absent. The skip-path case always runs, because it needs no Ruff at all: it asserts the message and the exit status when no Ruff is resolvable. A suite run on a machine without Ruff therefore reports a skip rather than a failure, and a suite run in CI exercises the real binary.

## B-8 and B-9: two contradictions

`claude/agents/audit-criticism.md` sets `model: opus` in its frontmatter while its body says to default to Sonnet and step up only for harder decisions. Frontmatter is what the dispatcher reads, so the role is routed to the more expensive model permanently and the prose never gets a say. One of the two must go. The body's reasoning is sound and specific, so the frontmatter changes to Sonnet and the body keeps its escalation guidance; the alternative, deleting the body advice, would discard the reasoning and leave a bare setting nobody can argue with.

`claude/README.md:266` still describes the port artifacts as frozen at the last build and tracked as an open issue. Two exporters now regenerate both trees, `--check` gates them in CI, at push, and in `doctor.sh`, and both checks pass. The paragraph teaches an architecture that no longer exists; it is rewritten from the current one.

## Domain vocabulary

- session identity - the value that answers whether two SessionStart events belong to the same session. chosen over: process identity, because a PID is recycled by the OS and a start time cannot always be read.
- liveness - whether the process behind a registry entry is still running. chosen over: freshness, because a timestamp cannot distinguish a long-running session from an abandoned one.
- pinned tool - a version declared in the repository and used identically by CI, fixtures, and hooks. chosen over: available tool, because the ambient version is what made the same commit enforce differently on two machines.
- skip - a fixture outcome reported separately from pass and fail, meaning the case could not run and nothing was proven. chosen over: pass, because a skipped check that reports as passing is the confidence theater this repository refuses.

## Assumption ledger

| Claim | Source | Verification | Status | Owner | Next action |
|---|---|---|---|---|---|
| Claude Code sends `session_id` in SessionStart | Observed in Codex debug log 2026-09-18 | Log one SessionStart payload from Claude Code and inspect | unverified | implementer | Confirm before B-2, since the fallback depends on knowing when it is absent |
| Cursor's adapter forwards `session_id` | Not observed | Drive the adapter with a synthetic Cursor payload | unverified | implementer | If absent, the PID fallback covers Cursor and the spec is unchanged |
| No consumer parses the registry file format | Only this hook reads it | grep the tree for the registry path | unverified | implementer | Confirm before changing the entry shape |
| Removing `uvx` breaks no current user | This repository has no Python | Ask the owner whether any downstream project relies on it | unverified | owner | Confirm before B-4 lands |

## Risks

The registry file format changes, so entries written by an older hook are unreadable by a newer one and vice versa. A session mid-flight during an upgrade could warn spuriously once. The mitigation is that an unparseable entry is dropped rather than treated as live, which degrades to the current behaviour of no warning rather than to a false one.

Removing the `uvx` fallback narrows where the Python gate runs. On a machine with `uvx` but no `ruff`, linting silently happened before and will now be skipped loudly. That is the point, but it will look like a regression to anyone who had been relying on it without knowing.
