# PR: draft pull request on first push, and the PR monitor instruction (R-517)

Ticket: IAN-137. Branch: `feat/draft-pr-on-first-push`. Time from the first implementation commit to this document: about 17 minutes (14:26 to 14:43 on 2026-09-19, from `git log` and `date`).

## Summary

Before this change, a pushed branch sat without a pull request until the session remembered to open one, and a PR that was opened got no CI or review monitoring unless someone turned the desktop app's monitor on by hand. This PR adds rule R-517 and two PostToolUse Bash hooks. `draft-pr-on-first-push.sh` opens a draft pull request itself, with `gh pr create --draft`, after a successful push of a non-default branch that has no open PR. It applies the same R-605 ticket check as the PreToolUse gate and never fails the push. `pr-monitor-reminder.sh` tells the session, after any successful `gh pr create`, to call `mcp__ccd_pr__set_monitor` with auto-fix, comment handling, and auto-archive switched on, and never to enable auto-merge unless the user asks.

## What changed

- `claude/hooks/shell-command-scan.sh` and `claude/hooks/pr-range-checks.sh` (new, sourced helpers) hold the shell-word scanner, the `Refs:` detection, the base resolution, and the docs-only and trivial-tier checks. These were previously private to `pr-ticket-ref-gate.sh`. The scanner gains a generic `find_simple_command <dir> <matcher>` walker, and `is_pr_create_command` is the matcher the gate and the monitor hook share.
- `claude/hooks/pr-ticket-ref-gate.sh` now sources both helpers and behaves as before. Its existing fixture passes unchanged. When a helper file is missing, the gate asks rather than failing open.
- `claude/hooks/draft-pr-on-first-push.sh` (new) opens the draft. The title is the oldest commit subject in the range, and the body lists the commit subjects, then the distinct `Refs:` lines, then the attribution line. It exits silently for a dry run, a delete, a tag-only push, a quoted `git push`, a push of `main`/`master`/`staging` or the default branch, a branch that already has an open PR, and the `.enforce.json` `"autoDraftPr": false` opt-out. It reports a missing ticket in the session context and opens nothing. Every `gh` call is bounded by `CLAUDE_GH_TIMEOUT_SECONDS`.
- `claude/hooks/pr-monitor-reminder.sh` and `claude/hooks/pr-monitor-instruction.sh` (new) handle the monitor instruction. The instruction text lives in the helper, and the draft hook emits it too, because the draft hook's own `gh` call is not a tool call and no other hook sees it.
- `claude/CLAUDE.md` gains the R-517 norm line, and `claude/rulebook/reference.md` gains its Spec, Scope, and Enforcement entry. `claude/enforce/manifest.json` gains two R-517 rows, and `claude/settings.json` registers both hooks in the PostToolUse Bash block, with 60-second and 10-second timeouts. `claude/README.md` and `claude/enforce/README.md` describe the hooks and the `autoDraftPr` key. The Codex and Cursor ports and `claude/enforce/hook-hashes.txt` are regenerated.

## Architectural decisions

- **Two hooks and three helpers, not one hook.** One script could handle both the push and the `gh pr create` event. It was split because each file then has one responsibility (R-318). The shared scanner also meant the monitor hook only needed a matcher.
- **The scanner was factored out as well, beyond the four named range functions.** Push detection has to be shell-aware in the same way the gate's `gh pr create` detection is. Copying the 90-line scanner would have duplicated the part of the gate that took two review rounds to get right (R-308).
- **Success is confirmed from git state, not only from the tool response.** The response is checked for interruption and rejection text. In addition, the remote-tracking ref for the pushed branch must equal HEAD. A rejected push, or a push of commits the remote does not have, therefore opens nothing whatever the response's format.
- **No `if: "Bash(git *)"` filter on the registration.** A `cd <repo> && git push` would never match a prefix filter, which is the same reason `pr-ticket-ref-gate.sh` carries none. The hook's own prefilter exits after one `jq` and one `grep`.
- **Pushes of a branch other than the checked-out one are skipped.** The shared range checks read `base..HEAD`, so acting on another branch would build the draft from the wrong commits.
- **The monitor instruction also names `mcp__ccd_pr__bind_pr`.** `set_monitor` works on the session's bound PR, so the instruction says to bind first if the call reports that no PR is bound.

## Testing

`claude/hooks/tests/draft-pr-on-first-push.test.sh` (47 assertions) stubs `gh` on PATH and uses real git against local bare remotes, so nothing reaches GitHub. It covers:
- a first push with Refs opening a draft, including the exact title, the body, and the monitor instruction;
- an existing PR, a push of main, and failed, interrupted, and lagging pushes;
- dry-run, `-n`, delete, and tag pushes;
- a quoted push in a commit message and in an echo;
- the opt-out;
- no Refs with a tracker configured, and the degraded no-tracker path;
- the trivial-tier and docs-only exemptions;
- gh failing, gh missing, and a malformed timeout;
- redirections, `@`, and `--repo`.

`claude/hooks/tests/pr-monitor-reminder.test.sh` (14 assertions) covers a successful create, including a `cd`-prefixed heredoc form. It also covers a failed, interrupted, and already-exists create, a quoted `gh pr create`, and unrelated commands.

Both full suites pass: `bash claude/hooks/tests/run-tests.sh` (22 fixtures) and `bash claude/enforce/tests/run-tests.sh` (86 fixtures). These include `pr-ticket-ref-gate.test.sh`, the manifest and hash closures, `guard-fail-closed.test.sh`, and `deny-tier-set-convention.test.sh`. `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` pass, and `shellcheck --severity=warning` is clean on every new file.

A fresh reviewer subagent read the diff before this PR opened and reported six findings. Five were fixed test-first in `a128b75`:
- `git push 2>&1 | tail` read `2>` as the remote;
- `git push origin @` was not treated as HEAD;
- `--repo <name>` dropped the remote name;
- a non-integer timeout broke the deadline arithmetic;
- gh's "already exists" failure, merged into stdout, triggered the monitor reminder.

The sixth is left open as a decision for the owner. A branch whose PR was already merged or closed gets a new draft if it is pushed again, because the owner's specification checks only for an open PR.

## Reflection

What I understand now: a PostToolUse hook that acts on the world has to verify the world's state rather than trust the text of the command. The tracking-ref comparison is the check that makes the hook safe against every push-failure format at once. What I got wrong first: the push-argument parser treated every non-flag word as the remote or a refspec. The first `2>&1` it met therefore became a remote named `2>`. The fixtures had not caught this, because none of them ran the push the way an agent usually does, with its output redirected. The fixture's `make_repo` also shifted its arguments before it named the bare remote, which only surfaced once a test added a second remote.
