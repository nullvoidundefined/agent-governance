---
name: ticket-lifecycle
description: Use to open, advance, close, or report on the external tracker ticket (Linear, Jira, Notion, or Asana) that tracks a task. Triggers when a task's draft PR opens (the ticket opens then at the latest), at the state changes listed here, at task close, and on "what did I ship this week" or "how long does this tier take".
---

# Ticket Lifecycle

Open a ticket by the time the draft PR opens, move it when the work moves, close it with `actual_minutes` and `risk`, and read the history back for rollups. The whole lifecycle stays inside the 1:1 budget (owner decision 2026-10-02, IAN-568): a few direct calls per task, no gate.

**Announce at start:** "I'm using the ticket-lifecycle skill to [open|advance|close|report on] the tracker ticket for this work."

Design: `docs/superpowers/specs/2026-09-17-ticket-lifecycle-design.md`.

## Who runs it

The main session runs every operation as direct tracker MCP calls, never through a subagent (owner decision 2026-09-24, IAN-345: a subagent spent about 136k tokens opening one ticket, while direct calls cost a few thousand each). Load the tracker's tools with ToolSearch once, by exact name from the config, then make one call per write. Only a `report` or `estimate` over a long history may go to a background subagent on `sonnet`.

## Instance config

Read `~/.claude/TICKET-TRACKER.json` before any operation. It names the active tracker, its MCP tool names, its container, and the canonical-state mapping; the template is `~/.claude/TICKET-TRACKER.template.json`, and the real file is gitignored.

Config absent: say once, in this turn, that no tracker is configured and how to fill one in, record the field set in the handoff if one is written, and continue the work.

Never type a provider status name that is not in the config's `states` map; an unmapped canonical state stops the operation and asks.

## Canonical states

| State | Enter when |
|---|---|
| `backlog` | Captured, not started. |
| `specced`, `planned` | Only when the owner asks. |
| `in-progress` | Work under way (the usual state at open). |
| `in-review` | Draft PR marked ready, or the review is running. |
| `blocked` | Waiting on an answer or an external dependency. |
| `done` | Merged and `task-cleanup` reported clean. |
| `dropped` | Abandoned, with the reason. |

