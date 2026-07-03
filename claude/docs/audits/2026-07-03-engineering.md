# Engineering Audit: Restructured Global Rules System (2026-07-03)

**Scope:** `~/.claude` on `main`, HEAD `2a05357` (`feat(enforce): convert five honor-system rules to mechanical enforcement`), preceded by `39f78f0` (`refactor(rules): century-block renumber, one grammatical template per rule, full reference migration`). Surfaces audited: `CLAUDE.md`, `rules/agents.md`, `rules/audits.md`, `rules/cost.md`, `rules/session-types.md`, `PROTOCOL.md`, `enforce/` (manifest, eslint config, lint runner, rules, tests, README, judge prompt), `hooks/*.sh` + `hooks/tests/`, hook registration in `settings.json`, `README.md`, `SETUP.md`.

**Method:** read every in-scope file; scripted cross-reference validation of all `R-NNN` citations against defined rule IDs across `CLAUDE.md` + `rules/*.md`; scripted diff of `enforce/manifest.json` against every `Enforcement:` line in `CLAUDE.md`; ran `bash enforce/tests/run-tests.sh` (11/11 pass) and each `hooks/tests/*.test.sh` individually (5/5 pass); diffed both commits in full against their parents.

## Executive Summary

The rule-template mechanics of the renumber are sound: all 92 rules follow the `R-NNN: imperative` plus `Scope`/`Spec`/`Enforcement` grammar with `Enforcement` always last, the `R-0xx`..`R-9xx` block boundaries are respected everywhere, every in-body `R-NNN` cross-reference inside `CLAUDE.md`/`rules/*.md` resolves to a real rule, and the Appendix B legacy-alias table in `PROTOCOL.md` is internally clean (94 pairs, zero dangling targets, zero duplicate mappings). All 16 enforcement fixture tests pass.

The "full reference migration" the renumber commit claims, however, stopped at the boundary of `hooks/`, `enforce/`, `tests/`, `skills/`, `prompts/`, and `global-memory/` (per its own commit message) and did not include `agents/`, `README.md`'s prose, or `enforce/manifest.json`'s completeness against `CLAUDE.md`. That gap produced three concrete defects: (1) a mechanical find/replace in `README.md` turned a valid rule range into a semantically backwards one; (2) all three standing audit-role files (the files this very audit dispatch depends on) now cite old rule IDs that silently collide with unrelated new rules; (3) `enforce/manifest.json` is missing entries for 10 rules `CLAUDE.md` itself says are hook-enforced, and the manifest's own self-check (`enforcement-guard-check.sh`) only verifies the opposite direction, so this gap is invisible to the system's own guardrail.

Separately, the same-day enforcement commit (`2a05357`) silently changed `settings.json`'s global `model` field from a valid `"opus"` to an unrecognized `"fable"`, with zero mention in a commit message otherwise scoped to five named rule conversions.

**Top 3 priorities:**
1. Verify and, if invalid, revert `settings.json`'s `"model": "fable"`: an unreviewed, undocumented change to global model routing bundled into an unrelated commit (P1, Operational Basics).
2. Fix the stale `R-403`/`R-107` citations in `agents/audit-engineering.md`, `agents/audit-security.md`, `agents/audit-criticism.md`: these now silently point at unrelated rules (bug-fix-path order; hooksPath-drift check) instead of audit output discipline and audit read-scope (P1, cross-reference integrity of the audit system itself).
3. Backfill `enforce/manifest.json` with the 10 missing rule entries and harden `enforcement-guard-check.sh` to check both directions (manifest to settings.json AND `CLAUDE.md` Enforcement-lines to manifest) so this class of drift cannot recur silently (P1, enforcement completeness).

## Operational Basics

