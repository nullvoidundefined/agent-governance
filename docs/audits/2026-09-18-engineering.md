# Engineering Audit: Claude, Codex, and Cursor Harness

Audit date: 2026-09-18. Repository state: `claude/handoff-probes-done` at `1b66b87`, with only the pre-existing untracked `.worktrees/` entry before these reports were written. This is a reporting-only audit. No implementation or configuration was changed.

## Coverage

| Surface | How checked | Reason when not executed or not covered |
|---|---|---|
| `claude/` canonical rules, hooks, settings, skills, agents, and enforcement data | executed | Both fixture suites were run; selected hooks were reproduced independently. |
| `claude/enforce/tests/` | executed | `run-tests.sh` completed red with two failing fixtures. |
| `claude/hooks/tests/` | executed | `run-tests.sh` completed red with one failing fixture. |
| `codex/` generated projection | executed | `node translate/codex.mjs --check` passed; adapter contract fixture passed. The 2026-09-18 live Codex probes in the rule-coverage audit were also reviewed. |
| `codex/hooks/codex-hook-adapter.sh` (hand-authored) | executed | Contract fixture passed. Live `apply_patch` dispatch and deny behavior were established by the prior same-day probe. The current branch also recognizes common shell-write targets, with runtime-computed paths documented as an explicit limit. |
| `cursor/` generated projection | executed/read only | `node translate/cursor.mjs --check` and the adapter contract fixture passed. No live Cursor host was available, so host-level decision enforcement was not covered. |
| `cursor/hooks/claude-hook-adapter.sh` (hand-authored) | executed | Contract fixture passed; no live Cursor session was available. |
| `translate/*.mjs` and both port maps | executed | Both translator checks and their enforcement fixtures passed. |
| `sync.sh` and `sync-tests/` | executed | `sync-tests/sync.test.sh` passed. The root audit session also ran the real `./sync.sh` successfully across all three installed homes. A read-only comparison found expected runtime state and known monotonic-sync residue; it did not show a tracked payload failing to install. |
| `.github/workflows/enforce.yml`, Dependabot, package lock | read only | Workflow wiring and deterministic installs were inspected. Current GitHub check status was not available locally. |
| Documentation and prior audits | read only | Project bootstrap, README, protocol, issues, handoff, and 2026-09-16 through 2026-09-18 audits were compared to code. No operational runbook directory exists. |
| Recent history | executed | Last 60 commits scanned for fix commits without test changes. |
| Credential persistence surfaces | executed/partial | Git history and tracked working tree were scanned content-free and were clean. The broad untracked scan found only vendor false positives under ignored TypeScript distributions. Home-directory transcript, history, cache, and vendor-config scans produced no accessible results under the sandbox, so those surfaces are recorded as not covered rather than clean. |
| Workspace duplicates | executed | Personal-code roots were searched; only this checkout was found. Linked `.worktrees/` are deliberate Git worktrees, not independent duplicate repositories. |
| Database, API, client polling, deployment runtime | not covered | This repository is a local governance harness with no database, application API, browser client, or deployable service. Their absence is not a defect. |

## Executive Summary

The harness has a strong architecture: one canonical Claude tree, deterministic Codex and Cursor projections, manifest-to-fixture closure, contract tests for both adapters, and CI that independently runs both suites and both port checks. The generated projections were current at the audited revision, and the sync and adapter contract tests passed.

The release state is nevertheless **not green**. Both primary test runners fail in the real task environment. The highest-risk failure is in the R-501 session-safety hook: a disappearing parent process makes a `ps` lookup return nonzero under `set -e`, so the hook exits before it writes the session registry. That converts a protection against cross-session overwrite into a silent no-op under exactly the process churn it is meant to tolerate. The two remaining failures show the suite is not hermetic: one fixture contradicts the required task-start lifecycle, and the Python push gate depends on an externally installed Ruff binary and fails open without it.

Top priorities:

1. Repair and test the R-501 disappearing-parent path so session registration cannot abort before writing the registry.
2. Make both suites green in a correctly classified task by isolating fixture state from the repository's required `.claude/task-tier.json`.
3. Make the Ruff fixture deterministic locally and in CI, while keeping the real configuration exercised.

