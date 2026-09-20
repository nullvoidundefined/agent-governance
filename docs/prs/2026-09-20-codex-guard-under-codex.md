# Let the Codex CLI edit test files under its own hook adapter

Ticket: IAN-164. Branch: `fix/codex-guard-under-codex`. Tier: standard.

## Summary

R-907 names the Codex CLI as the author of every slice's failing test, and
`codex-test-author-guard.sh` enforces that by asking whenever a Write or Edit
targets a test file. The guard also runs under Codex itself, through
`codex/hooks/codex-hook-adapter.sh`, and had no way to tell that its caller was
Codex. Because the adapter translates an ask into a deny (Codex hooks cannot
pause for a confirmation), the rule denied its own named author: on 2026-09-19
in template-fastapi-nuxt a `codex exec -s workspace-write` run created new test
files without trouble and had every edit of an existing test file blocked by
this hook.

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

Pending. Codex is over quota until 2026-09-21 02:26, so this section is filled
from the R-517 fallback (a separate Claude agent on a model at least as strong
as the authoring session) before the PR merges.