`blocked` returns to the state it interrupted. `done` and `dropped` are terminal; reopening means a new ticket linking the old key. On a tracker whose config maps `specced` and `planned` onto one shared status (Linear's Todo), a move into it carries the `specced` or `planned` label in the same call, because `linear-todo-label-gate.sh` denies it otherwise (IAN-473).

## Canonical fields

Six fields are required (owner decision 2026-10-02, IAN-568): `title`, `tier`, and `branch` at open; `started_at` at open; `actual_minutes` and `risk` at close. Every other field is optional.

| Field | Source |
|---|---|
| `title` | Imperative summary of the task. Required. |
| `tier` | `task-start` classification (R-901). Required. |
| `branch` | The branch the work lands on. Required. |
| `started_at` | UTC ISO-8601: the first timestamp in the session transcript, never a guess or the current time. Required. |
| `actual_minutes` | Attributable working minutes inside the sessions that worked the task, never the calendar gap between open and close. Required at close. |
| `risk` | `high` or `standard` (R-110): `high` when any slice recorded `**Risk:** high` or the R-109 security-surface detector flagged the range. Required at close. |
| `repo`, `pr_link`, `spec_link`, `completed_at` | Repository name only (never a local path, R-106), the PR URL, the spec path, and the close time. Optional. |
| `estimate_minutes`, `estimate_ratio` | An estimate, and `actual_minutes / estimate_minutes` at close. Optional. |
| `human_estimate_minutes`, `human_speedup` | A senior engineer's estimate set before work starts, and `human_estimate_minutes / actual_minutes`. Optional. |
| `findings_by_round` | The R-517 findings per round by severity, `r1:H1,M2,L3; r2:L1`, or `r1:none`. Optional. |
| `escaped_bugs` | Bugs found after merge that a dropped per-slice critic would plausibly have caught; `0` at close, incremented later with a comment naming the bug ticket. Optional. |

## Operation: open

Run when the draft PR opens, at the latest; earlier is allowed when the owner wants the ticket up front. There is no ticket gate before the first edit.

1. Skip for the trivial tier unless the user asks for a ticket.
2. Search the tracker for an open ticket carrying this `branch`. One hit: report its key and stop. Several hits: ask which is live.
3. Create the ticket in `in-progress` with `title`, `tier`, `branch`, `started_at`, and any optional fields already known. Sanitize the body first (R-104).
4. Report the key and URL, add `Refs: <key>` to the PR body and to later commits, and write it on the spec's `**Ticket:**` line when a spec exists. Optionally record it on the ledger with `task-tier.sh set <tier> "<reason>" --ticket <key>`.

## Operation: advance

Run at `in-review`, `blocked`, `done`, and `dropped`, in the same turn as the event.

1. Resolve the key from the PR body, the spec, or the last `Refs:` trailer. None found: say so and offer `open`.
2. Map the state through the config, write the status change, and add a comment `<from> -> <to> at <UTC ISO-8601>`, with the reason on `blocked` and `dropped`.
3. A status written with a failed comment is reported as advanced with the audit trail incomplete.

## Operation: close

Run inside `task-cleanup`, after the verification gate and the merge.

1. Refuse while tests, build, or lint are not green (R-509).
2. Compute `actual_minutes` from the transcript's first timestamp and the working time in any earlier session on the ticket, excluding gaps where nothing ran.
3. Read `risk` from the slice plans' `**Risk:**` lines or the security-surface detector. Add `findings_by_round`, `escaped_bugs: 0`, and the ratios only when they are cheap to read.
4. Write `done`, `completed_at`, `actual_minutes`, `risk`, `pr_link`, and any optional fields in one update. A tracker that maps none of the R-110 fields records them as `risk: <value>` lines in the `done` comment instead.

## Operation: report

Invoked as `report <day|week|month> <range>`; "what did I ship this week" means `report day` over the current week. Query tickets whose `completed_at` falls in the range; per bucket output the ticket count, summed `actual_minutes`, and the count by tier, plus the median `estimate_ratio` and `human_speedup` over the tickets that carry them. Count open tickets separately.

## Operation: report risk

Invoked as `report risk`; it measures R-110 rather than taking it on faith. Query closed tickets carrying `risk`. Fewer than ten: report `n=<count>` with the split and stop. Ten or more: one row each for `high` and `standard` with the count, the median `actual_minutes`, summed `escaped_bugs` where recorded, and the per-round severity totals from `findings_by_round` where recorded, then one line on whether standard-risk tickets escape bugs a critic would have caught.

## Operation: estimate

Invoked as `estimate <tier>`. Query closed tickets for the tier. Fewer than five samples: say `n` and return no number from history. Five or more: return the median and the 80th percentile of `actual_minutes` with `n` and the sample's date range.

## Provider mapping

The config carries the tool names; each operation needs create, update (status and fields), comment, search by field, and read one ticket. Jira transitions status through its transition tool, Notion through a select property, Asana through a section or `completed`. A tracker missing a field: name the field and its type, write the fields that exist, and stop; creating a property is the owner's schema change.

## Confirmation posture

Every write is one MCP call. R-105 passes the Linear server's write class without a prompt, while a Notion, Jira, or Asana write still asks; never batch writes behind one prompt, and a denial is a decision not re-asked in the same turn (R-203). A tracker failure never blocks the engineering work: report the failed call and retry at the next lifecycle event.

## Common Mistakes

- Opening a second ticket for a branch that already has one; search first.
- Recording calendar elapsed time as `actual_minutes`.
- Writing `done` without `actual_minutes` and `risk`.
- Putting a local path, a client name, or a secret in a ticket body.

## Integration

- **Called by:** task-cleanup (`open` at PR time when no ticket exists, then `close`), feature-create (`advance`), the user (`report`, `report risk`, `estimate`)
- **Rules:** R-605 (a ticket per task above trivial, by PR open), R-606 (actuals at close), R-110 (risk), R-517 (review rounds), R-901 (tier), R-105 (confirmation per write), R-106 (nothing client-identifying)
