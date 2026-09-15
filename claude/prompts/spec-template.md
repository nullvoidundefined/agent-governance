# Spec template

**Purpose:** the fixed headings a behavioral spec carries so the test author (R-705, R-707) and `agents/spec-conformance-review.md` have explicit requirements to work from. Copy the headings below into `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` (the `brainstorming` skill's path) or into an externally written spec during `spec-grounding`. `hooks/spec-glossary-check.sh` reminds when a design doc lacks `## Acceptance criteria`, `## Non-goals`, or the `## Domain vocabulary` glossary (R-330). Delete a heading only with a one-line reason under it; an absent heading reads as "not considered".

**How to use:** keep prose short under each heading. The load-bearing section is `## Acceptance criteria`: one numbered behavior per line, each one a slice the harness runs as RED then GREEN (R-412). A criterion a test cannot fail is not a criterion; move it to `## Non-goals` or rewrite it.

---

# <Feature name>

## Goal

One paragraph: what changes for the user or the system, and why now.

## Inputs

What arrives, from where, in what shape (request body, event, file, CLI args). Name the schema module when one exists.

## Outputs

What leaves, in what shape, with which status codes or events. Name the response envelope.

## Acceptance criteria

Numbered, one behavior each, each mechanically assertable. Order them the way the implementation needs them.

- B-1: <subject> <verb> <observable result> when <condition>.
- B-2: ...

## Invariants

Properties that hold before and after every behavior above (a total never goes negative, a row is never orphaned, an ID is stable across retries).

## Failure modes

For each: the trigger, the visible outcome, and whether the caller can retry. Cover invalid input (R-406), the dependency being down or slow (timeout, R-346), partial failure mid-operation, and a concurrent second call.

## State transitions

Only when the feature owns state: the states, the allowed transitions, and who triggers each. Otherwise write "none".

## Non-goals

What this spec deliberately does not do, so the critic does not report it and the implementer does not build it.

## Dependencies

Existing modules this reuses (R-308, with paths), third-party packages it needs (each one justified), and migrations it requires.

## Observability

The log lines, request-ID propagation (R-341), analytics events from the registry (R-343), and health-check changes (R-345) the behavior adds.

## Security

Who may call it, what is validated at the boundary, what is never logged (R-104).

## Domain vocabulary

- <term> - <meaning in this domain> - chosen over: <alternatives> because <reason>.
