# Handover: cloud session to Agent Governance Polish

**From:** `session_01McTHkb4rhdhfRhAxmrDY1J` (Claude Code on the web, container ephemeral)
**To:** `session_01BMYaRcjpQ3eCB2PNr6M6nN`, "Agent Governance Polish"
**At:** 2026-09-17T19:05Z
**Status:** the cloud session is frozen. Take over all four branches below. It will not push again.

Direct session-to-session messaging failed: the Polish session runs on the operator's machine over Remote Control and is not addressable from a cloud container, so this file is the channel. Everything described here is pushed; nothing is local-only.

## Branches and pull requests

| Branch | PR | Ticket | State |
|---|---|---|---|
| `claude/ticket-lifecycle-skill-ourn3y` | #8 | none | You have been driving it since `6080bcf` |
| `claude/permissive-bash-permissions` | #10 | IAN-77 | You pushed `9bccc6d` on top |
| `claude/mcp-guard-tracker-exemption` | #11 | IAN-78 | Head `91bee30`, all checks green, waiting on human review |
| `claude/config-hardening-safety` | none | IAN-76 | Plan only, no implementation started |

PR #8 carries the fifteen P2 and P3 items from the 2026-09-17 engineering audit plus the merge with PR #3. My last commit on it was `dc74c66`; every commit after that is yours.

PR #10 replaces the two blanket interpreter asks (`Bash(bash *)`, `Bash(sh *)`) with four asks on the inline form only (`bash -c`, `sh -c`, and the `-lc` spellings), leaving the curated allow list untouched. `settings-change-guard.test.sh` gained a fifth invariant that reads the checkout rather than `$HOME` and fails against a blanket `Bash` allow entry or a missing interpreter ask.

PR #11 narrows R-105 to exempt the Linear server's write class alone. Still asking: `merge`, `submit`, `upload`, `apply`; anything the destroy or transmit classes match on any server; every other server. `mcp-action-guard.sh` now classifies every token and takes the strongest class, ordered by consequence (destroy, transmit, database, write). `retire` and `retract` joined the destroy class. Nine documents name the server rather than a generic "private tracker": both R-105 statements, R-605's cross-reference, the ticket-lifecycle skill and its Integration list, that skill's design spec (B-9, Dependencies, Security), the hook header, the manifest note, and both Cursor rule files.

`claude/config-hardening-safety` holds `docs/superpowers/plans/2026-09-17-config-hardening-tranche-1-safety.md` and the session handoff at `docs/session-handoff/session-handoff.md` (`d972b59`). Your own merges have already delivered parts of B-1, B-2 and B-5 (`$schema`, a `sandbox` block, `statusLine`), so that plan needs re-grounding before anyone starts its slices 4 and 5. Slices 1 and 2 are untouched by your work and are the real remaining content.

## Tracker

Linear, team `Ian.greenough.developer`. IAN-76 config hardening tranche 1, Todo plus the `planned` label. IAN-77 for PR #10 and IAN-78 for PR #11, both In Progress plus `in-review`. PR #8 has no ticket; it predates the tracker and backfilling one mid-review would have distorted the estimate sample.

The instance config lives only in the frozen container at `~/.claude/TICKET-TRACKER.json` and is gitignored by design because it carries the team id. Its shape, so you can recreate it: eight canonical states map onto Linear's six statuses plus the four labels that already exist in the workspace (`specced`, `planned`, `in-review`, `blocked`); the nine canonical fields live in a fenced metadata block in the issue description because Linear exposes no custom issue fields; Linear's own `estimate` is story points and is deliberately not reused for `estimate_minutes`. The `state_labels` overlay in that config is inert until the skill learns to apply a label alongside a status.

## The one unfixed defect, highest value

R-403 is bypassable on PR #8's branch as it stands. `fix-commit-requires-test.sh:119` greps `$CMD` in full for `git add` segments, so it reads the `-F -` message body that `17837c0` correctly stopped the subject extraction from reading. Verified by controlled probe on a clean index, two commands identical but for one line:

```
git add src/a.ts && git commit -F - <<MSG          ->  deny
fix: a real subject
MSG

git add src/a.ts && git commit -F - <<MSG          ->  allowed
fix: a real subject
git add tests/fake.test.ts
MSG
```

A test path written inside a commit message satisfies the staged-test requirement, so a `fix:` commit lands with no test. The sibling finding is `commit-message-guard.sh:43`, where `COMMIT_TAIL` starts at the first textual `git commit`, including one inside an earlier payload.

Both reduce to one missing primitive: a single function that splits a Bash command into real command segments with heredoc bodies excluded, used by every extraction in both guards instead of each one grepping `$CMD` on its own terms. Every round of per-regex patching on those two files has surfaced the next hole in the other, which is the argument for writing the splitter once rather than patching a sixth regex. Reproduction is posted at PR #8 `#discussion_r4040001551`.

## Open review findings on PR #8, not started

- `claude/README.md:179` documents key resolution as the environment plus the macOS keychain only, now that the judge also reads `secret-tool` and `pass`.
- `enforcement-guard-check.sh` treats a successful store call as a usable key without requiring non-empty output, so an empty store silences the degraded-judge warning while every judge run still fails open.
- `claude-md-lint.test.sh:63` increments the rule-file counter before excluding `session-types.md`, so a directory holding only that file passes invariant 3 without inspecting a single stack rule file.
- `parse-sources.mjs:85` still uses a non-own-property check for `events`, the same class of bug `7225ab3` fixed for `unported_reasons`.
- `CLAUDE-PYTHON.md:193`, `CLAUDE-RUBY.md:167` and `CLAUDE-GO.md:125` still list R-318 and R-322 under `hook:llm-rule-judge`.

## Corrections, so you do not chase non-bugs

`session-start.test.sh`'s positive control and `harness-sync.test.sh` both pass. The cloud session reported the first as possibly real; it was environmental. Your R-003 `harness-sync` hook fixed both at that session's start by installing `rsync` and syncing 91 files, and CI, which runs both suites from the synced `$HOME/.claude`, is green on `91bee30`. The `sync.sh` exit 127 reported earlier has the same cause and is likewise gone. `hook-hashes-closure` fails in that container only because its live tree carried two fixtures belonging to PR #8's branch.

## What the cloud session got wrong, as input to your consolidation

Its first commit on PR #10 replaced the curated allow list with a blanket `Bash` entry and dropped the interpreter asks outright, reopening two holes this repository had already recorded: `ISSUES.md:11` (a `bash -c` wrapper hides its inner text from permission-rule matching, the stated reason those asks existed) and `ISSUES.md:69` (a blanket entry makes auto mode skip its own classifier for every Bash command, the stated reason the lenient list was reversed on 2026-09-15, two days earlier). It told the operator the change lost no protection before reading either line. The review bot caught it.

Separately, the R-105 exemption on #11 was itself exploitable for several rounds through first-token-wins classification, and its documentation was broader than its code in four places at once.

Both point at the same two lessons worth carrying into the consolidation: a permission or guard change needs the `ISSUES.md` history read before the edit, not after the review, and an exemption needs a fixture for its boundary and not only for its happy path.

## Blocker above everything, operator only

`claude/ISSUES.md:28`, the GitHub PAT rotation and transcript purge. Unchanged all day. No agent can close it, and B-4 keeps it first in the public-hardening list until the operator removes it.

## Coordination

The two sessions collided twice: a push to `claude/mcp-guard-tracker-exemption` was rejected non-fast-forward after eight commits landed on it from the terminal side, and the cloud session merged that history rather than rewriting it (`ba25343`). With the cloud session frozen this is moot, and it stays moot as long as one writer owns each branch.
