# Codex rule coverage: which governance rules are actually enforced under Codex CLI

Audit date: 2026-09-18. Repository state audited: `main` at `5ff4e6e`, working tree as checked out, with no changes made to any tracked file. This is an investigation, and the deliverable is this report; nothing in the repository was fixed, and every defect found below is recorded rather than repaired.

The question this answers is narrow and practical. The owner of this repository works in Codex CLI regularly, and the governance harness was authored for Claude Code. For each of the 101 enforcement entries in `claude/enforce/manifest.json`, this report determines whether a Codex event actually fires the enforcer, whether the enforcer fires but cannot do its job, or whether the rule survives only as something the operator has to remember.

## Live probe result (owner-run, 2026-09-18, Codex 0.154.0)

The largest unknown in this report, whether a `PreToolUse` matcher copied verbatim from
Claude Code matches anything under Codex, is now settled for the shell path and the
answer is favorable: Codex normalizes the tool name before dispatching to hooks. Running
with `CLAUDE_CODEX_HOOK_DEBUG=1`, Codex executed `/usr/bin/true` through `exec_command`
and delivered `tool_name: "Bash"` to the hooks, and the debug log at
`~/.claude/.codex-hook-state/debug.log:14` confirms the registered shell guards ran.

The hypothesis that only 9 entries are enforced is therefore unsupported, and the
registrations are correct rather than a verbatim copy that silently matches nothing. The
headline figure of 89 stands for the shell path.

Two parts of that figure remain unverified, and neither was exercised by this probe:

- **Edit dispatch.** Whether the `Write|Edit` matcher receives an `apply_patch` edit is
  untested. It governs secret-scan, protected-path-guard, and every write-time gate, so
  it carries more of the harness than the shell path does. Settling it costs one more
  session with the same debug flag and a single file edit.
- **Decision enforcement.** Whether Codex honors a deny returned by the adapter, rather
  than merely running the hook and continuing, is untested. A guard that runs and is
  ignored is indistinguishable from one that runs and passes, in every artifact this
  repository produces.

Both belong in the next Codex session rather than in a synthetic harness, since what is
in question is the tool's behavior and not this repository's code.

## Coverage: what was examined and how

A report that stays silent about what it did not check reads exactly like a report that checked everything, so this table comes first.

| Surface | How checked | Reason when not executed |
|---|---|---|
| `claude/enforce/manifest.json`, all 101 entries | read only, parsed programmatically | A data file. The declared tier counts were verified against the ground truth given: advisory 26, ast 35, regex 36, llm-judge 4. |
| `claude/settings.json`, hooks block | read only, parsed programmatically | Configuration. The 53 registrations and their per-event split were recomputed and match the ground truth exactly. |
| `claude/settings.json`, `permissions` block | executed | The 33 deny entries were extracted, and the 14 that express a shell command were driven through the adapter one at a time. |
| `translate/codex-port-map.json` | read only | The artifact whose accuracy is in question, so it was used as an input to be tested rather than as a source of truth. |
| `translate/render-codex-hooks.mjs` and `render-codex-rules.mjs` | read only | Generator source. Read to establish how matchers and enforcer tags are carried across, which turned out to matter a great deal. |
| `codex/hooks.json`, all 49 registrations | read only | Generated configuration, compared line by line against `settings.json`. |
| `codex/hooks/codex-hook-adapter.sh` | executed | Driven from a `mktemp` sandbox with a sandbox `HOME` and roughly forty synthetic payloads across every event it dispatches. |
| `apply_patch` replay: `Add File`, `Update File`, `Delete File`, `Move to` | executed | All four operations were replayed through the adapter against real guard scripts. |
| `claude/hooks/*.sh`, 48 scripts | executed selectively, through the adapter | Every hook group named in `codex/hooks.json` was invoked at least once. Individual guards were exercised on their trigger path where a safe synthetic payload existed, and on their plumbing path otherwise. The per-rule table says which. |
| `push-eslint-gate` | executed end to end | A throwaway repository with a real remote and a real outgoing TypeScript diff was created in the sandbox, and the gate denied the push on a genuine ESLint finding. |
| `push-ruff-gate`, `push-rubocop-gate`, `push-golangci-gate` | read only | `ruff`, `rubocop` and `golangci-lint` are not installed on this machine, and installing them would have written outside the sandbox. Their availability handling was read instead. |
| `llm-rule-judge` | executed with the API key deliberately unset | The paid path was never invoked, by instruction. The unset-key path is the one that matters for a Codex user anyway, and it was exercised against a real outgoing diff. |
| `verification-gate` on `Stop` and `SubagentStop` | executed | A sandbox repository with a deliberately red `.claude/verify.sh` was used to confirm the gate actually blocks. |
| `SessionStart` hook group | executed, with `harness-sync` excluded | `harness-sync` rsyncs a checkout over a home directory. It was left out to keep the run hermetic, and read instead. |
| `harness-sync` | read only | See above. It does pass `SYNC_CODEX_HOME`, so it refreshes the `~/.codex` tree and not only `~/.claude`. |
| OpenAI Codex CLI binary, tool-name and hook-event vocabulary | executed, `strings` and `grep` over the installed binary | Version installed at `~/.nvm/.../@openai/codex`. Used to establish which tool names Codex actually puts in `tool_name`. |
| The deployed `~/.codex/hooks.json` | read only | Read to confirm the deployed matchers match the repository's. They do. No file under `~/.codex` or `~/.claude` was written. |
| A live Codex session confirming matcher semantics | **not covered** | This is the one determination that could not be made safely. Settling it requires running a real Codex session, which spends the owner's Codex quota and requires network access. The adapter's own debug log (`~/.claude/.codex-hook-state/debug.log`) would have settled it from history, but it does not exist: debug mode was never enabled. |
| `.worktrees/*`, where the pending adapter fixes live | **not covered** | Instructed not to touch them because other agents are working there. Everything said below about the pending fixes is inferred from the defects on `main`, not from reading the fix branches. |
| `claude/rulebook/*.md`, the Tier 2 rules | read only | Read to recover the rule text for R-7xx, R-8xx and R-9xx, which do not appear in `CLAUDE.md`. |
| `claude/enforce/tests/` and `claude/hooks/tests/` | read only | Checked for an adapter contract test. There is none on `main`, which is why neither known defect was caught by CI. |

