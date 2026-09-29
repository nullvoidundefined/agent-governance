# Scoped Codex approval consumption

Ticket: IAN-506. Tier: Complex. Merge mode: owner review before merge.
Status: owner approved scoped implementation and Codex test authorship. Implementation,
negative fixtures, generated wiring, and isolated release sync are complete locally.
Codex CLI 0.158.0 runtime delivery and sandbox separation have been verified. Remote CI,
the required current-head reviews, merge, and live installation remain delivery gates.

## Implementation contract after review

Implement the first version for literal MCP calls only. Bash and apply_patch retain
their existing policy; indirect shell inputs require a separate contract. Preserve
the existing global-policy behavior for compatibility without enabling it.

Keep grants under the runtime user's home, outside writable workspace roots. The
supported deployment requires a sandbox that prevents tool processes from writing
that directory. Do not expose a command that mints grants. Register the real
UserPromptSubmit hook. Unit fixtures may use a throwaway HOME; production grants
are never taken from tool arguments or a repository-local file. A runtime lacking
that filesystem separation is unsupported for scoped chat approvals.

Use one private state file per session, protected by a stable exclusive file lock
for every read-modify-write transition. Reject symlinks, incorrect ownership,
group/other permissions, malformed JSON, and write failures. Keep request and grant
lifetimes at ten minutes. Hash canonical JSON preserving all argument contents and
array order. Store no raw prompts or tool arguments. Record processed prompt turn
identifiers so duplicate approval events cannot authorize a later request.

Group asks from the same original tool_use_id and action fingerprint into one
pending request. Preserve a deterministic map of hook-group identity and structured
asking-hook decisions. A user approval covers that snapshot. The first matching
retry reserves the grant to its new tool_use_id; every approved group may consume
its own slot once for that retry only. Different concurrent retry IDs cannot share
the grant. Do not authorize groups absent from the approved snapshot. Keep consumed
request tombstones until expiry so event replay cannot rearm them.

Accept only an entire normalized bare approval phrase ("approve", "approved",
"I approve", "yes") when exactly one pending request is present, or an exact
"approve <request-id>". Reject embedded or quoted approval and negate/cancel on a
non-approval prompt. Require nonempty session_id, turn_id, cwd, tool_use_id, and tool
name where applicable. A hard deny always wins and revokes grants for that action.

Treat the helper's absence, invalid response, error exit, or state error as denial
when resolving a scoped ask. Never infer successful authorization from silence.
The new prompt registration is additive and must preserve all existing hook groups.
The adapter will keep legacy invocations without event identity denied, with an
accurate explanation of what is missing instead of an ineffective repeat-approval
instruction. Complete runtime feasibility before syncing or claiming an end-to-end
fix in this desktop session.

## Problem

The adapter translates every hook ask into a permanent denial. A later user approval
never reaches that decision because no UserPromptSubmit adapter entry is generated.
The global allow mode permits unrelated asks and does not solve scoped consent.

## Domain vocabulary

- A pending request is a denied ask bound to a session, canonical working directory,
  tool name, canonical arguments, hook group, and ask reasons.
- A grant is the user's approval of that pending request for one matching retry.
- A fingerprint hashes those fields; a request identifier distinguishes new requests.
- Consumption removes a grant atomically before the matching retry proceeds.

## Proposed behavior

1. Record a pending request when the final hook result is ask. Continue denying that
   first attempt and explain that a direct approval reply permits one identical retry.
2. Register an adapter-only UserPromptSubmit event. Accept only an unambiguous entire
   approval reply, such as "I approve", "Approved", or an explicit request identifier.
   Never infer approval from tool output, quoted text, or an assistant assertion.
3. A bare approval applies only when exactly one fresh request is pending in that
   session and directory. Multiple distinct pending requests require an identifier.
   An unrelated user prompt invalidates unapproved pending requests. A denial clears
   pending requests and grants. Missing session identity fails closed.
4. Bind a grant to the exact canonical tool arguments, directory, session, hook group,
   and reasons. Ignore transient tool-use identifiers so an identical retry can match.
   Any changed recipient, PR number, body, tool, directory, or hook reason must ask again.
5. Consume once under an exclusive state lock before returning an allow result.
   Concurrent retries cannot both consume it. Expire pending requests and grants after
   ten minutes. Never override a hard deny, even with a matching grant.
