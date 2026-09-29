# Scoped Codex approval consumption

Ticket: IAN-506. Tier: Complex. Merge mode: owner review before merge.
Status: design review found blockers; complete B-0 before authorizing implementation.

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

## Spec review

Fresh Codex review found six blockers. No implementation or live installation has
occurred. Resolve these in the design and tests before approving implementation:

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