## Headline

**Of the 101 manifest entries, 89 are mechanically enforced under Codex today, 8 are degraded, and 4 are manual.** No entry is genuinely inapplicable, so the N/A bucket is empty.

That headline needs three qualifications immediately, because on its own it flatters the port.

First, the 101 manifest entries cover only **70 distinct rule identifiers**. Several rules carry three or more entries because they are enforced by several linters across stacks: R-344 alone has eight. A count of entries therefore overstates the breadth of what is covered, and any comparison against a count of rules is comparing different things.

Second, the 89 enforced entries are not enforced with equal force or at equal times. Thirty-five of them are AST-tier entries that run only inside a `push-*-gate` when the model tries to `git push`, which means they are **completely unenforced during the session**: a Codex user can write a hundred violations, and nothing says a word until a push is attempted. Twenty-three more are advisory entries that only inject a reminder into the model's context and block nothing at all. That leaves **31 entries that actually block a bad tool call at the moment it is made**, all of them regex-tier hooks.

Third, and most seriously, the whole 89 rests on an assumption about Codex matcher semantics that I was unable to verify and that the evidence actively undermines. That is the next section, and it is the most important finding in this report.

## RESOLVED by the owner's live probe: the matchers do match (see the Live probe result section above; the analysis below is kept as the reasoning that prompted the probe)

## The finding that prompted the probe: the matchers may not match

`codex/hooks.json` registers its `PreToolUse` and `PostToolUse` hook groups under the matchers `Bash`, `Write\|Edit`, `Write`, and `mcp__.*`. Those are Claude Code tool names. `translate/render-codex-hooks.mjs` copies the matcher across verbatim (`if (group.matcher) entry.matcher = group.matcher;`) and performs no translation whatsoever, whereas `translate/cursor-port-map.json` carries an explicit per-matcher translation table for the Cursor port. The asymmetry is conspicuous.

The problem is that Codex does not name its tools `Bash`, `Write` or `Edit`. The adapter itself knows this: its dispatch branches on `[ "$TOOL" = "apply_patch" ]` to trigger the patch replay, which is only meaningful if Codex reports `apply_patch` in `tool_name`. Examining the installed Codex binary supports the same conclusion. The literal string `apply_patch` appears throughout it, including as a quoted JSON value; `shell` and `exec_command` appear as the shell tool's names; the standard MCP naming `mcp__server__tool` is documented in its own prompt text. The string `Bash` occurs three times in the entire binary, and each occurrence is unrelated to tool dispatch: one is a tree-sitter grammar loading error, one is skill frontmatter documentation, and one is an unrelated concatenated enum blob. `Edit`, `MultiEdit` and the literal `Write\|Edit` do not occur as tool names at all.

If Codex matches a hook's `matcher` against its own `tool_name`, which is the documented behavior of the schema this port claims to share, then:

- the `PreToolUse` `Bash` group, carrying twenty hooks, never fires, because Codex's shell tool is not called `Bash`;
- the `PreToolUse` `Write\|Edit` group, carrying the eight edit gates, never fires, because Codex's edit tool is called `apply_patch`;
- the `PostToolUse` `Bash`, `Write` and `Write\|Edit` groups, carrying eight reminders and the output redactor, never fire either;
- only the `mcp__.*` group and the four un-matchered groups (`SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`) survive.

Under that reading, **9 of the 101 entries are enforced, not 89**: `R-003`, `R-102` (redaction-guard-check only), `R-107`, `R-203`, `R-501` and `R-516` on `SessionStart`; `R-509` on `Stop` and `SubagentStop`; `R-105` and `R-101` (destructive-db-guard only) on `mcp__.*`. Everything else, including every edit gate, every commit and push guard, and every linter gate, would be silently inert.

I could not settle this. Doing so requires one real Codex session, which costs the owner's quota and needs network access, and the adapter's debug log does not exist on this machine because debug mode was never turned on. **Treat this as an open, high-consequence unknown, not as a finding.** It is cheap for the owner to close: export `CLAUDE_CODEX_HOOK_DEBUG=1`, run one Codex session that edits a file and runs a shell command, and look at whether `~/.claude/.codex-hook-state/debug.log` was created and what `tool_name` values it recorded. If the file stays empty, the port is far more broken than `PORT-STATUS.md` suggests, and the per-rule table below should be read with its ENFORCED column collapsed to those nine rows.

