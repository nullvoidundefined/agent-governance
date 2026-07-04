# Cost, Routing, and Estimation (R-9xx)

R-901: Tag every plan task before execution.
  Spec:
  | Tag | Definition | Execution |
  |---|---|---|
  | `[trivial]` | Single-file edit, one-line config, doc tweak, env var rename | Inline, no subagents |
  | `[standard]` | Multi-file change, real logic, new function with tests, schema migration | One implementer + one reviewer |
  | `[complex]` | Cross-cutting refactor, new subsystem, security/auth-sensitive change | Implementer + spec reviewer + code-quality reviewer |
  Enforcement: manual

R-902: Execute inline work as brainstorm -> short spec -> execute; write full plans for subagent handoff only.
  Enforcement: manual

R-903: Route work to the cheapest capable model.
  Spec:
  | Model | Use for |
  |---|---|
  | Opus | Complex refactors, security-sensitive logic, ambiguous design, audits, multi-step planning |
  | Sonnet | Targeted features, well-scoped refactors, normal feature work |
  | Haiku | File moves, doc edits, single-line config, formatting, simple lookups |
  Enforcement: manual

R-904: Verify the signal condition (R-801) before running any audit.
  Enforcement: hook:audit-signal-check (advisory; surfaces the commit-count signal at push time); manual for verification before dispatch

R-905: Hold retrospectives only after real incidents (recovery > 30 min or a pattern repeated across commits); normal sessions get handoff docs.
  Enforcement: manual

R-906: Divide time estimates by 3-5x; pad only for external dependencies, first-of-a-kind work, or research tasks; recalibrate after every task.
  Enforcement: manual
