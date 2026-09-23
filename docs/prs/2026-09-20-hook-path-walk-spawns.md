# Walk a written path with parameter expansion, not one process per component

Refs: IAN-183

## Summary

`claude/enforce/tests/hook-latency.test.sh` failed and passed alternately on the
same hooks. IAN-183 recorded three consecutive runs with no change between them:
296ms against a 294ms budget, 354ms against 318ms, and 279ms against 288ms. The
budget is not a fixed number of milliseconds. It is six times a bare-spawn
control measured in the same run, so both the measurement and the line it is
compared against move, and under load the PreToolUse `Write|Edit` chain crossed
it.

Widening the multiplier was refused (R-204). The chain was close to the line
because it really was doing avoidable work, and the work is countable without a
clock. Three hooks in that chain resolved the directory of the file being
written by walking the path one component at a time, starting a `dirname` or a
`basename` process for every directory level. A fourth carrying the same two
shapes landed on `main` while this branch was open (see "The fourth hook"), and
a fifth was found by the R-517 review, hidden behind an early return (see "What
the review caught"). The original three:

- `hooks/protected-path-guard.sh`, `physical_path`'s deepest-existing-ancestor
  loop, one `basename` plus one `dirname` per level, plus one more `dirname` at
  the call site and a second per-level loop in `repo_root_for`
- `hooks/structure-gate.sh`, `find_package_file`'s walk toward the nearest
  `package.json`, one `dirname` per level for up to six levels, run twice per
  event
- `hooks/content-gate.sh`, the R-302 climb-depth check's walk to an existing
  directory, one `dirname` per level and unbounded

Bash removes a trailing path component with `${path%/*}` and takes the last one
with `${path##*/}`, both without starting anything. Every one of those loops
now does that.
No budget, multiplier, or floor in `hook-latency.test.sh` was touched.

This is the residual IAN-115 measured and left open. That ticket's outcome note
reads: "the Write chain runs near its 6x budget (protected-path-guard 63 ms,
content-gate 40 ms, secret-scan 37 ms, structure-gate 35 ms); not ticketed yet",
and its PR (#67) listed the same thing under "Out of scope, reported instead".
IAN-115 fixed a different and real cost, one `cmp` per tracked file in
`harness-sync.sh`'s drift check, which the latency fixture never measured
because its sandbox HOME makes that hook exit early. That is why closing IAN-115
did not stop the flake.

## Measurements

Processes started by the whole `Write|Edit` chain for one event, counted with
pass-through wrappers on PATH that log each start and then exec the real tool:

| Path written | Before | After |
|---|---|---|
| `/x/a.ts` | 74 | 61 |
| `/x/b/c/d/a.ts` | 92 | 61 |
| `/x/b/c/d/e/f/g/h/i/j/a.ts` | 118 | 61 |

About five processes per extra directory level before, none after. Those counts
were taken in a container with no ticket tracker configured, which, as the
review found and the section below records, understates the chain: with a
tracker present a fifth hook runs and the pre-fix growth is larger again.

Per-hook wall clock over 20 runs against the installed chain on an idle
four-CPU container, the fixture's own `Write` payload:

| Hook | Before | After |
|---|---|---|
| `protected-path-guard.sh` | 63ms | 36ms |
| `structure-gate.sh` | 43ms | 25ms |
| `content-gate.sh` | 38ms | 30ms |
| chain total | about 275ms | about 222ms |

`secret-scan.sh` (49ms, nine `grep` spawns) is untouched and is now the chain's
most expensive hook. It does not scale with path depth, so it is a separate
question from this one.

`hook-latency.test.sh`'s own `PreToolUse:Write` line, five consecutive runs
each, same container:

| | Measured | Control | Budget | Ratio |
|---|---|---|---|---|
| Before | 247 to 255ms | 54 to 63ms | 324 to 378ms | about 4.6x |
| After | 205 to 225ms | 57 to 66ms | 342 to 396ms | about 3.5x |

The multiplier is 6, so the margin went from about 1.3x to about 2.5x.

Under load, with the fixture invoked directly while both fixture suites ran
concurrently on four CPUs and with no settle pause, the chain measured 774ms
against a 642ms budget (7.2x) and failed. After the change, six consecutive runs
under the same load measured 4.3x to 5.7x and all passed.

Through the real runners, which is how the fixture actually runs, three rounds
of `enforce/tests/run-tests.sh` and `hooks/tests/run-tests.sh` started together
reported `ok hook-latency.test.sh` every time.

## What changed

- `claude/hooks/protected-path-guard.sh`: `physical_path` strips trailing
  slashes once up front, then removes one component per turn with parameter
  expansion instead of `basename` and `dirname`. The trailing-slash strip is
  load-bearing: `${target##*/}` on `a/b/` is the empty string where `basename`
  gives `b`. `repo_root_for`'s walk does the same. The call site takes the
  parent of `physical_path`'s result by expansion rather than through a
  `dirname` process, since that result is already absolute and unslashed.
- `claude/hooks/structure-gate.sh`: `find_package_file` walks by expansion. It
  runs twice per event, so at six levels it was twelve processes spent on a
  question about the path alone.
- `claude/hooks/content-gate.sh`: the R-302 depth check walks by expansion.
- `claude/hooks/scope-widening-gate.sh`: the same two shapes, `physical_path`
  and `nearest_existing_directory`. This one is IAN-262, not IAN-183, and its
  commit's `Refs:` trailer says so. See the note below.
- `claude/hooks/ticket-at-start-gate.sh`: the same two shapes again, in
  `resolve_edit_directory` and `resolve_edit_path`. Found by the R-517 review
  rather than by the original sweep. See "What the review caught" below.
- `claude/enforce/tests/hook-path-walk-budget.test.sh`, new: runs the chain read
  from `settings.json` over a shallow path and a path nine levels deeper and
  fails when the second starts more than six processes more than the first.
- `claude/enforce/hook-hashes.txt`: regenerated for the five changed hooks and
  the new fixture.

### The fourth hook (IAN-262), and the new fixture earning its place

`scope-widening-gate.sh` did not exist when this branch was cut. It arrived on
`main` in #96 (R-212) and joined the `Write|Edit` chain, carrying its own
`physical_path` with a `basename` plus a `dirname` per component and its own
`nearest_existing_directory` with a second per-component `dirname` loop, which
is the same defect in the same chain.

It is tracked as IAN-262 rather than folded into IAN-183, because it is a
different hook from a different change by a different author, and R-212 puts
that kind of widening to the user rather than reporting it afterwards. The user
asked for it to be its own ticket.

It rides on this branch because it cannot sensibly ride anywhere else: IAN-183's
fixture reads the chain from `settings.json`, so with this hook unfixed and in
the chain the fixture is red, and a branch cannot ship a test it fails. This PR
therefore lands as an R-512 bundle (label `bundle`, rebase-merged) rather than a
squash, so each ticket keeps exactly one commit on `main`.

The two commits are ordered IAN-262 first, IAN-183 second, and the order is
load-bearing rather than incidental. Taken the other way round, the commit
adding `hook-path-walk-budget.test.sh` would land on `main` while
`scope-widening-gate.sh` still walked per component, so `main` would carry a
commit whose own new fixture fails. Fixing the fourth hook first means every
commit in the bundle is green on its own, which is what makes a rebase-merge
safe to bisect across.

Rebasing onto that `main` turned this branch's own new fixture red, at 27 extra
processes for nine extra levels against a budget of 6. The chain measured 252 to
259ms where it had measured 205 to 225ms before the new hook, so the margin this
change had just bought was already being spent. Applying the same expansion to
both of its loops returns the chain to flat in depth and to 228 to 238ms, about
3.7 times its control.

This is the clearest evidence available that the fixture was worth adding: it
caught a fresh instance of the exact regression it guards, on the same day, from
a change that had nothing to do with latency and whose author had no reason to
think about process counts.

### What the review caught (the fifth hook, IAN-183)

The R-517 review found that the fixture above passed in this container **by
accident**, and the reason is worth more than the fix.

`hooks/ticket-at-start-gate.sh` is the ninth hook in the same `Write|Edit`
chain and carries the same defect twice, in `resolve_edit_directory` and
`resolve_edit_path`. It was missed by the original sweep because its second
line returns early when `$HOME/.claude/TICKET-TRACKER.json` is absent, before
either walk runs. The container this work was developed in has no tracker, so
the hook exited immediately and the fixture measured a shorter chain than any
real machine runs. Reproduced both ways on the same commit:

| `$HOME/.claude/TICKET-TRACKER.json` | Fixture verdict |
|---|---|
| absent (this container) | growth 0, PASS |
| present (R-605 requires it) | growth 9, FAIL |

A fixture whose verdict depends on the developer's own configuration is not a
gate. The fixture therefore now creates its own `TICKET-TRACKER.json` in a
sandboxed HOME and runs the chain against that, so every hook takes its full
path on every machine and the count means the same thing everywhere. The fifth
hook's walks are rewritten like the other four, and the chain is flat again at
73 processes on both probe paths.

This is folded into IAN-183 rather than given its own ticket, unlike the fourth
hook: it is not adjacent work that happened to be nearby, it is a defect in
IAN-183's own gate, which claimed a property of the whole chain that it was not
actually measuring.

The review also found a straight bug in the fixture's counting.
`grep -c '' "$log" || echo 0` prints `0` **and** exits 1 on an empty log, so the
`|| echo 0` fallback fires as well, the substitution captures `0\n0`, and the
subtraction below dies with an arithmetic syntax error. The deliberate
"chain started no shimmed process" guard, which exists precisely to stop a
vacuous pass, was therefore unreachable. It counts with `wc -l` now, which
prints 0 and exits 0.

**Answered, not fixed:** both probe paths sit outside any git work tree, so the
in-repo branches of these hooks (protected-path-guard's second `physical_path`
call, ticket-at-start-gate's `resolve_edit_path` past its repository check) are
never counted, and that is the path every real session Write takes. No hook
currently regresses there, since all five are fixed, so this is a coverage gap
rather than a false pass. Closing it means the fixture building a throwaway git
repository and probing inside it, which is a larger change to a fixture that is
already doing its job; it belongs in its own ticket rather than in this one.

## Architectural decisions

- **Chosen: count processes, do not time them.** The new fixture makes no claim
  about milliseconds. A process count is the same number on a fast laptop and a
  loaded container, so it cannot itself become a second flaky timing check.
  This is the shape IAN-115 arrived at for the same class of defect in
  `harness-sync.sh` (PR #67, case 3f), after Copilot pointed out that a timing
  proxy can pass a per-file loop on a fast runner and fail a correct batch on a
  slow one.
- **Chosen: assert flatness in depth, not an absolute ceiling.** An absolute
  per-event process budget would have to be revised every time a hook is added
  to or removed from the chain, and would fail for reasons unrelated to its
  subject. The invariant that matters is that per-event cost does not scale with
  the path, which is exactly what regressed, and it holds however many hooks the
  chain carries.
- **Rejected: a shared path-walking helper sourced by the five hooks.** R-308
  prefers reuse, but a sourced file costs each hook in the chain a read on every
  event, which is the opposite of the goal, and it would add a new file to the
  R-203 enforcement surface. The idiom is a handful of lines in each place.
- **Rejected: calling a bash function through command substitution.** A helper
  invoked as `parent=$(path_parent "$x")` forks a subshell per call. It is
  cheaper than exec'ing `/usr/bin/dirname` but not free, and it would leave the
  new fixture green while the real cost stayed. The loops expand in place.
- **Not changed: `secret-scan.sh`.** It is now the chain's most expensive hook
  at 49ms over nine `grep` spawns, but its cost is fixed in path depth, it is a
  different kind of change, and the chain passes with margin without touching
  it.

## Testing

- Red first. With only the new fixture added and no hook touched,
  `bash claude/enforce/tests/hook-path-walk-budget.test.sh` printed
  `FAIL: the Write|Edit chain starts 44 more process(es) for a path 9 levels
  deeper (budget 6): 73 for '/x/a.ts' against 117 for
  '/x/b/c/d/e/f/g/h/i/j/a.ts'` and exited 1. After the three hook changes it
  prints `61 spawns at depth 2, 61 at depth 11 (growth 0, budget 6)` and passes.
- The parameter expansions were differential-tested against `dirname` and
  `basename` over absolute, relative, single-component, dotted, hidden, and
  space-containing paths before being wired in. No difference on any input the
  loops can receive.
- `protected-path-guard.test.sh`, `structure-gate.test.sh`,
  `content-gate.test.sh`, and `convention-paths-scope.test.sh` all pass.
- `hook-hashes-closure.test.sh` passes after the regeneration, at 246 entries
  over 246 covered files.
- Both fixture suites were run concurrently three times. `hook-latency.test.sh`
  reported `ok` in all three rounds.

## Known red fixtures, unrelated to this change

Both were confirmed red on an untouched `origin/main` worktree in this same
container before anything here was written:

- `enforce/tests/run-fixture-shards.test.sh` was red on the branch point for this reason and is FIXED on current `main` by #96's root-uid unblock. It passes as root now. The note is kept because the `tdd.sh` refusal quoted below predates that fix.
  The case makes `.git/index` unreadable with `chmod 000` and expects git to
  fail. The container runs as root, and root ignores file permission bits, so
  git succeeds and the case does not. This is IAN-196.
- `hooks/tests/session-end.test.sh`, case "a failed render never prunes the
  all-completed log".

Three further fixtures (`judge-diff`, `push-eslint-gate`,
`single-file-folder-reminder`) failed during an early concurrent run and are not
regressions either. They build sandbox repositories and commit into them, and
they were being run against a measurement sandbox HOME that carried no
`.gitconfig`, so git refused with "unable to auto-detect email address". They
pass alone and they pass concurrently once the sandbox HOME has an identity.

## R-412 report: `tdd.sh` could not certify this slice

`tdd.sh open` worked. `tdd.sh red claude/enforce/tests/hook-path-walk-budget.test.sh`
refused:

```
jq: error: Could not open file /root/.claude/enforce/role-policy.json: No such file or directory
tdd.sh: the rest of the suite is red, so nothing here is a clean RED:
  claude/enforce/tests/hook-latency.test.sh
  claude/enforce/tests/run-fixture-shards.test.sh
```

Three separate things are worth recording:

1. `hook-latency.test.sh` is red in a fresh cloud container for a setup reason,
   not a timing one. It reads `$HOME/.claude/hooks` and `$HOME/.claude/settings.json`
   by deliberate design, and a fresh container has never run `./sync.sh`, so the
   fixture fails with `jq: error: Could not open file
   /root/.claude/settings.json`. IAN-183 records that this exact reading was
   twice misdiagnosed as the flake. It is the same fixture blocking the RED step
   of the ticket that exists to fix it.
2. `run-fixture-shards.test.sh` is IAN-196, above.
3. `tdd.sh` itself reads `role-policy.json` from `$HOME/.claude` rather than
   through `CLAUDE_TDD_HOME`, which `enforce/harness-root.sh` already binds to
   the checkout, so it emits a `jq` error in any container with no installed
   harness.

The consequence is the one IAN-183 describes: `tdd.sh red` certifies a slice
only when the whole suite is otherwise green, so two fixtures that are red for
container reasons block the RED step of every slice, including this one. The
R-403 discipline was followed by hand instead, and the red-then-green evidence
is recorded under Testing above.

## Residual, not fixed here

`SessionStart:resume` is now the thinnest of the three chains the latency
fixture measures. Invoked directly under two concurrent suites with no settle
pause, it measured 423ms and 428ms against a 402ms budget and failed twice in
six runs. It passed in all three rounds through the real runners, because
`run-fixture-shards.sh` waits up to 60 seconds for load to fall below the CPU
count before starting a serial fixture.

That chain is not spawn-bound the way the `Write|Edit` chain was.
`session-start.sh` costs 108ms over 21 processes and `parallel-session-check.sh`
74ms over 9, so both are doing real work (git, process listing, file hashing)
rather than wasting starts, and its own floor comment already records that the
shared floor never had honest headroom for it. Nothing here made it worse, since
none of its hooks were touched. It wants its own ticket and its own measurements
rather than a change smuggled into this one.
