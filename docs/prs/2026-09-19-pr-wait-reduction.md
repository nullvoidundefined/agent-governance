# PR wait reduction: local review first, conditional second Copilot round, bundle PRs

**Ticket:** IAN-122
**Branch:** `feat/pr-wait-reduction`

## Summary

PRs #63 to #68 stayed open between 4 and 29 minutes, and the time went to Copilot round trips rather than CI: each extra round costs about ten minutes of fix, push, CI, and re-review, and two of the second rounds were about PR-description wording. This PR puts the owner's four decisions from IAN-122 into the harness. A session now runs a local code review on the diff before it opens a PR, requests a second Copilot round only when the first round changed behavior, and starts its next ticket while CI and Copilot run instead of blocking on polls. R-512 gains an opt-in bundle exception, so 2 to 5 small related tickets can share one PR, one CI run, and one Copilot pass while each ticket still lands as exactly one commit on `main`. `git-workflow-guard.sh` enforces the bundle conditions before it lets a rebase merge through.

## What changed

- `claude/CLAUDE.md`: the R-512 norm line names the bundle exception (label `bundle`, 2 to 5 small related tickets, one commit per ticket with its own conventional subject and `Refs:` trailer, rebase-merged) and the change kinds that never bundle (deletion, security, sync, migration). It stays one line.
- `claude/rulebook/reference.md`: R-512 gains a Spec describing the default squash path, the bundle exception, the excluded change kinds, the repository setting a bundle needs, and the rule that merge commits are never allowed; its Enforcement line describes exactly what the hook checks. R-514's Spec gains three imperatives: run `/code-review` (or a fresh reviewer subagent given only the diff) before opening a PR and fix its findings test-first, request a second Copilot round only after a behavior change, and start the next ticket while CI and Copilot run. R-515 is unchanged.
- `claude/skills/task-cleanup/SKILL.md`: a six-step PR loop under "If on a feature branch" states the same process where a session runs it, including the bundle option.
- `claude/hooks/git-workflow-guard.sh`: `--merge` and `-m` stay denied. `--rebase` and `-r` (including bundled short flags such as `-dr`) now run `gh pr view <n> --json labels,commits` and pass to the R-514 ask only when the PR carries the `bundle` label and every commit message has a `Refs: [A-Z][A-Z0-9]+-[0-9]+` line naming a ticket no other commit names. Every other outcome denies with a reason naming the missing condition. `CLAUDE_GH_CMD` replaces `gh` for the fixture, following the `CLAUDE_RUBOCOP_CMD` pattern, and `CLAUDE_GH_TIMEOUT_SECONDS` (default 15) bounds the call.
- `claude/enforce/tests/git-workflow-guard.test.sh`: stubbed cases for the bundle exception, the fail-closed paths, the flag spellings, PR selection, and the env-prefixed merge.
- `claude/enforce/manifest.json`, `claude/enforce/hook-hashes.txt`, and the `codex/` and `cursor/` ports are regenerated to match.

## Architectural decisions

- **Verify the bundle through `gh pr view` at merge time, chosen over trusting a flag in the command or a local `git log`.** The label and the commits that will land live on GitHub, and a local branch can differ from the PR head. The alternative of accepting any `--rebase` on a branch named `bundle/*` would let a name stand in for the conditions the rule actually cares about.
- **Fail closed on every uncertain path.** A `gh` that errors, hangs past the deadline, or returns JSON that is not the expected shape denies. So does a command that runs `cd`/`pushd` or sets `GH_REPO`/`GH_HOST`, because the hook would be checking a different PR from the one the command merges. The alternative, resolving the `cd` target and following it, is more parsing for a case a session can avoid by running the merge from the repository's own directory.
- **A bounded, polled `gh` call, chosen over relying on the harness's hook timeout.** A PreToolUse hook that the harness kills prints nothing, and an empty output is an allow, so relying on the outer timeout would fail open. The poll loop follows the one in `verification-gate.sh` rather than a `sleep N` watchdog, for the orphaned-sleep reason recorded there.
- **Distinct `Refs:` keys per commit, added after the local review.** R-605 already puts a `Refs:` trailer on every commit, so "every commit has a trailer" alone would let a single-ticket branch with fixup commits rebase onto `main` just by adding the label. Requiring distinct keys ties the check to "one commit per ticket".
- **Size (2 to 5) and change kind stay manual.** A commit count check is cheap, but whether a change is "small" or touches security cannot be read from the PR metadata, so the hook checks only what it can decide and the Spec says so.
- **Product repositories stay squash only for now.** `repo-setup` disables rebase merging on the repositories it configures. Changing that default is a separate decision for the owner, so the R-512 Spec states that a bundle in such a repository needs rebase merging enabled first. This repository already allows it.

## Testing

- Red first: the bundle-allowed case (`gh pr merge 42 --rebase` against a stub returning the `bundle` label and a `Refs:` trailer on every commit) failed with `deny` where `ask` was expected, before the hook changed. After the local review, the `-r` case failed with `ask` where `deny` was expected, and the `GH_REPO=... gh pr merge` case failed with no decision at all, before the fixes.
- Green: `claude/enforce/tests/git-workflow-guard.test.sh` covers bundle plus all trailers (ask), no label (deny, reason names the label), a commit without a trailer line (deny, reason names `Refs:`), `gh` failure and unparseable output (deny), no PR number (deny when `gh` fails), `--merge`, `-m`, `-dm`, and `--merge --rebase` (deny), `-r` and `-dr` on a non-bundle (deny), `-r` on a bundle (ask), PR selection that skips a flag value and forwards `-R`, `cd` and `GH_REPO` prefixes (deny), two commits naming one ticket (deny), a hung `gh` cut off at a one-second deadline (deny in under ten seconds), `--squash` without consulting `gh` (ask), and an env-prefixed squash merge still reaching R-514 (ask).
- `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh` pass, `shellcheck --severity=error` is clean, and `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` report the ports current.

## Local review

This PR applied the new process to itself: `/code-review` at medium effort ran on the branch diff before the PR opened. It reported four findings, all real, and each was fixed with a failing case first:

1. The strategy check matched only `--merge` and `--rebase`, so `gh pr merge 42 -r` skipped the bundle check and `-m` skipped the merge-commit deny. The gap predated this PR (the 2026-08-21 engineering audit P2-4), but the new "fail-closed" wording made it a false claim. The hook now parses the merge arguments into tokens, including bundled short flags.
2. A `cd` inside the command moved the merge to another repository while the hook checked the PR in the session's directory. The hook now denies a bundle rebase when the command runs `cd`/`pushd` or sets `GH_REPO`/`GH_HOST`. While testing this, the env-prefixed form turned out to skip the hook entirely, which also bypassed the R-514 ask for any `GH_REPO=... gh pr merge`; the entry pattern now accepts leading assignments.
3. The `gh pr view` call had no timeout, and a hook killed by the harness timeout allows the command. The call now runs under a polled deadline.
4. Commits all naming the same ticket passed the trailer check. Keys must now be distinct.

Copilot was requested on this PR but did not review it, because the account's Copilot review quota is exhausted (PR #68 received a quota notice and PR #69 received no review). The local `/code-review` pass above stood in for the Copilot round, and the PR merged on green CI without a Copilot review.

## Reflection

The first version treated "every commit has a `Refs:` trailer" as the whole bundle condition, and it took the review to point out that R-605 already makes that true of almost every branch, so the check proved nothing on its own. The more useful lesson is that the local review earned its place on the first PR it ran on: all four findings would otherwise have arrived as Copilot comments, each costing a round.
