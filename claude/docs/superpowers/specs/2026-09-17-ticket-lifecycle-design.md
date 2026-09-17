# Ticket lifecycle

## Goal

Give every task above the trivial tier a work item in an external tracker (Jira, a Notion database, or Asana) that is opened when the task is classified, moved as the work actually moves, and closed with measured actuals. Two capabilities follow from that record and neither exists today: a history of completed work that can be read back by day, week, and month outside GitHub, and a tier-keyed estimate drawn from what comparable LLM-driven tasks actually took rather than from a guess. The repo currently tracks work in three places that all forget it: the TDD lock (deleted at `tdd.sh close`), the handoff doc (overwritten every session per R-602), and git history (searchable but carrying no tier, no estimate, and no duration). R-906 already requires recalibrating estimates after every task and no data has ever been kept to recalibrate against.

## Inputs

- The tier classification, model routing decision, and estimate produced by `skills/task-start/SKILL.md` (R-901, R-903, R-906).
- The spec and plan paths under `docs/superpowers/`, when the tier produced them.
- The branch name and worktree path from `skills/feature-create/SKILL.md`.
- The verification result, PR link, and merge decision from `skills/task-cleanup/SKILL.md`.
- `~/.claude/TICKET-TRACKER.json`, the per-machine instance config: which tracker is active, its MCP tool names, the container that holds tickets (Jira project key, Notion data source ID, or Asana project GID), and the canonical-state-to-provider-value mapping. Gitignored, because workspace identifiers and project keys are client-identifying and this repo is published (R-106). `claude/TICKET-TRACKER.template.json` is the checked-in template, following the `KNOWN-ISSUES.md` precedent.
- The tracker itself, read back for the report and estimate operations. The tracker is the only store of ticket history; this repo keeps no copy.

## Outputs

- One ticket per task, carrying the canonical field set below, in the configured tracker.
- One comment per state transition on that ticket, each naming the transition and its UTC timestamp, which is what makes the duration of each phase recoverable later.
- Actuals written onto the ticket at close: `completed_at`, `actual_minutes`, `estimate_ratio`, `rework_count`.
- A `Refs: <ticket-key>` trailer on every commit for the task, which is already an accepted trailer in `hooks/commit-message-guard.sh` and needs no hook change.
- The ticket key recorded in three durable places inside the repo so a later session can find the ticket without querying the tracker: the spec's `**Ticket:**` line, the user story's `**Ticket:**` line, and the handoff doc's first section (R-602).
- A rollup table for `report`, grouped by the requested granularity (day, week, or month), and an estimate with its sample size for `estimate`.

## Canonical states

Eight states, each tied to an event the repo can actually observe. The tracker's own status values are whatever the instance config maps them to; the skill never types a provider status name.

| Canonical state | Entered when |
|---|---|
| `backlog` | The ticket is captured but no work has started. |
| `specced` | The spec is written and accepted (complex and saga tiers only). |
| `planned` | The plan is written and accepted (complex and saga tiers only). |
| `in-progress` | The first slice opens (`tdd.sh open`) or, for a trivial tier, the first edit lands. |
| `in-review` | The branch is pushed and a review or PR is open. |
| `blocked` | Work is waiting on an answer or an external dependency. The blocking reason is the comment body. |
| `done` | The branch is squash-merged and `task-cleanup` has reported every applicable row. |
| `dropped` | The work is abandoned. The reason is the comment body. |

`specced` and `planned` are skipped by tiers that produce no spec or plan. `blocked` is re-entrant and remembers the state it interrupted, so leaving `blocked` returns to that state rather than guessing.

## Canonical field set

| Field | Value | Why it is on the ticket |
|---|---|---|
| `title` | Imperative summary of the task. | The readable spine of the history. |
| `tier` | `trivial`, `standard`, `complex`, or `saga`. | The estimate key (R-901). |
| `assist` | `llm` or `human`. | Estimates must be drawn from comparable samples; an LLM-driven task and a hand-written one are not comparable. |
| `model` | The model the work ran on (R-903). | Separates an Opus saga from a Haiku edit when the numbers disagree. |
| `estimate_minutes` | The up-front estimate after the R-906 division. | Without the estimate stored beside the actual, no recalibration is possible. |
| `repo` | Repository name only, never a local filesystem path (R-106). | Groups history per project. |
| `branch` | `feat/<slug>` or the branch the work landed on. | The join key between the ticket and git history. |
| `spec_link`, `plan_link` | Repo-relative doc paths. | Recovers the reasoning behind a closed ticket. |
| `pr_link` | The PR or review URL, when one exists. | Closes the loop to the diff. |
| `started_at`, `completed_at` | UTC ISO-8601 timestamps. | The day, week, and month buckets are derived from these. |
| `actual_minutes` | Attributable working minutes, not calendar elapsed time. | The measured quantity the estimate is compared against. |
| `rework_count` | Times a slice went back to red after a green, or a review sent the work back. | An estimate that ignores rework under-predicts the tier it most often misses. |
| `estimate_ratio` | `actual_minutes / estimate_minutes`, computed at close. | The single number R-906 recalibrates on. |

