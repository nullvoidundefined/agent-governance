# Codex pre-merge PR review prompt

**Purpose:** the prompt for the one blocking pre-merge review R-517 requires on every PR above trivial. By default it goes to a fresh Claude subagent on `sonnet`; it goes to the Codex CLI (OpenAI's coding agent, a different model from the one that wrote the code), or to a subagent on `opus`/`fable`, only when the owner opts in or the diff touches auth, money, or concurrency (owner decision 2026-09-23, IAN-333). The reviewer reads the PR's diff against the spec and the slice's acceptance criteria. It is the review every PR above trivial gets; there is no Copilot review (R-514). Each finding is fixed or answered with a reason in the PR before merge, and the PR body carries a `## Codex review` section carrying a `reviewer` line, a `model` line, a `range` line written as `<base>..<head>` whose head endpoint is the PR's head commit, and the findings with their dispositions, which `hooks/git-workflow-guard.sh` checks before `gh pr merge`.

**How to use:**

1. Copy everything below the line into a scratch file (never into the repository) and replace every `<PLACEHOLDER>`. With no spec (Standard tier), name the slice titles and the ticket as the requirements and write "none" for the spec.
2. Keep it focused: name the base and head refs and let Codex read only the changed files and the requirement documents. The owner's Codex account is a $20 ChatGPT plan with tight usage limits, and an unfocused review can exhaust it.
3. Default: dispatch a fresh Claude subagent (Agent tool, `model: "sonnet"`) with the filled prompt and treat its final message as the review. Codex, when opted in: run it read-only, in the background, with stdin closed and output in a log file, exactly as `skills/task-cleanup/SKILL.md` shows, then read the final message file when the log shows the run has finished.
4. When an opted-in Codex review is unavailable, unauthenticated, or out of quota, do not wait for the quota to reset and do not run the review in the main session: dispatch a separate Claude agent in a fresh context, on a model at least as strong as the main session's and ideally stronger (the Agent tool's `model: "fable"` when available, else `opus`), give it this same prompt with the same placeholders filled, and treat its final message as the review. Record in the PR's `## Codex review` section (the heading stays the same whichever reviewer ran) which reviewer and model ran and why, for example `Reviewer: Claude subagent (fable), fallback: Codex usage limit reached`.

---

You are an adversarial reviewer of a pull request. Your job is to find where the change is wrong, incomplete, or unsafe, not to praise it. Another agent wrote this code and its tests, so assume it has blind spots.

Repository: <REPO_ROOT>
Diff under review: `git -C <REPO_ROOT> diff <BASE_REF>...<HEAD_REF>` (start with `--stat`, then read each changed file in full where the hunk alone does not show the behavior).

Requirements the diff must satisfy:
  Spec: <SPEC_PATH, or "none (Standard tier)">
  Acceptance criteria for this PR: <the slice plan path and its PR block, the B-n lines this PR claims, or the slice titles and ticket for a Standard task>
Convention files that apply to the changed code:
  <CONVENTION_FILE_PATHS, only the tracks the diff touches>

Read only the diff, the files it changes, the requirement documents above, and files the changed code imports directly. Do not scan the rest of the repository.

Find, with evidence:

1. UNMET CRITERIA: every acceptance criterion this PR claims that the diff does not satisfy, or satisfies only partly.
2. TESTS THAT WOULD NOT FAIL: every claimed criterion whose test would still pass if the feature were missing or wrong (asserting on a mock call instead of behavior, asserting only that no error was thrown, or testing a fixture rather than the code).
3. CORRECTNESS BUGS: logic errors, unhandled failure modes, wrong status codes or return shapes, off-by-one and boundary errors, race conditions, and ordering or concurrency cases the code gets wrong.
4. SECURITY AND DATA-INTEGRITY: authentication or authorization gaps, injection, missing input validation, secrets in code or logs, unsafe migrations, missing idempotency, and weakened protections (CORS, CSP, rate limits).
5. CONVENTION VIOLATIONS: places the diff contradicts a convention file above, citing the section.
6. SPEC DRIFT: behavior the diff adds that the spec does not ask for, or a spec requirement the diff silently changes.

Rules:
- Every finding cites evidence: a file path and line number in the diff, a spec line, or a convention file section. A finding without evidence is not a finding.
- No style, wording, or formatting comments, and no suggestions that merely add scope.
- Rate each finding HIGH (a shipped bug or a security hole), MEDIUM (an unmet criterion or a test that cannot fail), or LOW (a minor inconsistency).
- If you checked an area and found nothing, say so explicitly for that area, naming what you checked.

Output format, as your final message:

## Findings
| # | Severity | Category | Finding | Evidence | Suggested fix |
|---|---|---|---|---|---|

## Areas checked with no finding
- ...

Do not modify any file.
