# Engineering Audit: Python Enforcement Parity in `enforce/` and `hooks/` (2026-07-31)

## Scope

`~/.claude` on `main`, HEAD `833cdaa` (`docs(rulebook): record the Python analogs and exceptions for the enforced rules`). Scoped per dispatch to the surfaces that tripped the R-801 5+ commit signal since the 2026-07-04 audit: `enforce/` (`eslint.config.mjs`, `lint.mjs`, `manifest.json`, `ruff-enforce.toml`, `resolveOutgoingBase.sh`, `tests/`) and `hooks/` (all `*.sh`, `hooks/tests/`). Dependencies read outside that boundary only where a scoped file cites them: `settings.json` hook registrations, `CLAUDE.md` and `rulebook/reference.md` rule text, `CLAUDE-PYTHON.md` (the convention file the Python parity commits document against).

23 commits touched `enforce/`/`hooks/` since 2026-07-04. Extra attention per dispatch: the three newest commits (`104ee79` extend seven hooks to `.py`, `1813375` add `push-ruff-gate.sh` plus `ruff-enforce.toml`, `833cdaa` document the analogs), plus `eslint.config.mjs` (5 commits) and `enforce/tests/` (11 commits) over the full window.

Method: read every changed hook and its diff; ran both fixture suites (`enforce/tests/run-tests.sh`, `hooks/tests/run-tests.sh`, all green, 24s/4s respectively); executed the actual push-ruff-gate against a live `ruff`/`uvx` binary to confirm JSON-path assumptions; executed `structure-gate.sh` directly against paths matching CLAUDE-PYTHON.md's documented tree (not just the shipped fixtures) to verify the new Python exceptions actually fire in the layout they claim to cover; ran `enforcement-guard-check.sh` against a settings.json copy with `push-ruff-gate.sh` deregistered to test the meta-guard's own coverage of the new tier; scanned commit history since 2026-07-04 in scope for `fix:`/`bug:`/`hotfix:` subjects and checked each for a paired test-file change (R-403/Bug Fix Discipline). Grepped `enforce/` and `hooks/` for hardcoded-secret patterns; only hits are redaction-pattern definitions and an all-`A` placeholder key in a test fixture, both expected and compliant.

Credential-exposure scan: not run as a full multi-surface sweep (git history, session transcripts, shell history, vendor CLI caches) this cycle. The dispatch scoped this audit to `enforce/`/`hooks/` source and explicitly excluded `.env*`, `~/.aws`, `~/.ssh`, and keychains from the read set; a full R-1xx-style credential sweep is a separate audit surface, not part of this dispatch. Noting the exclusion per audit discipline rather than silently omitting it.

## P0

None. No credential leak, no red suite, no hook missing its execute bit, no unregistered manifest enforcer for the `hook:`/`eslint:` tiers.

## P1

### P1-1: the new Python structure-gate exceptions never fire in the Python layout CLAUDE-PYTHON.md itself documents

`hooks/structure-gate.sh:25-40` gates the entire R-306 (catch-all), R-311 (abbreviation), R-312 (camelCase) check block behind having seen a `src` path segment:

```
25	IFS='/' read -ra PARTS <<< "$FILE"
26	in_src=0
27	in_app=0
...
33	for seg in "${PARTS[@]}"; do
...
35	  [ "$seg" = "src" ] && in_src=1 && continue
36	  [ "$in_src" -eq 0 ] && continue
...
40	  [ "$seg" = "app" ] && in_app=1 && continue
```

Seeing `app` sets `in_app=1` (used later only to permit kebab-case Next.js route segments) but does not set `in_src=1`. Since `in_src` never becomes 1 for a path with no `src` segment, line 36 (`continue`) skips every remaining segment for the rest of the loop, meaning the R-306/R-311/R-312 checks added in this same commit (`104ee79`) never run at all.

CLAUDE-PYTHON.md's own Directory Structure section (`CLAUDE-PYTHON.md:22-45`, unchanged by this window) places the FastAPI app tree directly at `app/` with no `src/` wrapper (`app/core/`, `app/db/`, `app/services/`, `app/clients/`, and so on), and its Entry Point section confirms the import path: `uvicorn runs app.main:create_app` (`CLAUDE-PYTHON.md:92`). The same commit's new Enforcement section states plainly: "`hook:structure-gate` allows snake_case package dirs, `db/`, and `core/` in Python trees; catch-alls, other abbreviations, kebab-case, and co-located tests still deny" (`CLAUDE-PYTHON.md:174`). That is false for the documented layout. Verified by direct execution:

