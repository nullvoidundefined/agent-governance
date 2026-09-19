# Open the tracker ticket at task start

Refs: IAN-149.

## Summary

R-605 asks for a tracker ticket at task classification, but the only mechanical check sat at `gh pr create` (`pr-ticket-ref-gate.sh`), and the R-518 draft PR on first push inherits the same check. By the time either fires, the whole task has run, so a missed ticket was discovered after the work and filed retroactively. That happened for IAN-102 to IAN-113, and twice more on 2026-09-19 (IAN-147 for PR #77 and IAN-148 for PR #71, both of which had shipped under an unrelated key). The owner's decision the same day was: "Always open retroactive tickets but we should really fix it so there are no retroactive tickets. We should be opening tickets as tasks start." This PR moves the check to the start of the work. The ticket key now lives in task-start's ledger, and a new hook refuses the first edit and every commit until the ledger carries the key for the branch being worked.

## What changed

- `claude/skills/task-start/scripts/task-tier.sh`: `set` accepts `--ticket <KEY>` (with `--share` in any order) and rejects a value that is not a tracker key. When `~/.claude/TICKET-TRACKER.json` exists, it refuses a tier above trivial without a ticket; with no tracker configured, R-605's degraded path, it does not. A reclassification on the same branch keeps the existing key. `summary` prints the key.
- `claude/hooks/ticket-at-start-gate.sh` (new, PreToolUse on `Write|Edit` and on `Bash`) denies a Write or Edit inside a git work tree, and every `git commit`, unless `<top>/.claude/task-tier.json` meets four conditions: it is untracked and unstaged, it is readable, it names the checked-out branch, and it records either the trivial tier or a ticket key. Nothing is gated when no tracker is configured or `HOME` is unset, outside a work tree, on a detached HEAD (a rebase or bisect in progress), or for a path under the repository's own `.claude/` or one git ignores. Commits are read with the quote-aware shell scan shared with the other R-605 hooks:
  - Every commit in a command is judged against the repository it really runs in, after `cd` and `pushd`, environment assignments, wrappers, shell keywords, and git's `-C`, `--work-tree`, and `--git-dir`.
  - A commit inside `sh -c`, `bash -c`, or `eval` cannot be read, so it is denied.
- `claude/settings.json` registers the hook on both matchers. The Codex adapter's write-target hook list (`codex/hooks/codex-hook-adapter.sh`, hand-authored) adds it, so a Codex `apply_patch` or shell write reaches it too.
- `claude/enforce/tests/ticket-at-start-gate.test.sh` (new) and `claude/enforce/tests/task-tier.test.sh` (extended) are the fixtures.
- Rule text:
  - `claude/CLAUDE.md` extends the R-605 norm line and its enforcer tags.
  - `claude/rulebook/reference.md` adds an "Enforcement, at task start" clause to R-605.
  - `claude/enforce/manifest.json` gains a second R-605 entry for the new enforcer.
- Skills and README:
  - `claude/skills/task-start/SKILL.md` reorders Step 1: classify, estimate, open the ticket, create the branch, then record the ledger with `--ticket`.
  - `claude/skills/ticket-lifecycle/SKILL.md` adds the ledger step to `open`.
  - `claude/skills/task-cleanup/SKILL.md` names the recovery for returning to a PR branch after the next ticket's ledger replaced this one.
  - `claude/README.md` lists the gate.
- The Codex and Cursor ports and `claude/enforce/hook-hashes.txt` are regenerated.

## Architectural decisions

- **Chosen: gate the first Write/Edit and every `git commit` (owner decision).** The alternatives were gating only commits (quieter, but one slice of work can happen before the ticket) and changing only `task-tier.sh` (cheapest, but it depends on task-start being run, which is what failed on 2026-09-19). Edits made through Bash skip the Write/Edit matcher, which is why commits are gated as well.
- **Chosen: the key lives in the task-tier ledger rather than a new file.** The ledger already records the tier, the branch, and the start time for the same task. It is untracked session state, and `post-compact-rules.sh` already re-injects it after a compaction. The ledger-trust rules match the R-517 trivial exemption (#77): untracked, same branch, parseable.
- **Chosen: no tracker, no gate.** This repository is public, and users without a tracker must not be blocked on a ledger they have no ticket for. That matches R-605's degraded path in `pr-ticket-ref-gate.sh`.
- **Chosen: gate `git commit` only, not cherry-pick, revert, am, or merge.** Gating `git merge` would deny routine merges on `main` in repositories that carry no ledger. The documentation says plainly that only `git commit` is gated, instead of claiming that every commit into history is.
- **Chosen: a new walker over the shared tokens rather than `find_simple_command`.** The shared walker stops at the first match. Here every commit must be judged, and a commit's repository depends on the `cd` before it and git's own `-C`, `--work-tree`, and `--git-dir`.

## Testing

- Red first, every round. The test-author agent wrote both fixtures as the recorded R-907 fallback (Codex was over its usage limit), and every new case failed against the absent hook and the unchanged `task-tier.sh`. Each review round then added cases that failed against the previous commit: 23 before `0e7e30d`, 17 before `2d1b2fa`, 6 before `01b4964`, 5 before `2ef5602`, 11 before `aedb1b3`, 9 before `02fb2a1`, 10 before `fcdc320`, 6 before `744241a`, 2 before `1bc2499`, 17 checks before `ac98999`, and 8 before `2ec6662`, for 190 fixture assertions in all.
- Both full suites pass with `HOME` pointed at a temporary directory whose `.claude` symlinks to this worktree's `claude/`: `ALL ENFORCEMENT TESTS PASS` and `ALL HOOK TESTS PASS`. `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` pass.
- This branch dogfoods the rule: its ledger was recorded with `task-tier.sh set standard ... --ticket IAN-149`, and the ticket was opened before the first edit.

## Codex review

- Reviewer: Claude subagent (fable), fallback: Codex usage limit reached ("You've hit your usage limit", reset at 6:00 PM), with the filled `claude/prompts/codex-pr-review-prompt.md`. Four rounds; each fix round's failing cases were written by the test-author agent (the R-907 fallback) and proven red first.
- Round 1, `origin/main...6d8710f`, eight findings, all fixed in `0e7e30d`:
  - HIGH: commits after `cd`/`pushd` were judged in the payload cwd. Fixed: commits are read by the shared quote-aware scan and every `cd` is replayed.
  - HIGH: commits behind assignments, wrappers, keywords, `\git`, `/usr/bin/git`, `sh -c`, and `eval` were missed. Fixed: prefixes are stripped, and shell strings deny as unreadable.
  - MEDIUM: the header and spec overclaimed that every commit into history was gated. Fixed by narrowing the claim to `git commit` (cherry-pick, revert, am, and merge are named as ungated).
  - MEDIUM: returning to a PR branch after the next ticket's ledger replaced this one denied without a recovery. Fixed: task-cleanup and the deny reason name it.
  - LOW, all fixed: a staged ledger's deny names `git rm --cached`; an unset `HOME` is the explicit degraded path; `--git-dir=<repo>/.git` is judged by `<repo>`; every commit in a command is judged.
- Round 2, `6d8710f...0e7e30d`, all eight verified; four new, all fixed in `2d1b2fa`:
  - MEDIUM: an unresolvable `cd` or `-C` target (`$VAR`, `$(...)`, `cd -`, a missing directory) fell back to allowing. Fixed: it denies as unreadable, and `~` expands.
  - LOW: `bash -c "git log --grep=commit"` false-denied.
  - LOW: `--work-tree` outranked `--git-dir`.
  - LOW: `sudo -k` swallowed `git`, and `$x commit` was unseen.
- Round 3, `0e7e30d...2d1b2fa`, all four verified; five new:
  - Fixed in `01b4964`: MEDIUM, the quoted `cd "$(git rev-parse --show-toplevel)"` idiom false-denied; LOW, `commit` is now read only as git's subcommand (covers `git log --grep commit` and a trailing `# commit` comment).
  - Answered, accepted by the reviewer: LOW, `$(which git) commit` is missed because the shared tokenizer splits `$(`. The fix belongs in `shell-command-tokens.sh`, which git-workflow-guard's merge scan also uses, so it is filed as a follow-up task.
  - Answered, accepted by the reviewer: LOW, `env -C` is GNU-only. Both are deliberate obfuscation, and this gate targets a forgotten ticket.
- Round 4, `2d1b2fa...01b4964`: all dispositions verified, and no new finding at MEDIUM or higher and no false denial of an ordinary command. Latency: 30 ms for a non-commit Bash call, about 100 ms for a commit, about 110 ms for a Write or Edit.
- Copilot round 1 (four comments), fixed in `2ef5602`: a commit on a later line of a multi-line `sh -c` string, `timeout --signal TERM` and other wrapper long options (with a backstop that denies a commit behind an unrecognized wrapper option), an unset `HOME` in `task-tier.sh`, and `--ticket` shown as optional for the trivial tier. Round 5 of the fallback review, on `2ef5602`: no finding.
- Copilot round 2 (seven comments), fixed in `aedb1b3`: `time -p`, an expanded subcommand (`git "$x"`), a repository created in the same command, `GIT_DIR`/`GIT_WORK_TREE` assignments, an expanded `bash -c` payload, a heredoc fed to `sh -s`, and a branch switch before a commit. Round 6, on `aedb1b3`, found two false denials, both fixed in `02fb2a1`:
  - MEDIUM: script arguments holding `$VAR` were denied, including `task-tier.sh set ... "$REASON"`. The expansion check now applies only to executed text in a command that mentions commit.
  - LOW: `git checkout -b feat/y && git commit` was denied as unreadable. A readable switch now has the later commit judged against the branch it lands on.
- Round 7, on `02fb2a1`, found two more, both fixed in `fcdc320`:
  - MEDIUM: `git switch -` was ignored. It now resolves to the previous branch.
  - LOW: checkout restore forms (`checkout main README.md`, `checkout .`) were read as branch switches.
- Round 8, on `fcdc320`: no finding.
- Copilot round 3 (ten comments). The owner scoped the PR (2026-09-19) to fixing the three that ordinary work hits, all fixed in `744241a`: `if cd <repo>; then git commit; fi`, a ledger still in `HEAD` behind a staged `git rm --cached`, and the ticket-lifecycle `open` order, which recorded the ledger after writing the spec. The other seven hide a commit deliberately: `coproc`, `env -S`, `env GIT_DIR=`, `popd`, `"$(git commit)"`, an inherited `$SCRIPT`, and Codex `sed -i` edits. They were answered in their threads as outside the gate's stated threat model (a forgotten ticket; the PR gate still backstops them) and are tracked in IAN-153. A fourth Copilot round was not requested, by the same decision.
- Round 9, on `744241a`, found one MEDIUM: the new HEAD check deadlocked the recovery its own deny message prescribed (the commit that untracks a committed ledger was refused). Fixed in `1bc2499`: while the ledger is in `HEAD` and its removal is staged, an edit of `.gitignore` and the untracking commit pass.
- Round 10, on `1bc2499`, found one MEDIUM: that exemption let `git add -A && git commit` or `git commit -am` carry other work. Fixed in `ac98999`: only a commit that stages nothing of its own qualifies, and a `git rm --cached` of the ledger earlier in the same command counts as the removal.
- Round 11, on `ac98999`, found one MEDIUM: other subcommands (`merge --squash`, `cherry-pick -n`, `stash pop`, a path checkout) could stage content before a plain commit. Fixed in `2ec6662` by turning the check into an allowlist of subcommands, and `--pathspec-from-file` now counts as staging.
- Round 12, on `2ec6662`: no finding at MEDIUM or higher and no false denial of an ordinary command. The one observation, a staging command wrapped in `bash -c` during the untracking recovery, is in the IAN-153 class and was added to that ticket.

## Reflection

The first implementation found commits with a regex over the raw command text, the same shortcut that `git-workflow-guard.sh` had already abandoned for R-517 after four review rounds. The fallback reviewer found the same holes within one round: `cd <repo> && git commit`, `FOO=1 git commit`, `sh -c`, and a second commit in the same command. The shared scanner existed to prevent exactly this, and I should have started from it. The per-checkout ledger also reaches past trivial PRs now: returning to a PR branch after starting the next ticket requires re-recording that PR's ledger. Keeping one worktree per in-flight ticket avoids the swap, and the deny reason now says so.
