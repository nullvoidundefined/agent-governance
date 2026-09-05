# Session Handoff: 2026-09-05 Audit, Observability Rules, Decisions, Next Steps

## 1. Last commit

- `5a1d78c` chore(settings): record the four audit decisions (#13), on `main`. Before it: #12 (`2aaccbd`, hooks and human-in-the-loop), #11 (`a8b503c`, observability rules R-341 to R-346), #10 (`e744391`, the configuration audit and its remediation).

## 2. Production state

- `main` is green in CI (`fixtures` required) through #12. Nothing on `main` is live in Ian's `~/.claude` until pulled; after the pull: `npm ci --prefix enforce` (lockfile changed twice), delete `~/.claude/.post-compact-pending` if present, and check `claude --version` (the `if`-gated hooks need 2.1.163 or later, the model-switch guard 2.1.251 or later; older builds ignore both).
- Both suites: 42 enforcement fixtures, 12 hook fixtures. `hook-integrity-check.sh` silent. `npm audit` clean.

## 3. What shipped

- **Audit and remediation (#10):** `docs/audits/2026-09-04-config.md`; SessionEnd timeout; compaction re-injection via `SessionStart` matcher `compact`; `Read` deny rules for R-102 paths; one-entry allow list; `if`-gated git hooks; CI on the node24 action majors with Dependabot; ESLint 10 with `eslint-plugin-import-x`; `lint.mjs` resolves the repo root from the file (the fixture "flake" root cause); latency fixture reads `settings.json`; memoized verification gate; `settings-change-guard.sh` on `ConfigChange`; R-001 and INDEX rewrite.
- **Observability (#11):** R-341 to R-346 with Spec blocks, backend and stack conventions, three custom ESLint rules plus `no-console` and `no-empty` scoped to server trees, ruff `T201`/`E722`/`S110`/`BLE001`, golangci `errcheck`/`errorlint` on a v2-schema config (the v1 file was silently rejected by v2 binaries, so the Go gate had enforced nothing), RuboCop `Lint/SuppressedException`, lexicon verbs `log`, `report`, `track`.
- **Hooks and human-in-the-loop (#12):** `observability-reminder.sh` (advisory, R-341/R-345/R-346), `model-switch-guard.sh` (PreModelSwitch, asks on a switch up the price ladder), the judge returns `ask`, deploy and `gh pr create` ask rules.
- **Decisions (this branch):** `model: opusplan`, `permissions.defaultMode: auto`, `code-review` and `code-simplifier` plugins off.

## 4. Pending

**Ian's next steps, in order (none of this is live until step 1):**

1. Pull and install: `cd ~/.claude && git pull origin main && npm ci --prefix enforce` (the lockfile changed twice: ESLint 10 and `eslint-plugin-import-x`).
2. `rm -f ~/.claude/.post-compact-pending` (the retired sentinel; nothing writes it now).
3. `claude --version`: the `if`-gated hooks need 2.1.163 or later and `model-switch-guard.sh` needs 2.1.251 or later; older builds ignore both, so run `claude update` if behind.
4. Activate the naming judge (R-315 to R-317, silent since 2026-08-01). The hook reads `ANTHROPIC_API_KEY` from its environment, then the macOS keychain; project `.env` files are never read (R-102). Pick one:
   - Keychain (current design, encrypted, macOS only): in a terminal outside any Claude session, `security add-generic-password -a "$USER" -s claude-judge-api-key -w`, paste the rotated key at the hidden prompt.
   - `~/.claude/.env` (plaintext, cross-platform, the file the notifier already sources for `NTFY_TOPIC`): needs a one-line change so `llm-rule-judge.sh` sources it; ask for that PR.
   - Shell profile `export ANTHROPIC_API_KEY=...`: works today, but puts the key in every process environment, which is how it reached a command line in April.
   The judge bills the API key, not the subscription; a dedicated key keeps its spend visible.
5. First session after the pull: `/status` should show `opusplan` and auto mode; `/skills` should no longer list the plugin `code-review` and `code-simplifier`; `/context` after a `/compact` in a throwaway session confirms the compact re-injection; `/doctor` answers whether `skipWorkflowUsageWarning` is a real key.
6. First backend repo: `node ~/.claude/enforce/ratchet.mjs --update` and commit `.enforce-baseline.json`; expect the count to grow, since existing `console.log` and empty-catch debt is grandfathered rather than blocked.

**Still open from earlier:** deleting stale merged remote branches (auto-delete is on now, so only old ones remain); the five deny-tier git guards still spawn on every Bash call (ISSUES.md, P2-5 residue); the `.env` deny enumerates variants rather than globbing, so any new secret-bearing `.env.*` name needs its own row (P1-4 residue).

**Not implemented by choice:** a `PermissionRequest` auto-decider and the sandbox; both encode policy only Ian can set.

## 5. Next-session tasks, with files to read

- **Before the first backend push,** read `enforce/README.md` ("The observability rules") so the new ESLint findings are recognized as R-342 to R-344 rather than noise.
- **Watch the first `/model opus` switch** in a session for the R-903 prompt; if it fires on a switch that should be silent, `hooks/model-switch-guard.sh` ranks by substring and the fix is one line.
- **Do not hand-edit the R-316 verb bullets** in `rulebook/reference.md`; regenerate from `enforce/lexicon.json`.
- **When adding an enforcer,** R-516 binds: manifest row plus fixture; `settings-change-guard.sh` refuses a settings save that drops one.
