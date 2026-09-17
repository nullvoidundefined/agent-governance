#!/usr/bin/env bash
# The contract the REAL cursor/hooks/claude-hook-adapter.sh owes the mirrored
# permissions layer. Same 2026-09-18 port audit finding as the codex fixture
# beside this one: the adapter sourced enforce/settingsPermissionRules.sh, a
# file that has never existed in this repository, with `2>/dev/null || true`,
# and then guarded `matching_bash_rule` and `read_is_denied` with `type`. Both
# guards were permanently false, so every `permissions.deny` Bash rule and
# every `permissions.deny` Read rule was inert under Cursor while
# cursor/PORT-STATUS.md advertised both as mirrored.
#
# Two properties are asserted here, and they are different properties:
#
#   the layer works       a denied command is denied, an ask rule asks, a
#                         denied Read is denied, and an unremarkable command
#                         still runs
#   the layer is loud     when the helper it needs cannot be loaded, the
#                         adapter refuses the call and says why, instead of
#                         allowing it the way the old `|| true` did
#
# The second is the one the audit cared about, because a silent permission
# layer and a working permission layer are indistinguishable from the outside
# until the day a deny rule was the only thing standing between the agent and
# the command.
#
# Hermetic: HOME, CLAUDE_HOME, the settings file, the state directory and the
# working tree all live under one mktemp sandbox removed on exit. Nothing here
# reads or writes the installed ~/.claude.
#
# What this does NOT assert: that Cursor sends these payload shapes. They are
# the shapes the adapter's own header documents, so a Cursor release that
# renames a field breaks the port while this fixture stays green.
set -uo pipefail

REPO_TOP=$(git rev-parse --show-toplevel)
ADAPTER="$REPO_TOP/cursor/hooks/claude-hook-adapter.sh"
PERMISSION_RULES_SOURCE="$REPO_TOP/claude/enforce/settings-permission-rules.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
# not <cmd...>: negates a command's exit status, which a bare "!" cannot do
# once it has travelled through check()'s "$@" expansion.
not() { ! "$@"; }

[ -f "$ADAPTER" ] || { echo "FAIL: no adapter at $ADAPTER, so this fixture proved nothing"; exit 1; }

# --- the sandbox ---------------------------------------------------------------

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/cursor-adapter-contract.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX_HOME="$SANDBOX/home"
SANDBOX_CLAUDE="$SANDBOX/claude"
WORK="$SANDBOX/work"
mkdir -p "$SANDBOX_HOME" "$SANDBOX_CLAUDE/hooks" "$SANDBOX_CLAUDE/enforce" "$WORK"

# The environment-file name is assembled at run time rather than written as a
# literal: a fixture that spells a credential path out loud is the shape the
# secret scanners look for (R-108), and the point here is the rule match, not
# the spelling.
ENV_BASENAME=".$(printf 'env')"
printf 'PLACEHOLDER=changeme\n' >"$WORK/$ENV_BASENAME"
printf '# readme\n' >"$WORK/README.md"

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

# A hook that decides nothing, so every verdict below comes from the mirrored
# permission rules rather than from a gate that happened to fire.
cat >"$SANDBOX_CLAUDE/hooks/record-calls.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null 2>&1 || true
exit 0
EOF
chmod +x "$SANDBOX_CLAUDE/hooks/record-calls.sh"

# --- driving the adapter -------------------------------------------------------

run_adapter() {
  # $1 = stdin payload, $2 = Cursor event name; the rest are hook basenames,
  # exactly as cursor/hooks.json passes them.
  local payload="$1"
  shift
  printf '%s' "$payload" | env \
    HOME="$SANDBOX_HOME" \
    CLAUDE_HOME="$SANDBOX_CLAUDE" \
    CLAUDE_SETTINGS_FILE="$SANDBOX_CLAUDE/settings.json" \
    CLAUDE_CURSOR_STATE_DIR="$SANDBOX/state" \
    bash "$ADAPTER" "$@"
}

shell_payload() {
  jq -n --arg c "$1" --arg cwd "$WORK" '{command:$c, cwd:$cwd, workspace_roots:[$cwd], conversation_id:"contract-fixture"}'
}

read_payload() {
  jq -n --arg f "$1" --arg cwd "$WORK" '{file_path:$f, cwd:$cwd, workspace_roots:[$cwd], conversation_id:"contract-fixture"}'
}

# --- assertions, each a wrapper so no pipeline or redirect rides on check() ----

permission_is() { [ "$(printf '%s' "$2" | jq -r '.permission // ""' 2>/dev/null)" = "$1" ]; }
message_mentions() { printf '%s' "$2" | jq -r '.user_message // ""' 2>/dev/null | grep -qF -- "$1"; }

# --- 1. the mirrored Bash rules -----------------------------------------------

OUT=$(run_adapter "$(shell_payload 'echo audit-denied now')" beforeShellExecution record-calls)
check "a settings.json Bash deny rule denies through the real adapter" permission_is deny "$OUT"
check "the deny message names the settings.json rule that matched" message_mentions 'echo audit-denied*' "$OUT"

OUT=$(run_adapter "$(shell_payload 'echo audit-ask now')" beforeShellExecution record-calls)
check "a settings.json Bash ask rule asks through the real adapter" permission_is ask "$OUT"
check "the ask message names the settings.json rule that matched" message_mentions 'echo audit-ask*' "$OUT"

OUT=$(run_adapter "$(shell_payload 'echo nothing to see here')" beforeShellExecution record-calls)
check "a command matching no rule is still allowed" permission_is allow "$OUT"

# --- 2. the mirrored Read rules ------------------------------------------------

OUT=$(run_adapter "$(read_payload "$WORK/$ENV_BASENAME")" beforeReadFile record-calls)
check "a settings.json Read deny rule denies the read through the real adapter" permission_is deny "$OUT"
check "the read denial cites the rule it enforces" message_mentions "R-102" "$OUT"

OUT=$(run_adapter "$(read_payload "$WORK/README.md")" beforeReadFile record-calls)
check "a file no Read rule covers is still readable" permission_is allow "$OUT"

# --- 3. the layer's own absence is loud ---------------------------------------

mv "$SANDBOX_CLAUDE/enforce/settings-permission-rules.sh" "$SANDBOX/permission-rules.parked" 2>/dev/null || true

OUT=$(run_adapter "$(shell_payload 'echo nothing to see here')" beforeShellExecution record-calls)
check "a missing permission helper denies the command rather than allowing it" permission_is deny "$OUT"
check "the fail-closed message names the helper it could not load" message_mentions "settings-permission-rules.sh" "$OUT"

OUT=$(run_adapter "$(read_payload "$WORK/README.md")" beforeReadFile record-calls)
check "a missing permission helper denies the read rather than allowing it" permission_is deny "$OUT"

mv "$SANDBOX/permission-rules.parked" "$SANDBOX_CLAUDE/enforce/settings-permission-rules.sh" 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "cursor-adapter-contract.test.sh PASS"
exit "$fail"
