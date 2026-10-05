#!/usr/bin/env bash
# Covers: hook:protected-path-guard
# Verifies spec A-6 for the Write and Edit tools (2026-10-05-audit-log.md): a
# Write or Edit to a path inside the audit directory
# ($HOME/.local/state/agent-audit, and ${AGENT_AUDIT_DIR} when set) is denied
# by protected-path-guard.sh from any working directory, while writes to a
# sibling directory stay allowed. HOME is a temp dir.
# The Bash rows live in fixtures/guard-corpus.txt.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
H="$WORK/home"; mkdir -p "$H/.local/state/agent-audit" "$H/.local/state/other"
REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q
ELSEWHERE="$WORK/elsewhere"; mkdir -p "$ELSEWHERE"

# decide <payload> [extra env]: prints deny or allow.
decide() {
  local out
  out=$(printf '%s' "$1" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE HOME="$H" CLAUDE_FIRE_LOG=/dev/null "${@:2}" bash "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi
}
write_p() { jq -nc --arg f "$1" --arg d "$2" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"x"}}'; }
edit_p() { jq -nc --arg f "$1" --arg d "$2" '{tool_name:"Edit",cwd:$d,tool_input:{file_path:$f,old_string:"a",new_string:"b"}}'; }
nb_p() { jq -nc --arg f "$1" --arg d "$2" '{tool_name:"NotebookEdit",cwd:$d,tool_input:{notebook_path:$f,new_source:"x"}}'; }

AUD="$H/.local/state/agent-audit"
for cwd in "$REPO" "$ELSEWHERE"; do
  tag=$(basename "$cwd")
  [ "$(decide "$(write_p "$AUD/2026-10-05.jsonl" "$cwd")")" = deny ] || fail "Write into the audit dir (cwd $tag) must deny"
  [ "$(decide "$(edit_p "$AUD/2026-10-05.jsonl" "$cwd")")" = deny ] || fail "Edit of an audit file (cwd $tag) must deny"
  [ "$(decide "$(write_p "$AUD/new-file.jsonl" "$cwd")")" = deny ] || fail "Write of a new file in the audit dir (cwd $tag) must deny"
  [ "$(decide "$(nb_p "$AUD/n.ipynb" "$cwd")")" = deny ] || fail "NotebookEdit in the audit dir (cwd $tag) must deny"
done
# A traversal that lands inside the directory.
[ "$(decide "$(write_p "$H/.local/state/other/../agent-audit/x.jsonl" "$REPO")")" = deny ] || fail "dot-dot path into the audit dir must deny"
# A symlink to the directory.
ln -s "$AUD" "$WORK/alias"
[ "$(decide "$(write_p "$WORK/alias/x.jsonl" "$REPO")")" = deny ] || fail "symlink into the audit dir must deny"
# AGENT_AUDIT_DIR override is protected too.
CUSTOM="$WORK/custom-audit"; mkdir -p "$CUSTOM"
[ "$(decide "$(write_p "$CUSTOM/x.jsonl" "$REPO")" AGENT_AUDIT_DIR="$CUSTOM")" = deny ] || fail "AGENT_AUDIT_DIR path must deny"
# Controls: a sibling directory is not protected.
[ "$(decide "$(write_p "$H/.local/state/other/x.txt" "$REPO")")" = allow ] || fail "control: write to a sibling dir must allow"
[ "$(decide "$(write_p "$H/.local/state/agent-audit-notes/x.txt" "$REPO")")" = allow ] || fail "control: a dir that only shares the name prefix must allow"

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS assertion(s)"; exit 1; fi
echo "PASS: audit-dir-protection"
