# ticket-at-start-gate walks a path by expansion too

Ticket: IAN-183. Branch: `fix/ticket-gate-path-walk`. PR: #110.

## Summary

`claude/hooks/ticket-at-start-gate.sh` resolved a written file path by calling `dirname` or `basename` once per path component, inside two `while` loops. The hook sits on the `PreToolUse` `Write|Edit` chain, so every edit paid one process per directory level of the path being written. This is the fifth hook carrying that pattern; IAN-183's sweep fixed three and IAN-262 fixed a fourth, all on PR #104.

Chain growth over nine extra levels drops from 9 spawned processes to 0.

## What changed

- `claude/hooks/ticket-at-start-gate.sh`: `resolve_edit_directory` and `resolve_edit_path` strip components with `${path%/*}` and `${path##*/}` instead of calling `dirname` and `basename` in a loop. Both follow the pattern PR #104 established in `scope-widening-gate.sh`, including the trailing-slash strip and the `.` compensation that `dirname` performs implicitly for a name with no slash.
- `claude/enforce/tests/ticket-at-start-gate.test.sh`: one new assertion, PW-1, scoped by `awk` to those two function bodies.
- `claude/enforce/hook-hashes.txt`: regenerated.

Three single `dirname` and `basename` calls elsewhere in the hook (sourcing the helper directory at line 47, naming a git directory at 261, labelling a message at 501) are untouched. Each is one process and none scales with depth.

## Architectural decisions

- **Chosen: a per-hook assertion (PW-1) scoped to the two resolver bodies.** **Alternative:** rely on `hook-path-walk-budget.test.sh`, the chain-level fixture PR #104 adds. **Why not:** that fixture reports chain growth without naming the offending file. Finding this hook took a grep across ten hooks in the chain; PW-1 makes the next regression cost one line of output. The chain fixture stays the backstop for a hook nobody thought to assert on.
- **Chosen: scope PW-1 to the two function bodies rather than the whole file.** **Alternative:** ban `dirname` and `basename` outright in this hook. **Why not:** the three remaining calls are legitimate, constant-cost, and banning them would force three awkward rewrites for no gain. The invariant is "no path walk", not "no `dirname`".
- **Chosen: duplicate the resolver pattern rather than extract a shared helper.** **Alternative:** move `physical_path` and `nearest_existing_directory` into a sourced helper beside `scope-match.sh`, as R-308 would prefer. **Why not:** these functions now exist in five hooks and consolidating them is a cross-cutting refactor touching all five plus their fixtures, which R-511 says belongs on its own branch. Recorded as a follow-up in the session handoff.
- **Chosen: a separate branch off `main` rather than a commit on #104.** **Alternative:** add it to #104, where the other four hooks live. **Why not:** #104 was force-pushed by a parallel session while this fix was being written, so pushing would have meant contending for a branch another session owns.

## Testing

- `ticket-at-start-gate.test.sh` passes, including PW-1. Proved red first: restoring the pre-fix hook makes PW-1 fail and naming the offending lines, and the fix makes it pass.
- `hook-path-walk-budget.test.sh` (on #104's branch, not on `main`) went from `growth 9, budget 6` to `growth 0`.
- Full fixture suite on the merged tree: 102 pass. `hook-latency.test.sh` is the only failure and is unrelated to this diff: it deliberately measures the installed `~/.claude/hooks`, which cannot improve until this and #104 are merged and `./sync.sh` runs.

## Codex review

Reviewer: Codex (`codex exec -s read-only`), back from the quota exhaustion that forced the Claude fallback all of 2026-09-20. Range: `origin/main...5470a52`.

Four findings, all genuine equivalence divergences between the expansion rewrite and the `dirname`/`basename` version it replaced. The review was worth running: two of the four change which repository a path is judged against, which is a correctness defect in a change presented as a pure performance fix.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | `dirname` ignores trailing slashes and `${p%/*}` does not, so `/etc/` resolved to `/private/etc` instead of `/`. For a repository directory passed with a trailing slash this selects that repository rather than its parent. | Fixed: trailing slashes are stripped before the expansion. Pinned by PW-2. |
| 2 | MEDIUM | `$(...)` stripped trailing newlines from every `dirname` and `basename` result; expansion does not. For `$'/etc\n/hosts'` the directory resolver returned `/` instead of `/private/etc`. | Fixed: trailing newlines are stripped after the expansion. Pinned by PW-2. |
| 3 | LOW | Repeated separators were kept while walking absent parents, so `missing//child/file` resolved to `$CWD/missing//child/file`. | Fixed in the hook. Deliberately **not** pinned by a test: `pwd -P` normalises `//` away, so an assertion on the output passes against the unfixed code too and would be a test that cannot fail (R-401). The comment in the fixture says so. |
| 4 | LOW | `basename /` returns `/` where `${p##*/}` returns empty, so `resolve_edit_path /` changed from `///` to `//`. | Accepted, not fixed. A Write whose `file_path` is `/` is not a real input and both answers are nonsense; special-casing it would add a branch no caller reaches. |

Equivalence was then verified directly rather than by inspection: a harness ran both implementations over eleven inputs including all four of the review's cases, and the only remaining divergence is finding 4.

## Reflection

**What I understand now.** The chain-level budget fixture and the per-hook assertion are not redundant, they answer different questions. The chain fixture answers "is the whole Write|Edit path cheap", which is the property that matters, but its failure message can only say that something walked. The per-hook assertion answers "which file", which is what a person needs at 2am. A guard that detects a problem it cannot localise still leaves the expensive part of the work undone.

**What I got wrong first.** Three things, in order. I wrote the PW-1 assertion referencing a `$HOOKS` variable this fixture does not define; under `set -u` it errored and the test still printed PASS, so my new assertion silently did nothing. That is the same fail-open-by-silence class this whole session has been documenting, produced by me while documenting it. Then I widened the regex and it matched the three legitimate calls, so it failed with the fix in place. Only the third version, scoped by `awk` to the function bodies, was both red without the fix and green with it. The lesson is that a new assertion needs proving in both directions, and I only did that after the second failure.

**On the platform.** This defect was invisible to CI. `enforce.yml` runs on `ubuntu-latest`, where the chain's process count sits under the budget; the fixture fails only on macOS, which is where the work happens. That is the second instance in one day of ubuntu-only CI hiding a defect on the development platform, after IAN-267's `mapfile`. A macOS or bash 3.2 CI leg is the missing coverage and is recorded in the handoff.
