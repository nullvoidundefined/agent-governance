#!/usr/bin/env bash
# Shard: slow
# Covers: hook:protected-path-guard
#
# The contract the REAL codex/hooks/codex-hook-adapter.sh owes the gates. Every
# other fixture in this tree exercises a hook directly; nothing exercised the
# adapter that stands between Codex and those hooks, and the 2026-09-18 port
# audit found two holes behind that gap:
#
#   1. The adapter sourced enforce/settingsPermissionRules.sh, a file that has
#      never existed in this repository, with `2>/dev/null || true`, and then
#      guarded every use of it with `type matching_bash_rule`. The whole
#      mirrored permissions layer was therefore inert: a settings.json rule
#      denying a command passed through the adapter with exit 0 and no output,
#      which Codex reads as allow, while PORT-STATUS.md advertised the layer as
#      ported.
#   2. The apply_patch replay dropped `*** Delete File:` and `*** Move to:`
#      lines on the floor, so deleting a file dispatched no hook event at all
#      and a rename's destination was never shown to any guard. R-410's locked
#      tests could be deleted, and a file could be renamed into a protected
#      tree, with the gates none the wiser.
#
# A live Codex probe on 2026-09-18 found the third, one door narrower: asked to
# edit a file, Codex often writes it with a shell redirection rather than with
# apply_patch, and that arrives as a single PreToolUse Bash event carrying a
# command string and no path. The gates Codex registers on the Write|Edit
# matcher (structure-gate, content-gate, dependency-add-guard, and the rest)
# therefore never saw the file at all, so the same edit was denied through
# apply_patch and allowed through `printf ... > path`. Section 3 below drives
# the real adapter with the shell constructions that write a file and asserts
# both halves: that a target is extracted, and that the real
# protected-path-guard, reached ONLY through the synthetic write event, denies
# it. The guard is deliberately kept out of the Bash-side hook list in those
# cases, because protected-path-guard carries a redirection extractor of its
# own; leaving it in would let the guard's own parsing pass a case the adapter
# had not fixed.
#
# Both holes look fine in a unit test of the hooks and fine in a unit test of a
# stub adapter. They are only visible end to end, so this fixture runs the
# actual adapter script, in a hermetic sandbox, with a synthetic settings.json,
# a synthetic recording hook, and (for the two protected-path cases) the real
# protected-path-guard.sh copied in beside it.
#
# Hermetic: HOME, CLAUDE_HOME, the settings file, the role policy, the state
# directory and the working tree all live under one mktemp sandbox that is
# removed on exit. Nothing here reads or writes the installed ~/.claude.
#
# What this does NOT assert: that Codex itself sends the payloads used here.
# The payload shapes are the ones the adapter's own header documents, and if a
# Codex release changes them this fixture keeps passing while the port breaks.
set -uo pipefail

REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
ADAPTER="$REPO_TOP/codex/hooks/codex-hook-adapter.sh"
PERMISSION_RULES_SOURCE="$REPO_TOP/claude/enforce/settings-permission-rules.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
# not <cmd...>: negates a command's exit status. A bare "!" loses its reserved
# word status once it travels through check()'s "$@" expansion, so negated
# checks route through this wrapper instead.
not() { ! "$@"; }

[ -f "$ADAPTER" ] || { echo "FAIL: no adapter at $ADAPTER, so this fixture proved nothing"; exit 1; }

# --- the sandbox ---------------------------------------------------------------

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/codex-adapter-contract.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX_HOME="$SANDBOX/home"
SANDBOX_CLAUDE="$SANDBOX/claude"
WORK="$SANDBOX/work"
EVENT_LOG="$SANDBOX/events.log"
mkdir -p "$SANDBOX_HOME" "$SANDBOX_CLAUDE/hooks" "$SANDBOX_CLAUDE/enforce" "$WORK/.claude" "$WORK/tests" "$WORK/src"
: >"$EVENT_LOG"

# The rules the adapter must mirror. Deliberately boring commands: a fixture
# that denies a real destructive command would be one editing mistake away from
# running it.
cat >"$SANDBOX_CLAUDE/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(echo *)"],
    "deny": ["Bash(echo audit-denied*)", "Read(//**/.env)"],
    "ask": ["Bash(echo audit-ask*)"],
    "defaultMode": "auto"
  }
}
EOF