| Check | Status |
|---|---|
| Enforcement fixture tests run and pass | Yes: `bash enforce/tests/run-tests.sh` produces `ALL ENFORCEMENT TESTS PASS` (11/11) |
| `hooks/tests/*.test.sh` run and pass | Yes, individually (5/5); **no aggregate runner, not wired to CI** (see P2 finding) |
| CI/CD | **None.** This is a local dotfiles-style repo with no GitHub Actions or equivalent; both test suites are manual-invocation only (`enforce/tests/run-tests.sh`, or the `for` loop documented in `SETUP.md`). Acceptable for this repo's nature but worth naming explicitly per Operational Basics discipline. |
| Rollback plan | Standard git revert; no deploy surface to roll back (config repo, not a service). |
| Monitoring | `enforcement-guard-check.sh` (SessionStart) is the closest thing to a monitor; see P1 finding on its one-directional blind spot. |
| Model routing config | **Degraded.** `settings.json:7` sets `"model": "fable"`, not a documented Claude Code model alias (see Finding P1-1). |

## Findings

### P1: settings.json model field changed to an unrecognized value, undocumented

`~/.claude/settings.json:7`
```
"model": "fable",
```
Prior value (per `git show HEAD -- settings.json`): `"model": "opus"`. Changed in commit `2a05357`, whose message is `feat(enforce): convert five honor-system rules to mechanical enforcement` and whose body enumerates five named rule conversions (R-103, R-311, R-324, R-505/R-506, R-513): it does not mention a model-routing change at all. `"fable"` does not match any documented Claude Code `model` value (`opus`/`sonnet`/`haiku`/`opusplan`/a full model ID string) and does not appear anywhere else in the repo as a defined alias (`grep -rn '"fable"'` across `.md`/`.json`/`.sh` returns only this one line). `rules/cost.md` R-903 explicitly routes "Opus" for "audits, multi-step planning": this config, if it resolves to nothing or to an unintended default, silently overrides that routing policy for every session, not just this one.

Governing rule: R-903 (model routing), R-510/commit-message hygiene (an unrelated, unmentioned change bundled into a scoped commit).

