# Domain-Vocabulary Spec Gate (R-330)

Design doc. Status: approved 2026-07-07, pending implementation plan.

## Motivation

Domain vocabulary chosen without a deliberate discussion at spec time bakes into
pervasive naming and becomes a cross-cutting refactor to change. Concrete case:
the distributed-system-demo coined `world` for the state of the simulated system
(`WorldState` in `@demo/shared`, a whole `services/worldState/` tree,
`emptyWorld`, `applyTelemetry`, `applyNodeSpawning`, `createWorldStore`). It is a
defensible simulation metaphor but not a framework standard, and for a
distributed system `systemState` / `clusterState` reads more precisely. Nobody
decided `world` vs `system` up front, so one undiscussed choice spread across 20
files in 5 directories. R-330 makes that decision a required, gated step of spec
writing so it happens once, cheaply, before it propagates.

## Rule R-330 (extends the R-3xx naming block)

R-330 sits above R-315/R-316/R-317: those govern how a name is formed once the
lexicon exists; R-330 establishes the domain-noun lexicon itself. Proposed text:

> R-330: Establish the domain vocabulary before naming propagates. During
> superpowers spec writing, run an intense domain-vocabulary round before
> presenting the design. The spec is not complete until it carries a committed
> domain glossary (the project's ubiquitous language) that all subsequent file,
> function, and type naming conforms to. Prefer domain-precise terms over
> evocative metaphors unless the metaphor is a framework standard (ECS `World`,
> Cucumber `World`).
> Enforcement: hook:domain-vocabulary-gate (advisory), hook:spec-glossary-check
> (advisory).

Recorded in PROTOCOL.md Appendix A with the world/distributed-system-demo origin.

## Components

### Hook A: domain-vocabulary-gate (the trigger)

- Event: `PreToolUse`, new `Skill` matcher in `settings.json`.
- Logic: read stdin JSON; if `.tool_input.skill == "superpowers:brainstorming"`,
  emit `hookSpecificOutput.additionalContext` mandating the domain-vocabulary
  round plus the glossary artifact. Same additionalContext contract as
  `audit-signal-check.sh`.
- Behavior: advisory, never blocks, never sets a permission decision; silent for
  every other skill and every non-Skill tool. `set -euo pipefail`; if `jq` is
  missing or input is malformed, exit 0 silently so a hook fault never breaks a
  tool call.
- Injected text (draft): "domain-vocabulary-gate (R-330): before presenting the
  design, run an intense domain-vocabulary round. The spec is incomplete until it
  carries a '## Domain vocabulary' section: each domain noun as `term - meaning -
  chosen over: <alternatives> because <reason>`. Prefer domain-precise terms over
  metaphors unless a framework makes the metaphor standard."

### Hook B: spec-glossary-check (the backstop)

- Event: `PostToolUse`, appended to the existing `Write` matcher in
  `settings.json` (alongside new-file-header-reminder, flat-directory-reminder).
- Logic: read stdin JSON; take `.tool_input.file_path`; if it matches
  `**/docs/superpowers/specs/*-design.md`, read the written file and check for a
  `## Domain vocabulary` heading followed by at least one entry line containing
  `chosen over:`. If absent, emit an additionalContext reminder that the spec is
  incomplete without the glossary.
- Behavior: advisory, never blocks; silent for any other path. Same fault
  tolerance as Hook A.

### Glossary artifact

A `## Domain vocabulary` section inside the design doc (one artifact, not a
separate file). Entry format:

`term - what it means in this domain - chosen over: <alternatives> because <reason>`

The `chosen over` clause is the load-bearing part: it forces the metaphor-vs-
precise decision to be written down. `world` had no such line because the
discussion never happened.

## Wiring and registration (R-516)

- `settings.json`: add `{ "matcher": "Skill", "hooks": [domain-vocabulary-gate] }`
  under `PreToolUse`; append `spec-glossary-check` to the `PostToolUse` `Write`
  matcher's hooks array.
- `manifest.json`: two advisory entries, both id `R-330`, tier `advisory`,
  severity `warn`, autofix false, enforcers `hook:domain-vocabulary-gate` and
  `hook:spec-glossary-check`.
- `PROTOCOL.md`: Appendix A origin note; hook descriptions in the hook catalog.
- SessionStart `enforcement-guard-check` then verifies both hooks stay registered
  every session automatically.

## Testing

Two fixture tests in `~/.claude/hooks/tests/`, run by `run-tests.sh`:

- `domain-vocabulary-gate.test.sh`: feeds a `PreToolUse` payload with
  `tool_input.skill = "superpowers:brainstorming"` and asserts additionalContext
  is emitted (positive); feeds another skill name and a non-Skill tool and
  asserts silence (negatives).
- `spec-glossary-check.test.sh`: feeds a `PostToolUse` Write payload for a
  spec-doc path whose content lacks a glossary and asserts a reminder
  (positive); feeds one whose content has a `## Domain vocabulary` section with a
  `chosen over:` entry and asserts silence; feeds a non-spec path and asserts
  silence (negatives).

## Verify first during implementation

Confirm the `Skill` tool actually fires `PreToolUse` and that the invoked skill
name arrives at `.tool_input.skill`. If the harness exposes it under a different
key or does not fire PreToolUse for `Skill`, Hook A's matcher/extraction changes;
nothing else in the design does. This is the one unverified assumption.

## Domain vocabulary

- domain-vocabulary round - the intense back-and-forth at spec time that settles
  the project's domain nouns - chosen over: "naming discussion" because it names
  the deliverable (a settled vocabulary), not just the activity.
- ubiquitous language - the shared domain vocabulary a spec commits to and all
  naming conforms to - chosen over: coining a new term because it is the
  established DDD term for exactly this concept (a framework-standard metaphor,
  per R-330's own exception).
- spec gate - a rule enforced at the spec-writing boundary rather than at
  implementation - chosen over: "hook" because the hook is only the mechanism;
  the gate is the boundary being enforced.
- trigger (Hook A) - the hook that fires when spec writing begins and injects the
  mandate - chosen over: "reminder" because it initiates the requirement rather
  than merely recalling it.
- backstop (Hook B) - the hook that verifies the finished spec carries the
  glossary - chosen over: "validator" because it does not block; it catches a
  miss and reminds, consistent with the advisory tier.
