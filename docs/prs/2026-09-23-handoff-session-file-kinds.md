# handoff-check learns two kinds of handoff

**Ticket:** IAN-260 (slice 1 of five)
**PR:** #114
**Branch:** `feat/handoff-session-file-kinds`

## Summary

`handoff-check.sh` matched exactly one path, `docs/session-handoff/session-handoff.md`, and applied four checks to it: an 8192-byte cap on the narrative, six sections in order, a resolving commit SHA, and silence everywhere else.

It now reads two kinds. The index keeps every check it had. A session file, `docs/session-handoff/YYYY-MM-DD-<slug>.md` and an immediate child of that directory, keeps the sections and the SHA and carries **no cap**.

## Why the cap is dropped on session files, and only there

The cap is not wrong; the single contended file is. One file overwritten by every session assumes sessions run one at a time, and on 2026-09-20 six of them wrote it. The compression needed to fold four sessions into 8179 bytes silently dropped a retraction, and only an adversarial review caught it before the next session could re-open a claim that had been explicitly withdrawn.

A session file is written by exactly one session and read by everyone. Nothing else writes it, so there is nothing for a cap to protect, and the cap is precisely what forced the lossy folds. The index stays capped because it is still the one contended file.

The load-bearing assertion is therefore a pair: a 12KB session file passes, while an oversized index is still named.

## Architectural decisions

**Chosen: one six-section contract for both kinds, differing only in the cap.** The spec's first draft gave the index four sections of its own and dropped "what shipped", "session metrics" and "next session" as per-session by nature. Rejected because it changes behaviour that `handoff-check.test.sh` already pins, and because two section contracts for two file kinds is more rule surface than one contract applied twice.

**Deferred deliberately: the `## Sessions` list the index will owe.** Enforcing it in this slice turns the existing compliant fixture red, and no session file exists for the index to list until the migration writes them. It lands in slice 5 together with the fixture update. The hook carries a comment saying so, rather than leaving the next reader to rediscover the contradiction; the first attempt at this slice bundled the two behaviours and deadlocked against its own locked test.

**Chosen: compare the parent exactly rather than glob it.** `*` in a `case` pattern matches `/`, so `*/docs/session-handoff/*` classified a file at any depth below that directory. Session files are immediate children, so `PARENT="${FILE%/*}"` is compared against the directory itself.

## Testing

Test first, under the R-412 slice lock. RED certified against a baseline of 103 passing fixtures; GREEN certified at 103, no regression. Seventeen directions, each mutation-tested rather than trusted because it was green:

| Mutation | Caught by |
|---|---|
| session arm never matches | the four positive session directions, and the oversized-plus-missing-section pair |
| cap applied to session files | `a session file over the cap is silent`, `not named for the cap` |
| section and order checks skipped for sessions | `missing a section is named`, `out of order is named` |
| order check alone disabled | `sections out of order is named` |
| parent anchoring reverted to the greedy glob | `nested below the handoff directory is silent` |
| empty slug accepted again | `with an empty slug is silent` |

## Reflection

What I understand now that I did not at the start: an absence assertion cannot detect a fail-open. Three times in two days I wrote a test that asserted an error string was missing, and each time it passed against an implementation that had stopped running at all. Here it was `a session file over the cap is silent`, which stayed green when the session arm was made to never match, because a path the hook never classifies is silent for the wrong reason. The fix is a payload that is both over the cap and missing a section, so the hook must prove it looked and prove it exempted.

What I got wrong first: I scoped this slice to include the `## Sessions` index check, having written into the spec, two commits earlier, the reason that would break the existing fixture. The slice deadlocked against its own lock, the PR had to ship as spec-only, and the implementation waited in a stash. The spec named the trap and I walked into it anyway.

Time since the first commit on this work: about fourteen hours, most of it spent on the deadlock and on two guard failures found along the way rather than on the change itself.
