R-500: Tag plan tasks before execution:

| Tag | Definition | Execution |
|---|---|---|
| `[trivial]` | Single-file edit, one-line config, doc tweak, env var rename | Inline, no subagents |
| `[standard]` | Multi-file change, real logic, new function with tests, schema migration | One implementer + one reviewer |
| `[complex]` | Cross-cutting refactor, new subsystem, security/auth-sensitive change | Implementer + spec reviewer + code-quality reviewer |

R-502: Verify signal condition (R-400) before running any audit.

R-503: Model routing:

| Model | Use for |
|---|---|
| Opus | Complex refactors, security-sensitive logic, ambiguous design, audits, multi-step planning |
| Sonnet | Targeted features, well-scoped refactors, normal feature work |
| Haiku | File moves, doc edits, single-line config, formatting, simple lookups |

R-504: Retrospectives only after real incidents (recovery > 30 min or pattern repeated across commits). Normal sessions get handoff docs.
R-506: Inline execution: brainstorm -> short spec -> execute. Full plans for subagent handoff only.
