# User Stories

Every user-facing feature in {{PROJECT}} is documented as a user story (R-607). Each story carries a stable identifier, acceptance criteria as a checklist, and the path of the end-to-end spec that covers it.

## Convention

- One file per product area: `docs/user-stories/<area>.md`, matching one `## <Area>` section of `docs/feature-list/features.md`.
- Story identifiers are `US-<AREA>-NNN`, numbered in order within the area and never reused or renumbered.
- Each story has the "As / I want to / So that" form, an acceptance-criteria checklist, an `**E2E test:**` line naming the covering spec, and a `**Ticket:**` line.
- When a feature that adds a page or an API route is complete, `docs/feature-list/features.md`, a story file here, and an e2e spec change with it (task-cleanup does this at feature completion); the repository's `scripts/require-feature-checklist.sh` can check it.

## Files

| File | Covers |
| ---- | ------ |
