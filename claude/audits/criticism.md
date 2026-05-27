# Criticism Audit (Devil's Advocate)

**Pointer file.** Canonical role definition: [`~/.claude/agents/audit-criticism.md`](../agents/audit-criticism.md). Persona, mission, authority and scope, allowed read scope, audit procedure, output format, and history all live in that file alongside the agent frontmatter (`name`, `description`, `tools`, `model`) that Claude Code's Agent runtime loads at dispatch time.

This pointer exists because earlier versions of the framework mirrored the role definition between `audits/` and `agents/`. The two copies drifted. The current rule: the agent file is the single source of truth; this file forwards references from `~/.claude/rules/audits.md`, the README's "Read this first" list, and per-project audit slash-commands.
