# Session Handoff: 2026-09-17 to 09-18, external audit remediation and the port protection boundary

## 1. Last commit

- `d8c43e7` `docs(agents): generated trees are in audit scope by default, and reports declare what they executed (#24)`, on `main`, pushed.
- Twenty-six PRs merged this session (audit findings: #20 to #25; earlier workstreams: #8, #10, #11, #13, #14, #16, #19). Zero open. No branch left unmerged.
- One primary checkout on `main`; every lane worktree and sibling `agent-governance-*` folder was removed after merge.

## 2. Production state

- Both suites green on `main`, plus `manifest-fixture-closure`, `hook-hashes-closure`, and both translator `--check` runs. Live `~/.claude`, `~/.cursor`, `~/.codex` synced from this tree.
- The mirrored permission layer works in both ports for the first time (#25). Both adapters sourced `enforce/settingsPermissionRules.sh`, a file that never existed here, with `|| true`, so every `permissions.deny` and `permissions.ask` Bash rule was inert: `rm -rf ~`, `rm -rf /`, and `gh repo delete` passed with no decision. `claude/enforce/settings-permission-rules.sh` supplies it, and both adapters now DENY visibly when it or `settings.json` is unreadable.
- Deletions and renames now dispatch events under Codex: the patch replay discarded `*** Delete File:` and `*** Move to:`, so a locked test was protected against editing but not deletion or rename (R-410, R-411).
- Fixtures test the submitted checkout, not the installed copy. Sixty-five resolved their subject through `$HOME/.claude`, so a pre-push run verified whichever branch was synced last. `claude/enforce/harness-root.sh` resolves each from the tree it lives in; `hook-latency.test.sh` deliberately stays on the live install.
- Ten push-time hooks now evaluate the repository a command actually targets; `git -C /other/repo push` was judged against the ambient tree before.

## 3. Session metrics

- 26 PRs merged, ~140 commits across all lanes, 6 subagents dispatched, 3 peer sessions coordinated and frozen.
- Roughly 16% of commits were pure bookkeeping (port regeneration, manifest refreshes, reconciliation). Worth watching, not necessarily avoidable.

## 4. What shipped

- **External audit remediation, all ten findings**, each re-verified on `main` first: the two adapter defects (#25); fixture-root binding, git target context, honest redaction docs (#20); one shared port-check inventory replacing three that had drifted, deterministic CI installs, a bounded paid judge, and `Rework commits` renamed to `Files revisited` (#21).
- **Prompt contracts** (#22): the engineering role forbade and required the same credential reads, reconciled at one line (match content-free, never open); Standard tier said no spec while pointing at a spec-driven loop, fixed in both skills; a new **Investigation tier** classifies work by what it produces.
- **Project-local bootstraps** (#23): `.cursor/rules/000-harness-bootstrap.mdc` and a root `AGENTS.md` give Cursor and Codex the entry point only Claude Code had. Building them exposed that `harness-sync.sh` compared only the `claude/` payload while `sync.sh` writes all three, so a stale `~/.cursor` could never trigger its own repair.
- **Audit scope defaults** (#24): generated trees are in scope unless an exclusion names their hand-authored files and why skipping them is safe; the roles ask the absence and symmetry questions; every report carries a Coverage table separating executed from read-only from not-covered.
- **Earlier**: the cursor exporter (#13), crash-safe task-state tracking (#14), the R-105 tracker exemption with its Cursor synthetic-server path (#11), the permissions narrowing (#10), slice 01 of the python and vue tracks (#19).

## 5. Pending, by urgency

- **P1, needs one live Codex session, about 10 minutes.** Two behaviors are unverified and the coverage figure of 89 of 101 rests on both. The owner's 2026-09-18 probe disproved the worst case: Codex 0.154.0 ran `/usr/bin/true` through `exec_command` and delivered `tool_name: "Bash"`, shell guards confirmed running in the debug log, so the matchers copied from Claude Code do match and the "only 9 enforced" hypothesis is dead. Full detail and the per-rule table are in `docs/audits/2026-09-18-codex-rule-coverage.md`, tracked as of this handoff.

  The two probes still owed, both one live Codex session with `CLAUDE_CODEX_HOOK_DEBUG=1` and then `~/.claude/.codex-hook-state/debug.log`:

  1. **Edit dispatch.** Make one small file edit through Codex and confirm the `Write|Edit` registration receives it. This governs `secret-scan`, `protected-path-guard`, and every write-time gate, so it carries more of the harness than the shell path the probe already settled. If it does not fire, the write-time half of the harness is inert under Codex and the coverage figure drops sharply.
  2. **Decision enforcement.** Run a command the mirrored permission rules deny (after #25, `settings-permission-rules.sh` matches them) and confirm Codex refuses it rather than running the hook and proceeding. A guard that runs and is ignored is indistinguishable, in every artifact this repository produces, from a guard that runs and passes. Nothing here can answer this: it is a question about Codex's behavior, not about this code.
- **P2, data-binding residue** (filed in `claude/ISSUES.md`): eleven hooks read data from `$HOME/.claude` behind override variables and few fixtures pin them, so a fixture can run checkout code against installed data. Two are pinned and pass against an empty `HOME`; the general fix is for `harness-root.sh` to export those overrides alongside `CLAUDE_HARNESS_ROOT`.
- **P2, `core.hooksPath` in linked worktrees.** `.git` is a file there, so the `pre-push` gate never runs and a branch pushed from a lane worktree gets no push-time gate. The repair changes shared git config, so it waits on a decision.
- **P2, owner actions from the earlier audit.** Rotate the GitHub PAT, purge the transcripts named in `claude/ISSUES.md`, resolve the GitGuardian incident as a test credential.
- **P3, doppelscript: vitest runs stale compiled tests from `dist/`.** Found while cutting that repository's Actions bill. `packages/constants/dist/__tests__/tier.test.js` was a fossil asserting a four-key tier config the source replaced with nine, and `tsconfig.build.json` excludes tests so the build neither regenerates nor removes it: it failed the pre-push suite while the source test passed 6 of 6, costing three failed pushes before the cause was clear. Deleting the orphan unblocked it; the durable fix is excluding `dist/**` from the vitest config. The same checkout also had `node_modules` stale against the lockfile (`@eslint/compat` missing), which is a plain `pnpm install --frozen-lockfile`.
- **P3, rename `redact-output.sh`.** The name promises what a PostToolUse hook cannot do, and every description that drifted toward prevention drifted toward the name. `secret-exposure-warning.sh` is the suggestion; the enforcer id moves in lockstep across eight files and both ports, so it is its own commit.
- **P3, parked from the cursor-exporter review**: the two gitignore renderers implement one algorithm twice, codex's closure check still carries the whole-hook gate cursor fixed, seven `translate/` names are noun phrases against R-316.

## 6. Next session

- Read first: `docs/audits/2026-09-18-codex-rule-coverage.md` (per-rule table, Coverage section), then `claude/ISSUES.md`'s 2026-09-17 and 2026-09-18 entries.
- Run the two Codex probes above before trusting any coverage number anywhere.
- The scoped ports-and-seams audit the owner approved now has its preconditions: scope defaults (#24) and the real-adapter contract suite (#25), so it can execute rather than read. Run it under the Investigation tier.
- Peer sessions `voyager-2-0-3f` and `agent-governance-reconcile-ed` were frozen here by owner directive and handed their branches over; nothing is owed back. The slice branch `feat/python-vue-conventions` still needs reconciling with `main` before slice 01 PR 3. A Voyager session has one authorized exception to that freeze: landing rule R-334 (compound naming) on its own branch and PR.
