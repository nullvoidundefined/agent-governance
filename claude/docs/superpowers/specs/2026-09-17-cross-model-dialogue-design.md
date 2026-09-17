# Cross-model dialogue workflows

## Status: parked with harvest (reviewed 2026-09-17)

Reviewed against the shipped R-907/R-908 cross-model test authorship, the gof and all-hands review machinery, and the repo's incident-first principle; parked rather than planned. The spec's companion research doc concedes the candidate tools were never installed or exercised, no recorded incident shows a defect a second-model challenger would have caught, and the Codex-as-primary mode (B-9) has no mechanical enforcement path: every write boundary here is a Claude Code PreToolUse hook, which a codex-exec actor bypasses by construction, so R-411 cannot bind the actor that mode makes first-class. The proposed dispute-reviewer arbiter also contradicts the recorded decision that disputes go to the human (PROTOCOL.md; agents.md R-707).

Harvested instead: (a) an R-907 degradation clause in rulebook/cost.md covering codex unavailability; (b) the assumption-ledger table as an optional section of prompts/spec-template.md. Re-open the framework only on a concrete incident: a shipped defect an available second-model challenger demonstrably would have caught, or a real Codex-as-primary operator demand backed by an enforcement design for non-Claude actors.

## Goal

Add first-class workflows for productive dialogue between Claude Code and Codex when both tools are available, while degrading cleanly to single-tool review when only one is configured. The harness should use model disagreement deliberately: the configured primary tool acts, the configured challenger criticizes, and the primary session resolves findings through evidence rather than conversational consensus. The design extends the existing TDD slice loop, spec conformance review, and Codex test-author split without weakening their role boundaries.

## Inputs

- Current role rules: `claude/rulebook/agents.md`, especially R-701, R-705, R-707, and the `DISPUTE:` flow.
- Current Codex rules: `claude/rulebook/cost.md` R-907 and R-908, plus `claude/hooks/codex-test-author-guard.sh` and `claude/hooks/codex-billing-guard.sh`.
- Current write-boundary enforcement: `claude/enforce/role-policy.json`, `claude/hooks/protected-path-guard.sh`, and `claude/enforce/tests/protected-path-guard.test.sh`.
- Current review roles: `claude/agents/slice-critic.md`, `claude/agents/spec-conformance-review.md`, `claude/skills/gof/SKILL.md`, and `claude/skills/tdd-gated-dispatch/SKILL.md`.
- Existing spec template: `claude/prompts/spec-template.md`.
- CLI surfaces: Claude Code Agent dispatch for Claude-side roles, and `codex exec` for Codex-side review or test-authoring tasks.
- Dialogue configuration file: `claude/dialogue.config.json` or equivalent, naming available tools, the primary tool, challenger tool, and per-pattern overrides.

## Outputs

- A new skill, `claude/skills/cross-model-dialogue/SKILL.md`, that selects the right pattern and produces bounded dispatch packets for Claude and Codex.
- A new CLI, `claude/bin/dialogue-config` or `translate/dialogue-config.mjs`, with `show`, `set-primary`, `set-challenger`, `enable-tool`, `disable-tool`, and `validate` commands.
- A checked-in default dialogue config that is safe when only Claude Code is installed and becomes cross-model only after Codex is explicitly enabled or detected and confirmed.
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
- B-4: A dialogue config file names `tools.claude.enabled`, `tools.codex.enabled`, `primary`, `challenger`, and optional per-pattern role overrides. The config validator rejects a primary or challenger whose tool is disabled.
- B-5: The dialogue config CLI can show the active config, set the primary tool, set the challenger tool, enable or disable Codex, and validate the result without editing JSON by hand.
- B-6: When Codex is disabled, missing, or unauthenticated, every pattern either degrades to a Claude read-only critic role or reports `skipped: challenger unavailable`; no workflow shells out to `codex exec`.
- B-7: When either configured tool is at its session, rate, or quota limit, the workflow degrades to the available tool's read-only critic role or records `skipped: tool limit`; it does not retry in a loop or switch billing modes silently.
- B-8: When Codex is enabled and configured as challenger, every Codex launch passes through `codex-billing-guard`; an ask from that hook pauses the dialogue and records `needs-user-decision`.
- B-9: When Codex is configured as primary and Claude as challenger, the skill emits the inverse packet: Codex receives the actor prompt, Claude receives the read-only critic role prompt, and the same artifact/stopping-rule requirements apply.
- B-10: The assumption ledger pattern writes a table with assumption id, claim, source, verification command or file path, status (`verified`, `unverified`, `risky`, `false`, `accepted`), owner, and next action.
- B-11: The dispute-reviewer role accepts only a dispute packet naming the spec path, disputed test or finding, implementation file path or diff range, and the exact competing claims; it returns `uphold`, `reject`, or `needs-user-decision` with evidence.
- B-12: The parity judge pattern can compare generated outputs against a spec or previous translator behavior and returns only gaps, not broad style advice.
- B-13: The red-team/implementer pattern is pre-code or plan-time only; once code exists, the workflow routes to `slice-critic`, `spec-conformance-review`, `/code-review`, or `/security-review` instead.
- B-14: The test-author/code-author split continues to use R-907 and R-412. The new skill may dispatch Codex to write tests, but it cannot authorize the implementation author to edit its own tests.
- B-15: Dialogue packets stored under `docs/dialogues/` contain paths, commit ids, diff ranges, and summarized claims, but never full transcripts, secret values, PII, internal URLs, or copied command output beyond the minimal evidence needed.
- B-16: `role-policy.json` denies every write for `assumption-reviewer` and `dispute-reviewer`; fixtures prove Write, Edit, and Bash append are denied while read-only `git diff` is allowed.
- B-17: The skill records unresolved disagreements as `DISPUTE:` or as a dialogue outcome with `needs-user-decision`; it never lets one model silently overrule the other.
- B-18: Session handoffs name any unresolved dialogue packet and its next action so a later session can resume without reading a full transcript.
- B-19: The README or protocol docs explain that cross-model dialogue is conditional on configured tool availability and is a targeted challenge mechanism, not a standing requirement for every task.