```
$ printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/app/utils/format.py"}}' | bash hooks/structure-gate.sh
(nothing, exit 0, allowed)

$ printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/app/svc/user.py"}}' | bash hooks/structure-gate.sh
(nothing, exit 0, allowed)

$ printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/app/user-preferences/api.py"}}' | bash hooks/structure-gate.sh
(nothing, exit 0, allowed)
```

All three should deny (banned catch-all `utils/`, banned abbreviation `svc/`, banned kebab-case respectively) and none did. For contrast, the equivalent TypeScript path denies correctly:

```
$ printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"/x/src/utils/format.ts"}}' | bash hooks/structure-gate.sh
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny", ...}}
```

The shipped fixtures (`enforce/tests/structure-gate.test.sh`, added lines from `104ee79`) all prefix Python paths with `/x/src/...` (`allow '{"tool_name":"Write","tool_input":{"file_path":"/x/src/user_preferences/api.py"}}'`, `deny '.../x/src/svc/user.py'`, and so on), an artificial layout that happens to satisfy the `in_src` gate but does not match the layout CLAUDE-PYTHON.md prescribes, so the test suite is green while the real-world behavior is broken. This is a false-negative on a deny gate for an entire stack's canonical layout, not a partial gap.

R-313 (test co-location) is unaffected: that check block (`structure-gate.sh:62-90`) is independent of the `in_src`/`in_app` loop and was verified to still deny a co-located `app/services/jobs/test_jobs.py` correctly.

Governing rule: R-306, R-311, R-312 (`hook:structure-gate`), contradicted in practice against the documented Python layout in CLAUDE-PYTHON.md.

Direction: change the trigger condition so the check block activates for Python files regardless of a `src/` segment (for example, activate immediately when `is_python=1`, or add `app` as an equivalent root-of-source marker for Python the way `src` is for TypeScript). To confirm: whether `app/` is the only documented Python root or whether some projects also use a `src/`-layout package (check any existing Python repos under the user's project roots for their actual top-level directory before picking the trigger); update the fixture tests in `enforce/tests/structure-gate.test.sh` to use `/x/app/...` paths (matching CLAUDE-PYTHON.md) in addition to or instead of the current `/x/src/...` fixtures, since the current fixtures would not have caught this.

### P1-2: the R-516 bidirectional guard and its own test are blind to the new `ruff:*` enforcer tier

`hooks/enforcement-guard-check.sh` checks two directions: every manifest `hook:`/`eslint:` enforcer is registered in `settings.json` (forward), and every `hook:`/`eslint:` enforcer cited in a rule file's `Enforcement:` line has a manifest entry (reverse):

```
16	REQUIRED=$(jq -r '.rules[].enforcer' "$MANIFEST" | awk '
17	  /^hook:/   { sub(/^hook:/,""); print $0 ".sh" }
18	  /^eslint:/ { print "push-eslint-gate.sh" }
19	' | sort -u)
...
30	CITED=$(cat $RULE_FILES 2>/dev/null | grep -E '^  Enforcement:' | grep -oE '(hook|eslint):[A-Za-z0-9_-]+' | sort -u || true)
```

`enforce/manifest.json` now carries four `ruff:*` enforcer entries (`ruff:PLR2004`, `ruff:E731`, `ruff:ANN401`, `ruff:PGH003`, added in `1813375`), and `rulebook/reference.md` cites them in `Enforcement:` lines (`ruff:PLR2004 via push-ruff-gate`, `ruff:E731 via push-ruff-gate`, `ruff:ANN401 + PGH003/PGH004 via push-ruff-gate`, added in `833cdaa`). Neither the forward `awk` pattern (line 17-18) nor the reverse `grep -oE` alternation (line 30, `(hook|eslint):`) recognizes a `ruff:` prefix, so:

- The forward check never requires `push-ruff-gate.sh` to be registered in `settings.json`, even though four manifest rules depend on it being there.
- The reverse check never requires a manifest entry for a `ruff:*` citation in `reference.md`.

Verified empirically by deregistering `push-ruff-gate.sh` from a copy of `settings.json` and running the guard:

```
$ FIX=$(mktemp); jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("push-ruff-gate") | not))' settings.json > "$FIX"
$ CLAUDE_SETTINGS_FILE="$FIX" bash hooks/enforcement-guard-check.sh < /dev/null
(nothing)
```

The guard stayed silent even though four manifest rules would then be pointing at an unregistered hook, exactly the R-516 failure mode the guard exists to prevent ("A rule with no manifest entry depends on recall"), now recurring one layer down (a manifest entry whose hook is not registered depends on recall too, because the guard cannot see it). The same gap exists in `enforce/tests/manifest.test.sh:22` (`re.search(r'\b(hook|eslint):', enforcement)`), which validates manifest closure against rule-file citations at test time and would also silently pass a `ruff:*` citation with no manifest entry. Neither `enforce/tests/enforcement-guard-check.test.sh` nor `enforce/tests/manifest.test.sh` was extended with a case exercising the `ruff:` prefix in this window, so the gap shipped untested in both the guard and its own fixture.

Governing rule: R-516 (`hook:enforcement-guard-check`).

Direction: add a `ruff:` branch to the `awk` pattern at `enforcement-guard-check.sh:16-19` (mapping to `push-ruff-gate.sh`, mirroring the existing `eslint:` to `push-eslint-gate.sh` line) and extend the `grep -oE` alternation at line 30 from `(hook|eslint):` to `(hook|eslint|ruff):`. Apply the same extension to `manifest.test.sh:22`'s regex. To confirm: whether any other enforcer-prefix convention (for example a future `mypy:` or `black:` tier) should be handled generically (a data-driven prefix list read from the manifest's own enforcer values, rather than hardcoding each new prefix in three places) to prevent this exact recurrence next time a new tier ships.

