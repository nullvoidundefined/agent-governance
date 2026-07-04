# Engineering Audit: Rule and Enforcement System (2026-07-04)

## Scope

`~/.claude` on `main`, HEAD `672658c` (`feat(enforce): audit-signal advisory hook for the R-801 commit-count trigger`). Target: the Claude Code operating system itself (rules, hooks, manifest, settings), not a product codebase. Surfaces read: `CLAUDE.md`, `rules/agents.md`, `rules/audits.md`, `rules/cost.md`, `rules/session-types.md`, `enforce/manifest.json`, `enforce/README.md`, `hooks/*.sh` (headers plus full reads of `secret-scan.sh`, `enforcement-guard-check.sh`, `audit-signal-check.sh`), `settings.json`, and the `hooks/`, `enforce/rules/`, `enforce/tests/`, `hooks/tests/` directory listings.

Method: cross-checked every `CLAUDE.md` `Enforcement:` line against `enforce/manifest.json`; cross-checked every manifest enforcer against hook registration in `settings.json` (both directions); verified existence of every path named in a rule; read the two highest-consequence hook scripts in full to test their actual coverage against the rule text they claim to enforce.

This audit does not re-report the 2026-07-03 findings. Verified closed since then: the 10 missing manifest entries are now all present (`manifest.json:10-22`); the phantom `R-503 / model:progress-reporting` manifest entry is gone; `ISSUES.md` now exists; `hooks/tests/run-tests.sh` now exists; fixture tests now cover `destructive-db-guard`, `no-em-dash`, `conflict-markers`, `audit-signal-check`, and others flagged as uncovered yesterday; the `enforce/README.md` tier-table examples now include `R-324` (ast) and `R-801` (advisory).

Still open from 2026-07-03 (referenced by ID, not re-detailed): the `commit-message-guard.sh` deny message cites `R-505` for a conventional-type-prefix requirement whose text lives only in `PROTOCOL.md` (yesterday P2); `README.md`'s "8 hook scripts" / "ten-layer model" counts remain stale against the actual 26-script, eleven-layer reality (yesterday P2).

## P0

None. Every manifest enforcer is registered in `settings.json`, all cited rule IDs resolve, and every path named in a rule exists. No active credential leak, no broken gate, no red suite.

## P1

### P1-1: the secret-scan gate does not cover the Write/Edit surface; a credential written directly into a file bypasses it

`~/.claude/hooks/secret-scan.sh:35-36` reads only the Bash-shaped input field:
```
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
```
It scans `.tool_input.command`, which exists only for the Bash tool. For a `Write` call the secret would be in `.tool_input.content`, and for an `Edit` call in `.tool_input.new_string`; this script reads neither. `settings.json` confirms the matcher scope: `secret-scan.sh` is registered only under the `PreToolUse` -> `Bash` matcher (`settings.json:11-16`). The `Write|Edit` PreToolUse matcher (`settings.json:63-78`) registers `no-em-dash`, `migration-defaults-guard`, and `structure-gate`, but not `secret-scan`. The `PostToolUse` -> `Bash` `redact-output.sh` scans command output only, not file content.

