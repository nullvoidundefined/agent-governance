---
name: feedback_pr_constant_value_check
description: When a named constant value changes, grep test files for the old value before pushing and update all stale assertions in the same commit.
metadata:
  type: feedback
---

Before pushing a branch that changes a named constant's value -- palette colors, status strings, limits, URLs, error messages -- grep the test suite for the old value and update every stale assertion in the same commit as the source change.

**Why:** PR #35 (film-finder) updated the subgenre color palette in `packages/constants/` but missed `apps/server/src/__tests__/integration/map-flow.test.ts`, which asserted the old hex values `#ff4d5e` and `#e3b23c`. CI went red after the PR was open. The fix was trivial but required a merge commit and another CI cycle.

**How to apply:**
1. `git diff HEAD~1 -- <constants-file>` to surface removed (old) values.
2. `grep -r '<old-value>' <test-dirs>` to find stale assertions.
3. Update all matches in the same commit as the constant change -- never in a follow-up.

Applies to every push, not just pre-PR. The longer the gap between the constant change and the test fix, the more CI cycles are wasted.

Related: [[feedback_pr_scope_discipline]]