Everything that follows assumes the matchers do fire, which is the assumption the repository itself is built on. That assumption is what makes the headline 89.

## The two confirmed adapter defects, reproduced on current main

Both defects described in the audit brief were reproduced by execution against `main`.

**The permission mirror is inert.** The adapter sources `"$CLAUDE_HOME/enforce/settingsPermissionRules.sh"` at line 43 and guards every use of the resulting function with `type matching_bash_rule >/dev/null 2>&1` at line 247. That file does not exist anywhere in the repository on `main`, which I verified by searching the whole tree. The `type` guard therefore fails, the mirror block is skipped silently, and the entire `permissions.deny` and `permissions.ask` layer of `settings.json` has no effect under Codex. Driving fourteen shell commands drawn from the deny list through the adapter, **five passed with no decision at all**: `rm -rf /`, `rm -rf ~`, `gh repo delete <repo>`, `gh release delete <tag>`, and `security find-generic-password`. The other nine were denied, but by `destructive-command-guard`, not by the mirror, and I confirmed that by running that guard alone against the same commands. `rm -rf ~` and `rm -rf /` are allowed under Codex right now.

This matters more than any single row in the per-rule table, because the deny list protects things that carry no rule number. Nothing in the 101 entries says "do not delete the user's home directory". That protection lived entirely in `settings.json`, and under Codex it is gone. A rule-count headline structurally cannot capture that loss.

A second-order point on the same defect: even once the helper file is restored, the mirror block only runs when the adapter sees `[ "$TOOL" = "Bash" ]`. If Codex reports `shell` rather than `Bash`, as the binary evidence suggests, the mirror stays dead after the file is restored. Whoever lands the fix should check that the tool-name test was corrected along with the missing file.

**The patch replay drops deletions and rename destinations.** The `patch_lines` awk program at lines 141 to 153 discards `*** Delete File:` outright and skips `*** Move to:` without recording the destination. Executed against real guards, this reproduces cleanly:

- an `apply_patch` that updates a protected gate input is denied by `protected-path-guard`, as it should be;
- an `apply_patch` that **deletes** that same protected gate input produces no decision at all;
- an `apply_patch` that **renames** an innocuous file onto that protected path produces no decision at all;
- an `apply_patch` that deletes a test file produces no decision at all.

So under Codex, R-410, R-411, R-412 and R-705 protect a locked test against modification but not against deletion or replacement by rename. Deleting a locked test through the shell is still caught, because `protected-path-guard` is also registered on shell calls, so the gap is specific to the patch tool. That is also the tool a Codex agent reaches for by default when changing files.

**Neither defect had a test.** `claude/enforce/tests/` contains seventy-odd fixture tests and not one of them executes `codex-hook-adapter.sh`. The adapter is hand-authored, listed in the port map's `hand_authored` array, and entirely unexercised by CI on `main`. That is the reason both defects survived to be found by an external audit rather than by the harness.

## Other gaps the registration count does not capture

**The `Read(...)` deny layer has no Codex port at all.** `settings.json` denies reading `.env`, `.env.production`, `~/.aws/**` and `~/.ssh/**` through the `Read` tool. Codex reads files through the shell, which has no read event, so those paths are simply open. I confirmed that `cat ~/.ssh/id_rsa`, `cat .env.production` and `cat ~/.aws/credentials` all pass the full shell hook group with no decision. The port map documents this honestly in its appendix, and the mitigation it claims, that `secret-scan` still blocks mutation of those paths, is true but is a different guarantee from keeping them off-path. R-102's off-path property does not hold under Codex. In fairness this is partly a shared gap, since a `cat` through Bash is not covered by a `Read(...)` rule under Claude Code either, but under Codex the shell is the only way to read anything, so the gap is total rather than incidental.

**The LLM judge is inert for a typical Codex user.** `llm-rule-judge` is registered on shell calls and triggers on `git push`, so it ports in the registration sense. Its preconditions are the problem. It requires `ANTHROPIC_API_KEY`, from the environment or a supported secret store, and it is documented to fail open when the key is unset. I ran it against a real outgoing diff with the key unset and it produced nothing at all. A Codex user working on a ChatGPT subscription is unlikely to have an Anthropic key present, and R-908 exists precisely because billing boundaries between the two vendors are a live concern in this repository. R-315 has no enforcer other than the judge, so R-315 is effectively unenforced under Codex. R-316, R-317 and R-325 each retain an ESLint entry, so they keep their AST coverage at push time and lose only the semantic half.

**Three of the four linter gates skip silently when their linter is absent.** `push-ruff-gate` falls through to a stderr notice and exits when neither `ruff` nor `uvx` is on `PATH`, and `push-rubocop-gate` and `push-golangci-gate` follow the same shape. This is identical under Claude Code, so it is not a Codex-specific loss, but it means the Python, Ruby and Go AST entries in the per-rule table are enforced only on a machine where those tools are installed. I did not execute those three gates, because installing their linters would have written outside the sandbox.

