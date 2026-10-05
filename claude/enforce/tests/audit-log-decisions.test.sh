#!/usr/bin/env bash
# Covers: hook:infra-mutation-guard hook:destructive-db-guard hook:secret-scan hook:protected-path-guard hook:destructive-ops-guard
# Verifies spec A-3 (2026-10-05-audit-log.md): when a guard emits a deny, it
# also appends one "decision" line to ${AGENT_AUDIT_DIR}/<UTC date>.jsonl
# through the shared helper hooks/audit-log-append.sh. One deny is driven
# through each guard with a command it already denies (rows of
# fixtures/guard-corpus.txt); the test checks the guard still denies (so the
# logging is not what is being tested in a vacuum) and that the line names the
# hook and the decision. A guard that does not log fails its row.
# Credential-shaped values are built at run time.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

[ -f "$CLAUDE_HARNESS_ROOT/hooks/audit-log-append.sh" ] \
  || fail "setup: hooks/audit-log-append.sh (shared helper) does not exist"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q
cat >"$REPO/.enforce.json" <<'EOF'
{"environments": {
  "production": ["db.internal.acme.net", "gke_acme_main"],
  "preview": ["*.preview.acme.dev"],
  "testing": ["ci-db.acme.net", "prod-mirror.testing.acme.net"]
}}
EOF
HOME_DIR="$WORK/home"; mkdir -p "$HOME_DIR/.claude"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"

repeat() { printf "$1%.0s" $(seq 1 "$2"); }
SECRET="ghp_$(repeat a 36)"

# drive <hook basename> <label> <payload-json>: runs the hook with a fresh
# audit dir, asserts it denied, then asserts a matching decision line.
n=0
drive() {
  local hook="$1" label="$2" payload="$3" dir out d line
  n=$((n + 1))
  dir="$WORK/audit$n"
  out=$(printf '%s' "$payload" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    HOME="$HOME_DIR" AGENT_AUDIT_DIR="$dir" CLAUDE_FIRE_LOG=/dev/null \
    bash "$CLAUDE_HARNESS_ROOT/hooks/$hook.sh" 2>/dev/null)
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo none)
  [ "$d" = deny ] || { fail "$label: precondition: $hook no longer denies this payload (got $d)"; return; }
  line=$(cat "$dir"/*.jsonl 2>/dev/null | jq -c 'select(.event == "decision")' 2>/dev/null | head -1)
  if [ -z "$line" ]; then
    fail "$label: $hook denied but wrote no decision line (dir holds: $(ls "$dir" 2>/dev/null | tr '\n' ' '))"
    return
  fi
  printf '%s' "$line" | jq -e --arg h "$hook" '(.hook | tostring | contains($h)) and .decision == "deny"' >/dev/null \
    || fail "$label: decision line has wrong hook/decision: $line"
  printf '%s' "$line" | jq -e '(keys_unsorted | join(",")) == "ts,session,event,tool,repo,cwd,input,hook,rule,decision"' >/dev/null \
    || fail "$label: decision line keys/order wrong: $line"
  [ "$(cat "$dir"/*.jsonl | wc -l)" -eq 1 ] || fail "$label: expected exactly one line for one deny"
  printf '%s' "$line" | grep -qF "$SECRET" && fail "$label: the secret reached the audit file"
}

bash_payload() { jq -nc --arg c "$1" --arg d "$REPO" --arg s sess-d '{session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'; }

drive infra-mutation-guard "infra" "$(bash_payload 'aws s3 rm s3://acme-bucket --recursive')"
drive destructive-db-guard "db" "$(bash_payload 'railway run -e production -- npm run migrate:down')"
drive secret-scan "secret" "$(bash_payload "export GITHUB_TOKEN=$SECRET")"
drive destructive-ops-guard "ops" "$(bash_payload 'rm -rf /srv/data')"
drive protected-path-guard "protected" "$(jq -nc --arg f "$HOME_DIR/.claude/security-review-ledger/x.json" --arg d "$REPO" \
  '{session_id:"sess-d",cwd:$d,tool_name:"Write",tool_input:{file_path:$f,content:"{}"}}')"

# A deny must still be a deny when the audit directory is unwritable: logging
# never changes the decision (A-4 spirit, checked on one guard).
echo plain > "$WORK/afile"
out=$(printf '%s' "$(bash_payload 'rm -rf /srv/data')" | env -u GIT_DIR HOME="$HOME_DIR" AGENT_AUDIT_DIR="$WORK/afile/sub" \
  CLAUDE_FIRE_LOG=/dev/null bash "$CLAUDE_HARNESS_ROOT/hooks/destructive-ops-guard.sh" 2>/dev/null; echo "rc=$?")
printf '%s' "$out" | grep -q '"deny"' || fail "unwritable audit dir changed the destructive-ops decision: $out"

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS assertion(s)"; exit 1; fi
echo "PASS: audit-log-decisions"