## Operational Basics

| Basic | Status | Assessment |
|---|---|---|
| Tests run | **No, blocker** | Both primary runners execute but finish red: two enforcement failures and one hook-suite failure. |
| CI green | **Unverified, blocker** | CI is well wired, but local parity is red and no live GitHub status was available. A release cannot claim green CI from workflow text. |
| End-to-end gates execute | **Partial, blocker** | Adapter contracts pass and Codex was live-probed. Cursor host behavior and installed-home parity were not executed here. |
| Monitoring | **Yes for scope** | Rule-fire logs, session metrics, and explicit hook warnings exist. A hosted error tracker is not applicable to a local shell harness. |
| Rollback plan | **Partial** | Git reversion covers source. `sync.sh` intentionally never deletes installed residue and has no automated rollback, so an install rollback requires a known-good checkout plus manual residue review. |

## Findings

### P1-1 blocker: R-501 can exit before registering the session when its selected parent disappears

Governing rules: R-501 (check for a parallel session before the first edit), R-401 (tests must fail when behavior is wrong), and R-509 (a turn must not end on a red suite). Evidence: executed locally; `parallel-session-check.test.sh` failed before creating the expected registry.

`claude/hooks/parallel-session-check.sh:39-46`:

```bash
started_at() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'; }

MY_PID=$(session_pid)
MY_START=$(started_at "$MY_PID")
```

The file enables `set -euo pipefail` at line 11. If the PID selected by `session_pid` exits between selection and `started_at`, `ps` returns nonzero, the command substitution inherits the failed pipeline status, and the hook exits before line 63 writes `$REGISTRY`. The fixture's first invariant then fails at `claude/enforce/tests/parallel-session-check.test.sh:19`:

```bash
[ -s "$LOCK_DIR/$(key_for "$TREE_A")" ]
```

This was reproduced under Codex with an empty isolated lock directory. The failure is timing-sensitive, which explains why a synthetic run can pass while the full runner fails.

**Fix direction:** make parent-start-time discovery an explicit fallible probe and preserve a stable identity fallback without aborting registration. Add a deterministic fixture that supplies a disappearing or nonexistent selected PID rather than relying on race timing. **To confirm:** whether Codex, Cursor, and Claude expose a stable session identifier in the SessionStart payload that can replace process ancestry; if not, confirm that an empty start time cannot collide with a recycled PID before adopting it as fallback.

### P1-2 blocker: the required task ledger makes the hook suite fail

Governing rules: R-001/R-503 (task classification and ledger), R-401, and R-509. Evidence: executed locally; `post-compact-rules.test.sh` failed with `ledger section emitted with no ledger on disk`.

`claude/enforce/tests/post-compact-rules.test.sh:28-30`:

```bash
# The task-start ledger ... is re-injected when
# the working tree carries .claude/task-tier.json, and absent otherwise.
printf '%s' "$CTX" | grep -q 'Task ledger' && { echo "FAIL: ledger section emitted with no ledger on disk"; exit 1; } || true
```

The hook correctly discovers the current Git root and reads its ledger at `claude/hooks/post-compact-rules.sh:53-56`:

```bash
LEDGER="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/task-tier.json"
if [ -f "$LEDGER" ] && jq -e . "$LEDGER" >/dev/null 2>&1; then
  CTX+=$'\n\n## Task ledger (re-injected from .claude/task-tier.json)\n\n'
```

The test assumes the checkout has no ledger, while the mandatory task-start procedure creates one for this audit. As a result, the suite is red in any correctly classified task. This is fixture contamination, not a product-hook defect, but it blocks the operational release gate.

**Fix direction:** run both absence and presence cases from isolated temporary repositories and pass every relevant path through explicit test overrides. **To confirm:** whether the hook should gain a `CLAUDE_TASK_LEDGER` override or whether changing the fixture's working directory is sufficient without weakening the real Git-root behavior.

### P2-1: the local Python fixture prerequisite is undocumented and the gate fails open without it

