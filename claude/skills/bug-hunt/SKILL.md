---
name: bug-hunt
description: Use when the user asks to find bugs, audit code quality, or hunt for issues in recent changes. Also use proactively after shipping 5+ commits on a feature branch before merge.
---

# Bug Hunt

Autonomous audit of recent changes for bugs, race conditions, security issues, and code quality problems.

## Process

1. **Scope the hunt.** Default: changes in the last 5 commits (`git diff HEAD~5`). The user can override with a file path, directory, or commit range.

2. **Identify changed files.**
```bash
git log --oneline -10  # recent context
git diff HEAD~5 --stat  # what changed
```

3. **Read and audit each changed file.** For each file, check:
   - Logic bugs, off-by-one errors, wrong comparisons
   - Race conditions in async code (missing await, unhandled promises, shared mutable state)
   - SQL injection or missing parameterization
   - Missing error handling (uncaught throws, ignored rejections)
   - Unvalidated user input at API boundaries
   - Credential leakage (hardcoded keys, tokens, secrets in code)
   - Missing null/undefined checks
   - Broken imports or references to deleted/renamed files
   - Type safety gaps (unsafe casts, `any` usage)
   - Test coverage gaps (new code paths without tests)

4. **Cross-reference.** Check if deleted files are still imported elsewhere. Check if new exports are consumed correctly.

5. **Report findings.** Use this format:

```markdown
## Bug Audit Report

### P0 (Critical - breaks production)
- [file:line] Description

### P1 (High - causes data loss or security risk)
- [file:line] Description

### P2 (Medium - incorrect behavior users will notice)
- [file:line] Description

### P3 (Low - code quality, edge cases, minor issues)
- [file:line] Description

### Clean
Files reviewed with no issues.
```

6. **Fix or file.** For each finding, either fix it inline (with a test per R-403) or add it to `ISSUES.md` with the priority tag.

## Dispatch Pattern

For large diffs (20+ files), dispatch a Sonnet subagent per directory to parallelize the read-and-audit pass. Each subagent returns its findings table. The primary agent deduplicates and presents the consolidated report.

## What NOT to Flag

- Pre-existing lint warnings (those are the linter's job)
- Style preferences already covered by prettier/eslint
- Missing documentation on internal functions
- Hypothetical performance issues without evidence
