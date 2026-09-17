#!/usr/bin/env bash
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

REPO_TOP=$(git rev-parse --show-toplevel)
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
chmod +x "$SANDBOX_CLAUDE/hooks/protected-path-guard.sh"

# The synthetic hook: records every payload the adapter dispatches to it and
# decides nothing, so a case can assert what the gates were shown.
cat >"$SANDBOX_CLAUDE/hooks/record-calls.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
payload=$(cat 2>/dev/null || true)
printf '%s\n' "$payload" >>"${ADAPTER_EVENT_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$SANDBOX_CLAUDE/hooks/record-calls.sh"

# A repository with a red slice whose test file is locked, so the real
# protected-path-guard has something to protect.
env HOME="$SANDBOX_HOME" git init -q "$WORK" >/dev/null 2>&1
printf 'locked\n' >"$WORK/tests/locked.test.sh"
printf 'widget\n' >"$WORK/src/widget.ts"
cat >"$WORK/.claude/tdd-lock.json" <<'EOF'
{"slice": "contract-fixture", "phase": "red", "tests": [{"path": "tests/locked.test.sh"}]}
EOF

# --- driving the adapter -------------------------------------------------------

ASK_POLICY="deny"

run_adapter() {
  # $1 = stdin payload; the rest are hook basenames, exactly as hooks.json
  # passes them. Every path the adapter reads is redirected into the sandbox.
  local payload="$1"
  shift
  printf '%s' "$payload" | env \
    HOME="$SANDBOX_HOME" \
    CLAUDE_HOME="$SANDBOX_CLAUDE" \
    CLAUDE_SETTINGS_FILE="$SANDBOX_CLAUDE/settings.json" \
    CLAUDE_ROLE_POLICY_FILE="$SANDBOX_CLAUDE/enforce/role-policy.json" \
    CLAUDE_CODEX_STATE_DIR="$SANDBOX/state" \
    CLAUDE_CODEX_ASK_POLICY="$ASK_POLICY" \
    ADAPTER_EVENT_LOG="$EVENT_LOG" \
    CODEX_TEST_GUARD=off \
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

[ "$fail" -eq 0 ] && echo "codex-adapter-contract.test.sh PASS"
exit "$fail"
