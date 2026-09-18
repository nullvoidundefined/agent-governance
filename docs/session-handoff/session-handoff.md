# Session Handoff: 2026-09-17 to 09-18, external audit remediation and the port protection boundary

## 1. Last commit

- `d8c43e7` `docs(agents): generated trees are in audit scope by default, and reports declare what they executed (#24)`, on `main`, pushed.
- Eighteen PRs merged across this session; the ten that close external-audit findings are #20, #21, #22, #23, #24, #25, with #8, #10, #11, #13, #14, #16, #19 landing the earlier workstreams. Zero PRs open. No branch is left unmerged.
- The single primary checkout is on `main` at `d8c43e7`; all lane worktrees live under `<repo>/.worktrees/`, and the six sibling `agent-governance-*` folders were removed after their branches merged.

## 2. Production state

- Both suites green on `main`: the enforcement suite and the hook suite, plus `manifest-fixture-closure`, `hook-hashes-closure`, and both translator `--check` runs. Live `~/.claude`, `~/.cursor`, and `~/.codex` are synced from this tree.
- The mirrored permission layer now works in both ports for the first time. Before #25, both adapters sourced `enforce/settingsPermissionRules.sh`, a file that never existed in this repository, with `|| true`, so every `permissions.deny` and `permissions.ask` Bash rule was inert under Codex and Cursor: `rm -rf ~`, `rm -rf /`, `gh repo delete`, `gh release delete`, and `security find-generic-password` all passed with no decision. `claude/enforce/settings-permission-rules.sh` supplies the helper, and both adapters now DENY with a visible message when it or `settings.json` cannot be read.
- Deletions and renames now dispatch events under Codex. The patch replay discarded `*** Delete File:` and `*** Move to:`, so a locked test was protected against editing but not against deletion or replacement by rename (R-410, R-411).
- Fixtures test the submitted checkout rather than the installed copy. Sixty-five fixtures resolved their subject through `$HOME/.claude`, so a local pre-push run verified whichever branch was synced last. `claude/enforce/harness-root.sh` resolves each fixture's root from the tree the fixture itself lives in; `hook-latency.test.sh` stays on the live install deliberately, since measuring the install is its purpose.
- Ten push-time hooks now evaluate the repository a command actually targets: `git -C /other/repo push` was previously judged against the ambient tree's diff and exemptions.

## 3. Session metrics

- 18 PRs merged, ~137 commits across all lanes, 5 subagents dispatched, 3 peer sessions coordinated and frozen.
- Roughly 16% of commits were pure bookkeeping (port regeneration, hash-manifest refreshes, branch reconciliation). Recorded here because the ratio is worth watching, not because it was avoidable on this tree.

## 4. What shipped

- **External audit remediation, all ten findings**, each re-verified on current `main` before any fix: the two adapter defects above (#25); fixture-root binding, git target context, and honest redaction documentation (#20); one shared port-check inventory replacing three that had already drifted, deterministic CI installs, a bounded paid judge with usage logging, and the `Rework commits` metric renamed to `Files revisited` (#21).
- **Prompt contracts** (#22): the engineering role forbade and required the same credential-file reads, now reconciled at an explicit line (match in a content-free mode, never open); `task-start`'s Standard tier said no spec while pointing at a spec-driven loop, now resolved in both skills; a new **Investigation tier** classifies work by what it produces, so audits no longer demand a spec and a plan.
- **Project-local bootstraps** (#23): `.cursor/rules/000-harness-bootstrap.mdc` and a root `AGENTS.md` give Cursor and Codex the entry point only Claude Code had. Building them exposed that `harness-sync.sh` compared only the `claude/` payload while `sync.sh` writes all three, so a stale `~/.cursor` or `~/.codex` could never trigger its own repair.
- **Audit scope defaults** (#24): generated trees are in scope unless an exclusion names their hand-authored files and why skipping those is safe, the roles ask the absence and symmetry questions, and every report carries a Coverage table separating executed from read-only from not-covered.
- **Earlier in the session**: the cursor exporter (#13), crash-safe task-state tracking with session-start resume (#14), the R-105 tracker exemption including its Cursor synthetic-server path (#11), the permissions narrowing (#10), and slice 01 of the python and vue convention tracks (#19).

## 5. Pending, by urgency

- **P1, needs a live Codex session, about 10 minutes.** Two behaviors remain unverified and the coverage figure of 89 of 101 rests on them. Whether `Write|Edit` receives an `apply_patch` edit (it governs secret-scan, protected-path-guard, and every write-time gate), and whether Codex honors a `deny` returned by the adapter rather than running the hook and proceeding. Recipe: `CLAUDE_CODEX_HOOK_DEBUG=1`, one edit and one denied command, then read `~/.claude/.codex-hook-state/debug.log`. The owner's probe on 2026-09-18 already disproved the worst case: Codex delivers `tool_name: "Bash"` for `exec_command`, so the registrations match. Full detail in `docs/audits/2026-09-18-codex-rule-coverage.md` (untracked).
- **P2, data-binding residue, filed in `claude/ISSUES.md`.** Eleven hooks read data from `$HOME/.claude` behind override variables; only a few fixtures pin them, so a fixture can run checkout code against installed data. `verification-gate.test.sh` and `protected-path-guard.test.sh` are pinned and pass against an empty `HOME`; the general fix is for `harness-root.sh` to export the data overrides alongside `CLAUDE_HARNESS_ROOT`.
- **P2, `core.hooksPath` in linked worktrees.** `.git` is a file in a worktree, so the `pre-push` gate never runs there; branches pushed from a lane worktree get no push-time gate. The repair changes shared git configuration, so it was left for a decision.
- **P2, owner actions carried from the earlier audit.** Rotate the GitHub PAT and purge the transcripts recorded in `claude/ISSUES.md`; resolve the GitGuardian incident as a test credential.
- **P3, rename `redact-output.sh`.** The name is a promise a PostToolUse hook cannot keep, and every description that drifted back toward prevention drifted toward the name. `secret-exposure-warning.sh` is the suggestion; the enforcer id must move in lockstep across eight files and both ports, so it is its own commit.
- **P3, parked from the cursor-exporter review**: the two gitignore renderers implement one algorithm twice, codex's closure check still carries the whole-hook gate cursor fixed, and seven `translate/` function names are noun phrases against R-316.

## 6. Next session

- Read first: `docs/audits/2026-09-18-codex-rule-coverage.md` (the per-rule table and its Coverage section), then `claude/ISSUES.md`'s 2026-09-17 and 2026-09-18 entries.
- Run the Codex probe above before trusting any coverage number in conversation or in a report.
- The scoped ports-and-seams audit the owner approved now has its preconditions: the scope defaults are in (#24) and the real-adapter contract suite exists (#25), so an audit can execute rather than read. Run it under the Investigation tier.
- Peer sessions `voyager-2-0-3f` and `agent-governance-reconcile-ed` were frozen on this repository by owner directive and handed their branches over. Nothing is owed back to them; `voyager-2-0-3f` asked to be told when the reintegrated `main` reached origin, which it has, and its slice branch `feat/python-vue-conventions` still needs reconciling with `main` before slice 01 PR 3.