## P2

### P2-1: `hook-latency.test.sh`'s modeled Bash chain omits `push-ruff-gate.sh`, which is registered in the real chain

`enforce/tests/hook-latency.test.sh:17` defines the hooks it times as a stand-in for the live `PreToolUse:Bash` chain:

```
17	BASH_HOOKS="secret-scan.sh no-em-dash.sh fix-commit-requires-test.sh conflict-markers.sh commit-message-guard.sh destructive-db-guard.sh global-repo-push-guard.sh push-eslint-gate.sh constant-change-guard.sh audit-signal-check.sh llm-rule-judge.sh single-file-folder-gate.sh"
```

`settings.json:110` registers `push-ruff-gate.sh` in the same `PreToolUse` to `Bash` matcher chain as `push-eslint-gate.sh` (`settings.json:106`), added in `1813375`, but the latency list was not updated alongside it. Impact is currently low: `push-ruff-gate.sh` early-exits on any non `git push` command at line 17 (`printf '%s' "$CMD" | grep -Eq ... || exit 0`), the same early-exit pattern `push-eslint-gate.sh` already uses, so its cost on the `ls -la` payload the test sends is negligible. The finding is that the guard's own stated invariant, modeling the real per-edit chain to catch latency growth before it ships, is no longer accurate to `settings.json`, and a future change that weakens or removes `push-ruff-gate.sh`'s early exit (for example a refactor that moves the `git push` check later, or that always shells out to resolve `uvx`) would not be caught by this test.

Governing rule: none numbered directly; instances the hook-latency invariant described in the file's own header comment (`hook-latency.test.sh:1-9`) and R-516's spirit of self-detecting drift.

Direction: add `push-ruff-gate.sh` to `BASH_HOOKS` at `hook-latency.test.sh:17`. To confirm: whether the budget multiplier/floor still holds with 13 hooks in the chain instead of 12 (rerun the test after the addition; it is a cheap early exit so should not move the number materially).

### P2-2: unpaired fix commit in the audited window

Commit `266d05e` (`fix(enforce): mirror trivago Prettier group boundaries in import/order pathGroups`) changes only `enforce/eslint.config.mjs` (20 lines: 14 insertions, 6 deletions) with no test file touched in the same commit:

```
$ git show --stat 266d05e
 enforce/eslint.config.mjs | 20 ++++++++++++++------
 1 file changed, 14 insertions(+), 6 deletions(-)
```

This is optimism-driven debugging under R-403's definition: a `fix:`-labeled change to enforcement source with no test proving the prior behavior was wrong or the new behavior is right. It is the lone unpaired fix in the audited window: the other four `fix:` commits touching `enforce/`/`hooks/` since 2026-07-04 all paired source and test changes (`4755571`, `1962e0c`, `43277d4` each changed a `.test.sh` alongside source; `c4e0ee8` modified only `hook-latency.test.sh` itself, which is a test-file-only change and excluded from the unpaired-fix count by the audit framework's own rule). One instance is a P2 pattern note per the Bug Fix Discipline threshold (three or more in the window would be P1).

