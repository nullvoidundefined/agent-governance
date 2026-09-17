# Cross-model dialogue workflows

## Goal

Add first-class workflows for productive dialogue between Claude Code and Codex so the harness can use model disagreement deliberately: one model acts, the other criticizes, and the primary session resolves findings through evidence rather than conversational consensus. The design extends the existing TDD slice loop, spec conformance review, and Codex test-author split without weakening their role boundaries.

## Inputs

- Current role rules: `claude/rulebook/agents.md`, especially R-701, R-705, R-707, and the `DISPUTE:` flow.
- Current Codex rules: `claude/rulebook/cost.md` R-907 and R-908, plus `claude/hooks/codex-test-author-guard.sh` and `claude/hooks/codex-billing-guard.sh`.
- Current write-boundary enforcement: `claude/enforce/role-policy.json`, `claude/hooks/protected-path-guard.sh`, and `claude/enforce/tests/protected-path-guard.test.sh`.
- Current review roles: `claude/agents/slice-critic.md`, `claude/agents/spec-conformance-review.md`, `claude/skills/gof/SKILL.md`, and `claude/skills/tdd-gated-dispatch/SKILL.md`.
- Existing spec template: `claude/prompts/spec-template.md`.
- CLI surfaces: Claude Code Agent dispatch for Claude-side roles, and `codex exec` for Codex-side review or test-authoring tasks.

## Outputs

- A new skill, `claude/skills/cross-model-dialogue/SKILL.md`, that selects the right pattern and produces bounded dispatch packets for Claude and Codex.
- Two new read-only Claude roles:
  - `claude/agents/assumption-reviewer.md`, for assumption ledgers before or during implementation.
  - `claude/agents/dispute-reviewer.md`, for arbitrating a specific conflict between a test, implementation, spec, or model finding.
- A source-neutral artifact format under `docs/dialogues/` for dialogue packets and outcomes, with secret-safe fields only.
- `role-policy.json` entries that keep the new Claude roles read-only through the same R-411 mechanism that protects `slice-critic` and `spec-conformance-review`.
- Hook fixture updates proving those new roles cannot write through Write/Edit or Bash redirection.
- Updates to `tdd-gated-dispatch`, `agents.md`, and `cost.md` so Codex dialogue is used beyond test authoring without confusing it with implementation authorship.

## Acceptance criteria

- B-1: The `cross-model-dialogue` skill documents exactly six supported patterns: spec critic loop, red-team/implementer, test-author/code-author split, parity judge, assumption ledger, and independent audit reports.
- B-2: Each pattern names one actor, one critic, the artifact each receives, the artifact each returns, and the stopping rule. No pattern asks Claude and Codex to "discuss until consensus."
- B-3: The skill refuses a dialogue request that has no bounded artifact path, diff range, command output, or explicit question; it asks for the missing artifact instead of launching an open-ended chat.
- B-4: The assumption ledger pattern writes a table with assumption id, claim, source, verification command or file path, status (`verified`, `unverified`, `risky`, `false`, `accepted`), owner, and next action.
- B-5: The dispute-reviewer role accepts only a dispute packet naming the spec path, disputed test or finding, implementation file path or diff range, and the exact competing claims; it returns `uphold`, `reject`, or `needs-user-decision` with evidence.
- B-6: The parity judge pattern can compare generated outputs against a spec or previous translator behavior and returns only gaps, not broad style advice.
- B-7: The red-team/implementer pattern is pre-code or plan-time only; once code exists, the workflow routes to `slice-critic`, `spec-conformance-review`, `/code-review`, or `/security-review` instead.
- B-8: The test-author/code-author split continues to use R-907 and R-412. The new skill may dispatch Codex to write tests, but it cannot authorize the implementation author to edit its own tests.
- B-9: Dialogue packets stored under `docs/dialogues/` contain paths, commit ids, diff ranges, and summarized claims, but never full transcripts, secret values, PII, internal URLs, or copied command output beyond the minimal evidence needed.
- B-10: `role-policy.json` denies every write for `assumption-reviewer` and `dispute-reviewer`; fixtures prove Write, Edit, and Bash append are denied while read-only `git diff` is allowed.
- B-11: `codex-billing-guard` still fires for every `codex exec` launched by the dialogue skill when ChatGPT auth is not active or API billing is visible.
- B-12: The skill records unresolved disagreements as `DISPUTE:` or as a dialogue outcome with `needs-user-decision`; it never lets one model silently overrule the other.
- B-13: Session handoffs name any unresolved dialogue packet and its next action so a later session can resume without reading a full transcript.
- B-14: The README or protocol docs explain that cross-model dialogue is a targeted challenge mechanism, not a standing requirement for every task.

