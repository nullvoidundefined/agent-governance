#!/usr/bin/env bash
# Verifies protected-path-guard.sh: the always-protected gate inputs (R-410),
# the slice lock phases written by enforce/tdd.sh (R-410, R-412), and the
# per-role write boundaries keyed on agent_type (R-411). Every case feeds a
# PreToolUse payload and asserts the decision; allow means silence.
set -euo pipefail
HOOK="$HOME/.claude/hooks/protected-path-guard.sh"

REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q
mkdir -p "$REPO/src/services" "$REPO/src/__tests__" "$REPO/.claude" "$REPO/docs/specs"
printf 'export function score() { return 1; }\n' > "$REPO/src/services/score.ts"
printf 'it("scores", () => {});\n' > "$REPO/src/__tests__/score.test.ts"
printf '{ "name": "fixture", "scripts": { "test": "vitest run", "build": "tsc" }, "dependencies": {} }\n' > "$REPO/package.json"

write() { jq -nc --arg f "$1" --arg c "$2" --arg a "${3:-}" --arg d "$REPO" \
  '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:$c}} + (if $a=="" then {} else {agent_type:$a} end)'; }
edit() { jq -nc --arg f "$1" --arg o "$2" --arg n "$3" --arg a "${4:-}" --arg d "$REPO" \
  '{tool_name:"Edit",cwd:$d,tool_input:{file_path:$f,old_string:$o,new_string:$n}} + (if $a=="" then {} else {agent_type:$a} end)'; }
bash_call() { jq -nc --arg c "$1" --arg a "${2:-}" --arg d "$REPO" \
  '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}} + (if $a=="" then {} else {agent_type:$a} end)'; }
decision() { local out; out=$("$HOOK"); if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi; }
expect() {
  local want="$1" label="$2" got
  got=$(decision)
  [ "$got" = "$want" ] || { echo "FAIL: $label: expected $want, got $got"; exit 1; }
}
expect_reason() {
  local pattern="$1" label="$2" out
  out=$("$HOOK")
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | grep -q "$pattern" \
    || { echo "FAIL: $label: reason did not mention '$pattern'"; exit 1; }
}

# --- Always-protected gate inputs (R-410), no lock present -------------------
write "$REPO/.claude/verify.sh" 'exit 0' | expect deny "Write to .claude/verify.sh"
write "$REPO/.claude/verify.sh" 'exit 0' | expect_reason 'R-410' "verify.sh reason cites R-410"
edit "$REPO/.enforce-baseline.json" '"total": 4' '"total": 9' | expect deny "Edit to the ratchet baseline"
write "$REPO/.enforce.json" '{}' | expect deny "Write to .enforce.json"
bash_call 'echo "exit 0" > .claude/verify.sh' | expect deny "Bash redirect into verify.sh"
bash_call 'cat .claude/verify.sh' | expect allow "Bash read of verify.sh"
bash_call 'rm -f .enforce-baseline.json' | expect deny "Bash rm of the baseline"
write "$REPO/vitest.config.ts" 'export default {}' | expect ask "Write to a test-runner config asks"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "echo ok", "build": "tsc" }, "dependencies": {} }' | expect ask "package.json test script change asks"
write "$REPO/package.json" '{ "name": "fixture", "scripts": { "test": "vitest run", "build": "tsc" }, "dependencies": { "zod": "^3" } }' | expect allow "package.json dependency add with the same test script"
edit "$REPO/package.json" '"test": "vitest run"' '"test": "vitest run --passWithNoTests"' | expect ask "package.json Edit touching the test script asks"
write "$REPO/src/services/score.ts" 'export function score() { return 2; }' | expect allow "production write with no lock"
write "$REPO/src/__tests__/score.test.ts" 'it("x", () => {});' | expect allow "test write with no lock"
jq -nc '{tool_name:"Read",tool_input:{file_path:"/x/.claude/verify.sh"}}' | expect allow "Read is never gated"
jq -nc '{tool_name:"Write",tool_input:{}}' | expect allow "empty file_path is silent"

# --- Slice lock, phase open: tests may be written, production may not (R-412) -
jq -n '{slice:"B-1",phase:"open",tests:[],locked:[]}' > "$REPO/.claude/tdd-lock.json"
write "$REPO/src/services/score.ts" 'x' | expect deny "production write while the slice is open"
write "$REPO/src/services/score.ts" 'x' | expect_reason 'tdd.sh red' "open-phase reason names the next step"
write "$REPO/src/__tests__/next.test.ts" 'it("y", () => {});' | expect allow "test write while the slice is open"
bash_call 'echo x > src/services/score.ts' | expect deny "Bash redirect into production while open"