Governing rule: R-403 (`hook:fix-commit-requires-test`).

Direction: none required retroactively (the commit already shipped and the fix.mjs behavior is presumably correct); note as a pattern to watch. To confirm: whether a regression test for the specific pathGroup boundary behavior described in the commit message (react/react-dom/next family blank-line separation versus adjacency) already exists elsewhere in `enforce/tests/eslint.test.sh` under a different commit's name; if so this is a documentation gap rather than a true test gap, and should not recur as a finding.

## P3

### P3-1: R-314's TypeScript-only nested-`__tests__` check is not scoped away from Python test filenames

`hooks/structure-gate.sh:80-90` matches both TypeScript and Python test-filename conventions in one `BASE` check, then applies the same `*/src/*/__tests__/*` R-314 nested-tree deny to whichever matched:

```
80	BASE=$(basename "$FILE")
81	if [ "$skip_colocation_check" -eq 0 ] && { [[ "$BASE" =~ \.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$ ]] || [[ "$BASE" =~ ^test_.*\.py$ ]] || [[ "$BASE" =~ _test\.py$ ]]; }; then
82	  case "$FILE" in
83	    */__tests__/* | */tests/* | */e2e/*)
84	      if [[ "$FILE" == */src/*/__tests__/* ]]; then
85	        deny "Test file sits in a per-directory __tests__ nested below src/ (R-314). Keep one top-level tree: src/__tests__/<mirrored source path>."
```

R-314 is explicitly tagged `[ts]` in `CLAUDE.md` ("R-314 [ts]: One top-level `__tests__/` tree per package's `src/`..."). A Python test file that happened to land in a nested `.../src/foo/__tests__/test_bar.py` path would be denied citing R-314 and told to use `src/__tests__/`, a TypeScript-only convention that contradicts R-313's Python guidance (`tests/`, not `__tests__/`). Low practical likelihood, since Python's own naming convention (`test_*.py` under `tests/`) rarely collides with a `__tests__/` directory, but the code path is real and untested; no fixture in `structure-gate.test.sh` exercises a Python filename against the `*/src/*/__tests__/*` branch.

Governing rule: R-314 `[ts]` scope, R-313 Python `tests/` convention.

Direction: gate the R-314-specific nested-tree deny (lines 84-86) to non-Python files only, since R-314 does not apply to the Python track; a Python test file nested under a `__tests__/`-named directory should instead fall through to the general R-313 co-location deny (or a Python-specific message) rather than citing a TS-only rule. To confirm: whether this combination has ever actually occurred in a real Python tree before prioritizing the fix, given the low likelihood noted above.

### P3-2: unquoted file lists in `xargs` invocations would mis-split a path containing a space

`hooks/push-ruff-gate.sh:59` (new) and the pre-existing `hooks/push-eslint-gate.sh:36` both pipe a newline-separated file list into `xargs` with default whitespace-based argument splitting:

```
59	RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUFF check --config "$CONFIG" --output-format json --no-cache 2>/dev/null || true)
```

A tracked file path containing a space would be split into multiple bogus arguments rather than treated as one path, causing `ruff`/`eslint` to either error or silently skip the intended file. Pre-existing pattern (shared by `push-eslint-gate.sh`, not introduced by this window) reproduced verbatim in the new `push-ruff-gate.sh`; low likelihood given this repo's own R-312 naming conventions disallow spaces in directory/file names, and no test in either `push-eslint-gate.test.sh` or `push-ruff-gate.test.sh` covers a spaced filename either way.

Governing rule: none numbered; general shell-quoting correctness the dispatch explicitly asked to check.

Direction: switch to `xargs -0` fed by `printf '%s\0'` (or a `while read -r` loop) in both push-gate scripts if space-containing paths are ever expected to occur in a consuming repo. To confirm: whether any repo this gate runs against uses space-containing paths today (if none do and the convention forbids it, this can stay P3/deferred rather than actioned).

## Verified clean (no finding)

