# Session Handoff: 2026-09-05 Audit Remediation, Observability Rules, Decisions

## 1. Last commit

- `2aaccbd` feat(hooks): observability reminder, model-switch guard, judge asks, deploy ask rules (#12), on `main`. Before it: #11 (`a8b503c`, observability rules R-341 to R-346) and #10 (`e744391`, the configuration audit and its remediation).
- This branch carries the four decisions Ian made on 2026-09-05 (settings.json, the Sonnet-default memory, ISSUES.md) and this handoff.

## 2. Production state

- `main` is green in CI (`fixtures` required) through #12. Nothing on `main` is live in Ian's `~/.claude` until pulled; after the pull: `npm ci --prefix enforce` (lockfile changed twice), delete `~/.claude/.post-compact-pending` if present, and check `claude --version` (the `if`-gated hooks need 2.1.163 or later, the model-switch guard 2.1.251 or later; older builds ignore both).
- Both suites: 42 enforcement fixtures, 12 hook fixtures. `hook-integrity-check.sh` silent. `npm audit` clean.

## 3. What shipped

- **Audit and remediation (#10):** `docs/audits/2026-09-04-config.md`; SessionEnd timeout; compaction re-injection via `SessionStart` matcher `compact`; `Read` deny rules for R-102 paths; one-entry allow list; `if`-gated git hooks; CI on the node24 action majors with Dependabot; ESLint 10 with `eslint-plugin-import-x`; `lint.mjs` resolves the repo root from the file (the fixture "flake" root cause); latency fixture reads `settings.json`; memoized verification gate; `settings-change-guard.sh` on `ConfigChange`; R-001 and INDEX rewrite.
- **Observability (#11):** R-341 to R-346 with Spec blocks, backend and stack conventions, three custom ESLint rules plus `no-console` and `no-empty` scoped to server trees, ruff `T201`/`E722`/`S110`/`BLE001`, golangci `errcheck`/`errorlint` on a v2-schema config (the v1 file was silently rejected by v2 binaries, so the Go gate had enforced nothing), RuboCop `Lint/SuppressedException`, lexicon verbs `log`, `report`, `track`.
- **Hooks and human-in-the-loop (#12):** `observability-reminder.sh` (advisory, R-341/R-345/R-346), `model-switch-guard.sh` (PreModelSwitch, asks on a switch up the price ladder), the judge returns `ask`, deploy and `gh pr create` ask rules.
- **Decisions (this branch):** `model: opusplan`, `permissions.defaultMode: auto`, `code-review` and `code-simplifier` plugins off.

## 4. Pending

- **Ian, outside any session:** `security add-generic-password -a "$USER" -s claude-judge-api-key -w` to activate the judge; the session-start warning stops once the key resolves.
- **Ian, first real session after the pull:** `/context` after a `/compact` in a throwaway session (confirms the compact re-injection); `/status` to confirm auto mode and that `typescript-lsp` registers; `/doctor` for `skipWorkflowUsageWarning` (not in the settings reference).
- **Still open from earlier:** deleting stale merged remote branches (auto-delete is now on); the deny-tier git guards still spawn on every Bash call (ISSUES.md, P2-5 residue).
- **Not implemented by choice:** a `PermissionRequest` auto-decider and the sandbox; both encode policy only Ian can set.

## 5. Next-session tasks, with files to read

- **First backend repo after the pull:** run `node ~/.claude/enforce/ratchet.mjs --update` and commit `.enforce-baseline.json`; expect the count to grow (existing `console.log` and empty-catch debt is grandfathered). Read `enforce/README.md` ("The observability rules").
- **Watch the first `/model opus` switch** in a session for the R-903 prompt; if it fires on a switch that should be silent, `hooks/model-switch-guard.sh` ranks by substring and the fix is one line.
- **Do not hand-edit the R-316 verb bullets** in `rulebook/reference.md`; regenerate from `enforce/lexicon.json`.
- **When adding an enforcer,** R-516 binds: manifest row plus fixture; `settings-change-guard.sh` refuses a settings save that drops one.
