# Let the Codex CLI edit test files under its own hook adapter

Ticket: IAN-174. Branch: `fix/codex-guard-under-codex`. Tier: standard.

## Summary

R-907 names the Codex CLI as the author of every slice's failing test, and
`codex-test-author-guard.sh` enforces that by asking whenever a Write or Edit
targets a test file. The guard also runs under Codex itself, through
`codex/hooks/codex-hook-adapter.sh`, and had no way to tell that its caller was
Codex. Because the adapter translates an ask into a deny (Codex hooks cannot
pause for a confirmation), the rule denied its own named author: on 2026-09-19
in template-fastapi-nuxt a `codex exec -s workspace-write` run was blocked by
this hook when writing test files.

The adapter now exports `CLAUDE_HOOK_RUNTIME=codex` into every hook child it
runs, and the guard exits silently on exactly that value. A Claude Code session
sets no such variable, so R-907 still asks there, which is the behavior the rule
exists for.

The same Codex run also could not execute the Python test it had written:
`uv run pytest` inside the `workspace-write` sandbox fails with
`Operation not permitted` on uv's cache directory, which lives outside every
writable root. That is a documentation gap rather than a code defect, and the
`tdd-gated-dispatch` skill now carries the fix.

## What changed

- `codex/hooks/codex-hook-adapter.sh` exports `CLAUDE_HOOK_RUNTIME="codex"` once,
  near the top, so every hook child inherits it on both dispatch paths: the
  event's own hook list and the synthesized write events the adapter builds out
  of a shell command's write targets. The adapter's header gains a fifth
  numbered item describing the difference this handles, in the shape of the four
  already there.
- `claude/hooks/codex-test-author-guard.sh` exits 0 with no output when
  `CLAUDE_HOOK_RUNTIME` is exactly `codex`, placed beside the existing
  `CODEX_TEST_GUARD=off` escape hatch. Its header stops claiming that the Codex
  CLI never reaches this guard, which was the false premise behind the bug.
- `claude/enforce/tests/codex-test-author-guard.test.sh` gains ten assertions:
  five for the Codex runtime (Write and Edit, Python and TypeScript,
  `conftest.py`), two for the ask surviving an unset variable, and three for the
  ask surviving a non-codex value, including `codex-review`, which pins the
  comparison as equality rather than a prefix.
- `claude/enforce/tests/codex-adapter-contract.test.sh` makes its recording hook
  report the `CLAUDE_HOOK_RUNTIME` it actually saw, runs the adapter under
  `env -u CLAUDE_HOOK_RUNTIME` so the ambient environment cannot supply the
  marker, and asserts the marker on both dispatch paths.
- `claude/skills/tdd-gated-dispatch/SKILL.md` gains a section on running uv and
  pytest inside the `workspace-write` sandbox, and its claim that "Codex runs
  outside Claude's hooks" is corrected to say what the adapter does and does not
  see.