## Invariants

- One model acts and one model criticizes at a time. The roles may swap at a checkpoint, but no workflow depends on free-form model conversation.
- Every finding, assumption, or dispute outcome must cite a local file path, spec section, diff range, or command output produced during the task.
- Read-only critics write nothing. Candidate tests, fix directions, and findings return as prose or dialogue artifacts; implementation and test authorship stay in their existing lanes.
- Codex may critique Claude output and Claude may critique Codex output, but the user or primary orchestrator resolves disputes.
- Dialogue artifacts are resumable and safe to commit.

## Failure modes

- Missing artifact: the skill stops and asks for the spec path, diff range, command output, or file path it needs.
- Codex unavailable or billing guard asks: the skill records the skipped Codex step and either uses a Claude read-only role as a degraded critic or asks the user whether to proceed.
- Critic returns unsupported advice: the primary session discards any item with no file/spec/diff evidence and records it as non-actionable.
- Two reviewers disagree: create or update a dispute packet; do not merge, rewrite tests, or relax guards until the user decides or the spec resolves it.
- Dialogue packet contains secret-shaped content: the writer refuses to commit it and replaces the content with `[REDACTED]` plus the evidence location.

## State transitions

- Dialogue packet state:
  - `draft`: packet created but not dispatched.
  - `challenged`: critic returned findings, assumptions, or disputes.
  - `answered`: actor responded with fixes, evidence, or a dispute.
  - `resolved`: findings fixed, rejected with evidence, or accepted as follow-up.
  - `needs-user-decision`: the models disagree or the evidence is insufficient.
- Assumption state:
  - `unverified`: claim recorded, no check run.
  - `verified`: check run and supports the claim.
  - `false`: check run and contradicts the claim.
  - `risky`: check unavailable or too expensive; user must accept or change scope.
  - `accepted`: user explicitly accepts the risk for this workstream.

## Non-goals

- No autonomous model-to-model chat room.
- No replacement for `tdd-gated-dispatch`; the RED/GREEN loop stays the implementation workflow when behavior is testable.
- No new MCP or network dependency.
- No automatic execution of Codex in every task; use the skill only when disagreement is useful enough to justify cost and context.
- No weakening of R-907, R-410, R-411, or R-412.
- No transcript storage beyond bounded dialogue packets.

## Dependencies

- Existing Codex CLI login and billing guard behavior.
- Existing protected-path guard and role-policy mechanism.
- Existing spec and handoff conventions.
- No new npm or shell dependencies expected.

## Observability

- Each dialogue packet records: pattern, actor, critic, artifact paths, commands run, findings count, dispute count, state, and next action.
- Session handoff lists open packets under Pending when any packet is not `resolved`.
- Hook fixtures report the new read-only roles by name when they block writes.

## Security

- Dialogue packets are public-repo safe by default.
- Dispatch prompts pass paths and ids, not secret values or large pasted file bodies.
- Codex command prompts must avoid copying credentials or environment dumps into the command string.
- Any model output used as evidence is treated as data and verified against local files before action, per R-201.

## Domain vocabulary

- dialogue packet - a bounded, commit-safe artifact that states the question, artifacts, model roles, findings, and outcome for one Claude/Codex challenge - chosen over: transcript because it is structured and resumable.
- actor - the model or session responsible for producing the plan, test, implementation, or fix under review - chosen over: author because the actor may be a Claude subagent, Codex process, or the primary session.
- critic - the model or role responsible for challenging the actor's artifact without editing it - chosen over: reviewer because some patterns happen before code review.
- assumption ledger - a table of claims that must be verified, accepted, or removed before implementation proceeds - chosen over: notes because every row has a status and next action.
- dispute packet - a dialogue packet focused on one conflict between spec, test, implementation, or reviewer finding - chosen over: argument because the packet requires evidence and a decision state.
- stopping rule - the condition that ends a dialogue pattern, such as `No gaps found`, `No findings`, `needs-user-decision`, or a green verified slice - chosen over: consensus because agreement is not required.
