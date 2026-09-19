# commit-message-guard finds commits through the quote-aware shell scan

Refs: IAN-152

## Summary

`claude/hooks/commit-message-guard.sh` enforces R-505 (a conventional commit subject, at most two triage IDs) and R-506 (a short body) on the commits a Bash tool call runs. Until now it decided whether a command was a commit with a regular expression over the raw command text, `(^|[;&|[:space:]])git[[:space:]]+commit`. That expression cannot tell a command from data. On 2026-09-19, during IAN-149, a subagent wrote a test file through a Bash heredoc, and the guard denied the call because the heredoc body contained the text `git commit -m ...` as test data. The same failure happened again while this change was being written: a Python heredoc whose comment mentioned a commit and a `-m` message was denied with the subject `message)`. This change makes the guard read the command the way the shell would, through the quote-aware word scan in `shell-command-tokens.sh` and `shell-command-scan.sh` that `pr-ticket-ref-gate.sh` already uses, so text inside quotes or inside a heredoc fed to a non-shell command is data, and only the commits that really run are validated.

## What changed

- `claude/hooks/commit-message-guard.sh` now scans the command into simple commands and judges every `git commit` among them. It reads a commit behind leading `VAR=value` assignments, behind the wrappers `env`, `time` (including `time -p`), `nice`, `nohup`, `timeout`, `sudo`, `xargs`, `exec`, `command`, and `builtin`, behind git's global options (`-C`, `-c`, `--git-dir`, and the rest), inside subshells and braces, and after `cd`.
- A commit run by a shell is still judged: the guard rescans the string of `bash -c`, `sh -c`, `zsh -c` (and clusters such as `-lc`), the words of `eval`, and a heredoc fed to a shell with no script file, to a nesting depth of four. A heredoc fed to `cat` or any other non-shell command stays data.
- Every commit in one Bash call is judged, not only the first. A deny on any commit wins over an ask on another, so the R-506 ask is held until every commit has been read.
- Message extraction reads the commit's own arguments after the scan has removed the quotes: every `-m`, `--message`, and `--message=` value (joined with a blank line, as git joins them), bundled short options the way git parses them (`-am msg`, `-qm msg`, `-am"msg"`), the body of `-m "$(cat <<'EOF' ... EOF)"`, and the heredoc behind `-F -`, `-F-`, `--file -`, or `--file=-`. The values of options that take one (`--author`, `-C`, `--trailer`, and the rest) are skipped, so `--author "-m x"` is not read as a message. `-F <file>` stays out of scope, as before. A message holding any other command substitution cannot be fully read, so the guard asks (R-506) instead of allowing it; see the Copilot review below.
- A cheap prefilter (a `git` word and the text `commit`) now runs before the scan, so commands that cannot run a commit never pay the scan's cost.
- When `shell-command-scan.sh` or `shell-command-tokens.sh` is missing, the guard denies a command that passes the prefilter and asks for `./sync.sh`, the same fail-closed behavior as `pr-ticket-ref-gate.sh`. A command with no `git` word is still allowed.
- `claude/hooks/shell-command-scan.sh` gains two shared functions: `strip_command_prefixes`, which removes shell keywords and command wrappers and sets `STRIPPED_WORDS` as an array (so a multi-line message word survives intact), and `is_git_commit_command`, a `find_simple_command` matcher that records a commit's arguments and heredoc the way `is_pr_create_command` does.
- Three new fixtures: `claude/enforce/tests/commit-message-guard-shell-scan.test.sh` (the data-versus-command cases from the incident, and real commits behind wrappers and global options), `claude/enforce/tests/commit-message-guard-review-cases.test.sh` (the cases the pre-merge review found), and `claude/enforce/tests/commit-message-guard-copilot-cases.test.sh` (the cases Copilot found). `claude/enforce/hook-hashes.txt` is regenerated. The Codex and Cursor ports regenerate with no changes.

## Architectural decisions

- **Chosen: reuse the shared scan and add the commit matcher to `shell-command-scan.sh`.** The file already exists to hold matchers over the scanned words (`is_pr_create_command`), and R-308 asks for reuse before new code. **Alternative:** copy `ticket-at-start-gate.sh`'s commit walk into this hook. **Why not:** that would be a third copy of the same wrapper-stripping logic. IAN-149's gate currently defines its own `strip_command_prefixes` (printing lines rather than filling an array). Its local definition overrides the shared one after it sources the helper, so nothing breaks when both branches merge, and IAN-149 can drop its copy in a follow-up.
- **Chosen: rescan shell strings rather than treating them as unreadable.** `ticket-at-start-gate.sh` denies a commit inside `sh -c` because it needs the directory, which it cannot know. This guard needs only the message, which the rescan reads exactly, so a rescan keeps `bash -c '...'` commits validated without denying them outright.
- **Chosen: a prefilter narrower than `*commit*`.** The shared scan walks the command one character at a time, and the review measured about 7 seconds on a 40 KB quoted word. The prefilter keeps that cost off every command that has no `git` word. The scan's own cost is a pre-existing property of the shared helper and is split out as a follow-up rather than fixed here.

