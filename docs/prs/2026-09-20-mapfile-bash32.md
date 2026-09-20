# Two scope guards were failing open on macOS

**Ticket:** IAN-267
**PR:** #105
**Branch:** `fix/mapfile-bash32`

## Summary

`#96` merged earlier today and introduced `mapfile` into `scope-widening-gate.sh` and `commit-message-guard.sh`. `mapfile` is a bash 4 builtin and macOS ships GNU bash 3.2.57, so on the machine this harness actually runs on, both hooks aborted at that line, emitted nothing, and were read as an allow. R-212's scope gate and R-214's out-of-scope commit gate stopped enforcing, silently, for about four hours.

This replaces both with a `while IFS= read -r` loop and adds a fixture that holds the bash 3.2 floor for the whole class rather than for these two lines.

## What changed

- `claude/hooks/scope-widening-gate.sh`: `mapfile -t SCOPE` becomes an explicit array build.
- `claude/hooks/commit-message-guard.sh`: the same, with `scope_line` added to the function's `local` list so the loop variable does not leak.
- `claude/enforce/tests/bash32-builtin-floor.test.sh`, new: greps every hook for bash 4 only constructs (`mapfile`, `readarray`, associative arrays, `${var^^}` and `${var,,}`, `&>>`), skipping comment lines, and adds a behavioural anchor asserting the scope gate does not abort with "command not found" or "unbound variable".
- `claude/enforce/manifest.json`: the new fixture recorded against R-212 and R-214.
- `claude/enforce/hook-hashes.txt`: regenerated with `CLAUDE_INTEGRITY_ROOT` pointed at the checkout.

## Architectural decisions

**Chosen: a class fixture rather than a regression test for `mapfile`.** A test asserting "no `mapfile` in `scope-widening-gate.sh`" would have caught this instance and nothing else. The failure mode is not `mapfile` specifically; it is that a hook written on bash 5 CI can use anything bash 5 has, and the failure appears only on a developer's machine, as silence. The fixture therefore enumerates the constructs bash 3.2 lacks.

**Alternative rejected: requiring bash 4+ via a shebang or a preflight check.** Changing every hook's shebang to `#!/usr/bin/env bash` does not help, because that still resolves to 3.2 on macOS. Requiring the owner to install a newer bash would fix the symptom by changing the environment rather than the code, and would leave every fresh checkout on a stock Mac broken until someone remembered.

**Alternative rejected: making the hooks fail closed on an internal fault.** That is the more general fix and is genuinely attractive, since `enforce/README.md` already says a guard fails closed by structure. It is also a much larger change across every hook, and a wrong turn here blocks the user's tool calls rather than letting them through. Worth its own ticket; not smuggled into a bug fix.

**Why the behavioural anchors are in the same fixture.** The greps are a proxy for the real property, so each guard is also driven end to end and asserted to emit its decision.

The first version of that anchor was wrong, and the review caught it. It asserted only that the output did not contain `command not found` or `unbound variable`, which an empty output satisfies. Empty output is precisely the IAN-267 fail-open signature, so the anchor passed against a guard sabotaged into silence. Asserting the absence of an error cannot detect a fail-open; only asserting the presence of the decision can. Both anchors now assert `permissionDecision`, with in-scope negative controls so they cannot pass by firing unconditionally.

**The limit of the anchors, measured rather than assumed.** A parse-time error kills a hook before it writes anything, and the anchors catch that whether or not the construct is listed: sabotaging a scratch copy with `;;&` turns the anchor red. An expansion error does not kill it. `${v^^}` under bash 3.2 prints "bad substitution", fails that one command, and execution continues, so a hook can carry on with a wrong value and still emit a decision. The original break was fatal only because `mapfile` left `SCOPE` unset and the next line read it under `set -u`. The residual gap is therefore an unlisted bash 4 construct that corrupts a value without aborting, which no fixture of this shape catches; the per-guard behavioural fixtures are what would, run on the floor.

## Testing

Test first, per R-403. `bash32-builtin-floor.test.sh` was written before the fix and failed on bash 3.2.57 with both the `mapfile` grep and the behavioural anchor red. After the fix, on the same shell:

| Fixture | Before | After |
|---|---|---|
| `bash32-builtin-floor.test.sh` | FAIL (new) | pass |
| `scope-widening-gate.test.sh` | FAIL, 8 assertions | pass |
| `finding-ledger.test.sh` | FAIL, 11 assertions | pass |
| `commit-message-guard.test.sh` | FAIL | pass |

The affected suite runs 86 fixtures green. One unrelated fixture, `hook-latency.test.sh`, is red at 450ms against a 378ms budget; that is IAN-183 and IAN-184, it is pre-existing on `main`, and R-204 says not to widen the budget to make it quiet.

## Reflection

What I understand now that I did not at the start: CI passing is not evidence a guard works. The whole point of these hooks is to run on a developer's machine at tool-call time, and that machine is the one configuration CI never tests. A guard that fails open produces no error anyone sees, so the only signals were two fixtures nobody had run on macOS since `#96` merged.

What I got wrong first: I read the two fixture failures as noise from my own in-progress work, because they surfaced in the same run as a fixture I had deliberately made red. They were the most important thing in that output. Checking `git diff origin/main -- claude/hooks/` took ten seconds and showed I had touched no hook at all.

What I got wrong second, and would have shipped: the fixture written to prevent this class could not detect the class. It asserted the absence of an error string rather than the presence of a decision, so it went green against a guard sabotaged into exactly the silence it existed to catch. A test for a fail-open has to assert that the thing still happens, not that a particular error does not appear. The review found it; my own run of the fixture did not, because a passing test tells you nothing about what it would do if the code were wrong.

Third, smaller, and only visible because I probed it: I assumed any bash 4 construct would abort a hook on bash 3.2. It depends on the error. A parse error aborts, an expansion error does not. That distinction decides what the anchors can and cannot cover, and it is now written down instead of assumed.

Time since `#96` introduced the break: about four hours, measured from `9218cf4`'s commit time against this branch's first commit.
