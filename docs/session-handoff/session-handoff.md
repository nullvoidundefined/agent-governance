# Session handoff: scoped Codex approval, 2026-09-30

## 1. Last commit

- `f44510a` (`chore(approval): refresh shared translator fingerprint`) is pinned by the published `keep/codex-approval-verified` tag. This handoff is the following bookkeeping commit.
- IAN-506 is on `fix/codex-scoped-approval`, with draft [PR #167](https://github.com/nullvoidundefined/agent-governance/pull/167).

## 2. Production state verified

- The new approval adapter has not been installed live or merged. The existing live governance source remains the separate release branch associated with PR #166.
- An isolated Codex CLI 0.158.0 probe verified real UserPromptSubmit-before-PreToolUse delivery with matching session and turn identities. A workspace-write sandbox tool could not write the runtime-owned probe directory; the trusted metadata hook could. No approval grants were created by the probe.
- This establishes the tested CLI boundary, not equivalent behavior in every desktop or hosted surface. No global allow policy or guard bypass was enabled.

## 3. Session metrics

- Commits this session: 14
- Files changed: 16
- Files revisited (touched by 2+ commits): 4
- Velocity flag: NORMAL
- Metrics were captured before this handoff commit. Calendar time includes approval waits and must not be reported as attributable working time.

## 4. What shipped on the branch

- IAN-506: literal MCP asks record one pending action, receive direct runtime approval, and permit one matching retry. Arguments, directory, session, asking-hook groups, and reasons remain bound to consent. Hard denials still win.
- Approved groups share one original request and reserve consumption to one retry ID. Prompt replay, unrelated prompts, changed inputs, expiry, unsafe state, helper failures, and lock timeouts fail closed.
- Helper output must contain exactly one JSON object. A real persistence failure is covered with an OS file-size limit, and unknown groups are tested while approved slots remain available.
- Generated configuration includes an additive UserPromptSubmit listener. Generated metadata retains the helper, and isolated release sync verifies installation into temporary homes.
- Four approval fixtures and 161 surrounding fixtures passed the final full harness and role validation. Targeted Python enforcement, both port freshness checks, and slice reviews passed. Check remote CI on PR #167 at its current head before treating delivery as complete.
- Bash and file-edit asks retain their prior policy. Shell command text cannot safely bind mutable external inputs by itself.

## 5. Pending work

- IAN-506: finish remote CI and the current-head PR review. Obtain the required security review on the configured model before merge or live installation. Do not silently substitute or waive that gate. Earlier attempts found the configured Claude review account quota exhausted; verify availability before relying on it.
- IAN-501: [PR #166](https://github.com/nullvoidundefined/agent-governance/pull/166) has the earlier governance release, an approved current-head Codex review, and previously green Linux/macOS CI. Its merge and public release remain pending. The owner already authorized that work; do not ask for those approvals again.
- IAN-187: relative worktree paths can resolve against the default session repository. Explicit absolute file targets avoided the observed scope misattribution; this branch does not fix that separate issue.
- Preserve older pending-work history in the [published pre-release handoff](https://github.com/nullvoidundefined/agent-governance/blob/keep/governance-pre-release-handoff/docs/session-handoff/session-handoff.md). This shorter handoff does not mark those tickets complete.

## 6. Recommended next session

- Read the IAN-506 spec, `codex/hooks/codex-hook-adapter.sh`, `codex/hooks/approval-state.py`, the four `codex-approval-*.test.sh` fixtures, and PR #167 before changing behavior.
- Check the current PR head and CI results, then finish the required reviews and delivery gates. Keep IAN-506 open until actual delivery is verified.
- Resume IAN-501 after its remaining merge/release blockers are resolved. Preserve existing owner approvals and distinguish runtime execution restrictions from new requests for consent.
