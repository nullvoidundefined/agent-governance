# Audits (R-8xx)

R-801: Run audits on signal only.
  Spec:
  - Pre-launch: all three standing roles.
  - Specific risk signal: the matching role only.
  - 5+ commits on a surface: Engineering only, on that surface.
  - No full three-role sweeps reactively.
  Enforcement: hook:audit-signal-check (advisory; detects the 5+ commits signal at push time); manual for pre-launch and risk-signal triggers

R-802: Have audit roles declare P0-P3 findings independently and never act on them directly.
  Spec:
  - Reports to `docs/audits/YYYY-MM-DD-<role>.md`.
  - P0/P1 current-effort; P2/P3 to `ISSUES.md`.
  - Roles do not commit code, modify settings, or run destructive actions.
  Enforcement: manual

R-803: Invoke on-request roles (UX, Design, Marketing, Financial, Legal) only when their specific signal is present.
  Enforcement: manual

R-804: Treat audit findings as the graded deliverable and proposed fixes as unverified hypotheses, never applied as-is.
  Scope: every standing and on-request role; audit dispatch prompts restate (a) through (c).
  Spec:
  - (a) Every finding pastes the actual offending code (the real key order, signature, markup, config) with file:line, names the governing rule or standard, and carries a P0-P3 severity. A finding whose pasted evidence shows compliance is dropped, not reported.
  - (b) Resolve precedence before flagging: a more-specific rule overrides a general one; project `CLAUDE.md` overrides global rules; a documented override is not a violation.
  - (c) Give fixes as a direction (the class of fix) plus `to confirm: <what to check>` (the real signature, whether a helper already exists, the governing rule), never a finished patch.
  - (d) The dispatcher verifies every finding against the code before acting (R-201).
  Enforcement: manual

R-805: Restrict audit roles to reading project source/docs/tests; Security additionally reads `.env.example`.
  Spec: no role reads `.env`, `~/.aws`, `~/.ssh`, or keychains without per-turn authorization.
  Enforcement: manual

Standing roles: Engineering (`~/.claude/audits/engineering.md`), Security (`~/.claude/audits/security.md`), Criticism (`~/.claude/audits/criticism.md`).