`actual_minutes` counts time attributable to the task within the sessions that worked it, measured from the R-503 start timestamp, and excludes wall-clock gaps where nothing was running. A ticket opened on Monday and closed on Friday is not four days of work, and recording it as such would poison every estimate drawn from it.

## Acceptance criteria

- B-1: `open` refuses to create a second ticket for a branch that already has an open one. It searches the tracker for the branch value first and reports the existing key instead.
- B-2: `open` refuses to proceed when `tier`, `assist`, `estimate_minutes`, `repo`, and `title` are not all known, and names the missing field. A ticket with no estimate cannot be recalibrated against and is worse than no ticket, because it silently shrinks the sample.
- B-3: `advance` writes both the provider status change and the transition comment. When the status write succeeds and the comment write fails, it reports the ticket as advanced with the audit trail incomplete, naming the missed comment, rather than reporting success.
- B-4: `advance` to a canonical state the instance config does not map stops and asks. It never guesses a provider status name and never writes a status value it was not given.
- B-5: `close` refuses while `task-cleanup`'s verification gate has not passed (tests, build, and lint green per R-509). A `done` ticket asserts the work shipped.
- B-6: `close` writes `completed_at`, `actual_minutes`, `rework_count`, and the computed `estimate_ratio` in the same update as the status change, so a ticket is never `done` with the actuals missing.
- B-7: `report <granularity> <range>` groups tickets by `completed_at` into day, week, or month buckets and reports per bucket: ticket count, summed `actual_minutes`, the count by tier, and the median `estimate_ratio`. Tickets with no `completed_at` are excluded and counted separately as open.
- B-8: `estimate <tier>` returns the median and the 80th percentile of `actual_minutes` over closed tickets matching that tier and `assist`, with the sample size stated. Below five samples it returns no number from history, says the sample is too small, and falls back to the R-906 heuristic, labelled as a heuristic.
- B-9: Every write to the tracker is a single MCP call. Since R-105's 2026-09-17 tracker narrowing, `hooks/mcp-action-guard.sh` confirms it with the user only when the call also lands code, submits for review, uploads a file, or applies a change; a plain bookkeeping write (a status update, a transition comment) is exempt and proceeds silently. No operation batches several writes behind one confirmation, and none is retried silently after a denial.
- B-10: With no `~/.claude/TICKET-TRACKER.json` present, every operation reports that no tracker is configured, points at the template, and records the same field set in the handoff doc instead. The work proceeds; the tracking degrades loudly rather than silently.
- B-11: Ticket titles, descriptions, and comments are sanitized before they are written: no secret values (R-102), no PII, and no local filesystem paths (R-104, R-106).

## Invariants

- The tracker is the system of record for ticket state. This repo stores no ticket database, no cache, and no mirror, so there is nothing that can drift out of sync with it.
- Information flows one way: repo events move the ticket. The skill never reads a tracker status and changes the repo to match it.
- Every timestamp is UTC ISO-8601.
- The instance config is the only authority on provider status values, tool names, and container identifiers. Adding a fourth tracker is a config change plus a mapping table row, not a change to the state machine.
- No credential, token, workspace ID, project key, or field ID enters this repo. MCP holds the auth and the template holds placeholders.
- A tracker failure never blocks the engineering work. It downgrades the tracking, reports what was missed, and the work continues.

## Failure modes

- No tracker configured: B-10. Report it once per session, not once per operation.
- The MCP server is unavailable or unauthorized: report the failed call, record the intended field set in the handoff doc, and retry at the next lifecycle event rather than abandoning the ticket silently.
- The user denies the R-105 confirmation: treat the denial as a decision, not an obstacle. Do not re-ask for the same write in the same turn, and note in the close report that the ticket is behind the work.
- A search returns several open tickets for one branch: stop and ask which one is live. Never pick one, and never open a third.
- The tracker lacks a field in the canonical set (a Notion database missing an `estimate_minutes` property, for instance): report exactly which properties or fields are missing and the type each needs, then write the fields that do exist. Creating properties in someone's database is a schema change and waits for the user.
- A session ends mid-task with the ticket in `in-progress`: this is correct, not a failure. The handoff doc carries the key and the next session advances it.
- Clock skew between the machine and the tracker: all durations are computed from locally captured timestamps, never from provider-side modification times, which differ per provider and are not reliably queryable.

## State transitions

```
backlog -> specced -> planned -> in-progress -> in-review -> done
             |           |            |              |
             +-----------+------------+--------------+--> blocked --> (prior state)
             |           |            |              |
             +-----------+------------+--------------+--> dropped
```

