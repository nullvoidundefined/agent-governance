---
name: all-hands
description: Run a lightweight weekly priorities scan across all 9 audit roles. Each role scans the current codebase and returns their top 3-5 action items for the week. Results are consolidated into a single prioritized list. Use at the start of a work week or when you want a cross-functional view of what needs attention. Produces `docs/audits/YYYY-MM-DD-all-hands.md` and commits it.
---

# All Hands

Dispatches all 9 audit roles in parallel. Each role does a fast scan and returns their top 3-5 recommended action items for the week -- not a full audit, just the most important things they see right now.

## Roles

The 9 roles are:

1. `audit-engineering` -- CTO: architecture, code quality, test coverage, CI, tech debt
2. `audit-security` -- CISO: auth, secrets, injection, dependencies, credential exposure
3. `audit-criticism` -- Devil's advocate: strategy, unit economics, self-deception, moat
4. `audit-design` -- CDO: visual identity, typography, color, component coherence
5. `audit-ux` -- CXO: user flows, accessibility, onboarding, friction, error states
6. `audit-customer` -- Customer advocate: PMF, adoption friction, churn signals, feedback
7. `audit-financial` -- CFO: spend caps, margin, SaaS creep, runway
8. `audit-legal` -- Head of Legal: missing documents, compliance gaps, marketing claims
9. `audit-marketing` -- CMO: positioning, messaging, conversion, brand coherence

## Dispatch Process

**Step 1 -- canary.** Dispatch `audit-engineering` alone first. Give it this prompt:

> You are running a lightweight weekly priorities scan, not a full audit. Read the codebase quickly. Return ONLY your top 3-5 action items for this week, each as a single bullet: `[P0/P1/P2] <role>: <action item in one sentence>`. Do not write a full audit report. Do not write to any file. Return the bullets only.

Wait for clean return. If the canary errors or produces garbage output, stop and report the error to the user before fanning out.

**Step 2 -- fan out.** Dispatch the remaining 8 roles in a single parallel batch, each with the same lightweight prompt above (substituting their role name). Use Sonnet for all roles.

**Step 3 -- consolidate.** Collect all bullet lists. Deduplicate overlapping items (same issue flagged by multiple roles -- keep the highest-priority instance and note how many roles flagged it). Sort by priority (P0 first, then P1, then P2). Write the consolidated output.

## Output Format

Write to `docs/audits/YYYY-MM-DD-all-hands.md`:

```markdown
# All Hands -- YYYY-MM-DD

## Top Priorities This Week

| Priority | Role | Action Item |
|----------|------|-------------|
| P0 | Security | Rotate the leaked API key in git history |
| P0 | Financial | Set a hard spending cap on Anthropic API |
| P1 | Engineering | Fix the 3 unpaired fix: commits with no test change |
| ... | | |

## Per-Role Recommendations

### Engineering (CTO)
- [P1] ...
- [P2] ...

### Security (CISO)
- [P0] ...

### Criticism (Devil's Advocate)
- [P1] ...

### Design (CDO)
- [P2] ...

### UX (CXO)
- [P1] ...

### Customer Advocate
- [P2] ...

### Financial (CFO)
- [P0] ...

### Legal (Head of Legal)
- [P1] ...

### Marketing (CMO)
- [P2] ...

## Notes

_Items flagged by multiple roles are consolidated in the top table. The per-role sections show each role's raw output before deduplication._
```

Commit the file to the current branch. Do not create a separate branch.

## What This Is NOT

This is a 15-minute pulse check, not a deep dive. Each role is scanning quickly and returning their most visible concerns. If a role flags something that needs a full investigation, the appropriate follow-up is to run that role's dedicated audit skill (e.g., `/audit-security` for a full security report).

## Model

Sonnet for all roles. This is pattern-matching against a clear rubric, not deep architectural reasoning. If the user explicitly requests Opus for a specific role, override that role only.