Governing rules: R-401, R-509, and the CI principle that the same locked operation should run locally and remotely. Evidence: executed locally; `push-ruff-gate.test.sh` failed and the hook printed `ruff produced no parseable output, skipping (fails open)`. This is not evidence that Ruff enforcement is implemented incorrectly. CI explicitly installs the pinned prerequisite, while this local environment does not provide it.

`claude/hooks/push-ruff-gate.sh:55-64,81-84`:

```bash
if [ -n "${CLAUDE_RUFF_CMD:-}" ]; then
  RUFF="$CLAUDE_RUFF_CMD"
elif command -v ruff >/dev/null 2>&1; then
  RUFF="ruff"
elif command -v uvx >/dev/null 2>&1; then
  RUFF="uvx ruff"
else
  echo "push-ruff-gate: no ruff or uvx on PATH, skipping the Python AST gate (install ruff or uv)" >&2
  exit 0
fi

RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUFF check --config "$CONFIG" --output-format json --no-cache 2>/dev/null || true)
printf '%s' "$RESULTS" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  echo "push-ruff-gate: ruff produced no parseable output, skipping (fails open)" >&2
  exit 0
}
```

CI installs `ruff==0.16.6` in `.github/workflows/enforce.yml`, but the repository has no local locked Ruff runtime and the fixture does not bind `CLAUDE_RUFF_CMD`. The same checkout therefore has different enforcement depending on ambient tools. The fail-open policy is documented, so the defect is the operational dependency and red local suite, not an undocumented precedence violation.

**Fix direction:** provide one repository-declared, version-pinned Ruff execution path used by CI, local fixtures, and the push hook, with an explicit skip test separate from behavior tests. **To confirm:** whether the intended distribution model permits downloading on first use; if it does not, decide whether Ruff must become an installation prerequisite verified by `doctor.sh` or be bundled by the sync/install process.

### P2-2: one recent product fix had no corresponding test change

Governing rule: R-403. The last 60 commits contain one fix commit that changed product code without changing a test path:

```text
1f3e821 fix(enforce): redact the home path through a helper that works on bash 3.2 and 5.2 (#9) | no test change
```

This is a single instance, so the rubric rates it P2 rather than the P1 behavioral pattern triggered by three or more in 30 days.

**Fix direction:** add a regression case that executes the Bash 3.2-compatible redaction path, or document which existing behavior test failed before this commit if the history scan missed it because the test lives outside conventional test paths. **To confirm:** inspect the commit's full diff and PR evidence for a pre-existing fixture that was run but unchanged.

### P2-3: live Cursor enforcement remains an assumption

Governing rules: R-003 and the audit requirement to execute hand-authored adapters. `AGENTS.md` requires `./sync.sh` before relying on installed gates. The root audit session completed that sync successfully and compared the installed homes read-only. Checkout-level sync and adapter tests also passed. No live Cursor host was available, however, to prove that Cursor honors a block decision before the side effect occurs.

**Fix direction:** add a hermetic installed-home integration probe for all three hosts and retain a small owner-run live probe for host decision semantics that cannot be simulated. **To confirm:** whether Cursor exposes a supported noninteractive probe mode; if not, document the manual release checklist and last successful version/date.

## Architecture & Design

The canonical-source and projection model is appropriate. `claude/` owns policy, `translate/` owns deterministic rendering, and the port maps explicitly distinguish generated files from hand-authored adapters. The current translator checks passed for both projections. The main architectural risk is the boundary between repository state and ambient machine state: live homes, process ancestry, task ledger files, and externally installed linters still influence whether the same commit is green.

## Code Quality

The shell code generally names failure behavior and uses shared helpers. The current defects cluster around implicit environment inputs rather than duplication or naming. ShellCheck is wired at error severity in CI, but was not independently run in this sandbox. No dead application code or client polling primitives apply to this repository.

## Security

The harness has layered command, credential, destructive-action, and role-boundary guards. Codex adapter contracts and the prior live deny probe show that normal tool-mediated writes are covered. Shell-write protection still depends on recognizing a literal target from a Bash command, but the current branch handles common redirections and mutating verbs and documents runtime-computed targets as an accepted boundary.

## Credential Exposure Scan