**The ask decision becomes a denial.** Codex hooks cannot pause for confirmation, so the adapter converts an `ask` into a `deny` by default, controlled by `CLAUDE_CODEX_ASK_POLICY`. I confirmed this on `mcp-action-guard`: a destructive MCP call is denied, and the denial text carries the translation preamble explaining that Claude Code would have asked. This makes Codex stricter rather than weaker, and the affected rules are counted as enforced, but the operator experience differs: the action does not happen at all, and a human has to run it.

**The Tier 2 rulebook never gets the "manual in Codex" treatment.** `render-codex-rules.mjs` rewrites `[hook:X]` enforcer tags into `hook:X in Claude Code; manual in Codex` for unported hooks, but it only runs over `claude/CLAUDE.md` and `claude/rules/session-types.md`. `claude/rulebook/` is not ported into `codex/` at all, and its tags are never rewritten. The practical consequence is R-903: it carries `[hook:model-switch-guard]` in `rulebook/cost.md`, that hook has no Codex event, and nothing anywhere tells a Codex reader so. `codex/AGENTS.md` carries exactly two rule-level "manual in Codex" tags, on R-504 and R-601, plus one explanatory sentence in the preamble. Those two tags are correct as far as they go, and they are the only two the generator can produce, because they are the only unported hooks whose rules live in `CLAUDE.md`.

## Per-rule coverage

One row per manifest entry, 101 rows, sorted by rule then by enforcer. A rule with several enforcers appears several times, which is how the manifest itself is structured. The bucket reflects that specific enforcer under Codex, not the rule as a whole, so a rule can be enforced through one entry and degraded through another. Every row that is not ENFORCED names what the operator has to do instead.