## Testing

- Slice 1 fixture (written by Codex through `codex exec`): 19 case groups. It failed against `origin/main`'s guard at its first case (a heredoc to `cat` with a bad commit subject in its body, expected allow, got deny) and passes with the change.
- Slice 2 fixture (written by the test-author agent, because Codex had reached its usage limit): bundled `-am`, `-qm`, and attached `-am"..."`; a literal `-m` beside an unreadable `-m "$(date)"`; a literal subject containing `$(`; a bad commit after a good one; a deny winning over an ask; `bash -c`, `sh -c`, `eval`, and a heredoc fed to `bash`; `time -p`; and the missing-helper deny, run against copies of the hook with each helper removed. It failed at its first case (`-am` with a bad subject, expected deny, got allow) and passes with the change.
- `tdd.sh red` and `tdd.sh green` proved each slice against the full enforce suite (baseline 87, then 88 passing outside the slice). `claude/enforce/tests/run-tests.sh` and `claude/hooks/tests/run-tests.sh` pass with HOME pointed at a temporary directory whose `.claude` links to the worktree's `claude/`. `shellcheck --severity=error` is clean.

## Codex review

Reviewer: Claude subagent (fable), fallback: Codex usage limit reached (resets 2026-09-21).

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | The scan's per-character loop is quadratic in command length (177 s on 200 KB), and the `*commit*` prefilter sends many commands into it. | Partly fixed: the prefilter now requires a `git` word. The scanner's cost is a pre-existing property of the shared helper used by four hooks; a follow-up task makes it linear. |
| 2 | MEDIUM | Bundled short options (`-am`, `-qm`) were not read, so their subjects escaped. | Fixed test-first (slice 2): short-option clusters are parsed as git parses them. |
| 3 | MEDIUM | One unreadable `-m` emptied the whole message. | Fixed test-first: an unreadable value is dropped, and only an unreadable first value fails open. |
| 4 | MEDIUM | Commits run through `bash -c`, `sh -c`, `eval`, or a heredoc fed to a shell escaped. | Fixed test-first: shell strings and shell-fed heredocs are rescanned. |
| 5 | MEDIUM | Only the first commit in a Bash call was judged. | Fixed test-first: every commit is judged, and a deny wins over an ask. |
| 6 | MEDIUM | No test covered the missing-helper deny. | Fixed: slice 2 runs the hook with each helper removed. |
| 7 | LOW | With helpers missing, any command containing `commit` was denied. | Fixed by the narrower prefilter, with a test. |
| 8 | LOW | `time -p git commit` escaped. | Fixed test-first: `time` now skips its own options in `strip_command_prefixes`. |
| 9 | LOW | A `<<-` heredoc keeps the body's leading tabs, so a tab-indented subject fails R-505. | Deferred: pre-existing behavior of `capture_heredoc` in the shared helper, included in the scanner follow-up. |
| 10 | LOW | The hook comment cites IAN-149. | No change: IAN-149 is the real ticket during which the incident happened. |

## Copilot review

Copilot's first round left four inline findings, each a valid command shape that still let a commit escape. All four were fixed test-first in a third slice (`claude/enforce/tests/commit-message-guard-copilot-cases.test.sh`, written by the test-author agent because Codex was still at its usage limit):

- A shell option that takes a value (`bash -O extglob -c '...'`, `-o`, `+O`, `+o`, `--rcfile`, `--init-file`) hid the later `-c`. The guard now skips those values before it looks for `-c`.
- A wrapper's long option with a separate value (`sudo --user root`, `env --chdir /tmp`, `timeout --signal KILL`, `nice --adjustment 5`, and the `xargs` equivalents) left the value where the command word was expected. `strip_command_prefixes` now skips those values.
- A redirection before the command word (`< /dev/null git commit`, `2>/dev/null git commit`, `>log git commit`) hid the commit. `strip_command_prefixes` now removes redirections, attached or with a separate target, and assignments ahead of the command word.
- A command substitution anywhere in a message (`-m "feat: x $(printf ...)"`, `-m "$(date)"`, a backtick form) can add body lines whose count the hook cannot see. Such a message is now an R-506 ask rather than an allow, and an unreadable subject is an ask rather than failing open. A deny on a literal subject still wins.

## Reflection

I first treated the prefilter as a detail and kept `*commit*` from the old guard, and the review showed that it decides how often the slow scan runs at all. I also assumed that matching the old guard's reach was enough, while the review showed that the old guard already missed bundled flags, later commits in a chain, and shell strings; once the guard parses arguments properly, those gaps are cheap to close and hard to justify leaving. The incident reproduced itself mid-task when one of my own Python heredocs was denied, which confirmed the failure mode better than the report did. Work started at 18:12 (+07:00); the first implementation commit landed about 30 minutes later, and the review round and slice 2 took about 40 minutes more.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
