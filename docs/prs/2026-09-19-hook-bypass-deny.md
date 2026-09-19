# Deny every way the agent can skip git hooks

Refs: IAN-141

## Summary

Before this change, the harness only asked for confirmation when the agent typed `git commit --no-verify` or `git commit -n`, through two literal-prefix rules in `claude/settings.json`. A prefix rule cannot see an abbreviated flag (`--no-veri`), a flag behind a global option (`git -c x=y commit -n`), a different subcommand (`git push --no-verify`), or any of the ways to skip hooks that are not a flag at all. The 2026-09-19 ECC audit ranked this as port item 2. ECC's own `block-no-verify.js` hard-blocks the flag forms but misses the environment-variable, one-command config, and hook-file forms. This change makes `destructive-command-guard.sh` deny all four classes on every attempt, and keeps ordinary developer commands that look similar working.

## What changed

- **B-1, flags.** `--no-verify`, and every prefix git accepts for it down to `--no-veri`, is denied on `commit`, `push`, `merge`, `rebase`, and `am`. `-n` is denied on `commit`, alone or in a bundled short-flag cluster (`-an`, `-anm`), except where the `n` belongs to an attached argument (`-mn` is the message "n", `-uno` is the untracked-files mode "no"). `git log -n`, `git push -n` (dry run), and `git merge -n` (no stat) stay allowed.
- **B-2, hook-manager variables.** `HUSKY=0`, `HUSKY_SKIP_HOOKS`, `SKIP` (the pre-commit framework's skip list), `LEFTHOOK=0` or `false`, and `LEFTHOOK_EXCLUDE` are denied on a hook-running git command, whether set as a prefix, through `env`, or by an `export` earlier in the same command. `SKIP=1 npm test` and `HUSKY=0 npm install` stay allowed.
- **B-3, one-command hooksPath overrides.** `git -c core.hooksPath=...`, `--config-env core.hooksPath=...`, `GIT_CONFIG_KEY_n=core.hooksPath`, and a `GIT_CONFIG_PARAMETERS` value naming `core.hooksPath` are denied on any git subcommand, with a case-insensitive key match. The existing check only covered `git config core.hooksPath <value>`.
- **B-4, hook files.** `rm`, `unlink`, `mv`, `chmod`, `chown`, `truncate`, `shred`, and `tee` on a `.git/hooks` path, `cp`, `ln`, and `install` onto one, `sed -i` or `perl -i` on one, `find` with a delete or exec action, and any output redirect into `.git/hooks` are denied, including after `sudo`. Reading the hooks and copying one out stay allowed.
- **Parsing.** The guard now splits the command into simple commands and turns each quoted run into a single word marked with a leading `Q`, with separators, redirects, and spaces inside it replaced. A commit message that mentions `--no-verify`, `HUSKY=0`, or `rm .git/hooks/pre-commit` therefore never reads as the thing it mentions, while `git -c "core.hooksPath=x"` keeps its content for the B-3 check. Global options are stripped with the existing `strip_git_global_options` from `git-invocation.sh`.
- New fixture `claude/enforce/tests/hook-bypass-guard.test.sh` with 127 cases (83 deny, 44 allow) in one section per slice. The manifest notes for R-107 and R-203 and the README's gate paragraph describe the new coverage; `hook-hashes.txt` is regenerated.

## Architectural decisions

- **Chosen: extend `destructive-command-guard.sh` rather than add a new hook.** It already owns the hooksPath and hooks-directory checks, it already runs on every Bash call, and a separate hook would add a process to the latency budget that `hook-latency.test.sh` enforces. **Alternative:** a dedicated `hook-bypass-guard.sh`. **Why not:** two hooks parsing the same command for overlapping git forms would drift apart.
- **Chosen: deny, not ask.** The settings rules asked, and an ask on a hook skip is the path of least resistance for an agent whose commit a hook just rejected. R-203 already says the agent never bypasses a guard, so the mechanical form of that rule is a deny. A human can still skip a hook at the terminal, and CI remains the gate that `--no-verify` cannot reach.
- **Chosen: quote-marking instead of quote-blanking.** The first two slices replaced every quoted run with a bare `Q`. That hid B-3's `git -c "core.hooksPath=/dev/null"`, so the tokenizer was changed to keep the content behind a marker. The marker is what stops `-m "--no-verify"` from matching the flag.
- **Chosen: the environment-variable checks key on the specific hook managers.** A generic rule ("any variable before git") would deny `GIT_AUTHOR_DATE=... git commit`, which is ordinary. The list names husky, pre-commit, and lefthook, which cover the managers in use across the owner's repositories.
- **Test author: `test-author` subagent (fallback: Codex usage limit reached)** for all four slices, per R-907's recorded fallback.

## Testing

- Each slice ran `tdd.sh open`, the test author's RED, `tdd.sh red`, the implementation, `tdd.sh green` (87 other fixtures passing each time, baseline 87), `tdd.sh validate implementer`, and `tdd.sh close`.
- The fixture passes under Homebrew bash 5 and macOS `/bin/bash` 3.2.
- `destructive-command-guard.test.sh` still passes unchanged.

## Reflection

- **What I understand now.** The two hard parts of a command guard are quoting and separators, not the flag list. Every false positive in the first design came from quoted text (a commit message mentioning a flag), and every miss came from a construct the prefix rule could not see (a global option, an `export` earlier in the same line).
- **What I got wrong first.** B-2's first implementation denied nothing at all. The segment splitter ended without a newline, so `read` silently dropped the only segment. B-1 had hidden this because its pipeline happened to end in `grep`, which adds one. The fix is `awk` as the last stage, and the comment above the function now records why. A BSD `sed '$a\'` attempt failed first.
- **Process gap found.** The R-509 stop gate blocks a test-author subagent from returning while its intended RED is red, because the gate does not consult an open slice lock. All four test-author runs hit it and reported instead of returning cleanly. That deserves its own ticket.

Time since implementation: the first commit landed at 10:34 UTC and the last at 11:35 UTC on 2026-09-19, and this document was written at 11:36 UTC, so the reflection is about a minute old.
