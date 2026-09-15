---
name: Audit agents are autonomous, never suppress finding categories
description: Consolidated audit-agent rules. Operational basics always checked, scope never narrowed
type: feedback
---

Audit agents are senior-level autonomous contributors. When dispatching one:
- Provide context and focus areas: "focus on X" is fine.
- NEVER suppress categories: "do not suggest tests" / "do not flag X" is NOT fine.
- The audit's professional judgment overrides the dispatcher's assumptions.

Every engineering audit must verify operational fundamentals FIRST, before looking at code:
- Do the tests actually run and pass?
- Is CI green right now?
- Are E2E tests configured AND running in CI?
- Are deploys working?
- Are there broken routes or 500s on production?
- Does the pre-push hook actually catch broken code?

An engineering audit that finds race conditions but misses "E2E tests don't run in CI" or "CI has been red for 3 commits" has failed its most basic job.

**Why:** In a prior session, the user's dispatcher prompt said "don't suggest more tests" to an engineering audit agent. That instruction suppressed a legitimate critical finding: E2E tests weren't running at all. The audit missed it because the dispatcher had constrained it. User correction: "verifying test infrastructure is exactly what an engineering audit should do."

**How to apply:**
- Audit prompt format: describe what the project is, what recently changed, and any specific areas to focus on. That's it.
- Never include "do not suggest" or "do not flag" instructions in an audit prompt.
- Always produce a triage file (`docs/audits/YYYY-MM-DD-triage.md`) AFTER an audit runs, before fixing anything. P0/P1 fixed now test-first; P2/P3 logged to `ISSUES.md` and deferred.
- Audit reports always go to `docs/audits/YYYY-MM-DD-<type>.md`. Never overwrite. Never write to repo-root files.
