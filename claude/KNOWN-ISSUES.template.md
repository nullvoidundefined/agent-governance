# Production Issues Log (last updated YYYY-MM-DD)

Append production incidents here as they occur. The `/known-issues` skill loads this file before a production deploy and when debugging a failure that resembles a past incident (per the Convention files table in `CLAUDE.md`).

The real log is gitignored (`KNOWN-ISSUES.md`) so infrastructure-specific details stay local. Copy this template to `KNOWN-ISSUES.md` on a fresh install and populate it from your own incidents.

One entry per incident. Keep entries concrete: what broke, why, the fix, and what now prevents it.

## YYYY-MM-DD: <short incident title>

### <sub-issue, if the incident had several>
- Symptom: <what was observed>
- Root cause: <the actual cause, not the surface error>
- Fix: <the change that resolved it>
- Prevention: <the rule, hook, test, or check that stops a recurrence>
