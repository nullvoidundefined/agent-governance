# Application Baseline: Testing, Observability, and Agent Evals

Date: 2026-09-17
Status: draft, awaiting owner review
Slice: 02 in the agent-governance repo (after slice 01, before the template spec)

## Summary

Every application the owner builds must ship four test levels, full observability and telemetry, and, when it contains an agent or any LLM call, an eval harness. Today the rulebook carries observability rules (R-341 to R-346) and test-quality rules (R-401 to R-412) but no rule naming the four test levels, no tracing rule, and no eval rules at all. The spec template has an `## Observability` heading but no `## Testing` or `## Evals` heading, and the hook that reminds on a thin spec checks only three sections.

This spec adds eight rules, two spec-template headings with their hook checks, and one pointer line in each build skill, so the baseline is demanded at spec time by a hook rather than remembered at build time. The eval rules distill two inputs: an audit of Voyager 1.0's judge eval harness and a survey of current LangGraph eval practice.

## Domain vocabulary

- Test level - one of unit, integration, end-to-end, smoke; each has its own runner and CI job - chosen over: "test type" because the levels are ordered by how much of the deployed system they exercise, and the ordering is the point.
- Eval - a scored run of an agent against a dataset case, producing a verdict rather than a pass or fail assertion - chosen over: "agent test" because a test asserts and an eval scores, and the two gate differently (R-425).
- Eval level - one of per-node, state snapshot, trajectory, judge, simulation - chosen over: Voyager 1.0's three "tracks" because tracks were three runners for three case types, while levels are five views of one run.
- Judge - a model call that scores an agent output against a rubric and returns a structured verdict - chosen over: "grader" because the ecosystem libraries (`openevals`, `agentevals`) use judge.
- Gating judge - the judge whose verdict can fail a CI run; it must come from outside the agent's model family - chosen over: "primary judge" because what distinguishes it is the gate, not precedence.
- Advisory judge - a judge whose verdict is reported but never fails a run; may share the agent's model family - chosen over: "secondary judge" for the same reason.
- Trajectory - the ordered list of tool calls, with arguments, an agent made during one run - chosen over: "trace" because a trace is the observability artifact a trajectory is extracted from.
- Golden trajectory - the reference trajectory a dataset case carries, matched in strict, unordered, subset, or superset mode - chosen over: "expected tool calls" because the match mode is part of the reference.
- State snapshot - the LangGraph checkpoint of graph state after a super-step, read through a test-owned checkpointer - chosen over: "intermediate state" because the checkpointer is the mechanism the assertion depends on.
- Must-not predicate - a structured rule on an adversarial case (`{type, value}`) that the runner evaluates deterministically; a hit fails the case regardless of the judge - chosen over: Voyager 1.0's free-text `must_not` strings because free text was matched by five regexes covering a fraction of the authored rules.
- Baseline - the committed report the current eval run is compared against; the gate is "no worse than baseline" - chosen over: an absolute threshold because judge scores carry a few points of noise per run and an absolute threshold turns that noise into flaky CI.
- Dataset hash - the content hash of the eval dataset files, stamped into every report - chosen over: a version number because a hash cannot be forgotten when a case is edited.

## Goals

1. No application spec is written without naming the four test levels and the observability it adds; a hook reminds when either is missing.
2. No agentic application spec is written without an `## Evals` section naming its dataset, levels, judges, and gate; the same hook reminds when the spec describes an agent and the section is missing.
3. The eval rules encode what Voyager 1.0's harness got right (the two-layer adversarial verdict, the hand-authored attack catalog, the persona archetypes, the compare-to-baseline diff) and forbid what it got wrong (free-text judge output, scattered judge models, a thin must-not detector, no CI gate, no dataset versioning, no cost capture, no calibration).
4. The build skills point at the baseline so a session that starts from task-start, feature-create, or build-by-slice reaches it without recall.

## Non-goals

- Porting Voyager 1.0's 54 attacks, 6 persona archetypes, or 17 seed scenarios. Those are Voyager 2.0 spec content.
- Choosing LangSmith or Langfuse. R-347 makes the trace backend configuration; the choice is per project.
- A reference eval runner implementation. The template workstream ships one under `evals/`; this slice ships the rules it must satisfy.
- Extending `observability-reminder.sh` to check spans. R-347 is manual in this slice.
- Judge calibration tooling. R-423 requires a held-out human-labeled set; the tooling that computes agreement is a Later item.

## Decisions already made

| Decision | Choice |
|---|---|
| Home | agent-governance repo, same slice branch as slice 01, after PR 7 of slice 01 merges |
| Gating judge provider | Outside the agent's model family (OpenAI or Gemini when the agent is Claude); same-family judges advisory only |
| Eval ownership | In-repo harness on `agentevals` and `openevals` with committed fixture datasets; hosted platforms optional as trace stores |
| Tracing | OpenTelemetry spans with GenAI semantic conventions; backend is configuration |
| Mechanization | Extend the existing `spec-glossary-check.sh` hook rather than add a second spec hook |