| Rule | Tier | Declared enforcer | Codex event that carries it | Bucket | What was found, and what a Codex user must do by hand |
|---|---|---|---|---|---|
| R-003 | advisory | `hook:harness-sync` | SessionStart `no matcher` | **ENFORCED** | SessionStart; syncs the ~/.codex tree as well as ~/.claude (SYNC_CODEX_HOME). Read only, not executed in the sandbox. |
| R-101 | regex | `hook:destructive-command-guard` | PreToolUse `Bash` | **ENFORCED** | Executed. Covers hooksPath edits, hook-directory removal and `gh api` DELETE. Does not cover `rm -rf /`, `rm -rf ~`, `gh repo delete`, `gh release delete` or `security find-generic-password`: those were covered only by settings.json permissions.deny, which is inert under Codex. |
| R-101 | regex | `hook:destructive-db-guard` | PreToolUse `Bash`; PreToolUse `mcp__.*` | **ENFORCED** | Registered on shell and on mcp__.*; the MCP half was executed. |
| R-102 | regex | `hook:destructive-command-guard` | PreToolUse `Bash` | **ENFORCED** | Executed. Covers hooksPath edits, hook-directory removal and `gh api` DELETE. Does not cover `rm -rf /`, `rm -rf ~`, `gh repo delete`, `gh release delete` or `security find-generic-password`: those were covered only by settings.json permissions.deny, which is inert under Codex. |
| R-102 | regex | `hook:redact-output` | PostToolUse `Bash` | **ENFORCED** | PostToolUse on shell output; executed, flagged a planted token. |
| R-102 | advisory | `hook:redaction-guard-check` | SessionStart `no matcher` | **ENFORCED** | SessionStart advisory; executed as part of the SessionStart group. |
| R-102 | regex | `hook:secret-scan` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **ENFORCED** | Fires on shell commands and on replayed apply_patch adds and updates. The settings.json `Read(...)` deny layer that keeps .env, ~/.ssh and ~/.aws off-path has no Codex port, so reading those files is unguarded. |
| R-103 | regex | `hook:secret-scan` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **ENFORCED** | Fires on shell commands and on replayed apply_patch adds and updates. The settings.json `Read(...)` deny layer that keeps .env, ~/.ssh and ~/.aws off-path has no Codex port, so reading those files is unguarded. |
| R-105 | regex | `hook:mcp-action-guard` | PreToolUse `mcp__.*` | **ENFORCED** | Executed; denies, carrying the ask-to-deny translation preamble, because Codex hooks cannot pause for confirmation. |
| R-106 | regex | `hook:global-repo-push-guard` | PreToolUse `Bash` | **ENFORCED** | Plumbing executed on a git push payload; the repo-specific branch was not exercised. |
| R-107 | regex | `hook:destructive-command-guard` | PreToolUse `Bash` | **ENFORCED** | Executed. Covers hooksPath edits, hook-directory removal and `gh api` DELETE. Does not cover `rm -rf /`, `rm -rf ~`, `gh repo delete`, `gh release delete` or `security find-generic-password`: those were covered only by settings.json permissions.deny, which is inert under Codex. |
| R-107 | advisory | `hook:hookspath-drift-check` | SessionStart `no matcher` | **ENFORCED** | SessionStart advisory; executed. |
| R-108 | regex | `hook:secret-scan` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **ENFORCED** | Fires on shell commands and on replayed apply_patch adds and updates. The settings.json `Read(...)` deny layer that keeps .env, ~/.ssh and ~/.aws off-path has no Codex port, so reading those files is unguarded. |
| R-203 | regex | `hook:destructive-command-guard` | PreToolUse `Bash` | **ENFORCED** | Executed. Covers hooksPath edits, hook-directory removal and `gh api` DELETE. Does not cover `rm -rf /`, `rm -rf ~`, `gh repo delete`, `gh release delete` or `security find-generic-password`: those were covered only by settings.json permissions.deny, which is inert under Codex. |
| R-203 | advisory | `hook:hook-integrity-check` | SessionStart `no matcher` | **ENFORCED** | SessionStart advisory; executed. |
| R-207 | regex | `hook:no-em-dash` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **ENFORCED** | Executed on both a shell payload and a replayed apply_patch add; denied both. |
| R-302 | regex | `hook:content-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Reaches replayed adds and updates. Blind to apply_patch deletions and rename destinations, same as every edit gate. |
| R-303 | ast | `eslint:no-cycle` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-303 | ast | `eslint:no-restricted-paths` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-304 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-305 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-306 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-309 | advisory | `hook:single-file-folder-reminder` | PreToolUse `Bash` | **ENFORCED** | Advisory on shell calls. |
| R-310 | advisory | `hook:flat-directory-reminder` | PostToolUse `Write` | **ENFORCED** | PostToolUse advisory; the Write group was executed and a reminder fired. |
| R-311 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-312 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-313 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-314 | regex | `hook:structure-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Executed; denied a replayed add under src/utils/. |
| R-315 | llm-judge | `hook:llm-rule-judge` | PreToolUse `Bash` | **DEGRADED** | DEGRADED. Executed with no ANTHROPIC_API_KEY against a real outgoing diff: the judge exits silently and fails open. It runs at `git push` only, and needs an Anthropic key that a Codex user on a ChatGPT subscription will usually not have. **By hand:** Read the outgoing diff yourself for the semantic naming rules; without ANTHROPIC_API_KEY the judge exits silently and never runs. |
| R-316 | ast | `eslint:naming-lexicon` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-316 | llm-judge | `hook:llm-rule-judge` | PreToolUse `Bash` | **DEGRADED** | DEGRADED. Executed with no ANTHROPIC_API_KEY against a real outgoing diff: the judge exits silently and fails open. It runs at `git push` only, and needs an Anthropic key that a Codex user on a ChatGPT subscription will usually not have. **By hand:** Read the outgoing diff yourself for the semantic naming rules; without ANTHROPIC_API_KEY the judge exits silently and never runs. |
| R-317 | ast | `eslint:naming-lexicon` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-317 | llm-judge | `hook:llm-rule-judge` | PreToolUse `Bash` | **DEGRADED** | DEGRADED. Executed with no ANTHROPIC_API_KEY against a real outgoing diff: the judge exits silently and fails open. It runs at `git push` only, and needs an Anthropic key that a Codex user on a ChatGPT subscription will usually not have. **By hand:** Read the outgoing diff yourself for the semantic naming rules; without ANTHROPIC_API_KEY the judge exits silently and never runs. |
| R-319 | ast | `eslint:one-export-per-file` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-320 | ast | `eslint:file-header-comment` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-320 | advisory | `hook:new-file-header-reminder` | PostToolUse `Write` | **ENFORCED** | PostToolUse advisory; executed, reminder fired. |
| R-321 | ast | `eslint:member-ordering` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-322 | advisory | `hook:clean-code-reminder` | PostToolUse `Write\|Edit` | **ENFORCED** | PostToolUse advisory; executed as part of the Write and Edit group. |
| R-323 | ast | `eslint:sort-keys` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-324 | ast | `eslint:no-magic-numbers` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-324 | ast | `golangci:mnd` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when golangci-lint is absent. Not executed. |
| R-324 | ast | `ruff:PLR2004` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-325 | ast | `eslint:destructure-object-reads` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-325 | llm-judge | `hook:llm-rule-judge` | PreToolUse `Bash` | **DEGRADED** | DEGRADED. Executed with no ANTHROPIC_API_KEY against a real outgoing diff: the judge exits silently and fails open. It runs at `git push` only, and needs an Anthropic key that a Codex user on a ChatGPT subscription will usually not have. **By hand:** Read the outgoing diff yourself for the semantic naming rules; without ANTHROPIC_API_KEY the judge exits silently and never runs. |
| R-326 | ast | `eslint:no-restricted-syntax` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-326 | ast | `ruff:E731` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-327 | ast | `eslint:no-nested-ternary` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-327 | ast | `rubocop:Style/NestedTernaryOperator` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when rubocop is absent. Not executed. |
| R-328 | regex | `hook:migration-defaults-guard` | PreToolUse `Write\|Edit` | **ENFORCED** | Reaches replayed adds and updates; the migration-specific branch was not exercised. |
| R-329 | ast | `eslint:ban-ts-comment` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-329 | ast | `eslint:no-explicit-any` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-329 | ast | `golangci:nolintlint` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when golangci-lint is absent. Not executed. |
| R-329 | ast | `ruff:ANN401` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-329 | ast | `ruff:PGH003` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-330 | advisory | `hook:spec-glossary-check` | PostToolUse `Write` | **ENFORCED** | PostToolUse advisory; executed as part of the Write group. |
| R-331 | regex | `hook:dependency-add-guard` | PreToolUse `Write\|Edit` | **ENFORCED** | Plumbing reaches the hook. My synthetic package.json payload did not trigger it under Claude Code semantics either, so the guard logic itself is unverified here, not the port. |
| R-341 | advisory | `hook:observability-reminder` | PostToolUse `Write\|Edit` | **ENFORCED** | PostToolUse advisory; executed as part of the Write and Edit group. |
| R-342 | ast | `eslint:no-console` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-342 | ast | `eslint:structured-log-call` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-342 | ast | `ruff:T201` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-343 | ast | `eslint:analytics-event-name` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-344 | ast | `eslint:no-empty` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-344 | ast | `eslint:no-swallowed-catch` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-344 | ast | `golangci:errcheck` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when golangci-lint is absent. Not executed. |
| R-344 | ast | `golangci:errorlint` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when golangci-lint is absent. Not executed. |
| R-344 | ast | `rubocop:Lint/SuppressedException` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when rubocop is absent. Not executed. |
| R-344 | ast | `ruff:BLE001` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-344 | ast | `ruff:E722` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-344 | ast | `ruff:S110` | PreToolUse `Bash` | **ENFORCED** | Push time only, and skips silently when neither ruff nor uvx is on PATH. Not executed. |
| R-345 | advisory | `hook:observability-reminder` | PostToolUse `Write\|Edit` | **ENFORCED** | PostToolUse advisory; executed as part of the Write and Edit group. |
| R-346 | advisory | `hook:observability-reminder` | PostToolUse `Write\|Edit` | **ENFORCED** | PostToolUse advisory; executed as part of the Write and Edit group. |
| R-351 | advisory | `hook:dockerfile-reminder` | PostToolUse `Write\|Edit` | **ENFORCED** | PostToolUse advisory; executed as part of the Write and Edit group. |
| R-401 | ast | `eslint:behavior-assertion-required` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-401 | ast | `eslint:no-self-mock` | PreToolUse `Bash` | **ENFORCED** | Executed end to end: a real outgoing diff was linted and the push denied. Enforced at `git push` only, never during the session. |
| R-401 | regex | `hook:content-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Reaches replayed adds and updates. Blind to apply_patch deletions and rename destinations, same as every edit gate. |
| R-403 | regex | `hook:fix-commit-requires-test` | PreToolUse `Bash` | **ENFORCED** | Registered on shell commit calls; plumbing only, the commit-specific branch was not exercised. |
| R-405 | regex | `hook:content-gate` | PreToolUse `Write\|Edit` | **ENFORCED** | Reaches replayed adds and updates. Blind to apply_patch deletions and rename destinations, same as every edit gate. |
| R-410 | regex | `hook:protected-path-guard` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **DEGRADED** | DEGRADED. Executed: it denies a replayed update to a gate input, but an apply_patch `*** Delete File:` of that same path and an apply_patch `*** Move to:` onto it both pass with no decision, because the adapter's patch parser drops deletions and discards move destinations. **By hand:** Never delete or rename a locked test, fixture, spec, or gate input through apply_patch; the guard cannot see either operation. Delete through the shell instead, where the guard does fire. |
| R-411 | regex | `hook:protected-path-guard` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **DEGRADED** | DEGRADED. Executed: it denies a replayed update to a gate input, but an apply_patch `*** Delete File:` of that same path and an apply_patch `*** Move to:` onto it both pass with no decision, because the adapter's patch parser drops deletions and discards move destinations. **By hand:** Never delete or rename a locked test, fixture, spec, or gate input through apply_patch; the guard cannot see either operation. Delete through the shell instead, where the guard does fire. |
| R-412 | regex | `hook:protected-path-guard` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **DEGRADED** | DEGRADED. Executed: it denies a replayed update to a gate input, but an apply_patch `*** Delete File:` of that same path and an apply_patch `*** Move to:` onto it both pass with no decision, because the adapter's patch parser drops deletions and discards move destinations. **By hand:** Never delete or rename a locked test, fixture, spec, or gate input through apply_patch; the guard cannot see either operation. Delete through the shell instead, where the guard does fire. |
| R-501 | advisory | `hook:parallel-session-check` | SessionStart `no matcher` | **ENFORCED** | SessionStart advisory; executed. |
| R-504 | advisory | `hook:task-commit-reminder` | PostToolUse `TaskUpdate` | **MANUAL** | No Codex event. Codex has no task tool, so the event never exists. **By hand:** Commit by hand after each discrete task; nothing prompts you. |
| R-505 | regex | `hook:commit-message-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell commit calls; plumbing only. |
| R-506 | advisory | `hook:commit-message-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell commit calls; plumbing only. |
| R-507 | regex | `hook:conflict-markers` | PreToolUse `Bash` | **ENFORCED** | Registered on shell commit calls; plumbing only. |
| R-508 | advisory | `hook:git-workflow-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-509 | regex | `hook:verification-gate` | Stop `no matcher`; SubagentStop `no matcher` | **ENFORCED** | Executed on Stop and SubagentStop; blocked a dirty tree with a red .claude/verify.sh. |
| R-511 | advisory | `hook:git-workflow-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-512 | regex | `hook:git-workflow-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-513 | advisory | `hook:constant-change-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell push calls; plumbing only. |
| R-514 | regex | `hook:git-workflow-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-516 | advisory | `hook:enforcement-guard-check` | SessionStart `no matcher` | **ENFORCED** | SessionStart advisory; executed. |
| R-516 | regex | `hook:settings-change-guard` | ConfigChange `user_settings` | **MANUAL** | No Codex event. ConfigChange is a Claude Code runtime event and guards Claude's live settings.json, which Codex never loads. **By hand:** Review any settings.json or enforcement-config edit by hand against R-516 before committing. |
| R-601 | advisory | `hook:task-state-tracker` | PostToolUse `TaskCreate\|TaskUpdate` | **MANUAL** | No Codex event. Codex has no task tool, so the event never exists. **By hand:** Track task state by hand; no crash-safe state file is written, so a crashed Codex session loses it. |
| R-602 | advisory | `hook:handoff-check` | PostToolUse `Write` | **ENFORCED** | PostToolUse advisory; executed as part of the Write group. |
| R-705 | regex | `hook:protected-path-guard` | PreToolUse `Bash`; PreToolUse `Write\|Edit` | **DEGRADED** | DEGRADED. Executed: it denies a replayed update to a gate input, but an apply_patch `*** Delete File:` of that same path and an apply_patch `*** Move to:` onto it both pass with no decision, because the adapter's patch parser drops deletions and discards move destinations. **By hand:** Never delete or rename a locked test, fixture, spec, or gate input through apply_patch; the guard cannot see either operation. Delete through the shell instead, where the guard does fire. |
| R-801 | advisory | `hook:audit-signal-check` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-903 | advisory | `hook:model-switch-guard` | PreModelSwitch `no matcher` | **MANUAL** | No Codex event. PreModelSwitch is a Claude Code event; Codex switches models through config.toml and /model. **By hand:** Choose the model deliberately per R-903; no warning fires on a switch. |
| R-904 | advisory | `hook:audit-signal-check` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |
| R-907 | regex | `hook:codex-test-author-guard` | PreToolUse `Write\|Edit` | **ENFORCED** | Reaches replayed adds and updates; the role-specific branch was not exercised. |
| R-908 | advisory | `hook:codex-billing-guard` | PreToolUse `Bash` | **ENFORCED** | Registered on shell calls; plumbing only. |