Consequence: writing a full-length API key, webhook secret, or private key straight into a repo file via the Write or Edit tool passes every gate. This is the exact persistence-to-disk leak class the whole system exists to prevent (the credential-scan audit section, `secret-scan.sh`'s own header, and the 2026-04-08 incident note). The argv vector that motivated the system is covered; the direct-to-file vector is not.

Governing rule: R-102 (`Enforcement: hook:secret-scan (PreToolUse)`, stated without a Bash-only qualifier), reinforced by R-104 (`Sanitize artifacts before writing them ... tokens/keys/cookies -> [REDACTED]`, currently `Enforcement: manual` with no Write-surface enforcer), and R-103 (protected-file mutation, whose `secret-scan.sh:87-91` mutation guard likewise only inspects Bash argv, so a `Write` to a `.env` path is also uncaught).

Direction: extend `secret-scan.sh` to also read `.tool_input.content` and `.tool_input.new_string`, and register it under the `Write|Edit` PreToolUse matcher alongside the existing three. `to confirm:` the exact field names Claude Code populates for Write vs Edit vs MultiEdit in this build (read the tool schema, not this repo); whether the same `PATTERN` block should apply verbatim (it should, the patterns are surface-independent); and whether a shared scan function should be extracted so the Bash and Write/Edit paths cannot drift. Add a fixture test writing a full-length placeholder key through a simulated Write payload and asserting `permissionDecision: deny`.

## P2

### P2-1: enforcement-guard-check still verifies only one direction, so a rule dropped from the manifest is invisible

`~/.claude/hooks/enforcement-guard-check.sh:14-25` derives `REQUIRED` from the manifest and checks each is registered in `settings.json`. It never checks the reverse: that every `Enforcement: hook:X` / `eslint:X` line in `CLAUDE.md` has a manifest entry.
```
REQUIRED=$(jq -r '.rules[].enforcer' "$MANIFEST" | awk '
  /^hook:/   { sub(/^hook:/,""); print $0 ".sh" }
  /^eslint:/ { print "push-eslint-gate.sh" }
' | sort -u)
```
The 2026-07-03 audit raised this as P1 because 10 rules were then missing from the manifest. Those entries were backfilled, so the acute gap is closed and this drops to P2. The structural blind spot remains: if a future edit removes a rule's manifest row (or adds a hook-enforced rule to `CLAUDE.md` without a manifest entry), the system's own guard stays silent, exactly the recurrence this hook is supposed to prevent. R-516 states "A rule with no manifest entry is unenforced"; nothing mechanically detects that state.

Governing rule: R-516.

Direction: add the missing direction, either in `enforcement-guard-check.sh` or as a dedicated `enforce/tests/` fixture: parse every `Enforcement: hook:*` / `Enforcement: *eslint:*` token out of `CLAUDE.md` + `rules/*.md` and assert each has a manifest `id`. `to confirm:` whether advisory secondary enforcers named in `CLAUDE.md` (see P3-1) should be required-in-manifest or explicitly exempted, so the new check has a defined expectation rather than flagging them as false positives.

### P2-2: mechanizable rules that fire on nearly every session are still Enforcement: manual (R-516 gaps), ranked by fire frequency

1. **R-504** (`Commit after every discrete task; a TaskUpdate to completed triggers an immediate commit`, `CLAUDE.md:361`, `Enforcement: manual`). Fires on every completed task, the single most frequent workflow event in the corpus, and depends entirely on recall. A `PostToolUse` hook matching `TaskUpdate` with `status: completed` could emit an advisory when the working tree has staged-but-uncommitted changes, giving R-504 the em-dash property the README argues every mechanizable rule should have. Highest-frequency gap.
2. **R-313 / R-314** (`Place test files in a conventional sibling test directory, never co-located`; `__tests__/` mirroring, banned per-directory `test/`, `CLAUDE.md:200-210`, both `Enforcement: manual`). Fires whenever a test file is created. Purely a path check, and `structure-gate.sh` already runs on `Write|Edit` doing exactly this class of path validation; adding a co-located-test-file check is a natural extension of an existing hook.
3. **R-405** (`Fix root causes, never weaken the protection ... SameSite=None without Secure, lowering bcrypt rounds, disabling rate limits`, `CLAUDE.md:349`, `Enforcement: manual`). Lower frequency but high consequence, and several sub-cases are regex-detectable against a diff (`SameSite=None` without an adjacent `Secure`, a bcrypt cost literal decreasing). A push-time advisory scanning the diff for these specific weakenings would catch the highest-risk cases.

Governing rule: R-516 (mechanizable rules should carry a real enforcer, not depend on memory).

Direction: promote R-504 to an advisory `TaskUpdate` hook first (highest payoff, lowest risk), then fold the R-313/R-314 co-location check into `structure-gate.sh`. `to confirm:` whether Claude Code exposes a `PostToolUse` matcher for `TaskUpdate` and the shape of its input in this build; whether `structure-gate.sh`'s current path logic already has the source-tree context needed to distinguish a co-located test from a legitimate `__tests__/` sibling.

## P3

### P3-1: two advisory enforcers are cited in CLAUDE.md and registered in settings but absent from the manifest

`CLAUDE.md:235` (`Enforcement: judge; hook:new-file-header-reminder (advisory)`) and `CLAUDE.md:254` (`Enforcement: judge; hook:clean-code-reminder (advisory)`) each name a second, advisory enforcer. Both scripts are registered in `settings.json` (`new-file-header-reminder.sh` at `:96-97`, `clean-code-reminder.sh` at `:108-110`), but neither appears in `enforce/manifest.json` (the R-320 and R-322 manifest rows list only `hook:llm-rule-judge`). By R-516's own logic these advisory enforcers are unregistered from the manifest's perspective, so if either were dropped from `settings.json`, `enforcement-guard-check.sh` would not warn. Low severity because the primary `llm-rule-judge` enforcer for both rules is manifested and would still fire.

Direction: either add advisory manifest rows for these two enforcers (matching how R-309/R-310 advisory reminders are manifested) or document in `enforce/README.md` that secondary advisory enforcers named inline in an `Enforcement:` line are intentionally manifest-exempt. `to confirm:` which convention the README intends, so P2-1's reverse-direction check does not later flag these as gaps.

### P3-2: R-320 cites a "default no-comments behavior" that is not a numbered rule anywhere

`CLAUDE.md:234`: `Overrides the default no-comments behavior for file-level headers.` No rule in `CLAUDE.md` or `rules/*.md` establishes a "no comments" default (grep for `no-comments`/`omit comments`/`do not comment` returns only this line). The override points at an unstated convention, so a reader cannot check what is being overridden. Direction: either add the baseline as explicit rule text (or a one-line note under R-320) or reword to reference the actual governing convention. `to confirm:` whether the no-comments default lives in `PROTOCOL.md` prose rather than a numbered rule.

### P3-3: R-402 is fully subsumed by R-403 and shares its enforcer (merge candidate)

R-402 (`Fix bugs test-first`, `CLAUDE.md:305`) and R-403 (`Follow the bug-fix path in order` with steps 1-4 being write-failing-test / smallest-fix / verify / commit-together, `CLAUDE.md:307-314`) state the same requirement at two granularities, and both map to the same manifest enforcer (`hook:fix-commit-requires-test`, `manifest.json:19-20`). R-402 adds nothing R-403 step 1 does not already mandate. Direction: consider folding R-402 into R-403 as its headline imperative, freeing an ID and removing the duplicate manifest row, or keep both but note the principle/procedure split explicitly. `to confirm:` whether any external citation (skills, agent files, `PROTOCOL.md`) references R-402 independently of R-403 before collapsing it.

### P3-4: R-403 step 3 "Run full verification" reads in tension with R-509's per-commit scope

`CLAUDE.md:312` (R-403 step 3): `Run full verification.` immediately before step 4 `Commit test and fix together.` `CLAUDE.md:374` (R-509): `Target changed files only in per-commit test runs; run the full suite at pre-push.` Taken literally, R-403 asks for full verification at bug-fix commit time while R-509 restricts per-commit runs to changed files and defers the full suite to pre-push. The more-specific bug-fix rule (R-403) plausibly governs, but "full verification" is vague enough to read as contradicting the general per-commit scope. Direction: tighten R-403 step 3 wording to name what "full verification" means at commit time (changed-file tests plus the fix's own new test) versus at pre-push, aligning it with R-509. `to confirm:` the intended verification scope for a bug-fix commit specifically.

### P3-5: R-304's banned-catch-all list duplicates R-306 (overlap)

`CLAUDE.md:130` (R-304): `Banned catch-alls: lib/, utils/, helpers/, common/, core/, misc/, shared/ (contents move to services/ ... per R-306).` `CLAUDE.md:140` (R-306): `Never create lib/ or utils/ directories`. The prohibition lives in two places; R-306 is the universal rule and R-304 restates a superset of it for the server tree. Not a defect (R-304 already forward-references R-306), but the `lib/`/`utils/` ban is now maintained in two lists that can drift. Direction: have R-304 reference R-306's banned set by ID rather than re-enumerating the overlapping members, keeping one canonical list. `to confirm:` whether R-304's list intentionally extends R-306 with server-specific additions (`helpers/`, `common/`, `core/`, `misc/`, `shared/`) that R-306 does not name, in which case only the overlapping `lib/`/`utils/` members should be de-duplicated.

## Top 5 recommended updates, ranked by payoff

| # | Update | Payoff | Effort |
|---|---|---|---|
| 1 | Extend `secret-scan.sh` to scan `.tool_input.content`/`.new_string` and register it under the `Write|Edit` PreToolUse matcher; add a Write-payload fixture test (P1-1) | H: closes the direct-to-file credential-leak vector the system was built to stop | M |
| 2 | Add the reverse-direction check (CLAUDE.md Enforcement lines -> manifest) to `enforcement-guard-check.sh` or a fixture test (P2-1) | H: makes manifest-coverage drift self-detecting instead of dependent on an annual audit | M |
| 3 | Mechanize R-504 as an advisory `TaskUpdate` hook, then fold R-313/R-314 co-location into `structure-gate.sh` (P2-2) | H: gives the two highest-frequency manual rules the em-dash property | M |
| 4 | Reconcile the advisory-enforcer manifest gap (P3-1) and the R-320 dangling "no-comments" referent (P3-2) so the manifest and rule text are self-consistent before update #2 lands | M: prevents update #2's new check from firing false positives | L |
| 5 | Resolve the redundancy/tension pairs: merge R-402 into R-403, tighten R-403 step 3 against R-509, de-duplicate R-304's catch-all list against R-306 (P3-3/P3-4/P3-5) | M: reduces the rule surface that can drift | L |