[ -f "$PERMISSION_RULES_SOURCE" ] && cp "$PERMISSION_RULES_SOURCE" "$SANDBOX_CLAUDE/enforce/settings-permission-rules.sh"
cp "$REPO_TOP/claude/enforce/role-policy.json" "$SANDBOX_CLAUDE/enforce/role-policy.json"
cp "$REPO_TOP/claude/hooks/protected-path-guard.sh" "$SANDBOX_CLAUDE/hooks/protected-path-guard.sh"
cp "$REPO_TOP/claude/hooks/log-rule-fire.sh" "$SANDBOX_CLAUDE/hooks/log-rule-fire.sh"
cp "$REPO_TOP/claude/hooks/codex-test-author-guard.sh" "$SANDBOX_CLAUDE/hooks/codex-test-author-guard.sh"
chmod +x "$SANDBOX_CLAUDE/hooks/protected-path-guard.sh"
chmod +x "$SANDBOX_CLAUDE/hooks/codex-test-author-guard.sh"

# The synthetic hook: records every payload the adapter dispatches to it and
# decides nothing, so a case can assert what the gates were shown.
# One line per dispatch, so a case can count events as well as read them.
# Each line also carries hook_runtime, the CLAUDE_HOOK_RUNTIME this hook child
# saw in its own environment, so section 4 can assert the marker the guards read
# rather than the marker the adapter says it sets.
cat >"$SANDBOX_CLAUDE/hooks/record-calls.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
payload=$(cat 2>/dev/null || true)
printf '%s' "$payload" \
  | jq -c --arg runtime "${CLAUDE_HOOK_RUNTIME-}" '. + {hook_runtime: $runtime}' \
    >>"${ADAPTER_EVENT_LOG:-/dev/null}" 2>/dev/null
exit 0
EOF
chmod +x "$SANDBOX_CLAUDE/hooks/record-calls.sh"

# A repository with a red slice whose test file is locked, so the real
# protected-path-guard has something to protect.
# The locked spec carries a space in its name on purpose: a path with a space
# is exactly what a regex over raw command text gets wrong, so it is the case
# that separates extracting a target from guessing at one.
mkdir -p "$WORK/docs"
env HOME="$SANDBOX_HOME" git init -q "$WORK" >/dev/null 2>&1
printf 'locked\n' >"$WORK/tests/locked.test.sh"
printf 'widget\n' >"$WORK/src/widget.ts"
printf 'spec\n' >"$WORK/docs/my spec.md"
cat >"$WORK/.claude/tdd-lock.json" <<'EOF'
{"slice": "contract-fixture", "phase": "red", "tests": [{"path": "tests/locked.test.sh"}], "locked": ["docs/my spec.md"]}
EOF

# --- driving the adapter -------------------------------------------------------

ASK_POLICY="deny"
# The CODEX_TEST_GUARD value run_adapter passes down. It is "off" for every
# case that is not about codex-test-author-guard itself, because this fixture
# drives writes into a test tree and that guard exists to stop exactly that;
# section 4b flips it to "on" for the two cases that run the guard for real.
TEST_GUARD="off"
# Which hooks a synthetic write event is shown to. Empty for every case that is
# not about the shell door, so those cases see the Bash event and nothing else;
# section 3 sets it to the one hook that case is asserting about.
WRITE_TARGET_HOOKS=""

run_adapter() {
  # $1 = stdin payload; the rest are hook basenames, exactly as hooks.json
  # passes them. Every path the adapter reads is redirected into the sandbox.
  local payload="$1"
  shift
  # CLAUDE_HOOK_RUNTIME is unset here on purpose: section 4 asserts that the
  # adapter itself marks its hook children, so the ambient environment of
  # whoever runs this fixture must not be able to supply the marker.
  printf '%s' "$payload" | env -u CLAUDE_HOOK_RUNTIME \
    HOME="$SANDBOX_HOME" \
    CLAUDE_HOME="$SANDBOX_CLAUDE" \
    CLAUDE_SETTINGS_FILE="$SANDBOX_CLAUDE/settings.json" \
    CLAUDE_ROLE_POLICY_FILE="$SANDBOX_CLAUDE/enforce/role-policy.json" \
    CLAUDE_CODEX_STATE_DIR="$SANDBOX/state" \
    CLAUDE_CODEX_ASK_POLICY="$ASK_POLICY" \
    CLAUDE_CODEX_WRITE_TARGET_HOOKS="$WRITE_TARGET_HOOKS" \
    ADAPTER_EVENT_LOG="$EVENT_LOG" \
    CODEX_TEST_GUARD="$TEST_GUARD" \
    bash "$ADAPTER" "$@"
}

