# Session Handoff: 2026-08-21 Manual Rule Mechanization

## 1. Last commit

- `a6c25a3` feat(enforce): mechanize R-514, R-512, R-511, R-508, and R-501
- Pushed to `origin/main` (`b16bcee..a6c25a3`, four commits); working tree clean at handoff (this doc's commit follows).
- An engineering audit was dispatched at the end of the session; its report commit may land after this doc.

## 2. Production state

- Both suites green: `enforce/tests/run-tests.sh` (31 cases) and `hooks/tests/run-tests.sh` (11 cases), run at pre-push.
- `enforce/hook-hashes.txt` regenerated (46 entries); `enforcement-guard-check.sh` reports no drift in either direction.
- Rulebook enforcement tally moved from 30 mechanized to **41 of 76 rules**; 28 remain `[manual]`, 7 on the judge tier.
- **The six new checks activate in NEW sessions only.** `settings.json` hooks snapshot at session start, the same activation lag `push-ruff-gate.sh` had on 2026-07-31.
- R-106 review ran before the push: no secrets, no local filesystem paths, no client-identifying content in the outgoing diff.

## 3. What shipped

- `8244974` feat(enforce): mechanize the R-304 and R-305 structure vocabularies
  - `structure-gate.sh` denies a new non-entry `.ts` at an Express `src/` root (R-304) and a new `.tsx` written directly into `components/` (R-305).
  - Both scoped by the nearest `package.json` dependency (express / react) so a server rule never lands on a client tree or a foreign repo; both creation-only, so existing loose files stay editable; `index/server/app/main.ts` and `.d.ts` exempt.
  - Origin: two flat-layout regroups in one build session. Both rules existed and were correct; neither was reachable at file-creation time. Lesson in `global-memory/feedback_mechanize_structure_rules.md`.
- `b0b26e2` feat(enforce): mechanize R-105, R-401, R-405, and R-302
  - `hooks/mcp-action-guard.sh` (new, matcher `mcp__.*`): asks when any token of the action name is a mutating or transmitting verb. Before this, **no hook matched any MCP tool at all**; every matcher was Bash or Write|Edit, so mail, issue writes, page deletions, and design-file creation were ungated. Browser server exempt.
  - `hooks/content-gate.sh` (new, Write|Edit): R-401 (`.only` denied outright; a skip denied unless its line names a triage ID, which is R-401 anti-pattern 8's own carve-out), R-405 (TLS, CORS, CSP, CSRF, bcrypt cost, outside test trees), R-302 (relative import whose `../` chain resolves above the git toplevel).
- `a6c25a3` feat(enforce): mechanize R-514, R-512, R-511, R-508, and R-501
  - `hooks/git-workflow-guard.sh` (new, Bash): R-514 asks before `gh pr merge` and before a push whose target branch resolves to main/master (explicit refspec wins, else the checked-out branch); R-512 denies `--merge`/`--rebase`; R-511 and R-508 warn at commit time.
  - `hooks/parallel-session-check.sh` (new, SessionStart): registers the session PID under a hash of its working tree; registrations live only as long as their process, so no cleanup hook is needed.
  - `~/.claude` is exempt from the main-branch rules (main is its working branch; R-106 already gates its pushes). Staged paths union `git add` arguments in the same command, reusing the 2026-07-31 P1 fix.
- `1e15939` chore(memory): log the rule fires through 2026-08-20 (pre-existing dirty file, triaged at session start).

## 4. Pending (by urgency)

- **Engineering audit landed** (`docs/audits/2026-08-21-engineering.md`, commit `8d88048`): no P0, three P1, eight P2. Its verdict was construction sound, coverage overstated: three hooks matched a narrower input set than their `Enforcement:` lines claimed, every gap reachable through an ordinary idiom. All three P1s were reproduced here before acting (R-804(d)).
- **Fixed same day, test-first** (see `ISSUES.md` Resolved for the full list): refspec resolution for R-514 (`HEAD`, `refs/heads/main`, `+main` all bypassed the ask), camelCase MCP tool names (`createIssue` was silent), `git -C <path>` bypassing the whole workflow guard, an express devDependency giving a React package the server vocabulary, `single-file-folder-gate` warning R-309 on the exact folder R-305 orders, PID recycling in the session registry, and `xargs` on a quote-bearing path.
- **P1 still open, needs a decision**: MCP database tools (neon, supabase `run_sql`/`execute_sql`) reach a managed Postgres with no R-101 enforcement, because `destructive-db-guard.sh` exits on any payload with no `.tool_input.command` and every deny/ask entry in `settings.json` is `Bash(...)`. `mcp-action-guard.sh` now asks on `sql`/`migration`/`execute`/`ddl`, which closes the silence but is not a production hard block. Decide where the statement-level check lives before writing it.
- P2 (known limitation, documented in the reference Specs): R-405's gate covers seven of the nine protections the rule names; rate-limit ceilings and `SameSite`/`Secure` cookie flags are value changes rather than patterns and stay manual.
- P2 (known limitation): Figma's `use_figma` and `weave_run_tool` write to Figma but carry no verb `mcp-action-guard` recognizes; they pass silently.
- P3 (known limitation): R-508's surface heuristic (added routes, handlers, `page.tsx`, `route.ts`, feature slices, Dockerfile, compose, `.env.example`) both misses and over-fires by construction; it warns rather than blocks for that reason.
- Carried from prior audits, untouched today: the four P2/P3 entries in `ISSUES.md` from 2026-07-31 and 2026-07-03 (R-314 message wording for Python, `xargs` space-in-path in the push gates, unpaired `fix:` commit `266d05e`, untested session-lifecycle hooks).

## 5. Next session

- If a new deny misfires in a real project, read the hook first, then its fixture test: `hooks/content-gate.sh`, `hooks/structure-gate.sh` (R-304/R-305 blocks at the end), `hooks/git-workflow-guard.sh`, `hooks/mcp-action-guard.sh`.
- Every new deny is creation-only or scoped by a `package.json` dependency; the fastest correct fix for a false positive is usually to tighten that scope, not to widen an allowlist.
- The audit's most transferable finding is about fixtures, not hooks: three of this cycle's tests were built in a way that avoids the failure mode they should probe, so a green suite overstated coverage. Read that section before writing the next hook test.
- Tier B of the mechanization investigation is now shipped in full. What remains `[manual]` was assessed as genuinely unmechanizable: the conduct block (R-104, R-201 through R-209), the judgment rules (R-301, R-307, R-308), and the process rules (R-404, R-408/409, R-502/503, R-509/510, R-515, R-601 through R-604).
- The 2026-07-31 handoff's Python-parity context is superseded but still accurate; `git show 410508c` if Python enforcement misbehaves.
