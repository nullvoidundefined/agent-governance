---
name: gof
description: Run a Gang of Four (PE, Security, Critic, Designer) review against whatever the user is working on or points at. Infers the target from conversation context if not explicit.
---

# Gang of Four (GoF) Audit

Four-perspective review by Product Engineer (PE), Security Engineer, Critic, and Designer.

## Target Resolution

The target is determined in this order:

1. **Explicit:** The user names a file, feature, or area ("GoF review the corpus tagging spec")
2. **Contextual:** Infer from the conversation -- if the user just wrote a spec, review the spec; if they just shipped a feature, review the feature code; if they're about to start implementation, review the plan
3. **Ask:** If neither explicit nor inferable, ask "What should the Gang of Four review?"

Never default to reading todo files. The GoF review targets whatever is in front of the user.

## Perspectives

| Role | Focus |
|------|-------|
| **Product Engineer (PE)** | Feasibility, missing edge cases, implementation gaps, data model correctness, API contract completeness, dependency ordering, migration safety |
| **Security Engineer** | Auth boundaries, injection surfaces, data exposure, trust boundaries, rate limiting, input validation, credential handling |
| **Critic** | Assumptions that may be wrong, scope creep, overengineering, missing alternatives, unstated risks, premature optimization, coupling that will hurt later |
| **Designer** | A11y gaps, UX flow breaks, empty/error/loading states, responsive behavior, token compliance, interaction patterns, keyboard navigation |

## Process

1. **Read the target** -- the file(s) the user specified or that context implies
2. **Read referenced codebase files** -- schemas, handlers, components, migrations, types that the target depends on or modifies
3. **Run each perspective pass** independently, producing findings tagged by role and severity (P0-P3)
4. **Cross-reference findings** -- if two roles flag the same issue, note the overlap and escalate severity
5. **Present findings** grouped by severity, then by role
6. **Recommend next steps** -- which findings to fix inline, which to add to todos, which to note in the spec/plan

## Output Format

```
### [P{0-3}] {Short title}
**Source:** {PE|Security|Critic|Designer} (+ any co-signers)
**Affected:** {file paths or spec sections}
**Issue:** {What is wrong or missing}
**Recommendation:** {What to do about it}
```

## Severity Definitions

| Level | Definition |
|-------|-----------|
| **P0** | Blocks the work from shipping correctly. Data loss, security hole, broken contract, missing migration step. |
| **P1** | Will cause problems post-ship. Performance cliff, UX dead end, missing error handling on a common path. |
| **P2** | Should be fixed but won't break anything. Code smell, missing test, a11y gap on a secondary flow. |
| **P3** | Nice to have. Polish, naming, documentation, future-proofing. |

## Rules

- **Read before judging.** Always read the actual codebase state before claiming something is missing or wrong in a spec. The spec may be outdated but the code may already handle it.
- **No false positives.** Every finding must be verified against the current code. "The spec says X but the code does Y" requires reading both.
- **Actionable findings only.** "This could be better" is not a finding. "This will break when Z happens because of Y" is.
- **Respect the scope.** Review what the user asked you to review. Do not expand into a full codebase audit unless asked.
- **Tag overlaps.** When PE and Security both flag the same issue, note it as co-signed. This is signal, not noise.