- Git history across all refs: content-free path scan found no full-length matches.
- Tracked working tree: no full-length matches.
- Broad working tree including ignored dependencies and linked worktrees: matches occurred only in TypeScript distribution/translation files under `node_modules`; these are false positives caused by localized diagnostic text and are not credentials.
- Claude session transcripts, shell histories, vendor CLI files, process artifacts, and editor caches: not covered under this sandbox. The scan emitted no accessible paths or counts, which is not evidence of cleanliness.
- The project issue register already records owner actions to rotate a GitHub PAT and purge named transcripts. Those remain **P0 remediation work** until the owner confirms rotation and purge. No secret value was read or copied into this report.

Required remediation for any real full-length match remains: rotate at the vendor first, purge the persistence surface second, and keep the PreToolUse secret-scan hook installed. Git-history rewriting is appropriate only after confirming repository visibility and collaborator impact.

## Database

Not applicable. The harness carries no schema, migrations, connection pool, or database query layer.

## API Design

Not applicable to a network API. Hook JSON is the effective interface, and adapter contract fixtures cover its event and decision shapes.

## Performance

No browser polling exists. Hook latency has a dedicated fixture, and push-time work is scoped to outgoing diffs. The largest performance risk is external-tool startup and network resolution (`uvx ruff`) on a push path, which is also the prerequisite gap in P2-1.

## Testing

Contract and closure coverage is extensive, but the current state is red: enforcement fixtures fail on R-501 and Ruff, while hook fixtures fail on ledger contamination. The runner correctly reports failures instead of accepting partial passes. The largest missing E2E check is a live Cursor decision-enforcement probe.

## Dependencies & Supply Chain

The Node dependency lock exists and CI uses `npm ci`. Ruff is version-pinned only in the workflow, not in a repository-local runtime contract. GitHub Actions are on explicit major versions, and Dependabot is present. No network vulnerability audit was run in this restricted environment.

## Deployment & Infrastructure

This is an installed local harness, not a containerized service, so Docker and health endpoints are not applicable. `sync.sh` is the deploy mechanism. It is intentionally non-deleting, which avoids destructive upgrades but leaves stale installed files requiring manual cleanup. The real sync completed successfully from the root audit session.

## Bug Fix Discipline

The last 60 commits were scanned. One qualifying unpaired fix was found, listed as P2-2. The threshold for a P1 optimism-driven-debugging pattern was not met.

## Runbook-vs-Code Drift Scan

No `docs/runbooks/` or similarly named operational runbook exists. Setup and operational guidance live in `AGENTS.md`, `README.md`, `claude/SETUP.md`, `claude/PROTOCOL.md`, and the session handoff. The project-local instruction to run `./sync.sh` matches code intent and the install completed successfully during this audit.

## Workspace Hygiene

Searching `~/Desktop/code`, `~/code`, and `~/projects` found only `/Users/iangreenough/Desktop/code/personal/tools/agent-governance`. The `.worktrees/` entries inside it are linked worktrees and should not be treated as duplicate repositories. The working tree was clean before the report was added.

## Tech Debt Register

| Debt | Risk | State |
|---|---|---|
| R-501 process-ancestry identity is race-prone | High | P1-1, open |
| Fixture behavior depends on repository task ledger | High | P1-2, open |
| Ruff availability/version is ambient outside CI | Medium | P2-1, open |
| Live Cursor semantics lack a repeatable release probe | Medium | P2-3, open |
| Codex runtime-computed shell write targets are not statically observable | Medium | Documented adapter boundary |
| Credential rotation and transcript purge | Critical | Owner action already tracked; completion unverified |

## Prioritized Recommendations

| Rank | Direction | Impact | Effort |
|---|---|---:|---:|
| 1 | Make R-501 registration survive disappearing parent processes and add a deterministic regression fixture. | H | M |
| 2 | Isolate the post-compaction fixture from real task-ledger state. | H | S |
| 3 | Define one pinned Ruff runtime contract shared by local runs, CI, and push enforcement. | H | M |
| 4 | Run a successful installed-home sync/parity check and a live Cursor deny probe before the next harness release. | H | M |
| 5 | Complete and document the already-tracked PAT rotation and transcript purge. | H | M |
| 6 | Pair the untested historical fix with a regression test or record the existing reproducer. | M | S |
