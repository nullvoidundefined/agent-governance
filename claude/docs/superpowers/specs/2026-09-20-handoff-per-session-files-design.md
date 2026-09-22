# Spec: per-session handoff files behind a capped index

**Ticket:** IAN-260
**Rule touched:** R-602
**Branch:** `refactor/handoff-per-session-files`

## Problem

`docs/session-handoff/session-handoff.md` is one file, overwritten by every session, capped at 8192 bytes. That design assumes sessions are serial. They are not: on 2026-09-20 six sessions wrote it.

Observed cost, all on that one day:

- The prior handoff already carried "Two sessions ran in parallel today and both wrote here. This file merges them."
- PRs #98 and #99 collided. Folding four sessions into the cap took the whole of IAN-259 and left 13 bytes of headroom at `6eac897`; a later correction on the #98 lineage (`23cdfca`) left 4.
- PRs #100 and #101 both conflicted on it. #100 was closed unmerged rather than resolved; #101 is the live conflict and cannot be resolved without cutting content that includes three owner actions.

Each fold is manual, each one drops detail, and the drop is invisible afterwards because the file is overwritten rather than appended.

## Domain vocabulary

| Term | Meaning |
|---|---|
| **session file** | `docs/session-handoff/YYYY-MM-DD-<slug>.md`, written by exactly one session, carrying R-602's six sections for that session alone. Never rewritten by another session. |
| **index** | `docs/session-handoff/session-handoff.md`, the one file `session-start.sh` loads. Carries R-602's six sections, compressed, plus a `## Sessions` list linking the session files. Rewritten each session, but only in the append-a-row and refresh-state sense. |
| **live warning** | A production-state fact that would cause harm if a next session missed it, for example "do not sync from this branch". Lives in the index, not only in a session file. |
| **pending queue** | The union of open work across session files, ordered by urgency, held in the index. It is the one section a next session acts on directly, which is why it stays in the index rather than moving to a session file. |
| **narrative** | The index or session-file prose, excluding the generated `## Task state` block. The cap applies to narrative only, as today. |

## Shape

### Session file

The six R-602 sections in the mandated order, for that session only. Carries a resolving commit SHA in backticks. **No byte cap**, because it is never contended, so there is nothing to protect, and the cap is what forced the lossy folds.

Naming: the date the session ended, plus a slug naming the work, for example `2026-09-20-ian184-gate-exemption.md`.

### Index

Rewritten each session, and its **narrative** stays under 8192 bytes: the measurement excludes the generated `## Task state` block exactly as `narrative_without_task_state` excludes it today (`hooks/handoff-check.sh:42-54`), and excludes the `## Sessions` list for the same reason, since neither is written by hand.

**The index keeps R-602's existing six sections, in the existing order.** An earlier draft of this spec gave the index four sections of its own (last commit, live warnings, pending, sessions) and dropped "what shipped", "session metrics" and "next session" as per-session by nature. That was wrong for two reasons:

- It would change behaviour that `enforce/tests/handoff-check.test.sh` already pins, forcing an edit to a tracked test script. That is workable but costs a step: editing one emits a manifest content-drift line, and the remedy is the one the closure fixture prints, `hooks/hook-integrity-check.sh --update` with the manifest committed, run before `tdd.sh red`. It is not a hard blocker, and a later slice should not treat it as one.
- Two section contracts for two file kinds is more rule surface than one contract applied twice. The cap, not the section list, is what differs.

So both file kinds carry the same six sections. In the index the three per-session ones compress to a pointer ("per session, see the files listed below"), which costs about 100 bytes and keeps the invariant uniform. The index additionally carries a `## Sessions` list, one dated row per session file, newest first, with a one-line summary and the link; it sits after section 6.

`## Live warnings` becomes a labelled block inside section 2, production state, rather than a section of its own. It holds the facts a next session must not miss, each naming the session file it came from. This is the one place content is still contended, and it is deliberately small.

### Retention

The `## Sessions` list keeps **the 20 most recent rows**, counted, not dated.

A calendar window does not survive the arithmetic. A row carrying a date, slug, link and one-line summary runs about 117 bytes. Thirty days at the two-sessions-a-day rate is 60 rows, about 7.0 KB, which exceeds the 8192-byte cap before any of the six sections exist; at the six-a-day rate this document opens with, it is about 21 KB. A count bounds the list at about 2.3 KB and leaves the sections room.

**Who prunes:** the session writing the handoff, as a step in `skills/task-cleanup/SKILL.md`. It drops rows past the twentieth when it adds its own. Older rows leave the index only; their files stay on disk and in git, and `git log docs/session-handoff/` is the full history.

**What enforces it:** nothing mechanical, by choice. A hook cannot tell a deliberately short list from a pruned one, and the cap already fails loudly when the list grows too long, which is the failure that matters. This is a `[manual]` step, and the rule text says so rather than implying a check exists.

## Behavioural changes

### `handoff-check.sh`

Today it matches one path and applies four checks. After:

| Written path | Cap | Six sections in order | SHA resolves | `## Sessions` present |
|---|---|---|---|---|
| `docs/session-handoff/session-handoff.md` | yes, 8192 | yes | yes | **not in slice 1** |
| `docs/session-handoff/YYYY-MM-DD-*.md` | no | yes | yes | no |
| anything else | silent, as today | | | |

