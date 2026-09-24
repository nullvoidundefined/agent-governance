#!/usr/bin/env bash
# Shard: slow
# Covers: hook:protected-path-guard
# Verifies the write targets protected-path-guard.sh must not lose now that it
# judges Bash by what a command writes (R-410; R-517 review of IAN-342): an
# operand reached through a shell variable assigned in the same command, a
# `>|` clobbering redirection, and a nested shell deeper than the guard scans,
# which asks rather than passing unread. Every case feeds a PreToolUse
# payload; allow is silence.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"

REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q
mkdir -p "$REPO/src/services" "$REPO/src/__tests__" "$REPO/.claude"
printf 'it("scores", () => {});\n' > "$REPO/src/__tests__/score.test.ts"
jq -n '{slice:"B-1",phase:"red",tests:[{path:"src/__tests__/score.test.ts",sha256:"0"}],locked:[]}' > "$REPO/.claude/tdd-lock.json"

bash_call() { jq -nc --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
expect() {
  local want="$1" label="$2" out got
  out=$(CLAUDE_FIRE_LOG=/dev/null "$HOOK")
  if [ -z "$out" ]; then got=allow; else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'); fi
  [ "$got" = "$want" ] || { echo "FAIL: $label: expected $want, got $got"; exit 1; }
}

bash_call 'T=src/__tests__/score.test.ts; rm "$T"' | expect deny "rm through a variable"
bash_call "T=src/__tests__/score.test.ts; sed -i '' 's/a/b/' \"\$T\"" | expect deny "sed -i through a variable"
bash_call 'DEST=src/__tests__/score.test.ts; cp /tmp/x "$DEST"' | expect deny "cp onto a variable destination"
bash_call 'T=src/__tests__; git checkout -- "${T}/score.test.ts"' | expect deny "git checkout through a braced variable"
bash_call 'T=src/services/score.ts; rm "$T"' | expect allow "rm of production through a variable while red"
bash_call 'echo x >| src/__tests__/score.test.ts' | expect deny "clobbering redirection onto the locked test"
bash_call "bash -c \"bash -c \\\"bash -c 'bash -c \\\\\\\"echo x > src/__tests__/score.test.ts\\\\\\\"'\\\"\"" | expect ask "a nested shell past the scan depth asks"

rm -rf "$REPO"
echo "protected-path-guard-bash-indirection.test.sh PASS"
