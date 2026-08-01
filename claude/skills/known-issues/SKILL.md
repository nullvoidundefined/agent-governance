---
name: known-issues
description: Use before any production deploy, or when debugging a failure that resembles a prior deployment incident.
---

# Known Issues

`KNOWN-ISSUES.md` is a private operational log, gitignored by design. It exists only on the machine where it was written and is absent from any fresh clone of this repo, so the loader below reports that explicitly rather than returning silence.

```! cat ~/.claude/KNOWN-ISSUES.md 2>/dev/null || echo "KNOWN-ISSUES.md is not present on this machine. It is gitignored by design (private operational log), so a fresh clone will never have it. Proceed without it, and do not read the absence as 'no known issues'." ```
