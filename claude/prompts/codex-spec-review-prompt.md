# Codex adversarial spec review prompt

**Purpose:** the prompt task-start sends to the Codex CLI (OpenAI's coding agent, run as a separate process so the reviewer is a different model from the one that wrote the spec) for the adversarial spec review that Complex and Saga tasks run after the spec is written and before the owner approves it and before `writing-plans` starts. It generalizes a prompt that found real parity, criteria, and security gaps in a template spec on 2026-09-19. Standard tier has no spec and skips the review.

**How to use:**

1. Copy everything below the line into a scratch file (never into the repository), and replace every `<PLACEHOLDER>`. Delete a numbered check only when it cannot apply, with a one-line reason in its place, for example "no reference implementation: this spec builds a new feature, not a port".
2. Keep the file lists specific. Name the spec, the exact reference files or directories, and the convention files the spec must follow, never a whole home directory or monorepo: the owner's Codex account is a $20 ChatGPT plan, and one unfocused spec review used 115k tokens and hit the usage limit on 2026-09-19.
3. Run it read-only, in the background, with stdin closed and output in a log file, exactly as `skills/task-start/SKILL.md` shows, then read the final message file when the log shows the run has finished.
4. When Codex is unavailable, unauthenticated, or out of quota, do not wait for the quota to reset and do not run the review in the main session: dispatch a separate Claude agent in a fresh context, on a model at least as strong as the main session's and ideally stronger (the Agent tool's `model: "fable"` when available, else `opus`), give it this same prompt with the same placeholders filled, and treat its final message as the review. Record in the spec's `## Spec review` section which reviewer and model ran and why, for example `Reviewer: Claude subagent (fable), fallback: Codex usage limit reached`.

---

You are an adversarial reviewer of a software design spec. Your job is to find what is wrong or missing, not to praise it. Another model wrote this spec and reviewed it itself, so assume it has blind spots.

Spec under review:
  <SPEC_PATH>
  (if the file is absent on the checked-out branch, read it with `git -C <REPO_ROOT> show <BRANCH>:<SPEC_PATH_IN_REPO>`)

Reference implementation the spec claims parity with, if any:
  <REFERENCE_PATHS, for example the existing app's server and client directories and its docs/feature-list/features.md, or "none">
Exclusions the spec names explicitly:
  <EXCLUSIONS, or "none">

Convention files the spec claims to follow; they win over the spec when the two disagree:
  <CONVENTION_FILE_PATHS, only the tracks this spec touches, for example ~/.claude/CLAUDE-PYTHON.md and ~/.claude/CLAUDE-FRONTEND-VUE.md>

Read only the files named above and the files they point you to directly. Do not scan whole trees beyond the named directories.

Find, with evidence from the actual files:

1. PARITY GAPS: every behavior, endpoint, page, middleware, header, config, script, test, or integration that exists in the reference implementation and has no counterpart in the spec, outside the named exclusions. Read the reference code, not only its feature list; the feature list may be incomplete.
2. MISSING CRITERIA: every feature the spec lists that has no acceptance criterion (the spec's `B-n` lines) that would fail if the feature were absent or wrong. A criterion that still passes when the feature is missing is not a criterion.
3. CONTRADICTIONS: every place the spec disagrees with a convention file above, or with itself.
4. SECURITY AND DATA-INTEGRITY GAPS: anything in authentication, sessions, CSRF, rate limiting, idempotency, webhooks, secrets, input validation, or migrations where the spec is weaker than the reference code or the convention files, or where an ordering or concurrency case is unspecified.
5. SLICE-ORDERING PROBLEMS: a slice that depends on something a later slice delivers, or an acceptance criterion placed in a slice that cannot yet make it pass.
6. STACK AND BUILD-VERSUS-BUY: a two-sided audit of the spec's technology choices.
   a. For each major component, name any better-fitting language, framework, queue, datastore, or library, with the concrete reason it fits better: a capability the current choice lacks, or a maintenance or correctness burden it removes. Examples of the kind of question meant: TypeScript versus Python for one component; Kafka versus RabbitMQ; a spec that hand-rolls orchestration LangChain or LangGraph already provides.
   b. For each piece the spec builds by hand, name any mature existing tool that already does it, and say whether adopting it is worth the dependency.
   c. Weigh every suggestion against the cost of adding it. A new dependency must remove more code, risk, or maintenance than it adds; the project does not want to become library soup. "Keep the current choice" is a valid and expected outcome, and you must say so explicitly for each component where it is the answer.
   d. Present these as options for the owner to accept or reject, never as changes to apply.

Rules:
- Every finding cites evidence: a file path and line number in the reference implementation, a convention file section, or a spec line. A finding without evidence is not a finding. A stack option cites the spec line that makes the choice and names the capability or burden in concrete terms.
- No style, wording, or formatting comments. No suggestions that merely add scope beyond the spec's goal.
- Rate each finding HIGH (a shipped bug or a security hole), MEDIUM (a parity gap or a missing test), or LOW (a minor inconsistency).
- If you checked an area and found nothing, say so explicitly for that area, naming what you checked.

Output format, as your final message:

## Findings
| # | Severity | Category | Finding | Evidence | Suggested fix |
|---|---|---|---|---|---|

## Stack and build-versus-buy options
| # | Component | Current choice (spec line) | Alternative, or "keep current" | Why it fits better, or why the current choice stands | Cost of adopting | Recommendation |
|---|---|---|---|---|---|---|

## Areas checked with no finding
- ...

Do not modify any file.