- `claude/rulebook/cost.md` (R-907's spec) and `claude/enforce/manifest.json`
  record the marker and drop the same false premise; the manifest hash file is
  regenerated for the changed hooks and fixtures.

## Architectural decisions

**Chosen: an environment marker the adapter exports once.** The adapter is the
only thing that runs the Claude hooks under Codex, so a variable it sets is a
sound proxy for "the caller is Codex". Exporting it once at the top rather than
per dispatch means a hook added to any matcher is marked without a second place
to remember it.

**Alternative: a field in the hook payload.** The adapter already rewrites the
payload for its apply_patch and shell-write replays, so it could have added a
`runtime` key next to `agent_type`. Rejected because the payload is only
rewritten on some paths, and a hook reached on the untouched path would have
seen nothing; the environment covers every path by construction.

**Alternative: widen the existing `agent_type` check to a `codex` value.**
Rejected because `agent_type` is Claude Code's own field describing which
subagent is writing, and overloading it would make a Codex run indistinguishable
from a Claude subagent named codex in any hook that reads it.

**Equality, not a prefix.** `CLAUDE_HOOK_RUNTIME=codex-review` still asks. A
marker that distinguishes runtimes is worth nothing if a neighbouring runtime
name inherits the silence, and the fixture pins that case so a later "starts
with" refactor fails a test.

**The marker is assigned, never read from the caller.** The adapter does not
honor an inherited `CLAUDE_HOOK_RUNTIME`, and the contract fixture runs it under
`env -u CLAUDE_HOOK_RUNTIME` to prove the adapter supplies it. A marker the
environment could supply would be a marker a Claude session could inherit, which
is the hole rather than the fix.

## Testing

One TDD slice under the R-412 lock: `tdd.sh open`, the failing fixtures,
`tdd.sh red` (RED on both files, baseline 93 passing outside),
`tdd.sh validate test-author` (VALID, 2 changed paths, both inside the boundary),
the test commit, the implementation, `tdd.sh green` (GREEN, 93 passing outside,
baseline unchanged), the fix commit, `tdd.sh close`.

Test author: `test-author` subagent (fallback: Codex usage limit reached,
resets 2026-09-21 02:26). The Codex dispatch ran and returned
`You've hit your usage limit`, which is exactly the R-907 Degradation case.

Not covered by any fixture: the guard and the adapter are verified separately,
never in one end-to-end run where Codex actually edits an existing test file.
The contract fixture cannot close that gap because its `run_adapter` sets
`CODEX_TEST_GUARD=off` for every case. A live Codex probe is the only real proof
and it is blocked until the quota resets; it is worth running then.

Also unverified by test: the uv documentation. The sandbox behavior it describes
is read off the Codex binary's own configuration schema
(`sandbox_workspace_write.writable_roots`, `exclude_tmpdir_env_var`,
`exclude_slash_tmp`, and the core inherit list of
`shell_environment_policy`) plus the reported failure, not off a run that
succeeded, for the same quota reason.

## What the review changed

The pre-merge review returned seven findings, six MEDIUM and one LOW, and three
of them were defects in this work rather than notes on it.

The one worth reading twice is finding 3. The incident report said new test
files were created successfully while edits of existing ones were denied, and
this PR had written that asymmetry into four places as the diagnosis. It cannot
be true of this guard, which reads `Write` and `Edit` identically, and the
reviewer reproduced a pre-fix deny on an `Add File` of a test path. So either
the report conflated two runs, or those creates reached no `Write|Edit` gate at
all, which would mean `secret-scan`, `structure-gate`, `content-gate` and
`protected-path-guard` missed them too and that route is still open. The
asymmetry is gone from all four places and the open question is recorded on
IAN-174 rather than shipped as an explanation.

Finding 4 is the one that narrows what this PR should be understood to claim.
The marker names the runtime, not the role, while R-907's invariant is about
role. The guard is now silent for any Codex run that writes a test file, not
only the orchestrated test-author dispatch, and only inside that dispatch does
`tdd.sh validate test-author` prove the paths. Keying the silence on a slice
marker the orchestrator sets and the adapter forwards is the real answer and is
a separate change; the residual scope is stated in R-907 and in the guard's
header so it is visible rather than implied.

The rest: the contract fixture's write-event case passed with the synthesized
dispatch stubbed out (finding 1), nothing exercised the guard and the adapter
together on the defect's own `apply_patch` shape (finding 2), a guard silenced
by the marker wrote no telemetry at all (finding 5, now a `codex-runtime` rule
fire placed past the test-file decision so it records only where the ask would
have been), and the uv section named a macOS cache path uv does not use
(finding 6) while over-claiming the `shell_environment_policy` default
(finding 7). Both now defer to `uv cache dir` and to what is observable.

## Reflection

What I understand now that I did not at the start: the adapter is not a passive
translator. Turning an ask into a deny is a decision, and every hook that asks
rather than denies becomes a hard block under Codex. This guard is the one where
that inversion contradicts the rule the guard enforces, but it is unlikely to be
the only hook whose ask means something different once Codex is the caller, and
the marker this PR adds is the general hook for answering that question. The
adapter's header now says so explicitly.

What I got wrong first: I reached for the payload before the environment,
because the adapter's existing rewrites made a payload field look like the
established pattern. It is not, and that reading would have shipped a marker
that covered the apply_patch path while leaving the shell-write path, which is
the path Codex actually uses most, unmarked.

Second thing I got wrong: the first `tdd.sh red` came back "the rest of the
suite is red" and I read it as a stale installed harness needing a sync. It was
not. `hook-hashes.txt` covers the fixture files themselves, so editing a fixture
drifts the manifest and reds `hook-hashes-closure`. The RED step of any slice
that touches a fixture in this repository needs the manifest regenerated first,
and that is a cost of the closure check nobody had paid yet.

## Codex review

Reviewer: Claude subagent (opus), fallback: Codex usage limit reached, resets
2026-09-21 02:26. Seven findings, all dispositioned.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | The contract fixture's synthesized-write case passed with `replay_shell_writes()` stubbed out | Fixed. The case now asserts a `Write` event with the marker, and was proved to fail against the stubbed adapter. |
| 2 | MEDIUM | Nothing exercised the guard and the adapter together on an `Update File` of a test path | Fixed. A new contract case runs the real adapter without `CODEX_TEST_GUARD=off`, and fails against an adapter with the export removed. |
| 3 | MEDIUM | The create-versus-edit asymmetry in the diagnosis is not reproducible | Fixed. Removed from all four places; the open question is recorded on IAN-174. |
| 4 | MEDIUM | The marker names the runtime, R-907's invariant is about role, so the silence is wider than the rule | Answered and scoped. The residual scope is now stated in R-907 and the guard header. Narrowing it needs a slice marker the orchestrator sets, which is a separate change. |
| 5 | MEDIUM | The bypass wrote no telemetry, because the exit sat before `log_rule_fire` | Fixed. The check moved past the test-file decision and logs a `codex-runtime` fire. |
| 6 | MEDIUM | The uv section named `~/Library/Caches/uv` on macOS, which uv does not use | Fixed. The section and the `--add-dir` form now defer to `uv cache dir` and `uv python dir`. |
| 7 | LOW | The `shell_environment_policy.inherit` default was asserted beyond what is verifiable | Fixed. Softened to the observable claim; the recommended inline form works under either default. |

Two notes the reviewer raised that are not findings. The diff grew during the
review (the port regeneration landed mid-pass) and its findings cover the full
range. The `secret-scan` hook fired on a `strings` dump of the Codex binary run
while verifying the sandbox config keys; the matches are field names in a
compiled Rust executable, not a credential, but the raw bytes did reach the
session transcript.

## Follow-ups this PR does not do

- Re-derive the 2026-09-19 incident from a `CLAUDE_CODEX_HOOK_DEBUG` log or a
  live probe once the Codex quota resets, and close the question of whether a
  write route exists that reaches no `Write|Edit` gate.
- Key the R-907 silence on the test-author dispatch rather than the runtime.
- Run one live `codex exec` editing an existing test file, which is the only
  real proof of the fix and is the gap no fixture closes.
- `claude/enforce/tests/hook-latency.test.sh` is flaky at its budget line (one
  failure in three consecutive runs at 296ms, 354ms and 279ms against budgets
  of 294ms, 318ms and 288ms). It measures the installed `~/.claude`, so it is
  unrelated to this branch, but it reds `tdd.sh red` for any slice when it
  trips.