- `hooks/push-ruff-gate.sh` fail-open logic: confirmed both branches work as documented, falling back to `uvx ruff` when `ruff` is not on `PATH` (this machine has no bare `ruff` binary; the fixture test passed via the `uvx` fallback), and exiting 0 with a stderr note when ruff produces no parseable JSON.
- `hooks/push-ruff-gate.sh` added-line scoping (the `ADDED` awk block, lines 49-56): unified-diff hunk-header parsing (`@@ -a,b +c,d @@`, field `$3`) correctly derives the new-file line ranges added by the diff; a pure-deletion hunk (`+c,0`) correctly contributes zero added lines. Verified by the shipped fixture's added-line-scoping cases (debt.py) and by manual trace.
- `enforce/ruff-enforce.toml` per-file-ignores for `tests/`, `test_*.py`, `conftest.py`: verified live against an actual `uvx ruff` invocation and via the shipped fixture (`push-ruff-gate.test.sh` case 5), a magic-value comparison inside `tests/test_ttl.py` is correctly exempted while the same pattern in `ttl.py` is correctly denied.
- `hooks/migration-defaults-guard.sh` Python (Alembic) regex additions (`NESTED_RE`/`SQL_CALL_RE` at lines 41-42): traced by hand against `server_default="'active'"` (nested-quote anti-pattern, matches and denies), `server_default="active"` (bare constant, correctly does not match), `server_default="now()"` (bare SQL call, matches and denies), and `server_default=sa.text("now()")` (correctly exempt, because `sa.text(` immediately follows `=` rather than a quote character, so neither alternative anchors). All four shipped as fixture assertions and pass.
- `hooks/fix-commit-requires-test.sh` pytest-glob extension (line 100): correctly matches `tests/`, `test_*.py`, `*_test.py`, and `conftest.py` staged paths; heredoc-subject extraction and non-fix-prefix passthrough unaffected by the Python addition.
- `hooks/llm-rule-judge.sh` diff-scope extension to `*.py` (line 21): confirmed a Python-only diff reaches the judge and can deny, per the shipped fixture and code trace.
- `hooks/constant-change-guard.sh` Python constants-file regex (line 19) and test-glob extension (line 32): traced correctly matches `constants.py` and Python test paths; shipped fixture (stale pytest assertion produces `ask`, updated assertion produces `none`) passes.
- `hooks/single-file-folder-gate.sh` and `hooks/flat-directory-reminder.sh` Python `__init__.py`/`conftest.py`/`test_*.py`/migrations exclusions: traced correct against the shipped fixtures; both hooks already handled `.py` file-type filtering correctly before this window for the sibling `clean-code-reminder.sh` and `new-file-header-reminder.sh` (pre-existing, not part of the "seven hooks," confirmed already Python-aware).
- `enforce/eslint.config.mjs` (5-commit window, `4755571`, `266d05e`, `1962e0c` plus two feature commits): the type/schema magic-number exemption, and the two import/order Prettier-boundary fixes, each read correctly against their stated rationale and are covered by fixture assertions in `eslint.test.sh` except `266d05e` (see P2-2).
- `settings.json`'s `deny`/`ask` block reorder in `1813375`: pure key reorder, no permission semantics changed; verified by diff.
- No `core.hooksPath` drift (unset, matches expected `lefthook`-free default for this repo); no uncommitted changes in the working tree at audit time.

## Top priorities for this effort

| # | Finding | Payoff | Effort |
|---|---|---|---|
| 1 | Fix the `in_src` gate in `structure-gate.sh` so R-306/R-311/R-312 actually fire against CLAUDE-PYTHON.md's documented `app/`-rooted layout; add `/x/app/...` fixtures (P1-1) | H: closes a total false-negative on three deny rules for an entire stack's canonical layout | M |
| 2 | Add a `ruff:` branch to `enforcement-guard-check.sh`'s forward/reverse checks and to `manifest.test.sh`'s citation regex (P1-2) | H: restores the R-516 meta-guard's coverage of the newest enforcement tier, currently blind to its own registration | S |
| 3 | Add `push-ruff-gate.sh` to `hook-latency.test.sh`'s `BASH_HOOKS` list (P2-1) | M: keeps the latency regression guard honest against the real registered chain | S |

P2/P3 items for `ISSUES.md`: P2-2 (unpaired fix commit `266d05e`, pattern note), P3-1 (R-314 TS-only nested-tree message misapplied to Python test filenames), P3-2 (unquoted `xargs` file-list splitting in both push gates).