**The `## Sessions` check is deferred to slice 5, deliberately.** Enforcing it in slice 1 turns `enforce/tests/handoff-check.test.sh:53` ("compliant handoff is silent") red, because that test's compliant case is the inline `good()` heredoc at `:26-48`, which carries the six sections and no `## Sessions`. It would also make today's index non-compliant, and no session file exists for it to list until the migration writes them. Slice 5 adds the check, adds a `## Sessions` block to `good()`, and runs `hooks/hook-integrity-check.sh --update` with `enforce/hook-hashes.txt` committed in the same commit.

The other index directions (cap, sections, SHA) are exactly what they are today, so they keep passing unchanged through slices 1 to 3. There is no separate fixture file for the compliant case to live "beside": it is a function inside the tracked test script, so any change to the index contract edits that script.

Still advisory, still exits 0 on any internal fault.

### `session-start.sh`

Loads the index and SHA-verifies it exactly as it loads the handoff today. Additionally names the most recent session file in the injected context, so a session needing detail knows which file to open without listing the directory. "Most recent" is the last row of the index's `## Sessions` list, which the writing session appends in order; filename date and mtime both tie when two sessions run on one day, which is the case this spec exists for. It does not inline session files, because that would reintroduce the size problem in the context window rather than in the file.

### `session-end.sh`

The generated `## Task state` block moves to the session file, since it describes one session's tasks. The index does not carry it.

The hook cannot currently find that file. It hardcodes `handoff_file="$session_cwd/docs/session-handoff/session-handoff.md"` (`hooks/session-end.sh:378`) and holds only `session_cwd` and the session id, while the `<slug>` is chosen by the agent, so nothing it has determines the filename.

**Resolution rule:** the session records the path it wrote in `.claude/session-handoff-path` (untracked, session state like the tier ledger), and `session-end.sh` reads that file, falling back to the index when it is absent so an older session keeps working. A newest-file heuristic was rejected: filename date and mtime disagree, and two sessions on the same day tie on the date, which is the case this whole spec exists for.

This needs its own slice, and the `render_succeeded` and log-pruning logic at `hooks/session-end.sh:370-424` keys on the target existing, so it moves with the target.

## Migration

The four sessions currently merged into `session-handoff.md` on `main` split back out into four session files, reconstructed from the pre-fold originals rather than from the compressed merge, so the detail the cap forced out is recovered:

| Session file | Source | Ref |
|---|---|---|
| `2026-09-20-ian156-tdd-red.md` and `2026-09-20-r334-engine-case.md` | `d426098` | on `main` |
| `2026-09-20-r605-ticket-audit.md` | `c6af9dd` plus the `23cdfca` corrections | `keep/ian260-migration-r605-audit`, `keep/ian260-migration-r605-corrected` |
| `2026-09-20-ian184-gate-exemption.md` | `ef2d24b` | `keep/ian260-migration-ian184-gate` |

**Use the refs, not the bare SHAs.** Three of these four commits sit on no branch: their PR branches were deleted after merge, `git branch -a --contains` returns nothing, and an unreachable object is prunable by auto-gc and absent from a fresh clone. The `keep/` tags were pushed before this spec merged, for exactly that reason. Only `d426098` is reachable on its own.

Then #101's handoff commits become its own session file, which removes the conflict without a fold. #100 is closed, so it needs nothing; it stands as the precedent for what happens when this file is left contended. Note that `25e180d` and `7b72052` sit on both branches, so the two were never independent sets of commits.

## Slices

1. **Index and session-file shape.** `handoff-check.sh` distinguishes the two paths and applies the table above. Fixture per row, including the negative directions: an over-cap index, a session file with sections out of order, a session file over 8 KB that passes. The index-missing-`## Sessions` and dead-link directions belong to slice 5, which is where that column is enforced; the hook has no link resolution today and would need one, using the `DIR` it already derives at `hooks/handoff-check.sh:78-79`.
2. **Session-start load.** The index is loaded and SHA-verified; the newest session file is named, not inlined. Fixture asserts the injected context names it.
3. **Rule text, procedures and ports.** R-602's norm line and Spec rewritten, manifest row per R-516, both ports regenerated. Also `skills/task-cleanup/SKILL.md` and `codex/skills/session-handoff/SKILL.md`, which are the procedures that actually write the handoff: without them no session ever produces a session file. Each slice that changes a hook also updates that hook's fixture, `hooks/tests/session-end.test.sh` (which pins the task-state target in about ten places) and `hooks/tests/session-start.test.sh:20-34` (which pins the injected path).
4. **Task-state relocation.** `session-end.sh` reads `.claude/session-handoff-path` and writes the generated block into the session file, with the index as fallback. Moves `render_succeeded` and the log pruning with it.
5. **Migration and the `## Sessions` check.** The four session files written from the `keep/` refs, the index built from them, the `## Sessions` column enforced, `good()` in `handoff-check.test.sh` updated, #101 resolved.

## Acceptance

- Two sessions writing handoffs on the same day touch no common file except the index, and touch different lines of it.
- The index narrative stays under 8192 bytes with a full 20-row `## Sessions` list.
- No fact present in any pre-fold handoff on 2026-09-20 is absent from the new tree.
- `session-start.sh` injects the index and names the newest session file.

## Open question for the owner

The `## Live warnings` block inside section 2 is still contended: two parallel sessions can both add one. The conflict is one line rather than a whole document, so git resolves it far more often, but it is not zero. Accepting that is the tradeoff for keeping one loaded file; the alternative is a warnings directory, which makes `session-start.sh` read N files every session.
