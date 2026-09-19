# ticket-at-start-gate uses the shared strip_command_prefixes

Refs: IAN-152

## Summary

PR #78 (IAN-149) and PR #79 (IAN-152) merged minutes apart on 2026-09-19, and together they broke `main`: `claude/hooks/ticket-at-start-gate.sh`, the R-605 gate that denies a commit in a repository with no ticketed task-start ledger, stopped denying anything. Each PR was green on its own. #78's gate defined its own `strip_command_prefixes`, which printed the remaining words one per line, and then sourced `claude/hooks/shell-command-scan.sh` at runtime. #79 added a shared `strip_command_prefixes` to that helper, which fills a `STRIPPED_WORDS` array and prints nothing. Once both were on `main`, sourcing the helper replaced the gate's definition with the shared one, the gate read an empty word list for every command, and it allowed every commit it should have denied. `main`'s CI went red on `ticket-at-start-gate.test.sh` (G-11, G-12, R-1, R-2). This change makes the gate use the shared function and adds a fixture that fails whenever a hook redefines a function of a helper it sources.

## What changed

- `claude/hooks/ticket-at-start-gate.sh` no longer defines `strip_command_prefixes`. `inspect_commit_words` calls the shared one and reads `STRIPPED_WORDS`. A short comment at the old location says where the function lives and why the local copy was removed.
- New fixture `claude/enforce/tests/shell-helper-redefinition.test.sh`: for every hook that sources `shell-command-scan.sh` or `shell-command-tokens.sh`, it collects the functions those helpers define (a hook that sources the scan inherits both) and fails naming the hook and the function when the hook defines one of the same name. A self-check builds a throwaway hook that redefines `scan_command_tokens` and requires the detector to flag it, so the fixture cannot pass vacuously.
- `inspect_commit_words` reads `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, and `GIT_COMMON_DIR` from every word the strip removed, not only from assignments that lead the command, so an assignment after `if`, `{`, `!`, a wrapper, or a redirection still names the repository the commit lands in (review finding 1).
- `claude/hooks/draft-pr-on-first-push.sh` drops its local `REDIRECTION_PATTERN`, which the sourced helper already replaced at runtime (review finding 3).
- `claude/enforce/hook-hashes.txt` is regenerated. The Codex and Cursor ports regenerate with no changes.

## Architectural decisions

- **Chosen: delete the gate's copy and use the shared function.** The shared version is a superset of the gate's: it also removes redirections and assignments ahead of the command word, skips `sudo -R`/`-T`, `env -P`, and `exec -a` values, treats `command` and `exec` as option-taking wrappers, and turns `env -S '<cmd>'` into the `sh -c` string it runs, which the gate already treats as an unreadable shell string and denies. Every difference makes the gate see more commits, never fewer. **Alternative:** rename the gate's function so both coexist. **Why not:** that keeps two diverging copies of the same wrapper table, which is how the gate's copy fell behind the shared one in the first place.
- **Chosen: a structural fixture for the collision class.** The gate's own fixture caught the symptom only after both PRs merged. The new fixture fails on the redefinition itself, on any branch, so a future PR that adds a helper function whose name a hook already uses fails its own CI.

## Testing

- RED: `tdd.sh red` on both files against `origin/main` (`ed34236`): `shell-helper-redefinition.test.sh` failed naming `ticket-at-start-gate.sh: strip_command_prefixes`, and `ticket-at-start-gate.test.sh` failed at G-11 (a ledgerless commit allowed). GREEN: both pass, with 92 fixtures passing outside them.
- `claude/enforce/tests/run-tests.sh` (through `tdd.sh`) and `claude/hooks/tests/run-tests.sh` pass with HOME pointed at a temporary directory whose `.claude` links to the worktree's `claude/`. Run against the real HOME on this machine, `git-workflow-guard.test.sh` and `task-cleanup-scan.test.sh` fail at both `ed34236` and `6f6ca63` because a real `~/.claude/TICKET-TRACKER.json` makes `task-tier.sh set standard` require `--ticket`; CI has no tracker file and passes them, so they are an environment dependency of those fixtures rather than part of this regression.

## Codex review

Reviewer: Claude subagent (fable), fallback: Codex usage limit reached (resets 2026-09-21).

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | The shared strip removes `VAR=value` words after a shell keyword or redirection, and the gate read `GIT_*` only from leading assignments, so `if GIT_DIR=<ledgerless>/.git git commit` and `{ GIT_DIR=... git commit; }` went from deny to allow compared with the gate before #79. | Fixed test-first: `inspect_commit_words` now reads `GIT_*` from every word the strip removed. Six W-4 cases added (`if`, `{`, `!`, `env`, `time`, and a leading redirection). |
| 2 | MEDIUM | The redefinition fixture recognized only `name() {` at column 0. | Fixed: it now recognizes `name(){`, `name () {`, `function name {`, `function name() {`, `name() (`, indented definitions, and a brace on the next line, with a self-check for each shape. |
| 3 | LOW | `draft-pr-on-first-push.sh` assigned its own `REDIRECTION_PATTERN`, which the sourced helper replaced at runtime: the same mechanism with a constant. | Fixed test-first: the fixture now flags a hook that reassigns a helper's column-0 constant, which failed on this hook; the dead local constant is removed. |
| 4 | LOW | The fixture counted a hook as a consumer only when the helper's file name appeared with its `.sh` extension. | Fixed: a hook that names the helper without the extension counts, with a self-check. |
| 5 | LOW | `env --chdir <repo>`, `env -C`, and `sudo --chdir` commit in another repository but are judged against the cwd's ledger, before and after this change. | Deferred to a follow-up task: pre-existing, and fixing it means replaying the directory change. The `GIT_*`-under-a-wrapper half is fixed by #1. |
| 6 | LOW | The tokenizer splits `3>&1` at the `&`, so `exec 3>&1 git commit` hides the commit, before and after this change. | Deferred to the same follow-up: pre-existing tokenizer behavior. |

## Reflection

I checked for this collision while writing #79 and concluded it was safe, because I assumed the gate's local definition came after the `source` line and would win. It does not: the gate sources the helper inside its Bash branch at runtime, after all its functions are defined, so the helper's definition is the one that survives. The lesson is that "a local definition overrides the sourced one" depends on execution order, not file order, and it held only until the helper grew a function with the same name. After merging #79 I verified the merge on `main` by running the neighboring gate's fixture, which is how this surfaced within minutes instead of at the next commit a session tried to make. Time from finding the failure to this document was about fifteen minutes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
