#!/usr/bin/env bash
# Shard: slow
# Covers: hook:protected-path-guard
# Verifies that protected-path-guard.sh judges a Bash command by what it
# writes, not by the text it carries (R-410, R-412). On 2026-09-24 the guard
# refused a Vitest run whose -t filter held the word "rm" (every path in the
# command, the locked test included, became a write target) and a
# `python3 - <<EOF` edit whose body held `=> {` (the arrow read as a
# redirection onto a file named "{"). Quoted text and heredoc bodies are data
# unless the command around them writes: a redirection, tee, cp or mv onto a
# path, sed -i, a nested shell, or an inline interpreter script whose write
# call names the path. Every case feeds a PreToolUse payload; allow is silence.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"

REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q
mkdir -p "$REPO/src/services" "$REPO/src/__tests__" "$REPO/.claude"
printf 'export function score() { return 1; }\n' > "$REPO/src/services/score.ts"
printf 'it("scores", () => {});\n' > "$REPO/src/__tests__/score.test.ts"

bash_call() { jq -nc --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
expect() {
  local want="$1" label="$2" out got
  out=$("$HOOK")
  if [ -z "$out" ]; then got=allow; else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'); fi
  [ "$got" = "$want" ] || { echo "FAIL: $label: expected $want, got $got ($(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | cut -c1-160))"; exit 1; }
}

# --- Phase red: the test is locked, production is writable -------------------
jq -n '{slice:"B-1",phase:"red",tests:[{path:"src/__tests__/score.test.ts",sha256:"0"}],locked:[]}' > "$REPO/.claude/tdd-lock.json"

# Read-only runs that name the locked test.
bash_call 'pnpm vitest run src/__tests__/score.test.ts -t "does not rm the session cookie"' | expect allow "vitest run with rm inside the -t filter"
bash_call 'npx vitest run src/__tests__/score.test.ts -t "score > rejects a bad job" 2>&1 | tail -20' | expect allow "vitest run with > inside the -t filter"
bash_call 'cat src/__tests__/score.test.ts | grep -c "rm -rf"' | expect allow "grep for a mutating verb in the locked test"
bash_call 'cp src/__tests__/score.test.ts /tmp/score-copy.ts' | expect allow "cp FROM the locked test"
bash_call "node -e \"console.log(require('fs').readFileSync('src/__tests__/score.test.ts', 'utf8'))\"" | expect allow "node -e reading the locked test"

# A heredoc script that reads the locked test and edits an unrelated file.
bash_call "python3 - <<'EOF'
import pathlib
test_source = pathlib.Path('src/__tests__/score.test.ts').read_text()
target = pathlib.Path('src/services/score.ts')
source = target.read_text().replace('(x) => {', '(y) => {')
target.write_text(source)
EOF" | expect allow "python heredoc editing production while reading the locked test"

# Real writes onto the locked test are still refused.
bash_call 'cp /tmp/other.ts src/__tests__/score.test.ts' | expect deny "cp onto the locked test"
bash_call 'echo x | tee -a src/__tests__/score.test.ts' | expect deny "tee -a onto the locked test"
bash_call "sed -i '' \"s/scores/scored/\" \"src/__tests__/score.test.ts\"" | expect deny "sed -i on a quoted locked path"
bash_call "perl -pi -e 's/scores/scored/' src/__tests__/score.test.ts" | expect deny "perl -pi on the locked test"
bash_call "bash -c 'echo x > src/__tests__/score.test.ts'" | expect deny "nested shell redirect onto the locked test"
bash_call "python3 -c \"open('src/__tests__/score.test.ts', 'w').write('x')\"" | expect deny "python -c opening the locked test for writing"
bash_call "node -e \"require('fs').writeFileSync('src/__tests__/score.test.ts', 'x')\"" | expect deny "node -e writeFileSync onto the locked test"
bash_call "python3 - <<'EOF'
from pathlib import Path
Path('src/__tests__/score.test.ts').write_text('x')
EOF" | expect deny "python heredoc write_text onto the locked test"
bash_call "python3 - <<'EOF'
test_path = 'src/__tests__/score.test.ts'
with open(test_path, 'w') as handle:
    handle.write('x')
EOF" | expect deny "python heredoc opening the locked test through a variable"
bash_call "bash <<'EOF'
echo x > src/__tests__/score.test.ts
EOF" | expect deny "bash heredoc redirect onto the locked test"
bash_call "cat > src/__tests__/score.test.ts <<'EOF'
it('x', () => {});
EOF" | expect deny "cat heredoc into the locked test"

# --- Phase open: production is read-only, tests are writable -----------------
jq -n '{slice:"B-1",phase:"open",tests:[],locked:[]}' > "$REPO/.claude/tdd-lock.json"
bash_call "python3 - <<'EOF'
import pathlib
path = pathlib.Path('src/__tests__/score.test.ts')
path.write_text(path.read_text().replace('() => {', 'async () => {'))
EOF" | expect allow "python heredoc with => { editing a test while open"
bash_call 'npx vitest run src/__tests__/score.test.ts -t "score > rejects"' | expect allow "vitest -t filter with > while open"
bash_call "python3 - <<'EOF'
import pathlib
pathlib.Path('src/services/score.ts').write_text('x')
EOF" | expect deny "python heredoc writing production while open"

rm -rf "$REPO"
echo "protected-path-guard-bash-parsing.test.sh PASS"