bash_payload() {
  jq -n --arg c "$1" --arg cwd "$WORK" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}'
}

patch_payload() {
  jq -n --arg p "$1" --arg cwd "$WORK" \
    '{hook_event_name:"PreToolUse", tool_name:"apply_patch", tool_input:{command:$p}, cwd:$cwd}'
}

delete_patch() {
  printf '*** Begin Patch\n*** Delete File: %s\n*** End Patch\n' "$1"
}

move_patch() {
  printf '*** Begin Patch\n*** Update File: %s\n*** Move to: %s\n@@\n-widget\n+widget two\n*** End Patch\n' "$1" "$2"
}

update_patch() {
  printf '*** Begin Patch\n*** Update File: %s\n@@\n-thing\n+thing two\n*** End Patch\n' "$1"
}

add_patch() {
  printf '*** Begin Patch\n*** Add File: %s\n+first line\n*** End Patch\n' "$1"
}

# --- assertions, each a wrapper so no pipeline or redirect rides on check() ----

decision_is() { [ "$(printf '%s' "$2" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)" = "$1" ]; }
reason_mentions() { printf '%s' "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null | grep -qF -- "$1"; }
context_mentions() { printf '%s' "$2" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | grep -qF -- "$1"; }
log_mentions() { grep -qF -- "$1" "$EVENT_LOG"; }
log_has_events() { [ -s "$EVENT_LOG" ]; }
reset_log() { : >"$EVENT_LOG"; }

# --- 1. the mirrored permission rules -----------------------------------------

OUT=$(run_adapter "$(bash_payload 'echo audit-denied now')" record-calls)
check "a settings.json Bash deny rule denies through the real adapter" decision_is deny "$OUT"
check "the deny reason names the settings.json rule that matched" reason_mentions 'echo audit-denied*' "$OUT"

OUT=$(run_adapter "$(bash_payload 'echo nothing to see here')" record-calls)
check "a command matching no rule is not denied" not decision_is deny "$OUT"

OUT=$(run_adapter "$(bash_payload 'echo audit-ask now')" record-calls)
check "an ask rule reaches a decision rather than passing silently" not decision_is "" "$OUT"
check "the default ask policy turns the ask into a deny" decision_is deny "$OUT"
check "the translated ask explains that confirmation is owed" reason_mentions "confirmation" "$OUT"

ASK_POLICY="allow"
OUT=$(run_adapter "$(bash_payload 'echo audit-ask now')" record-calls)
check "the allow ask policy injects the confirmation as context instead" context_mentions "CONFIRM WITH THE USER" "$OUT"
ASK_POLICY="deny"

# The layer's own absence must be loud. A permission mirror that quietly stops
# mirroring is worse than one that was never claimed, because PORT-STATUS.md
# still says the rules are enforced.
mv "$SANDBOX_CLAUDE/enforce/settings-permission-rules.sh" "$SANDBOX/permission-rules.parked" 2>/dev/null || true
OUT=$(run_adapter "$(bash_payload 'echo nothing to see here')" record-calls)
check "a missing permission helper denies rather than allowing" decision_is deny "$OUT"
check "the fail-closed reason names the helper it could not load" reason_mentions "settings-permission-rules.sh" "$OUT"
mv "$SANDBOX/permission-rules.parked" "$SANDBOX_CLAUDE/enforce/settings-permission-rules.sh" 2>/dev/null || true

# --- 2. the apply_patch replay ------------------------------------------------

reset_log
OUT=$(run_adapter "$(patch_payload "$(add_patch 'src/added.ts')")" record-calls)
check "an Add File patch still dispatches an event (no regression)" log_mentions "src/added.ts"

reset_log
OUT=$(run_adapter "$(patch_payload "$(delete_patch 'tests/locked.test.sh')")" record-calls)
check "a Delete File patch dispatches a hook event at all" log_has_events
check "the Delete File event carries the path being deleted" log_mentions "tests/locked.test.sh"

reset_log
OUT=$(run_adapter "$(patch_payload "$(move_patch 'src/widget.ts' 'tests/moved.test.ts')")" record-calls)
check "a Move patch carries the source path" log_mentions "src/widget.ts"
check "a Move patch carries the destination path" log_mentions "tests/moved.test.ts"

# The end-to-end point of the two cases above: a real guard must be able to act
# on what it is shown, not merely receive it.
OUT=$(run_adapter "$(patch_payload "$(delete_patch 'tests/locked.test.sh')")" protected-path-guard)
check "deleting a locked test through a patch is denied (R-410)" decision_is deny "$OUT"
check "the deletion denial names the locked path" reason_mentions "tests/locked.test.sh" "$OUT"

OUT=$(run_adapter "$(patch_payload "$(move_patch 'src/widget.ts' 'tests/moved.test.ts')")" protected-path-guard)
check "renaming a file into a locked test tree is denied (R-410)" decision_is deny "$OUT"
check "the rename denial names the destination, not only the source" reason_mentions "tests/moved.test.ts" "$OUT"

# --- 3. the shell door: a file written by a command, not by a patch -----------

# Runs one shell command through the adapter with the real protected-path-guard
# reachable ONLY as a write-target hook, so a denial can have come from nothing
# but a synthesized write event.
guarded_shell_run() {
  WRITE_TARGET_HOOKS="protected-path-guard"
  run_adapter "$(bash_payload "$1")" record-calls
  WRITE_TARGET_HOOKS=""
}

# Runs one shell command with the recording hook on both doors, so the event log
# holds the Bash event first and then one line per synthesized write event.
recorded_shell_run() {
  reset_log
  WRITE_TARGET_HOOKS="record-calls"
  run_adapter "$(bash_payload "$1")" record-calls >/dev/null
  WRITE_TARGET_HOOKS=""
}

# The file paths the adapter synthesized, one per line, sandbox prefix removed.
logged_write_targets() {
  jq -r 'select(.tool_name == "Write") | .tool_input.file_path' "$EVENT_LOG" 2>/dev/null \
    | sed "s|^$WORK/||"
}

logged_write_target_is() { [ "$(logged_write_targets)" = "$1" ]; }
logged_write_targets_are() { [ "$(logged_write_targets | paste -sd, -)" = "$1" ]; }
logged_event_count_is() { [ "$(grep -c . "$EVENT_LOG")" -eq "$1" ]; }
no_write_event_logged() { [ -z "$(logged_write_targets)" ]; }

OUT=$(guarded_shell_run "printf 'x' > tests/locked.test.sh")
check "a > redirection onto a locked test is denied (R-410)" decision_is deny "$OUT"
check "the redirection denial names the locked path" reason_mentions "tests/locked.test.sh" "$OUT"

OUT=$(guarded_shell_run "printf 'x' >> tests/locked.test.sh")
check "a >> redirection onto a locked test is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "printf 'x' | tee tests/locked.test.sh")
check "tee onto a locked test is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "printf 'x' | tee -a tests/locked.test.sh")
check "tee -a onto a locked test is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "cp src/widget.ts tests/locked.test.sh")
check "a cp destination inside the locked tree is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "mv -f src/widget.ts tests/locked.test.sh")
check "an mv destination inside the locked tree is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "install -m 644 src/widget.ts tests/locked.test.sh")
check "an install destination inside the locked tree is denied (R-410)" decision_is deny "$OUT"

# The quoted operand is the case a regex over command text cannot reach: the
# locked spec's name contains a space, so only a quote-aware tokenizer sees it.
OUT=$(guarded_shell_run "printf 'x' > 'docs/my spec.md'")
check "a single-quoted target with a space is denied (R-410)" decision_is deny "$OUT"
check "the quoted-target denial names the whole path" reason_mentions "docs/my spec.md" "$OUT"

OUT=$(guarded_shell_run "printf 'x' > \"docs/my spec.md\"")
check "a double-quoted target with a space is denied (R-410)" decision_is deny "$OUT"

OUT=$(guarded_shell_run "printf 'x' > src/generated.ts")
check "a redirection onto an ordinary production path is not denied" not decision_is deny "$OUT"

recorded_shell_run "printf 'x' > src/one.ts; printf 'y' > tests/locked.test.sh"
check "two redirections on one command line each produce a target" \
  logged_write_targets_are "src/one.ts,tests/locked.test.sh"

recorded_shell_run "printf 'x' > tests/locked.test.sh"
check "the Bash event still runs beside the synthesized write event" logged_event_count_is 2

# The negative case: no write target, no synthetic event, and the Bash event
# the adapter always dispatched is still the only one.
recorded_shell_run "git status --short"
check "a command with no write target dispatches exactly one event" logged_event_count_is 1
check "a command with no write target synthesizes nothing" no_write_event_logged

recorded_shell_run "echo x > /dev/null"
check "a /dev target is not reported as a file write" no_write_event_logged

recorded_shell_run "grep -R widget src 2>&1 | head -3"
check "an fd duplication is not read as a redirection target" no_write_event_logged

# The documented limit, pinned so it cannot be mistaken for coverage: a target
# that only exists once the shell has run is dropped, not guessed at.
recorded_shell_run 'printf "x" > "$LOCKED_TEST"'
check "a target built from a variable yields no synthetic event" no_write_event_logged

recorded_shell_run 'printf "x" > "$(mktemp)"'
check "a target built from a command substitution yields no synthetic event" no_write_event_logged

# A heredoc body is the text being written, not shell. A > inside it must not
# become a target of its own, or ordinary writes would draw false denials.
recorded_shell_run "cat <<'DOC' > docs/note.md
a > b is not a redirection here
DOC"
check "a heredoc body's > is not mistaken for a second target" logged_write_target_is "docs/note.md"

# --- 4. the runtime marker every hook child must carry ------------------------

# codex-test-author-guard.sh (R-907) exits silently when it sees
# CLAUDE_HOOK_RUNTIME=codex, because tests are Codex's job to write and the
# adapter turns the guard's ask into a deny, which blocked Codex from editing
# any existing test file (observed 2026-09-19 in template-fastapi-nuxt). That
# silence is only sound if the real adapter truly exports the marker into every
# hook child it runs; a guard trusting a variable nothing sets would be an open
# door rather than a fix. run_adapter sets CODEX_TEST_GUARD=off, so these cases
# assert the marker as a hook child actually observes it, not a decision.

# The distinct CLAUDE_HOOK_RUNTIME values recorded on SYNTHESIZED WRITE events
# only, one per line. This exists because the set-of-all-events helper below
# cannot tell a run that walked the synthesized-write door from one that only
# ran the ordinary Bash event: the Bash event supplies "codex" by itself, so
# the set comparison still read "codex" with replay_shell_writes() stubbed to
# return 0 and no write event dispatched at all (2026-09-19 pre-merge review,
# finding 1: a case that could not fail).
logged_write_event_runtimes() {
  jq -r 'select(.tool_name == "Write") | .hook_runtime // ""' "$EVENT_LOG" 2>/dev/null | sort -u
}

# True when at least one synthesized write event was recorded AND every one of
# them saw exactly the given runtime value. The non-empty half is the half that
# makes the case falsifiable.
logged_write_runtime_is() {
  local write_runtimes
  write_runtimes=$(logged_write_event_runtimes)
  [ -n "$write_runtimes" ] && [ "$write_runtimes" = "$1" ]
}

# The distinct CLAUDE_HOOK_RUNTIME values the recording hook saw, one per line.
logged_hook_runtimes() {
  jq -r '.hook_runtime // ""' "$EVENT_LOG" 2>/dev/null | sort -u
}

# True when every recorded dispatch saw exactly the given runtime value.
logged_hook_runtime_is() {
  [ -s "$EVENT_LOG" ] && [ "$(logged_hook_runtimes)" = "$1" ]
}

reset_log
run_adapter "$(bash_payload 'echo nothing to see here')" record-calls >/dev/null
check "the adapter marks its hook children with the codex runtime" \
  logged_hook_runtime_is "codex"

# Both doors, since the synthesized write event is the one the Write|Edit gates
# (codex-test-author-guard among them) are reached through.
recorded_shell_run "printf 'x' > src/one.ts"
check "the synthesized write event carries the codex runtime too" \
  logged_write_runtime_is "codex"
check "that run walked both doors: the Bash event and one synthesized write" \
  logged_event_count_is 2
check "the marker is on every event of that run, not on the write alone" \
  logged_hook_runtime_is "codex"

# --- 4b. the R-907 guard and the adapter, together ----------------------------
#
# Section 4 asserts the marker the adapter exports, and the guard fixture
# asserts what the guard does with a marker it is handed; until now nothing ran
# the two together, and run_adapter switched the guard off for every case, so
# the defect shape of 2026-09-19 appeared in no fixture at all. That shape is
# precise: Codex edits an EXISTING test file, which arrives as an apply_patch
# carrying "*** Update File:" on a test path, is replayed as an Edit into the
# Write|Edit gate list where codex-test-author-guard sits, and with the ask
# policy at deny an ask there becomes a hard block on the one job R-907 gives
# Codex. These cases run the real guard behind the real adapter, with nothing
# switched off.

# Runs one payload through the adapter with codex-test-author-guard live rather
# than disabled, then restores the fixture-wide setting so no other case in
# this file changes behavior.
run_adapter_with_test_guard() {
  local out
  TEST_GUARD="on"
  out=$(run_adapter "$@")
  TEST_GUARD="off"
  printf '%s' "$out"
}

# Calls the sandbox copy of codex-test-author-guard.sh directly on one payload,
# with the runtime marker removed from its environment.
guard_decision_without_marker() {
  printf '%s' "$1" | env -u CLAUDE_HOOK_RUNTIME \
    HOME="$SANDBOX_HOME" \
    CODEX_TEST_GUARD=on \
    CLAUDE_FIRE_LOG=/dev/null \
    bash "$SANDBOX_CLAUDE/hooks/codex-test-author-guard.sh"
}

# The Edit payload the adapter replays an "*** Update File:" section as, so the
# direct call below asks the guard the same question the adapter asked it.
edit_payload() {
  jq -n --arg f "$1" \
    '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$f, old_string:"thing", new_string:"thing two"}}'
}

printf 'thing\n' >"$WORK/tests/test_thing.py"

OUT=$(run_adapter_with_test_guard "$(patch_payload "$(update_patch 'tests/test_thing.py')")" codex-test-author-guard)
check "editing an existing test file through the real adapter is not denied (R-907)" \
  not decision_is deny "$OUT"
check "the R-907 guard behind the adapter reaches no decision at all" \
  decision_is "" "$OUT"

# The mirror image cannot be staged through the adapter, because the adapter
# exports the marker unconditionally and nothing downstream can take it back
# off. Asking the copied guard directly, with the marker absent, is the honest
# form of the same question: it proves the not-a-deny above is the marker's
# doing rather than this guard being indifferent to that path.
OUT=$(guard_decision_without_marker "$(edit_payload "$WORK/tests/test_thing.py")")
check "the same edit without the runtime marker still asks (R-907)" \
  decision_is ask "$OUT"
check "the unmarked ask names the test file it is asking about" \
  reason_mentions "test_thing.py" "$OUT"

# --- 5. the write-target hook list, against the registration it mirrors -------

# The adapter names the Write|Edit gates itself, because it is handed only its
# own matcher's hook list. These two read the same set from both sides so the
# copy cannot drift out of the port unnoticed.
adapter_write_target_hooks() {
  sed -n 's/^read -r -a CODEX_WRITE_TARGET_HOOKS <<<"${CLAUDE_CODEX_WRITE_TARGET_HOOKS-\(.*\)}"$/\1/p' "$ADAPTER" \
    | tr ' ' '\n' | grep . | sort
}

registered_write_edit_hooks() {
  jq -r '.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[].command' \
    "$REPO_TOP/codex/hooks.json" 2>/dev/null \
    | sed -E 's/.*codex-hook-adapter\.sh //' | tr ' ' '\n' | grep . | sort
}

write_target_hooks_match_registration() {
  [ -n "$(adapter_write_target_hooks)" ] \
    && [ "$(adapter_write_target_hooks)" = "$(registered_write_edit_hooks)" ]
}

check "the adapter's write-target hooks are the Write|Edit registration" \
  write_target_hooks_match_registration

[ "$fail" -eq 0 ] && echo "codex-adapter-contract.test.sh PASS"
exit "$fail"
