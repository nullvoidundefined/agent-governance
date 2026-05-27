# Customer Audit

**Pointer file.** Canonical role definition: [`~/.claude/agents/audit-customer.md`](../../agents/audit-customer.md). Persona, mission, authority and scope, allowed read scope, the four-severity rubric, audit procedure, and output format all live in that file alongside the agent frontmatter (`name`, `description`, `tools`, `model`) that Claude Code's Agent runtime loads at dispatch time.

This pointer exists because the customer role was originally defined here before the agent file existed; the all-hands skill referenced `audit-customer` as a dispatchable agent, but no agent file was registered. The role now lives in `agents/` with the rest; this file forwards references from `~/.claude/rules/audits.md`, the README, and the all-hands skill.