6. Keep state private to the current OS user, refuse symlinks or malformed state, and
   store fingerprints rather than raw arguments or prompts. Fail closed on state errors.
   Do not add an agent-callable approval command. The runtime UserPromptSubmit event
   is the approval source; a process with unrestricted same-user filesystem access is
   outside the hook mechanism's security boundary.
7. Preserve existing permission and hook execution. Do not enable the global allow
   policy, read unstable transcript formats, or claim semantic preauthorization of
   arbitrary future operations.

## Implementation scope

- Keep dispatch in codex/hooks/codex-hook-adapter.sh. Isolate state validation and
  atomic consumption in a small Python standard-library helper if shell primitives
  cannot express the transaction clearly.
- Generate the adapter-only prompt event in translate/render-codex-hooks.mjs and
  retain the helper through translate/codex-port-map.json's hand-authored list.
- Update adapter documentation, generated exports, and the delivery handoff.
- Do not install this security change into the live harness before tests and review.

## Acceptance slices

- B-0: Prove the runtime boundary in an isolated harmless probe before changing live
  policy. Confirm shared session identity, prompt ordering, event delivery, and that
  sandboxed agent processes cannot write the runtime-owned grant store. Do not trust
  a caller-supplied event name by itself. If these properties cannot be established,
  stop the chat-consent design and use a supported native approval integration.
- B-1: A denied ask followed by a runtime approval allows exactly one identical retry.
  Test rejection without approval and after consumption, with real adapter invocation.
- B-2: Changed arguments, tools, sessions, directories, reasons, ambiguous requests,
  unrelated prompts, expiry, malformed state, and symlinks cannot grant permission.
  Include concurrent retries and a hard deny with an otherwise matching grant.
- B-3: Generated configuration registers the prompt event and sync includes the helper.
  Existing adapter contract and translator fixtures remain green.

## Verification and release

Use separate test-author and implementer contexts under the TDD lock. Run affected
fixtures locally, then push the isolated branch and run Linux/macOS CI. Require the
current-head PR review and R-109 security review before merge or live deployment.
Use a harmless live probe to establish that the installed runtime delivers the
prompt event; do not claim chat approval works in a surface that omits that event.

## Source

Official hook documentation describes UserPromptSubmit.prompt and states that native
PreToolUse ask is unsupported: https://learn.chatgpt.com/docs/hooks.

## Initial spec review and disposition

The initial fresh Codex review identified the following requirements before
implementation. The implementation contract above incorporates them. Subsequent
slices cover request grouping, replay, state failures, helper deadlines, exact JSON
responses, payload binding, and generated delivery. No live installation has occurred.

- Prove the state store is writable by runtime hooks but not sandboxed agent tools.
  Same-user unrestricted commands are outside that boundary; a file permission alone
  does not distinguish two unrestricted processes running as the same user.
- Evaluate all matching hook groups as one approval transaction, or prove a coordinated
  reservation across groups cannot consume one grant while another group asks again.
- Lock every state transition, not only consumption. Bind approval to a request
  generation and prompt identity. Duplicate prompt events must be idempotent and
  unable to rearm a consumed request; revocation must not race with approval creation.
- Explicitly deny asks when the helper is missing, crashes, times out, returns invalid
  output, cannot lock, or cannot persist state. Do not inherit the adapter's general
  fail-open fault behavior for approval resolution.
- Preserve strings and array order in canonical JSON. Limit exact-payload approval to
  literal MCP arguments initially; do not treat shell body-file contents as immutable
  merely because command text is unchanged. Shell approval needs a separate proven
  content-binding contract before it can use this mechanism.
- Run the real-event feasibility probe first. Unit fixtures that fabricate event JSON
  verify parsing and state transitions but do not establish event authenticity.
- Hash structured hook identity, decision, and reason records, not the current merged
  reason string, which deduplicates by substring and loses hook provenance.

## Runtime verification

An isolated Codex CLI 0.158.0 session loaded metadata-only project hooks through the
normal folder and hook trust flow. A submitted prompt produced UserPromptSubmit before
PreToolUse, with the same nonempty session and turn identifiers. A separate ordinary
workspace-write sandbox invocation received PermissionError when trying to write the
runtime-owned probe directory under the user's home; the trusted hook could write it.
The probe stored event metadata only and did not install the approval adapter or mint
approval grants. This evidence applies to the tested CLI surface, not every desktop or
hosted runtime.