Direction: verify what `"fable"` actually resolves to in this environment before doing anything else; if it is not an intentional, documented alias, revert to `"opus"` in its own commit. To confirm: whether "fable" is a supported internal alias for this Claude Code build (check Claude Code's own settings schema/changelog, not this repo), and whether any session has failed to start or silently downgraded model since `2a05357` landed (Jul 3 10:21).

### P1: Canonical audit-role files cite rule IDs that now collide with unrelated new rules

`~/.claude/agents/audit-engineering.md:14` and `:43`, `~/.claude/agents/audit-security.md:14`, `:48`, `:64`, `~/.claude/agents/audit-criticism.md:14`, `:16`, `:65` all cite:
```
## Finding and fix discipline (R-403)
...
**Allowed read scope** (per CLAUDE.md R-107): ...
```
Under the pre-2026-07-03 scheme these were correct: old R-403 was "Audit output discipline" and old R-107 was "Audit roles read project source/docs/tests..." (confirmed against the pre-restructure rule text). `PROTOCOL.md` Appendix B's own alias table maps old `R-403` to new `R-804` and old `R-107` to new `R-805`. But under the **current** scheme, `R-403` and `R-107` are live, differently-scoped rules:
- `CLAUDE.md` current `R-403`: "Follow the bug-fix path in order" (Testing and quality block).
- `CLAUDE.md` current `R-107`: "Investigate any `core.hooksPath` value resolving outside the expected lefthook path before committing" (Secrets and trust block).

So these three files, which `audits/engineering.md`, `audits/security.md`, and `audits/criticism.md` (all in the audited scope) point to as "the single source of truth", now cite the wrong rules for their own governing discipline and read-scope restriction. This is not a dangling reference a naive grep would catch (both IDs resolve to real, valid-looking rules), which is exactly why it survived the automated cross-reference sweep: the collision is semantic, not syntactic. The renumber commit's own message states its reference migration covered "hooks, manifest, tests, skills, prompts, and memory citations": `agents/` is conspicuously absent from that list, and file mtimes confirm none of the three files were touched by either of today's commits (last touched Jun 23/24).

Governing rule: this is a cross-reference-validity defect against `PROTOCOL.md` Appendix B (which the renumber commit itself established as the authoritative old to new mapping) and against `rules/audits.md` R-805 (which these files are supposed to restate correctly).

Direction: update the three citations (`R-403` to `R-804`, `R-107` to `R-805`) in each of the three `agents/audit-*.md` files. To confirm: whether any other agent file under `agents/` (the six on-request roles) carries the same stale citations; this audit's scope did not include a full sweep of all nine agent files, only the three standing roles that this dispatch's role file points to.

### P1: enforce/manifest.json is missing entries for 10 rules CLAUDE.md itself says are hook-enforced

Scripted diff of every `CLAUDE.md` rule's `Enforcement:` line against `enforce/manifest.json`'s `id` list found these rules with a named hook enforcer in `CLAUDE.md` but **no manifest entry**:

| Rule | CLAUDE.md Enforcement line | manifest.json entry |
|---|---|---|
| R-101 | `hook:destructive-db-guard` | absent |
| R-102 | `hook:secret-scan (PreToolUse), hook:redact-output (PostToolUse), hook:redaction-guard-check (SessionStart)` | absent |
| R-106 | `hook:global-repo-push-guard` | absent |
| R-107 | `hook:hookspath-drift-check (SessionStart warning)` | absent |
| R-207 | `hook:no-em-dash` | absent |
| R-328 | `hook:migration-defaults-guard` | absent |
| R-402 | `hook:fix-commit-requires-test` | absent |
| R-403 | `hook:fix-commit-requires-test` | absent |
| R-507 | `hook:conflict-markers` | absent |
| R-516 | `hook:enforcement-guard-check` | absent |

`enforce/README.md:64` states the system's own design contract: "Ship the enforcer... AND a fixture test under `tests/`. A rule with no manifest entry is unenforced and depends on recall." By that stated contract, these 10 rules, several of them the highest-consequence rules in the file (R-101 destructive-DB hard-block, R-102 secret redaction, R-516 the manifest-completeness rule itself), read as "unenforced" to anyone trusting the manifest as the completeness index, even though a hook script genuinely exists and is registered in `settings.json` for each of them. This is a documentation-of-coverage gap, not a functional enforcement gap (the hooks do fire), but it directly undermines R-516's stated purpose ("compliance does not depend on recall") because the manifest, the tool built specifically to make coverage checkable without recall, cannot currently answer "is R-101 enforced?" correctly by itself.

Confirmed structural cause: `hooks/enforcement-guard-check.sh` (the SessionStart guard R-516 cites as its own enforcer) only checks one direction: it derives `REQUIRED` hooks from the manifest and verifies they're registered in `settings.json` (lines 14-25 of the script). It never checks the reverse: whether every `hook:X` cited in a `CLAUDE.md` `Enforcement:` line has a manifest entry. `enforce/tests/manifest.test.sh` likewise only validates the manifest's own internal schema (non-empty, required keys, valid tier enum): it does not cross-check against `CLAUDE.md`.

Governing rule: R-516 ("Register every mechanizable rule in `~/.claude/enforce/manifest.json`... A rule with no manifest entry is unenforced and depends on memory").

Direction: add manifest entries for the 10 rules above (tier `regex` for the SessionStart/PreToolUse guards, matching the pattern already used for R-103/R-311/R-306/R-312). Separately, extend `enforcement-guard-check.sh` (or a new fixture test) to check the missing direction: parse every `Enforcement: hook:X` / `Enforcement: eslint:X` line out of `CLAUDE.md` and assert each rule ID has a manifest entry. To confirm: the exact tier each of the 10 belongs in (several, like R-102 and R-516, span multiple hooks across multiple events and may need multiple manifest rows or a documented one-to-many convention that doesn't currently exist in the schema).

## Findings: P2

- **`hooks/commit-message-guard.sh` enforces a broader rule than R-505's text states.** `~/.claude/hooks/commit-message-guard.sh:50-51` denies any commit subject that doesn't match `^(feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert)(\([^)]*\))?!?: .+`, citing "R-505" in the deny reason. But `CLAUDE.md`'s R-505 text is narrowly "Make one commit per triage ID... two IDs max when inseparable": it says nothing about a conventional-commit type prefix. The broader type-prefix requirement exists only as prose in `PROTOCOL.md:78-87` ("Commit-subject conventions") with no corresponding numbered `CLAUDE.md` rule. The hook is functioning as designed and its test suite (`enforce/tests/commit-message-guard.test.sh`) is well-built, but it is citing the wrong (or only partially matching) governing rule to the user in its deny message, which will read as confusing when someone checks R-505 in `CLAUDE.md` and finds no mention of subject-type format. Direction: either fold the conventional-type requirement into R-505's `Spec`, or add a new rule ID for it and update the hook's `deny` message and the manifest entry's rationale. To confirm: whether this was an intentional scope expansion during the R-505/R-506 conversion work, in which case the fix is documentation (update R-505's Spec text), not code.
- **R-503's manifest enforcer isn't a real mechanical check.** `enforce/manifest.json:26` lists `{"id":"R-503","tier":"advisory","enforcer":"model:progress-reporting",...}`, and `CLAUDE.md`'s R-503 Enforcement line reads `manual (manifest: advisory)`, a format no other rule in the file uses (every other advisory-tier rule names a real `hook:X`). `model:progress-reporting` doesn't correspond to any script under `hooks/` or `enforce/`; it's a label for "the model is expected to self-report," i.e. still honor-system. Having a manifest entry for a rule with no backing mechanism creates false confidence that R-503 has been mechanized when it has not. Direction: either build a real enforcer (e.g., a `Stop`/`SubagentStop` hook that checks the task ledger for percentage/timestamp fields) or remove the manifest entry and mark R-503 explicitly honor-system per `enforce/README.md`'s own stated design principle (rules without enforcement carry an honor-system marker). To confirm: whether a `model:*` enforcer category is an intentional, documented third thing distinct from `hook:`/`eslint:` (it does not appear in `enforce/README.md`'s tier table, which only documents `regex`/`ast`/`llm-judge`/`advisory` mechanisms, not `model:*` as a mechanism name).
- **12 of 24 registered hooks have no fixture test.** Cross-referencing `hooks/*.sh` plus `hooks/*.mjs` against every test file's referenced hook name (`enforce/tests/*.test.sh` + `hooks/tests/*.test.sh`) found no test coverage for: `clean-code-reminder.sh`, `clean-code-scan.mjs`, `conflict-markers.sh`, `destructive-db-guard.sh`, `fix-commit-requires-test.sh`, `flat-directory-reminder.sh`, `no-em-dash.sh`, `ntfy-notify.sh`, `pre-compact.sh`, `redact-output.sh`, `redaction-guard-check.sh`, `session-start.sh`. Several of these back high-consequence rules: `destructive-db-guard.sh` has zero test coverage, and R-207 em-dash, the single most emphasized rule in the whole corpus, also has zero direct fixture coverage (`hooks/tests/session-end.test.sh` references `no-em-dash.sh` only incidentally, inside a fires-log string, not as a functional test of the hook). Direction: prioritize fixture tests for `destructive-db-guard.sh`, `fix-commit-requires-test.sh`, and `no-em-dash.sh` first (highest-consequence, zero coverage); the remainder are advisory/reminder hooks where a missing test is lower risk. To confirm: whether any of these were deliberately left untested (e.g., `pre-compact.sh`/`session-start.sh` are lifecycle hooks that may be hard to fixture-test in isolation) versus simply not yet built.
- **`hooks/tests/` has no aggregate runner and isn't documented as part of "running the tests."** `enforce/README.md:66-70` ("Running the tests") only documents `bash ~/.claude/enforce/tests/run-tests.sh`. `hooks/tests/` (5 files) has no equivalent `run-tests.sh`; `SETUP.md:50` documents a manual `for t in ~/.claude/hooks/tests/*.test.sh; do bash "$t"; done` loop as the "Verify the install" step, but this is a separate, easy-to-miss document from `enforce/README.md`, and neither is invoked by any hook or automation: both suites are entirely dependent on someone remembering to run them by hand. Direction: add a `hooks/tests/run-tests.sh` mirroring `enforce/tests/run-tests.sh`, and reference both runners from a single documented "run all tests" command in `enforce/README.md`. To confirm: whether combining both directories under one runner is preferred over keeping them separate (they currently live in different trees for a reason: `enforce/tests/` covers the manifest-driven system, `hooks/tests/` covers hooks outside that system, so a single combined script rather than a merge may be the right shape).
- **`README.md`'s hook inventory and layer count are stale.** `README.md:32` and `:47` cite "8 hook scripts"; the directory tree at `README.md:81-89` lists exactly 8 files (`secret-scan.sh`, `no-em-dash.sh`, `fix-commit-requires-test.sh`, `conflict-markers.sh`, `redact-output.sh`, `pre-compact.sh`, `session-start.sh`, `session-end.sh`). The actual `hooks/` directory has 24 scripts (`ls hooks/*.sh hooks/*.mjs | wc -l`). This predates today's restructure (last `README.md` hook-count edit predates the current session) but the restructure's own `README.md` edit (in `39f78f0`) touched this file for rule-ID substitutions and left the stale count/list untouched, so it remains current-state drift after the audited commits. Separately, `README.md:3` and `:36-51` frame the system as a "ten-layer model" with a 10-row table; `PROTOCOL.md` (correctly updated by the same commit) now documents **eleven** layers, with Layer 11 (Destructive-action guards / `destructive-db-guard.sh` / R-101) entirely absent from `README.md`'s table. Direction: regenerate the `README.md` hook inventory and directory tree from the actual `hooks/` listing, and add Layer 11 to the "ten-layer model" section (retitling it "eleven-layer model" to match `PROTOCOL.md`). To confirm: whether `README.md` is meant to stay a curated summary (intentionally omitting some hooks) rather than an exhaustive list; if so, the "8 hook scripts" and "ten-layer" framing still need correcting even under that reading, since both are factually wrong counts, not curation choices.
- **No `ISSUES.md`/`TODO.md` exists at the repo root.** `rules/audits.md` R-802 ("P2/P3 current-effort... to `ISSUES.md`") and `CLAUDE.md` R-601 ("update `TODO.md`/`ISSUES.md` with deferred work") both name a file that does not exist anywhere in `~/.claude` (`ls ISSUES.md TODO.md` returns not found). Every past audit's P2/P3 items and every session's deferred work have had no canonical landing place matching what the rules describe. Direction: create `ISSUES.md` (or point R-802/R-601 at wherever deferred work actually lives, if it lives somewhere else already, e.g. `global-memory/`). To confirm: whether deferred items are actually tracked elsewhere (e.g. inside dated `docs/audits/*-session-handoff.md` files) and the rule text is stale rather than the practice.

## Findings: P3

- `CLAUDE.md` R-315, R-316, R-317, R-318, R-325 all have `Enforcement: judge` (bare), while R-320 and R-322 (same `llm-judge` manifest tier) write `judge; hook:llm-rule-judge (advisory)` / `judge; hook:clean-code-reminder (advisory)`, naming the actual backing hook. The bare-`judge` rules don't name `hook:llm-rule-judge` even though `enforce/manifest.json` lists that exact enforcer for all of them. Minor template inconsistency within the same tier. Direction: standardize all seven `llm-judge`-tier rules to name `hook:llm-rule-judge` explicitly, matching R-320/R-322's format.
- R-303's AST-tier enforcement (`import/no-restricted-paths`) is entirely inert by default: `enforce/lint.mjs:24-38` only activates it when the target repo supplies a `.enforce.json` with a non-empty `importZones` array. This is documented in `enforce/README.md:41` ("With no zones, import-direction is not enforced") but `enforce/manifest.json`'s R-303 entry (`"severity":"error"`) gives no signal that the check is conditional/opt-in per repo, which could read as "always checked" to someone trusting the manifest alone. Direction: note the conditionality inline in the manifest (a `"note"` field, or a distinct tier) rather than only in the separate README prose.
- `enforce/eslint.config.mjs:2-5` and `hooks/push-eslint-gate.sh:4` header comments both cite only `R-323/R-321/R-319` as the rules checked at the AST tier; the actual manifest AST tier now also includes R-326, R-327, R-303, and (added today) R-324. Functionally harmless (the comments don't drive behavior; `lint.mjs` runs the full bundled config regardless of what the comment says), but the comments are stale documentation as of today's commit. Direction: update both header comments to list the current AST-tier rule set, or better, have them reference "the manifest's `ast` tier" generically instead of enumerating IDs that will drift again.

## Compliance Notes (checked, no finding)

- All 92 rule definitions in `CLAUDE.md` + `rules/*.md` follow the `R-NNN[ [tag]]: imperative` template with `Scope`/`Spec`/`Enforcement` always in that order and `Enforcement` always present and last: zero violations found by scripted check.
- Every in-body `R-NNN` cross-reference inside `CLAUDE.md`/`rules/*.md` (Scope/Spec text pointing at other rules) resolves to a currently-defined rule ID: zero dangling references found.
- `PROTOCOL.md` Appendix B's legacy-alias table (94 old to new pairs) is internally consistent: every "New" target is a real current rule ID, no duplicate old-ID sources, no duplicate new-ID targets.
- `PROTOCOL.md` Appendix A's "old R-XXX" citations and the "Retired" footnote correctly and clearly label historical IDs as historical; they are not live cross-references and are not a defect.
- `hooks/*.sh`, `hooks/tests/*.sh`, `enforce/*.mjs`, `enforce/*.md`, `enforce/tests/*.sh`, `enforce/manifest.json`, and `settings.json` cite zero stale/undefined rule IDs: the "hooks, manifest, tests... migrated atomically" claim in the renumber commit message holds for this surface.
- The five newly-converted rules (R-103, R-311, R-324, R-505, R-506, R-513) each have a manifest entry, a registered hook (where applicable), and a fixture test that passes; `structure-gate.sh`'s abbreviation list correctly excludes `config/`/`services/`/`database/`/`dependencyInjection/` (only exact-match abbreviations like `db`/`di`/`cfg` are blocked, not the full words the rules mandate).
- `SETUP.md`'s two rule-ID substitutions from the renumber (R-109 to R-107, R-101 to R-102) are both correct per the Appendix B alias table.

## Tech Debt Register

| Item | Risk | Notes |
|---|---|---|
| `enforce/manifest.json` completeness depends on manual sync with `CLAUDE.md` | Medium | No automated check in either direction currently exists beyond the manifest to settings.json half; see P1 finding. |
| `agents/` directory excluded from the renumber's reference-migration tooling | Medium | Same root cause likely affects the six on-request agent files (`audit-ux.md`, `audit-design.md`, etc.), not audited here; scope was the three standing roles only. |
| `README.md` drifts independently of `PROTOCOL.md` | Low-Medium | Two documents describe the same layer model and can silently diverge (already have: 10 vs 11 layers). No single source of truth for the layer count. |
| No CI for `~/.claude`'s own test suites | Low | Acceptable for a local config repo, but means a future change can silently break `enforce/tests/` or `hooks/tests/` and nobody finds out until the next manual run. |
| `commit-message-guard.sh` enforces conventional-commit typing under R-505's ID without R-505's text covering it | Low | Cosmetic/citation-accuracy issue, not a functional bug; the check itself is reasonable. |

## Prioritized Recommendations

| # | Recommendation | Impact | Effort |
|---|---|---|---|
| 1 | Verify `settings.json` `"model": "fable"` is intentional; revert to `"opus"` if not | H | L |
| 2 | Fix `R-403` to `R-804` and `R-107` to `R-805` citations in the three standing `agents/audit-*.md` files | H | L |
| 3 | Add the 10 missing manifest entries; extend `enforcement-guard-check.sh` (or add a fixture test) to check the `CLAUDE.md` to manifest direction | H | M |
| 4 | Sweep the six on-request `agents/audit-*.md` files for the same stale-ID pattern | M | L |
| 5 | Regenerate `README.md`'s hook inventory/count and add the eleventh layer to its table | M | M |
| 6 | Add fixture tests for `destructive-db-guard.sh`, `fix-commit-requires-test.sh`, `no-em-dash.sh` | M | M |
| 7 | Add a `hooks/tests/run-tests.sh` runner and document both runners in one place | L | L |
| 8 | Reconcile R-505's text with what `commit-message-guard.sh` actually enforces (fold in or split out the conventional-type requirement) | L | L |
| 9 | Create `ISSUES.md` or repoint R-802/R-601 at the actual deferred-work store | L | L |
| 10 | Fix the stale AST-tier rule-ID lists in `eslint.config.mjs`/`push-eslint-gate.sh` comments | L | L |
