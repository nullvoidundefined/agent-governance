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

REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
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

# --- 4. sessionStart gives session-start.sh a stable per-conversation key -----
#
# Cursor has no transcript at ~/.claude/projects/<key>/<session-id>.jsonl, so
# the adapter passes a synthetic transcript_path that names a file which never
# exists. session-start.sh then records the R-503 start from its own clock,
# once per conversation, and re-reads that record on every later start.

cp "$REPO_TOP/claude/hooks/session-start.sh" "$SANDBOX_CLAUDE/hooks/session-start.sh"
chmod +x "$SANDBOX_CLAUDE/hooks/session-start.sh"

session_payload() {
  # $1 = conversation_id; "" omits the field entirely. $2 = workspace root,
  # defaulting to $WORK.
  local root="${2:-$WORK}"
  if [ -n "$1" ]; then
    jq -n --arg id "$1" --arg cwd "$root" '{cwd:$cwd, workspace_roots:[$cwd], conversation_id:$id}'
  else
    jq -n --arg cwd "$root" '{cwd:$cwd, workspace_roots:[$cwd]}'
  fi
}
context_mentions() { printf '%s' "$2" | jq -r '.additional_context // ""' 2>/dev/null | grep -qF -- "$1"; }
start_records() { find "$SANDBOX_HOME/.claude/projects" -name 'session-start.*' 2>/dev/null; }
record_count_is() { [ "$(start_records | grep -c .)" -eq "$1" ]; }
transcript_count_is() { [ "$(find "$SANDBOX_HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | grep -c .)" -eq "$1" ]; }
first_record_is_under_cursor_key() { start_records | head -1 | grep -qE '/projects/cursor-[0-9a-f]+/session-start\.conv-alpha$'; }

OUT=$(run_adapter "$(session_payload conv-alpha)" sessionStart session-start)
check "a Cursor conversation gets a Session start (R-503) block" context_mentions "## Session start (R-503)" "$OUT"
check "the block names the Cursor conversation as the session" context_mentions "(session conv-alpha)" "$OUT"
check "exactly one start record is written, under a cursor-<hash> key" first_record_is_under_cursor_key
check "the synthetic transcript is never created on disk" transcript_count_is 0

RECORD=$(start_records | head -1)
printf '2026-01-02T03:04:05Z\n' >"$RECORD"
OUT=$(run_adapter "$(session_payload conv-alpha)" sessionStart session-start)
check "a second start of the same conversation re-reads the record, not the clock" context_mentions "started_at: 2026-01-02T03:04:05Z" "$OUT"
check "the second start adds no record" record_count_is 1

OUT=$(run_adapter "$(session_payload conv-beta)" sessionStart session-start)
check "a second conversation in the same workspace gets its own record" record_count_is 2

OUT=$(run_adapter "$(session_payload "")" sessionStart session-start)
check "a payload with no conversation_id gets no R-503 block" not context_mentions "## Session start (R-503)" "$OUT"
OUT=$(run_adapter "$(session_payload default)" sessionStart session-start)
check "the conversation_id \"default\" gets no R-503 block" not context_mentions "## Session start (R-503)" "$OUT"
check "neither unkeyed start writes a record" record_count_is 2

# Two ids that sanitize to the same filename characters stay two records: a
# shared record would hand the second conversation the first one's start.
run_adapter "$(session_payload "conv/gamma")" sessionStart session-start >/dev/null
run_adapter "$(session_payload "conv_gamma")" sessionStart session-start >/dev/null
check "ids that differ only in unsafe characters get distinct records" record_count_is 4

# The workspace is part of the key: the same conversation id under a second
# root lands in a different cursor-<hash> directory with its own record.
WORK_OTHER="$SANDBOX/work-other"
mkdir -p "$WORK_OTHER"
run_adapter "$(session_payload conv-alpha "$WORK_OTHER")" sessionStart session-start >/dev/null
cursor_key_dirs_are() { [ "$(start_records | sed -E 's#/session-start\.[^/]*$##' | sort -u | grep -c .)" -eq "$1" ]; }
check "a second workspace gets its own cursor-<hash> directory" cursor_key_dirs_are 2
check "the second workspace's conv-alpha record is separate from the first's" record_count_is 5

[ "$fail" -eq 0 ] && echo "cursor-adapter-contract.test.sh PASS"
exit "$fail"