### Bucket counts

| Bucket | Entries | Share of 101 |
|---|---|---|
| ENFORCED | 89 | 88 percent |
| DEGRADED | 8 | 8 percent |
| MANUAL | 4 | 4 percent |
| N/A | 0 | 0 percent |

Split by tier, because the tiers differ enormously in what enforcement means:

| Tier | Entries | ENFORCED | DEGRADED | MANUAL | When it actually fires under Codex |
|---|---|---|---|---|---|
| regex | 36 | 31 | 4 | 1 | At the tool call. These are the only entries that stop a bad action as it happens. |
| ast | 35 | 35 | 0 | 0 | At `git push` only, inside a `push-*-gate`. Nothing fires during the session. |
| advisory | 26 | 23 | 0 | 3 | Injects context; blocks nothing. |
| llm-judge | 4 | 0 | 4 | 0 | At `git push`, and only when an Anthropic API key is present. |

The N/A bucket is empty on purpose. Each of the four MANUAL entries loses its enforcer under Codex, but none of the four rules stops applying: a Codex user still has to commit after each task (R-504), still has to track task state (R-601), still has to register mechanizable rules in the manifest (R-516), and still has to route work to the cheapest capable model (R-903). Calling any of them inapplicable would misreport an enforcement gap as a scope boundary.

