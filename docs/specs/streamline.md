# Spec: streamline agent-governance back to a lightweight rules harness

**Owner decisions (2026-10-03):** delete the process machinery (git history keeps it); keep the translator and both the Codex and Cursor ports; keep the stack convention files but trim them hard; delete build-fast; build-by-slice keeps only "one PR per slice, and the owner approves each PR before the next slice starts".

## Problem

The harness was meant to give Claude a short set of global rules and a few safety guards, like the old `claude-global-rules` file. It grew into a compliance system: 63 hook scripts (11,200 lines), 24 enforce scripts (6,000 lines), 190 fixtures (35,000 lines), 5,600 lines of rule prose, 17 skills, and 15 agents. Most of that code enforces a development process and tests itself. Turn-end fixture runs took 5 to 15 minutes, a TDD RED took 21 minutes, and a security review ran seven rounds on one false positive. Product work stalled.

## Goal

The installed harness changes how Claude works only where it prevents damage or states a preference the owner holds. Success means:

- `claude/CLAUDE.md` is a short, plain rules file (target under 60 lines) with no rule IDs, rulebook, or enforcer tags.
- Only damage-prevention hooks are registered, and nothing runs at turn end.
- No hook, test, or manifest exists to protect the harness from its own edits.
- A feature session spends its time on the feature.

## What stays

- **Safety hooks** (with their own fixtures):
  - `secret-scan`
  - `redact-output`
  - `destructive-command-guard`
  - `destructive-db-guard`
  - `mcp-action-guard`
  - `codex-billing-guard`
  - `conflict-markers`
  - `global-repo-push-guard`
  - `agent-dispatch-guard` and `agent-watchdog-instruction`
  - `harness-sync`
  - their helper libraries
- **`git-workflow-guard`**, rewritten small:
  - asks before a push to `main` or `master`
  - asks before every `gh pr merge`
  - denies a merge-commit strategy (squash only)
  - none of the PR-body review or security-artefact checks
- **Skills:**
  - `build-by-slice-require-review` (rewritten: plan slices, one PR each, stop after opening each PR until the owner approves or merges it)
  - `bug-hunt`
  - `documentation-create`
  - `spec-grounding`
  - `structure-conventions` (trimmed with the stack files)
- **Agents:** `pr-reviewer`, for an optional review when asked.
- **Stack convention files:** each trimmed to the conventions that change code, about 50 to 80 lines each, still loaded only by path.
- **Ports:** the translator (`translate/`), `codex/`, `cursor/`, `sync.sh`.
- **The status line** and the quota files from slice 04 PRs 1 and 2.

## What goes

- **Process hooks:**
  - `verification-gate`
  - `protected-path-guard`
  - `content-gate`, `structure-gate`
  - `commit-message-guard`
  - `fix-commit-requires-test`
  - `no-em-dash`
  - `pr-ticket-ref-gate`
  - `constant-change-guard`
  - `migration-defaults-guard`
  - `dependency-add-guard`
  - `linear-todo-label-gate`
  - the push lint gates (eslint, ruff, semgrep)
  - every reminder and coaching hook
  - the session-start and session-end bookkeeping
  - `hook-integrity-check`, `enforcement-guard-check`, `settings-change-guard`
  - `model-switch-guard`, `parallel-session-check`, `audit-signal-check`
- **Enforce machinery:**
  - the TDD lock (`tdd.sh`, `role-policy.json`)
  - the security-review ledger, model pin and surface detector
  - task tiers and build lanes
  - the fixture shard runner
  - the rule manifest and hook-hash manifest
  - the ESLint bundle and `node_modules`
  - harness profiles (`apply-profile.mjs`, `harness-profiles.json`)
- **Rule prose:** `rulebook/`, `PROTOCOL.md`, `docs/harness-audit.md`, rule IDs throughout.
- **Skills:**
  - `build-fast`
  - `task-start`, `task-cleanup`
  - `tdd-gated-dispatch`
  - `ticket-lifecycle`
  - `gof`, `all-hands`
  - `add-stack-track`, `feature-create`, `repo-setup`
  - `cleanup-specs-plans`, `resolve-user-feedback`
- **Agents:**
  - `test-author`, `implementer`, `slice-critic`
  - `security-reviewer`, `spec-conformance-review`
  - the nine audit agents
- **CI:** the enforce fixture workflow shrinks to the remaining hook fixtures plus the port `--check`. `rule-judge` goes, and the security workflow keeps semgrep and CodeQL.

## Acceptance

1. `./sync.sh` installs a tree whose `settings.json` registers only the hooks listed under "What stays".
2. Every remaining hook has a fixture, and `claude/enforce/tests/run-tests.sh` runs them in under a minute.
3. `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` exit 0.
4. `claude/CLAUDE.md` reads as plain guidance and is under 60 lines.
5. `build-fast` no longer exists, and `build-by-slice-require-review` is under 60 lines, with the owner-approval stop as its only gate.

## Follow-ups (not in this change)

- The Docker and `rm` destructive-ops guard (IAN-606, branch `claude/docker-command-guard`) lands as one small PR on the slim tree.
- Quota routing PRs 3 to 5, built plainly.