## Current state (findings)

### Rulebook

R-341 to R-346 cover request IDs, structured logs, analytics events, error reporting, health endpoints, and client telemetry. No rule covers distributed tracing or LLM-call spans. R-401 to R-412 cover test quality, bug-fix order, negative-input tests, and the slice lock. No rule names the four test levels; the portfolio-level project instructions do (Vitest, Playwright, integration on a real database, `npm run smoke`), but they are project instructions, not rules, and carry no enforcer. No rule mentions evals, judges, datasets, or trajectories.

### Spec template and hook

`prompts/spec-template.md` carries Goal, Inputs, Outputs, Acceptance criteria, Invariants, Failure modes, State transitions, Non-goals, Dependencies, Observability, Security, and Domain vocabulary. `hooks/spec-glossary-check.sh` fires on every Write to `docs/superpowers/specs/*-design.md` and reminds when Domain vocabulary (with a `chosen over:` entry), Acceptance criteria, or Non-goals is missing. It never blocks and exits 0 on any fault. Its fixture is `hooks/tests/spec-glossary-check.test.sh`.

### Voyager 1.0 eval harness

Three separate tracks with three runners and three report shapes: a cooperative eval (16 generated personas over 6 archetypes, a 5-dimension judge, 9 deterministic assertions, a weighted score), an adversarial eval (54 hand-authored attacks over 8 categories, an LLM antagonist, a two-layer verdict where deterministic must-not hits are authoritative), and a production replay judge (6 dimensions over a single turn, the only schema-enforced judge). None runs in CI; only the harness's own unit tests do. Judge output in two of three judges is free-text JSON recovered by slicing from the first brace to the last, which caused one real incident when a model rejected assistant prefill. Three different judge models are hardcoded in three files. The must-not detector implements 5 predicates against dozens of authored rules. The cross-model judge script's output parser does not match the reporter's output and would fail every run. No trajectory, per-node, or state assertions exist; no dataset hash is stamped into reports; token usage is never read; no human-labeled calibration set exists.

### Current LangGraph eval practice

Five levels are taught: per-node pytest with fixture state, state-snapshot assertions through a checkpointer, trajectory match in four modes with `agentevals`, final-response LLM judge with structured output through `openevals`, and multi-turn simulation with a simulated user. Judges should use decomposed rubrics, structured verdicts, order swapping on pairwise comparisons, a provider outside the agent's family for gating, and periodic calibration against human labels. Gates compare to a committed baseline rather than an absolute pass rate; a sampled run gates each PR, the full suite runs nightly and on prompt change; repeated runs with majority vote absorb judge noise. The libraries run standalone with in-repo datasets; tracing through OpenTelemetry keeps the backend a configuration choice.

## Design

### 1. Rulebook additions

Eight rules. Each gets a norm line in `claude/CLAUDE.md` with its enforcer bracket, a Spec block in `claude/rulebook/reference.md`, and a manifest entry when the enforcer is a hook. Numbering: R-347 joins the observability block; R-413 joins testing; R-421 to R-426 open an agent-evals sub-block inside testing.

**R-347 (observability, manual).** Trace every LLM call and every agent node as an OpenTelemetry span carrying the GenAI semantic-convention attributes (model, input and output token counts, tool name, and the request ID from R-341); the trace backend (LangSmith, Langfuse, or an OpenTelemetry collector) is configuration read by one module under `clients/`, never a code dependency elsewhere.

**R-413 (testing, hook:spec-glossary-check for the spec section, manual for the rest).** Ship four test levels with every application from its first feature: unit (no I/O), integration (real database and real Redis, never a mock of the thing under test), end-to-end (a browser driving the running stack, asserting data and behavior, never element presence alone), and smoke (health, auth, and one error path against a deployed instance). Each level has a named runner, a named CI job, and a paragraph in the spec's `## Testing` section.

**R-421 (evals, manual).** Keep every eval dataset in the repo as fixture files under `evals/datasets/`, one file per case type; stamp the dataset content hash, the agent model, the prompt version, and the judge model into every eval report.

**R-422 (evals, hook:spec-glossary-check for the spec section, manual for the rest).** Evaluate every agent at five levels: per-node unit tests with fixture state, state-snapshot assertions through a test-owned checkpointer, trajectory match against golden trajectories with the match mode named per case, a final-response judge, and multi-turn simulation with a simulated user. The spec's `## Evals` section names the dataset path, which cases run at which level, the gating and advisory judges, and the gate.

**R-423 (evals, manual).** Return every judge verdict through a structured-output schema (a forced tool call), score a decomposed rubric with one field per criterion and a justification per score, swap candidate order on pairwise comparisons and average, and take every gating verdict from a judge outside the agent's model family; a same-family judge is advisory only. Resolve every judge model from one configuration value, preflight it with a trivial call before any paid run, and keep a held-out human-labeled set the judge is checked against.