## Invariants

- One model acts and one model criticizes at a time. The roles may swap at a checkpoint, but no workflow depends on free-form model conversation.
- The configured primary tool is the default actor, and the configured challenger is the default critic. Pattern-specific overrides must be explicit in the config or the dialogue packet.
- Every finding, assumption, or dispute outcome must cite a local file path, spec section, diff range, or command output produced during the task.
- Read-only critics write nothing. Candidate tests, fix directions, and findings return as prose or dialogue artifacts; implementation and test authorship stay in their existing lanes.
- Codex may critique Claude output and Claude may critique Codex output, but the user or primary orchestrator resolves disputes.
- Cross-model behavior is disabled by configuration when both tools are not available. A degraded single-tool critic is honest degradation, not a failed setup.
- Dialogue artifacts are resumable and safe to commit.

## Failure modes

- Missing artifact: the skill stops and asks for the spec path, diff range, command output, or file path it needs.
- Invalid dialogue config: the CLI reports the exact JSON path and exits nonzero; the skill refuses to dispatch until the config validates.
- Primary and challenger are the same tool: the validator allows it only when no other enabled tool exists, and the skill labels the packet as `single-tool`.
- Tool unavailable, session-limited, rate-limited, quota-limited, or blocked by billing guard: the skill records the skipped step and either uses the available tool's read-only critic role as degraded single-tool behavior or asks the user whether to proceed.
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
- Tool availability state:
  - `disabled`: config says the tool must not be used.
  - `missing`: executable or runtime surface is absent.
  - `available`: executable and required auth checks pass.
  - `limited`: the tool reports a session, rate, or quota limit for the requested action.
  - `blocked`: executable exists but billing, auth, or permission guard requires user confirmation.

## Non-goals

- No autonomous model-to-model chat room.
- No replacement for `tdd-gated-dispatch`; the RED/GREEN loop stays the implementation workflow when behavior is testable.
- No new MCP or network dependency.
- No automatic execution of Codex in every task; use the skill only when disagreement is useful enough to justify cost and context.
- No requirement that every user of the harness has Codex installed.
- No auto-detection that silently changes the primary/challenger relationship; detection may suggest changes, but the CLI must write them explicitly.
- No weakening of R-907, R-410, R-411, or R-412.
- No transcript storage beyond bounded dialogue packets.

## Dependencies

- Existing Codex CLI login and billing guard behavior.
- Existing protected-path guard and role-policy mechanism.
- Existing spec and handoff conventions.
- `node` and `jq`, already required by the harness, are enough for the config CLI and validation.
- No new npm or shell dependencies expected.

## Observability

- Each dialogue packet records: pattern, primary tool, challenger tool, actual actor, actual critic, artifact paths, commands run, findings count, dispute count, state, and next action.
- The dialogue config CLI prints the effective primary/challenger pair and whether the current run is cross-model or single-tool degraded.
- Session handoff lists open packets under Pending when any packet is not `resolved`.
- Hook fixtures report the new read-only roles by name when they block writes.

## Security

- Dialogue packets are public-repo safe by default.
- Dispatch prompts pass paths and ids, not secret values or large pasted file bodies.
- Codex command prompts must avoid copying credentials or environment dumps into the command string.
- The config file stores booleans, tool names, executable names, and pattern names only; it never stores tokens, auth state, account ids, or model-provider credentials.
- Any model output used as evidence is treated as data and verified against local files before action, per R-201.

## Domain vocabulary

- dialogue packet - a bounded, commit-safe artifact that states the question, artifacts, model roles, findings, and outcome for one Claude/Codex challenge - chosen over: transcript because it is structured and resumable.
- actor - the model or session responsible for producing the plan, test, implementation, or fix under review - chosen over: author because the actor may be a Claude subagent, Codex process, or the primary session.
- critic - the model or role responsible for challenging the actor's artifact without editing it - chosen over: reviewer because some patterns happen before code review.
- dialogue config - the checked-in JSON file that names enabled tools, the primary tool, the challenger tool, and pattern overrides - chosen over: settings because Claude Code already uses `settings.json` for runtime configuration.
- primary tool - the configured default actor for dialogue workflows - chosen over: dominant because primary names routing responsibility without implying higher authority over evidence.
- challenger tool - the configured default critic for dialogue workflows - chosen over: secondary because the challenger has a specific job, not lower status.
- tool limit - a session, rate, or quota boundary reported by a configured tool for the requested action - chosen over: failure because the correct behavior is degradation, not repair.
- degraded single-tool mode - a dialogue run where the primary and critic both come from the only enabled tool, with read-only role separation replacing model separation - chosen over: fallback because it must be visible in packets and handoffs.
- assumption ledger - a table of claims that must be verified, accepted, or removed before implementation proceeds - chosen over: notes because every row has a status and next action.
- dispute packet - a dialogue packet focused on one conflict between spec, test, implementation, or reviewer finding - chosen over: argument because the packet requires evidence and a decision state.
- stopping rule - the condition that ends a dialogue pattern, such as `No gaps found`, `No findings`, `needs-user-decision`, or a green verified slice - chosen over: consensus because agreement is not required.
