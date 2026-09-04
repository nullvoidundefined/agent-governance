# Session Handoff: 2026-09-04 Configuration Audit and Remediation

## 1. Last commit

- `c2dd7c5` on `main` (#8). This session's work is on `claude/config-audit-8m7s5k`, pushed, no PR opened (none asked for): the audit report, then one commit per finding.

## 2. Production state

- Not yet live: nothing on this branch has been merged or pulled to the maintainer's `~/.claude`. Both suites green on the branch tip in the remote container (39 enforcement fixtures, 12 hook fixtures) with the checkout symlinked as `~/.claude`; `hook-integrity-check.sh` silent; `npm audit` clean after the ESLint 10 move.
- The container cannot see the real runtime (plugins, `projects/`, plan, CLI version). The `if` hook field needs CLI 2.1.163 or later; on an older CLI the field is ignored and the hooks simply run as before.

## 3. What shipped

**`docs/audits/2026-09-04-config.md`**, the audit against the docs, the changelog 2.1.160 to 2.1.261, the registries, the Actions runtimes, the plugin manifest, and community reports; one consequence of P1-2 was withdrawn the same day (an empty SessionStart matcher already fires on `compact`) and the report says so inline.

**Fixed, one commit each:** SessionEnd `timeout: 60` (P1-1); compaction re-injection moved to `SessionStart` matcher `compact` with a global-only rule list, sentinel pair deleted (P1-2); `Read` deny rules for the R-102 paths (P1-4); allow list collapsed to `Bash`, strict variant restated (P2-2); CI on `checkout@v7`, `setup-node@v7`, ruff 0.16.6, read-only token, Dependabot (P2-3); ESLint 10 plus `eslint-plugin-import-x` (P2-4); `if: "Bash(git *)"` on the eight push-time and advisory hooks (P2-5); latency fixture reads `settings.json` (P2-7); R-001 and INDEX.md describe the injected reads (P2-8); verification gate memoizes the last green tree (P3-2); new `settings-change-guard.sh` on `ConfigChange` with manifest row and fixture (P3-3); three wording fixes (P3-4, P3-5, P3-6); demo marketplace removed (half of P2-9).

**Root-caused on the way:** the eslint fixture "flake" was `lint.mjs` reading the repo root from cwd; fixed with a cwd-independent resolver and two fixture cases.

## 4. Pending

**Maintainer decisions (each is one line in a file):** P1-3 model default (`sonnet`, `opusplan`, or Opus, recorded in whichever artifact loses); P2-1 `permissions.defaultMode`; P2-9 keep or drop `code-review` and `code-simplifier` after `/skill-doctor`; P2-6 store the judge key or prototype the `agent` hook.

**Local checks the container could not run:** `/context` after a `/compact` in a throwaway session (confirms the compact re-injection and whether `~/.claude/CLAUDE.md` itself is re-read); `/doctor` for `skipWorkflowUsageWarning`; `/status` for the start mode and `typescript-lsp`; `claude --version` for the `if` field.

**After merge:** pull to `~/.claude`, `npm ci` in `enforce/` (the lockfile changed), `hooks/install-git-hooks.sh` is unchanged. Delete `~/.claude/.post-compact-pending` if present; nothing writes it now. Watch the first CI run on `main` for the v7 actions and ruff 0.16.6.

**Still open from earlier sessions:** branch protection naming `fixtures`; deleting merged remote branches.

## 5. Next-session tasks, with files to read

- **Confirm the compaction path live** (`hooks/post-compact-rules.sh`, `settings.json` SessionStart groups): `/compact`, then `/context`; if `~/.claude/CLAUDE.md` is re-read on its own, the re-injected list can shrink further.
- **Decide the deny-tier `if` question** (ISSUES.md, P2-5 residue) before touching `git-workflow-guard.sh` and its four siblings.
- **Do not hand-edit the R-316 verb bullets** in `rulebook/reference.md`; they are generated from `enforce/lexicon.json`.
- **When adding an enforcer,** R-516 still binds: manifest entry plus fixture. `settings-change-guard.sh` will now refuse a settings save that drops one.