**R-424 (evals, manual).** Give every agent a hand-authored adversarial catalog covering at least grounding, specificity, topic integrity, prompt integrity (injection through the user turn and through tool results), persistence under pressure, resource abuse, safety, and inventory integrity; each case carries its must-not rules as structured predicates the runner evaluates deterministically, and a deterministic hit fails the case regardless of the judge.

**R-425 (evals, manual).** Gate evals on regression against a committed baseline, never on an absolute score: a sampled run on every PR that touches agent, prompt, or tool code; the full suite nightly and on any prompt change; majority vote over repeated runs for judge-scored cases; token cost and latency read from provider usage into every report.

**R-426 (evals, manual).** Run every eval case type (cooperative, adversarial, production replay) through one runner emitting one report schema; a new case type is a plugin to that runner, never a second runner.

### 2. Spec template and hook

`prompts/spec-template.md` gains two headings, placed after `## Dependencies`:

- `## Testing`: one paragraph per level (unit, integration, end-to-end, smoke) naming the runner, the CI job, and the behaviors from `## Acceptance criteria` that level proves. A level with nothing to prove says so in one line.
- `## Evals`: present when the feature makes an LLM call or runs an agent. Names the dataset path under `evals/datasets/`, the cases at each of the five levels, the gating judge and the advisory judges with their providers, and the gate (baseline path, sample size per PR, nightly schedule).

`hooks/spec-glossary-check.sh` gains two checks in the same jq program, same advisory behavior:

- `## Testing` is required on every design spec, and the section body must contain the words `unit`, `integration`, `end-to-end` or `e2e`, and `smoke`. The reminder names which of the four is missing.
- `## Evals` is required when the spec content matches, case-insensitively, any of `agent`, `LLM`, `language model`, `prompt`, `LangGraph`, `tool call`, or `model call`. The reminder states which word triggered it.

The manifest entry for R-330 gains R-413 and R-422 as sibling entries on the same hook. `hooks/tests/spec-glossary-check.test.sh` gains cases: a spec without Testing reminds; a spec with Testing naming three of four levels reminds naming the fourth; a spec mentioning an agent without Evals reminds; a spec mentioning no agent without Evals is silent; a complete agentic spec is silent.

### 3. Build skills

One pointer each, no rationale:

- `skills/task-start/SKILL.md`, Complex and Saga process blocks: "Spec: Yes, carrying `## Testing` at four levels (R-413), `## Observability`, and `## Evals` when agentic (R-422)."
- `skills/feature-create/SKILL.md`, the scaffolding checklist: a step that creates `evals/datasets/` with a `.gitkeep` and records the eval dataset path in the feature doc when the plan names an agent or LLM call.
- `skills/build-by-slice-require-review/SKILL.md`, the hard first step: "Read the spec, its flows, its acceptance criteria, and its Testing, Observability, and Evals sections; a slice plan for an agentic feature includes the PR that lands its evals."

## Acceptance criteria

- B-1: `manifest.test.sh` passes with the eight new rules registered (R-413 and R-422 with `hook:spec-glossary-check`, the rest with no manifest entry because they are manual).
- B-2: `claude/CLAUDE.md` carries one norm line per new rule, each ending in an enforcer bracket, and `claude-md-lint.test.sh` passes.
- B-3: The hook reminds on a design spec with no `## Testing` section, naming the section.
- B-4: The hook reminds on a `## Testing` section that names unit, integration, and smoke but not end-to-end, naming end-to-end.
- B-5: The hook reminds on a spec whose body contains the word "agent" and has no `## Evals` section, naming the trigger word.
- B-6: The hook is silent on a spec with no agent, LLM, prompt, or model-call word and no `## Evals` section.
- B-7: The hook is silent on a spec carrying all sections including a four-level Testing and an Evals section.
- B-8: The three skills each contain the pointer sentence, verified by grep in `convention-rules.test.sh` or a new skills fixture.
- B-9: `enforce/tests` and `hooks/tests` suites are green at the end of every PR.
- B-10: After `sync.sh`, `hook-integrity-check.sh` reports no drift.

## Slice and PR breakdown

| PR | Concern | Size |
|---|---|---|
| 1 | Rulebook Spec blocks, CLAUDE.md norm lines, manifest entries for R-413 and R-422 | 3 files, about 120 lines |
| 2 | Spec template headings, hook extension, fixture cases | 3 files, about 90 lines |
| 3 | Skill pointers, README, sync, hashes, handoff, slice record | 6 files, small |

## Later list

- Judge calibration tooling (agreement statistics against the human-labeled set).
- Extending `observability-reminder.sh` to detect an LLM client without span emission.
- A reference `evals/` runner in the template workstream that satisfies R-421 to R-426.

## Risks

- The `## Evals` trigger words will fire on non-agentic specs that mention "prompt" in another sense (a CLI prompt, a permission prompt). The hook is advisory and names the trigger word, so a false reminder costs one line of reading; the template's heading convention allows "## Evals: none, <reason>".
- Eight rules in one PR is a large rulebook diff. Mitigation: the PR body lists each rule with its Voyager 1.0 finding or research citation, and the reviewer is pointed at R-423 and R-425 as the two that change how CI behaves.