## What the pending adapter fixes would change

Both fixes are on another branch and were not read, by instruction, so this section describes what the defects on `main` imply rather than what the fix branches contain.

**The permission helper fix** restores the `settings.json` deny and ask mirror on shell calls. It moves no row in the per-rule table, because no manifest entry names the permission layer as its enforcer. What it restores is the protection sitting outside the rule-numbered set: `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `gh repo delete`, `gh release delete` and `security find-generic-password` go from allowed to denied. It also strengthens R-101, R-102, R-106 and R-203 in practice without changing their bucket, since those rules already hold an enforced hook entry. The caveat stated above applies: if the fix restores the helper file without also correcting the adapter's `[ "$TOOL" = "Bash" ]` test to Codex's actual shell tool name, the mirror will still never run.

**The patch replay fix** replays `*** Delete File:` and `*** Move to:` as the shell operations the guards already understand. That moves four entries from DEGRADED to ENFORCED:

| Rule | Enforcer | From | To |
|---|---|---|---|
| R-410 | `hook:protected-path-guard` | DEGRADED | ENFORCED |
| R-411 | `hook:protected-path-guard` | DEGRADED | ENFORCED |
| R-412 | `hook:protected-path-guard` | DEGRADED | ENFORCED |
| R-705 | `hook:protected-path-guard` | DEGRADED | ENFORCED |

It also silently improves every other edit gate that is registered on shell calls as well as on edits, because a deletion or rename that previously produced no event at all will now produce one. R-102, R-103 and R-108 through `secret-scan`, and R-207 through `no-em-dash`, all gain coverage of the delete and rename paths without changing bucket.

With both fixes landed, and still assuming the matchers fire, the counts become **93 ENFORCED, 4 DEGRADED, 4 MANUAL**. The four that remain degraded are the llm-judge entries (R-315, R-316, R-317, R-325), and neither pending fix touches them: they are degraded by a missing Anthropic API key and by running at push time only, not by the adapter.

Neither fix addresses the matcher question, the `Read(...)` deny gap, or the absence of an adapter contract test.

## Recommended manual discipline under Codex

The shortest honest list, ordered by consequence. A Codex user who remembers only the first three has covered most of the real exposure.

1. **Treat destructive shell commands as entirely unguarded.** `rm -rf ~`, `rm -rf /`, `gh repo delete`, `gh release delete` and keychain reads all execute without a prompt under Codex today. Under Claude Code the deny list stops them. Read any `rm -rf`, any `gh` deletion, and any credential-store command aloud before running it, and prefer to run genuinely destructive commands yourself outside the agent.
2. **Never delete or rename a locked test, fixture, spec, or gate input through the patch tool.** The guard sees updates and is blind to deletions and to rename destinations. If a protected file genuinely has to go, delete it with a shell `rm`, where the guard does fire, and let it tell you no.
3. **Assume secret files are readable.** The `Read` deny list that keeps `.env`, `~/.ssh` and `~/.aws` off-path does not exist under Codex. Do not ask the agent to look at those files, and do not assume a refusal will arrive if you do.
4. **Run the linters and the suite yourself during the session.** Every AST-tier rule, thirty-five entries covering R-303, R-316, R-317, R-319 through R-329 and R-341 through R-344, fires only when a `git push` is attempted. Nothing checks them while you work. The Stop gate does run the project's own checks and does block, which was verified, so the suite is covered at the end of a turn; the linters are not.
5. **Carry the four unenforced rules in your head.** Commit after every discrete task (R-504) because nothing prompts you. Keep your own task state (R-601) because the crash-safe tracker never runs. Review manifest and settings edits against R-516 yourself. Choose the model deliberately per R-903, since no warning fires on a switch.
6. **Do your own semantic naming review before pushing.** R-315 has no enforcer other than the LLM judge, and the judge fails open and silent without an Anthropic API key, which a Codex user on a ChatGPT subscription will not have. R-316, R-317 and R-325 keep their ESLint half at push time and lose the semantic half.
7. **Expect confirmations to arrive as refusals.** Anything Claude Code would pause and ask about is denied outright under Codex, with an explanation. That is the intended translation, not a malfunction. Run the action yourself once you have decided, or set `CLAUDE_CODEX_ASK_POLICY=allow` to turn those into context notes instead.

## Unknowns, stated as unknowns

- **Whether any `PreToolUse` or `PostToolUse` hook fires under Codex at all.** This is the matcher question, and it is unresolved. It governs 92 of the 101 entries. The evidence leans toward "they do not fire", and the fix if so is a matcher translation table in `translate/codex-port-map.json` mirroring the one the Cursor port already has. Settle it with one Codex session under `CLAUDE_CODEX_HOOK_DEBUG=1`.
- **The trigger logic of eight guards was not exercised, only their plumbing.** `fix-commit-requires-test`, `conflict-markers`, `commit-message-guard`, `constant-change-guard`, `audit-signal-check`, `codex-billing-guard`, `git-workflow-guard` and `global-repo-push-guard` were confirmed to receive a payload through the adapter, but their rule-specific branches were not driven to a decision. Their ports are structurally identical to guards that were driven to a decision, so the risk that they behave differently is low, but it is not zero and it was not measured.
- **`dependency-add-guard` (R-331) did not fire on my synthetic `package.json` payload**, and it also did not fire when the same payload was fed to it directly, bypassing the adapter. That means the non-firing is a property of my test input or of the guard's own trigger conditions, not of the port. R-331's port is unverified beyond the plumbing.
- **`migration-defaults-guard` (R-328) and `codex-test-author-guard` (R-907)** were confirmed to receive replayed edit payloads, but their specific trigger branches were not exercised.
- **`harness-sync` (R-003) was not executed**, because it rsyncs a checkout over a home directory. Reading it confirms it passes `SYNC_CODEX_HOME` and therefore refreshes `~/.codex` as well as `~/.claude`, so a stale Codex port is not an additional risk, but that is a reading and not a run.
- **The three non-ESLint linter gates were not executed**, because their linters are not installed here.
- **The pending fix branches under `.worktrees/` were not read**, by instruction. Everything in the section above about what those fixes would change is inferred from the shape of the defects on `main`.
- **The judge's live path was never invoked**, by instruction. Only its unset-key path was tested.
- **`session-end`, `post-compact-rules` and `build-cheatsheets`** are registered in `settings.json` and ported, but no manifest entry names them as an enforcer, so they fall outside the 101 and were not assessed.

## Method note

The adapter was driven from a sandbox at a `mktemp`-style scratch path, with `HOME` and `CLAUDE_HOME` pointed at a copied `claude/` tree, so that every `$HOME/.claude/...` reference inside the hook scripts resolved into the sandbox. Throwaway git repositories were created inside the sandbox for the push-gate and Stop-gate tests. Nothing was written to the real `~/.claude`, the real `~/.codex`, or anywhere in the repository other than this report file. Two probes had to be rewritten mid-audit because the auditing session's own harness correctly blocked them: a literal U+2014 in a test payload, and a credential-shaped literal in another. Both were reconstructed at runtime from parts, which is the behavior R-108 asks for.