# --- Slice lock, phase red: tests, fixtures, and the spec are locked (R-410) --
jq -n '{slice:"B-1",phase:"red",tests:[{path:"src/__tests__/score.test.ts",sha256:"0"}],locked:["src/__fixtures__/","docs/specs/score.md"]}' > "$REPO/.claude/tdd-lock.json"
write "$REPO/src/__tests__/score.test.ts" 'it("x", () => {});' | expect deny "Write to the RED test"
edit "$REPO/src/__tests__/score.test.ts" 'scores' 'scored' | expect deny "Edit to the RED test"
write "$REPO/src/__tests__/score.test.ts" 'x' | expect_reason 'DISPUTE' "locked-test reason names the escalation path"
write "$REPO/src/__fixtures__/score.json" '{}' | expect deny "Write into a locked fixture dir"
write "$REPO/docs/specs/score.md" '# spec' | expect deny "Write to the locked spec"
write "$REPO/src/__tests__/other.test.ts" 'it("z", () => {});' | expect deny "any test write once the slice is red"
write "$REPO/src/services/score.ts" 'export function score() { return 3; }' | expect allow "production write while red"
write "$REPO/src/services/rank.ts" 'export function rank() {}' | expect allow "new production module while red"
bash_call 'rm src/__tests__/score.test.ts' | expect deny "Bash rm of the RED test"
bash_call 'git rm -q src/__tests__/score.test.ts' | expect deny "Bash git rm of the RED test"
bash_call "sed -i 's/scores/scored/' src/__tests__/score.test.ts" | expect deny "Bash sed -i on the RED test"
bash_call "cat > src/__tests__/score.test.ts <<'EOF'
it('x', () => {});
EOF" | expect deny "Bash heredoc into the RED test"
bash_call "cat > $REPO/src/__tests__/score.test.ts <<'EOF'
it('x', () => {});
EOF" | expect deny "Bash heredoc with an absolute path"
bash_call 'mv src/__tests__/score.test.ts /tmp/gone.ts' | expect deny "Bash mv of the RED test"
bash_call 'git checkout -- src/__tests__/score.test.ts' | expect deny "Bash git checkout of the RED test"
bash_call 'git diff src/__tests__/score.test.ts' | expect allow "Bash read-only git on the RED test"
bash_call 'npx vitest run src/__tests__/score.test.ts' | expect allow "Bash running the RED test"
bash_call 'rm .claude/tdd-lock.json' | expect deny "Bash rm of the lock"
write "$REPO/.claude/tdd-lock.json" '{}' | expect deny "Write to the lock"

# --- Slice lock, phase green: same protection holds through REFACTOR ---------
jq -n '{slice:"B-1",phase:"green",tests:[{path:"src/__tests__/score.test.ts",sha256:"0"}],locked:[]}' > "$REPO/.claude/tdd-lock.json"
write "$REPO/src/__tests__/score.test.ts" 'x' | expect deny "Write to the test while green"
write "$REPO/src/services/score.ts" 'x' | expect allow "production write while green"

# --- Unparsable lock fails closed --------------------------------------------
printf '{not json' > "$REPO/.claude/tdd-lock.json"
write "$REPO/src/services/score.ts" 'x' | expect deny "production write with an unreadable lock"
write "$REPO/src/services/score.ts" 'x' | expect_reason 'unreadable' "unreadable-lock reason says so"
rm "$REPO/.claude/tdd-lock.json"

# --- Role boundaries by agent_type (R-411), no lock --------------------------
write "$REPO/src/services/score.ts" 'x' test-author | expect deny "test-author writing production"
write "$REPO/src/services/score.ts" 'x' test-author | expect_reason 'R-411' "role reason cites R-411"
write "$REPO/src/__tests__/rank.test.ts" 'it("r", () => {});' test-author | expect allow "test-author writing a test"
write "$REPO/src/__fixtures__/rank.json" '{}' test-author | expect allow "test-author writing a fixture"
bash_call 'echo x > src/services/score.ts' test-author | expect deny "test-author Bash redirect into production"
bash_call 'npx vitest run' test-author | expect allow "test-author running tests"
write "$REPO/src/__tests__/rank.test.ts" 'x' implementer | expect deny "implementer writing a test"
edit "$REPO/src/__tests__/score.test.ts" 'a' 'b' implementer | expect deny "implementer editing a test"
write "$REPO/docs/superpowers/specs/2026-09-06-score-design.md" '# spec' implementer | expect deny "implementer writing a spec"
write "$REPO/src/services/score.ts" 'x' implementer | expect allow "implementer writing production"
bash_call 'rm src/__tests__/score.test.ts' implementer | expect deny "implementer Bash rm of a test"
write "$REPO/src/services/score.ts" 'x' slice-critic | expect deny "critic writing production"
write "$REPO/notes.md" 'x' slice-critic | expect deny "critic writing a note"
bash_call 'echo finding >> review.md' slice-critic | expect deny "critic Bash append"
bash_call 'git diff HEAD~1' slice-critic | expect allow "critic read-only git"
write "$REPO/src/services/score.ts" 'x' audit-engineering | expect allow "unknown agent_type has no role restriction"
write "/tmp/scratch-$$/note.ts" 'x' test-author | expect allow "write outside the repo root is not governed"

# --- Lock plus role compose: the stricter answer wins ------------------------
jq -n '{slice:"B-1",phase:"red",tests:[{path:"src/__tests__/score.test.ts",sha256:"0"}],locked:[]}' > "$REPO/.claude/tdd-lock.json"
write "$REPO/src/services/score.ts" 'x' implementer | expect allow "implementer production write while red"
write "$REPO/src/services/score.ts" 'x' test-author | expect deny "test-author production write while red"

rm -rf "$REPO"
echo "protected-path-guard.test.sh PASS"