Legal entries into `in-progress` skip `specced` and `planned` for the trivial and standard tiers. `in-review` returns to `in-progress` when a review sends the work back, and that return increments `rework_count`. `done` and `dropped` are terminal; reopening means a new ticket that links the old one.

## Non-goals

- No mirroring into or out of GitHub issues. Tracking outside GitHub is the point of the work, and a two-way mirror would recreate the thing being replaced.
- No story points, sprints, velocity, or burndown. Estimates are in minutes and governed by R-906. Points are a second unit that would have to be reconciled with minutes forever.
- No calendar time tracking. `actual_minutes` is attributable working time, and this skill will not attempt to measure idle wall clock.
- No new MCP server, no direct REST calls, no tokens in the repo. Whatever MCP server the user already has for the tracker is the transport.
- No mechanical enforcement hook this cycle. A hook can only check a local signal, and the only local signal available is a file this repo would have to invent (a per-branch ticket link) whose shape depends on which of the three trackers the user settles on. The rules ship `[manual]`, consistent with the rest of the R-6xx block, and the mechanical tier is revisited once one tracker has real history in it. This is stated here so an audit reads it as a decision with a reason rather than as the recall-dependent gap R-516 warns about.
- No migration of past work. The history starts empty and fills from the next task forward.
- No change to `tdd.sh`, the TDD lock, or the protected-path guard. The lifecycle sits beside the slice machinery and never gates a commit.

## Dependencies

- An MCP server for the chosen tracker, already connected. The Notion and Linear servers are present in the maintainer's setup today; Jira and Asana are connected the same way when used.
- `hooks/mcp-action-guard.sh`, which asks on every `create`, `update`, `save`, `add`, and `comment` call (R-105). This skill is a stream of exactly those verbs, so the confirmation traffic is real and intended. The remedy is the user's own per-tool "don't ask again", which is their pre-authorization to give; the skill never suppresses the guard and never asks to have it bypassed (R-203).
- `hooks/commit-message-guard.sh`, unchanged: `Refs:` is already in its trailer allowlist.
- `skills/task-start`, `skills/feature-create`, and `skills/task-cleanup`, each gaining the lifecycle step at the point where it already makes the matching decision.
- R-906 in `rulebook/cost.md`, whose Spec gains the tracker history as the thing recalibration reads.

## Observability

The tracker is the observability surface: the ticket list grouped by `completed_at` is the day, week, and month view the user asked for, and the transition comments are the audit trail behind each row. The `report` operation exists so the rollup can be produced without hand-building a provider query, and `estimate` exists so the number that goes into the next ticket comes from the history rather than from optimism. No logger, no metrics pipeline, and no analytics events apply: this is a skill, not a service, so R-341 through R-346 are out of scope and named here so the conformance review does not report their absence as a gap.

## Security

Tracker credentials live in the MCP server's own configuration and never in this repo or in a prompt (R-102). The instance config holds identifiers rather than secrets, and is gitignored anyway because a project key and a workspace ID identify a client (R-106). Ticket bodies are sanitized before writing (R-104): secrets to `[REDACTED]`, PII to `[PII]`, internal URLs to `[INTERNAL_URL]`. A plain bookkeeping write (status change, transition comment) is exempt from R-105's confirmation since the 2026-09-17 narrowing, because the tracker is private to the operator and a wrong field is editable in place; a call that lands code, submits for review, uploads a file, or applies a change still passes through the confirmation, since that is content leaving the machine for a use the operator cannot undo by re-editing the same record.

## Domain vocabulary

- ticket - the tracker work item that is the system of record for one task's lifecycle - chosen over: "issue", because a GitHub issue is precisely what this replaces and the collision would be read the wrong way in every rule that mentions it, and over "card", which is board-specific and wrong for Jira and Notion.
- tracker - the configured external system holding tickets, one of Jira, a Notion database, or an Asana project - chosen over: "provider", which reads as the MCP server rather than the destination, and over "PM tool", which is not a name.
- canonical state - one of the eight lifecycle states the skill knows, mapped by the instance config onto whatever the tracker calls them - chosen over: "status", which is the provider-side field name and must stay distinguishable from it.
- instance config - `~/.claude/TICKET-TRACKER.json`, the gitignored per-machine file naming the active tracker, its tool names, its container, and its state mapping - chosen over: "settings", which collides with `settings.json`, and over "tracker config", which reads as configuration of the tracker itself rather than of this skill's view of it.
- actuals - the measured `actual_minutes`, `rework_count`, and `estimate_ratio` written at close - chosen over: "metrics", which implies a pipeline that does not exist here.
- assist - whether a task was LLM-driven or hand-written, recorded so estimates draw only on comparable samples - chosen over: "author", which reads as a person's name, and over "source".
- attributable minutes - working time inside the sessions that worked the task, as against calendar elapsed time between open and close - chosen over: "duration", which is exactly the ambiguity this term exists to remove.
