# Spec: per-session handoff files behind a capped index

**Ticket:** IAN-260
**Rule touched:** R-602
**Branch:** `refactor/handoff-per-session-files`

## Problem

`docs/session-handoff/session-handoff.md` is one file, overwritten by every session, capped at 8192 bytes. That design assumes sessions are serial. They are not: on 2026-09-20 six sessions wrote it.

Observed cost, all on that one day:

- The prior handoff already carried "Two sessions ran in parallel today and both wrote here. This file merges them."
- PRs #98 and #99 collided. Folding four sessions into the cap took the whole of IAN-259 and left 4 bytes of headroom.
- PRs #100 and #101 now conflict and cannot be resolved without cutting content that includes three owner actions.

Each fold is manual, each one drops detail, and the drop is invisible afterwards because the file is overwritten rather than appended.

## Domain vocabulary

| Term | Meaning |
|---|---|
| **session file** | `docs/session-handoff/YYYY-MM-DD-<slug>.md`, written by exactly one session, carrying R-602's six sections for that session alone. Never rewritten by another session. |
| **index** | `docs/session-handoff/session-handoff.md`, the one file `session-start.sh` loads. Carries current state and links to session files. Rewritten each session, but only in the append-a-row and refresh-state sense. |
| **live warning** | A production-state fact that would cause harm if a next session missed it, for example "do not sync from this branch". Lives in the index, not only in a session file. |
| **pending queue** | The union of open work across session files, ordered by urgency, held in the index. |
| **narrative** | The index or session-file prose, excluding the generated `## Task state` block. The cap applies to narrative only, as today. |

## Shape

### Session file

The six R-602 sections in the mandated order, for that session only. Carries a resolving commit SHA in backticks. **No byte cap**, because it is never contended, so there is nothing to protect, and the cap is what forced the lossy folds.

Naming: the date the session ended, plus a slug naming the work, for example `2026-09-20-ian184-gate-exemption.md`.

### Index

Rewritten each session, and stays under 8192 bytes. Sections, in this fixed order:

1. `## Last commit`: the current `main` SHA and subject. Unchanged in meaning from today.
2. `## Live warnings`: the production-state facts a next session must not miss, each naming the session file it came from. This is the one place content is still contended, and it is deliberately small.
3. `## Pending`: the queue by urgency, one line per item, carrying ticket key, estimate and one sentence. Detail stays on the ticket.
4. `## Sessions`: one dated row per session file, newest first, with a one-line summary and the link.

The index does **not** carry "what shipped", "session metrics" or "next session". Those are per-session by nature and live in the session files, which is exactly why they are the sections that blew the cap.

### Retention

The `## Sessions` list keeps the trailing 30 days. Older rows drop off the index; their files stay on disk and in git. Without this the index grows without bound and hits the same cap in a slower way.

## Behavioural changes

### `handoff-check.sh`

Today it matches one path and applies four checks. After:

| Written path | Cap | Six sections in order | SHA resolves | Links resolve |
|---|---|---|---|---|
| `docs/session-handoff/session-handoff.md` | yes, 8192 | no, index sections instead | yes | yes |
| `docs/session-handoff/YYYY-MM-DD-*.md` | no | yes | yes | not applicable |
| anything else | silent, as today | | | |

Still advisory, still exits 0 on any internal fault.

### `session-start.sh`

Loads the index and SHA-verifies it exactly as it loads the handoff today. Additionally names the newest session file in the injected context, so a session needing detail knows which file to open without listing the directory. It does not inline session files, because that would reintroduce the size problem in the context window rather than in the file.

### `session-end.sh`

The generated `## Task state` block moves to the session file, since it describes one session's tasks. The index does not carry it.

## Migration

The four sessions currently merged into `session-handoff.md` on `main` split back out into four session files, reconstructed from the pre-fold originals rather than from the compressed merge, so the detail the cap forced out is recovered:

| Session file | Source |
|---|---|
| `2026-09-20-ian156-tdd-red.md` and `2026-09-20-r334-engine-case.md` | `d426098` |
| `2026-09-20-r605-ticket-audit.md` | `c6af9dd` plus the `23cdfca` corrections |
| `2026-09-20-ian184-gate-exemption.md` | `ef2d24b` |

Then #100's and #101's handoff commits become their own session files, which removes both conflicts without a fold.

## Slices

1. **Index and session-file shape.** `handoff-check.sh` distinguishes the two paths and applies the table above. Fixture per row, including the negative directions: an over-cap index, an index missing `## Sessions`, a session file with sections out of order, a dead link.
2. **Session-start load.** The index is loaded and SHA-verified; the newest session file is named, not inlined. Fixture asserts the injected context names it.
3. **Rule text and ports.** R-602's norm line and Spec rewritten, manifest row per R-516, both ports regenerated.
4. **Migration.** The four session files written, the index built from them, #100 and #101 resolved.

## Acceptance

- Two sessions writing handoffs on the same day touch no common file except the index, and touch different lines of it.
- The index stays under 8192 bytes with 30 days of rows.
- No fact present in any pre-fold handoff on 2026-09-20 is absent from the new tree.
- `session-start.sh` injects the index and names the newest session file.

## Open question for the owner

The `## Live warnings` section is still contended: two parallel sessions can both add one. The conflict is one line rather than a whole document, so git resolves it far more often, but it is not zero. Accepting that is the tradeoff for keeping one loaded file; the alternative is a warnings directory, which makes `session-start.sh` read N files every session.
