---
name: lesson_subagent_first_for_multi_file
description: Default to subagent dispatch for anything that reads more than 5 files in the main session. Subagents isolate context and let you pick the right model per task. Inline investigation in the main session pollutes context and inherits the main session's (usually Opus) model.
type: feedback
---

**Default to subagent dispatch for any task that requires reading more than 5 files, exploring a codebase, or producing a focused report. Inline investigation in the main session is the exception, not the default.**

**Why:** On 2026-04-08 two audits ran via Explore subagents (frontend: ~80 files; backend: ~140 files). Both produced clean summaries that fit in the main session as single assistant turns. That was the right pattern. Earlier the same session, multiple bash-based file inspections, grep sweeps, and CLAUDE.md reads ran inline in the main Opus session, polluting the main context with content that did not need to be there. A subagent with `model: sonnet` would have cost 3-5x less and kept the main session's context window clean for the high-value reasoning.

**How to apply:**

- **Multi-file investigation goes to a subagent.** Grep sweeps across the whole repo, architecture exploration, audits, "find every place that uses X", dependency scans, test coverage surveys. All subagent work. Never inline.
- **Specify the model.** When dispatching, pass `model: "sonnet"` or `model: "haiku"` in the Agent tool call unless the investigation genuinely requires Opus-level reasoning (security audits, architectural decisions, complex refactoring plans). The Explore agent defaults to a high-cost model; override it explicitly for routine investigations.
- **Scope the prompt tight.** Ask for specific evidence (file:line citations, counts, patterns), not open-ended exploration. A tight prompt means a smaller subagent context window and a smaller returned summary.
- **Keep the main session for reasoning.** The main session's job is to orchestrate, decide, and synthesize. It should not be reading hundreds of files itself.

**When inline is correct:**

- Reading one or two specific files the user named
- Editing a file you just read two turns ago
- Running a quick git status or ls
- Any task where the total file-read count is under 5 and the content is directly relevant to the current conversation

**When a subagent is correct:**

- Auditing a surface (frontend, backend, security, etc.)
- Finding every call site of a function
- Counting lint warnings across a workspace
- Surveying test coverage
- Anything where a human would say "look at the codebase and tell me"

**Evidence:** the 2026-04-08 session ran two successful subagent audits (~200k tokens combined) that kept the main session lean. The same session also did multiple inline Grep and Read passes for smaller investigations that each added ~10-20k tokens to the main context. Most of those inline passes should have been bundled into a single subagent call earlier in the session.
