# Session Handoff: 2026-07-31 Python Enforcement Parity

## 1. Last commit

- `410508c` fix(enforce): close the 2026-07-31 audit P1s on Python gate scope and ruff drift detection
- Pushed to origin/main; working tree clean at handoff (this doc's commit follows).

## 2. Production state

- All five session commits pushed to `github.com/nullvoidundefined/claude-global-rules` main.
- Both test suites green: `enforce/tests/run-tests.sh` and `hooks/tests/run-tests.sh`, including `claude-md-lint` (118 lines, 76 rules in sync) and the manifest closure test.
- `push-ruff-gate.sh` is registered in `settings.json` but hooks snapshot at session start: it activates in NEW sessions only.
- ruff is available via `uvx ruff` (0.16.0); no standalone binary on PATH. The gate fails open with a stderr note where neither exists.

## 3. What shipped

- `104ee79` feat(enforce): extend clean-code hooks to Python
  - Fixed a real false-block: `fix-commit-requires-test.sh` now recognizes `tests/`, `test_*.py`, `*_test.py`, `conftest.py` (R-403 globs).
  - `llm-rule-judge.sh` diff scope now includes `*.py` (R-315/316/317/318/322/325 apply to Python at push).
  - `structure-gate.sh`: snake_case package dirs allowed for `.py`, `db/` and `core/` blessed per CLAUDE-PYTHON.md; kebab, other abbrevs, catch-alls still deny.
  - `migration-defaults-guard.sh`: Alembic analogs (nested-quote `server_default`, bare-string SQL call; `sa.text()` passes).
  - `flat-directory-reminder`, `single-file-folder-gate`, `constant-change-guard`: `.py` coverage with `__init__.py`/`conftest.py`/migrations exclusions.
  - Fixture tests extended for every hook; first-ever test for `fix-commit-requires-test.sh`.
- `1813375` feat(enforce): add push-ruff-gate for the Python AST tier
  - `hooks/push-ruff-gate.sh`: push-time, outgoing-diff, added-lines-only (parity with the 2026-07-10 eslint-gate decision), exempt-repos honored, fails open.
  - `enforce/ruff-enforce.toml`: PLR2004 (R-324), ANN401 + PGH003/PGH004 (R-329 analog), E731 (R-326 analog); per-file-ignores for tests/fixtures/migrations.
  - Manifest: four `ruff:*` entries. settings.json registration (also carried a pre-existing deny/ask block reorder).
- `833cdaa` docs(rulebook): Python analogs and exceptions in reference.md (R-306/311/312/324/326/328/329), R-312 norm line in CLAUDE.md, Enforcement section in CLAUDE-PYTHON.md.
- `628e879` docs(audits): engineering audit (Sonnet subagent, scoped to enforce/ + hooks/): no P0, 2 P1, 2 P2, 2 P3. Report at `docs/audits/2026-07-31-engineering.md`.
- `410508c` fix(enforce): both P1s closed with reproduce-then-pass fixtures:
  - structure-gate now scans `app/`-rooted Python trees (previously the entire Python stack bypassed it; synthetic `/x/src/` fixtures had masked this).
  - `enforcement-guard-check.sh` + `manifest.test.sh` now know the `ruff:` tier (R-516 drift detection); `hook-latency.test.sh` chain includes the ruff gate (audit P2).

## 4. Pending (by urgency)

- P2 (low, no action possible): `266d05e` unpaired `fix:` commit pattern note; recorded in ISSUES.md.
- P3 (small, ~15 min): `structure-gate.sh` shows the TS-only R-314 message for Python nested test dirs.
- P3 (small, ~30 min): `xargs` space-in-path weakness shared by `push-ruff-gate.sh` and `push-eslint-gate.sh`; fix both together (NUL-delimited or while-read).
- P3 (design needed): session-lifecycle/notifier hooks untested (pre-existing, 2026-07-03).

## 5. Next session

- If Python enforcement misbehaves in a real project: read `hooks/push-ruff-gate.sh`, `enforce/ruff-enforce.toml`, `hooks/structure-gate.sh`, and `docs/audits/2026-07-31-engineering.md` first.
- Optional follow-ups: pick up the two small P3s from ISSUES.md in one commit; consider a `hooks/tests` case for the R-314 message wording.
- New project-scoped memory: `fixture-paths-mirror-documented-layouts` (fixture paths must mirror documented layouts, from the P1 miss); indexed in this machine's project memory MEMORY.md.
- jq gotcha worth remembering when editing the gates: `index()` evaluates its argument against the piped-in input, so bind `.location`-derived keys with `as` before `select($arr | index($key))`.
