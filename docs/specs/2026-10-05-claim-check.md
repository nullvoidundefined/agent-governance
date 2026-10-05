# Hardening PR 5: completion-claim check

Plan: hardening control 6 (verification honesty), approved by the owner
2026-10-04 ("include the claim check"). Sibling specs:
`docs/specs/2026-10-04-harness-hardening.md`, `2026-10-05-credential-reads.md`,
`2026-10-05-audit-log.md`.

**Risk:** standard. A turn-end check on the model's own prose; it touches no
authentication, secret, production data or trust boundary. The owner can
override.

## Goal

A turn that claims something was verified, fixed, or passing must point at a
command that actually ran in that turn, or say plainly that it did not run.
This is the "then reports it verified everything" half of the incident.

## Why this differs from the removed gate

PROTOCOL.md records removing a turn-end verification gate (#182 to #188: 320
blocks, no product catch). That gate ran tests. This one runs nothing: it
compares the final message against the turn's own tool calls, costs
milliseconds, and fires only on claim words.

## Definitions

- **Turn:** the transcript entries after the last entry that is a genuine user
  message (type `user` whose content is text, not a `tool_result`).
- **Commands run:** the `command` input of every Bash `tool_use` in the turn.
- **Claim:** a case-insensitive match in the final assistant message, outside
  fenced code blocks, of: `verified`, `confirmed`, `fixed`, `tests? pass`,
  `passes`, `passed`, `passing`, `is working`, `now works`, `works now`,
  `deployed`, `all good`, `is green`, `are green`, `turned green`.
- **Citation:** a backtick span in the final message that is a substring of a
  command run, at least 6 characters long, or a backtick span equal to a whole
  command run.
- **Hedge:** `assumed`, `not verified`, `unverified`, `did not run`, `not run`,
  `not rerun`, `not re-run`, `reported by`, `per the`.

## Acceptance criteria

- V-1: a Stop hook `claim-check-guard.sh` blocks the stop when the final
  message holds a claim, holds no citation, and holds no hedge. The block
  reason says: cite the command you ran (in backticks) and its result, or say
  "assumed, not run".
- V-2: it passes when there is no claim, when there is a citation, or when
  there is a hedge.
- V-3: claim words inside fenced code blocks, and in the phrases `working on`,
  `works by`, `how it works`, `fixed-width`, `fixed point`, do not count.
- V-4: it reads `last_assistant_message` from the payload when present, else
  the transcript tail; it reads Bash commands from the transcript's current
  turn only (a command from an earlier turn is not a citation).
- V-5: the same hook is registered on SubagentStop and applies the same check
  to a subagent's final message against that subagent's transcript
  (`agent_transcript_path` when present, else `transcript_path`).
- V-6: it fails open: `stop_hook_active` true, a missing or unreadable
  transcript, no `jq`, or a malformed payload exits 0 with no output. It never
  blocks twice in one turn.
- V-7: a fixture corpus (`claude/enforce/tests/fixtures/claim-check/`) holds
  at least 15 block cases and 15 pass cases, including the V-3 phrases and a
  citation of a command from a previous turn (block).
- V-8: it is registered after `turn-summary-guard.sh` under Stop, with a
  timeout of 10 seconds, and its runtime on a 5 MB transcript is under 300 ms.
- V-9: Codex and Cursor ports are marked unported with the reason (no Stop
  event in their adapters), as `turn-summary-guard.sh` is.

## Review r1 amendments (2026-10-05)

- V-10: the trailing `Done:` / `Decide:` / `Next:` summary lines (bold or
  plain, as `turn-summary-guard.sh` reads them) are removed before the claim
  search; a claim word there never blocks.
- V-11: a `user` entry is not a turn boundary when it has `isMeta` or
  `isCompactSummary` true, or its text starts (after whitespace) with
  `<task-notification`, `<system-reminder`, `<command-`, `Stop hook feedback`,
  `[SYSTEM NOTIFICATION`, or `Another Claude session sent a message`.
- V-12: citable inputs are Bash `command`, and Read/Grep/Glob `file_path`,
  `path` and `pattern` values, all from the current turn.
- V-13: the claim words `fixed` and `passes` count only in claim forms:
  `is|are|was|were|now|been fixed`, `fixed it|this|that|the|in`, and
  `now passes`, `passes now`, `test passes`, `suite passes`, `check passes`.
  Plain `fixed list`, `fixed-width`, `passes the value` do not count.
- V-14: the runtime limit is 300 ms on a 5 MB transcript measured as the best
  of three runs, and the hook reads only the transcript tail back to the last
  turn boundary (bounded read), not the whole file.
- Accepted (no change): when `turn-summary-guard.sh` blocks first, the retry
  carries `stop_hook_active` and the claim check fails open for that turn.

## Bypass (accepted)

The model can run a trivial command and cite it. The check catches
unsupported claims, not dishonest ones; the audit log (PR 4) is the record
for that.
