# Session handoff

## Last commit

- `dd58b14` fix(hooks): the destroy class covers retire, and every document carrying R-105 matches the hook (on `claude/mcp-guard-tracker-exemption`)
- This session ran in Claude Code on the web, container ephemeral. Every artifact below is pushed; nothing of value is local-only except the two items under Pending that say so.

## Production state

- `main` is at `3138809` (PR #3, the skills audit). Three PRs open against it, none merged.
- `main` now requires a pull request: a GitHub repository ruleset rejects direct pushes. The operator considers that over-broad and wants it scoped to the build-by-slice-require-review flow; nothing in the repo controls it, only Settings, Rules, Rulesets.
- The llm-judge tier cannot run in this container (no `ANTHROPIC_API_KEY`, no secret-store entry), so three to four manifest rules fail open on every push.
- `rsync` is absent from this container, so `sync.sh` dies at line 46 with a bare `127` and no diagnostic.

## Session metrics

- Commits: 6 across four branches (1 on `ticket-lifecycle-skill-ourn3y`, 2 on `permissive-bash-permissions`, 2 on `mcp-guard-tracker-exemption`, 1 on `config-hardening-safety`).
- Files changed: about 80, dominated by the 65-file Codex port regeneration.
- Rework count: 3. One commit pushed without its staged files, one permission change that reopened two recorded holes, one guard whose PR body claimed a verb was covered when it was not.
- Velocity flag: slow. Half the session went on correcting this session's own output rather than new work.

## What shipped

- **PR #8**, `claude/ticket-lifecycle-skill-ourn3y`: the fifteen P2 and P3 findings from the 2026-09-17 engineering audit, merged with PR #3. Its new R-516 closure test caught #3's undeclared `handoff-check` enforcer on first contact. Also made `skills-lint` read the checkout instead of `~/.claude/skills`.
- **PR #10**, `claude/permissive-bash-permissions`, ticket IAN-77: `Bash(bash *)`/`Bash(sh *)` leave the ask list, four asks on the inline form (`bash -c`, `sh -c`, `-lc` spellings) replace them, curated allow list untouched. `settings-change-guard.test.sh` gained invariant 5, which reads the checkout and fails against a blanket `Bash` allow or a missing interpreter ask.
- **PR #11**, `claude/mcp-guard-tracker-exemption`, ticket IAN-78: R-105 exempts the private tracker's write class; `merge`, `submit`, `upload`, `apply`, the destroy and transmit classes, and every other server still ask. `retire`/`retract` added to the destroy class after review found `retire_issue_label` drew no decision at all. Rule text synchronized across `CLAUDE.md`, `reference.md`, the manifest note, the ticket-lifecycle skill, its design spec, and the Codex and Cursor copies.
- **`claude/config-hardening-safety`**, ticket IAN-76, pushed but no PR: the tranche-1 plan at `docs/superpowers/plans/2026-09-17-config-hardening-tranche-1-safety.md`, grounded in probe results rather than the spec's prose.
- Linear is configured as the tracker. Eight canonical states map onto six Linear statuses plus four existing labels; the nine canonical fields live in a description metadata block because Linear has no custom issue fields.

## Pending

1. **PAT rotation and transcript purge (`claude/ISSUES.md:28`), operator action, blocks B-4 and the spec's `publishable` state.** Unchanged all session. No agent can close it.
2. **Place `~/.claude/TICKET-TRACKER.json` on the operator's machine, 2 minutes.** It was written in this container, is gitignored by design (it carries the team id), and will die with the container. The file was sent to the operator in chat.
3. **B-3, the open credential read path, effort: half a day.** `secret-scan.sh` enforces R-103 on the Bash path and not R-102 at all. Verified with synthetic paths: `cp .env /tmp/x` is denied, while `cat .env`, `base64 <key>`, `python3 -c "open(<key>).read()"`, `node -e "readFileSync(<creds>)"`, `curl -F file=@<creds>` and `curl --data-binary @<key>` all draw no decision. The eleven `Read(...)` deny rules bind only the `Read` tool. Slices 1 and 2 of the tranche-1 plan close it.
4. **Three fixtures read `$HOME` instead of the checkout, effort: 2 hours.** `post-compact-rules` (reads a real tier ledger), `hook-hashes-closure` (reads the live tree), and the `HOOK` path in every `enforce/tests` fixture. They fail in a container for reasons no commit caused. Belongs with the tranche-2 doctor work.
5. **Unaddressed PR #8 review findings, effort: 3 hours.** Copilot raised ten, several correct and untouched: the judge-liveness probe reports healthy from `secret-tool`/`pass` while `llm-rule-judge.sh` still resolves only `ANTHROPIC_API_KEY` or macOS `security`; `isRegistrationPorted` still uses `in` rather than an own-property check; the CLI computes `unexpected` and discards it, so the token is never named; both heredoc extractors reject a hyphenated delimiter and anchor the closing delimiter to end-of-command, so a chained `git commit -F - <<MSG ... MSG; git push` still bypasses R-403/R-505/R-506; `claude-md-lint` counts rule files before the exemption, so an effectively empty directory passes.

## Next session

1. Read `docs/superpowers/plans/2026-09-17-config-hardening-tranche-1-safety.md`, then `claude/hooks/secret-scan.sh` and `claude/enforce/tests/secret-scan.test.sh`. Start slice 1 on `claude/config-hardening-safety`: fixture first, proven RED, then the read denial. Ticket IAN-76.
2. Before that, if the three PRs still sit open: read `claude/ISSUES.md:11` and `:69` before touching `claude/settings.json` for any reason. This session made a permission claim without reading them and was wrong.
3. The PR watch subscriptions and the hourly check-in belonged to the web session and do not transfer. Re-subscribe or check the PRs by hand.
4. For PR #8's findings, read `claude/hooks/commit-message-guard.sh:47` and `claude/hooks/fix-commit-requires-test.sh:89` together: both heredoc extractors share the same two defects.
