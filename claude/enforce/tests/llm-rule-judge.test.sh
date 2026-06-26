#!/usr/bin/env bash
# Verifies llm-rule-judge.sh denies a push when the judge returns a high-confidence
# violation, and allows below-threshold or empty verdicts. Uses CLAUDE_JUDGE_CMD to
# stub the model, so no live API call.
set -euo pipefail
HOOK="$HOME/.claude/hooks/llm-rule-judge.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init
printf 'export function generate(){}\n' > generate.ts; git add .; git commit -q -m x

# A stub that prints the given JSON verdict to stdout.
mkstub() { local j f; j=$(mktemp); printf '%s' "$1" > "$j"; f=$(mktemp); printf '#!/usr/bin/env bash\ncat %q\n' "$j" > "$f"; chmod +x "$f"; echo "$f"; }

# High confidence -> deny.
S1=$(mkstub '{"violations":[{"rule":"R-217","confidence":0.9,"file":"generate.ts","why":"vague filename"}]}')
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S1" "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Below threshold -> allow (no output).
S2=$(mkstub '{"violations":[{"rule":"R-217","confidence":0.5,"file":"generate.ts","why":"maybe"}]}')
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S2" "$HOOK")
[ -z "$OUT2" ]

# No violations -> allow.
S3=$(mkstub '{"violations":[]}')
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S3" "$HOOK")
[ -z "$OUT3" ]

# High confidence violation of a warn-severity rule (R-227) -> allow (no deny output).
S4=$(mkstub '{"violations":[{"rule":"R-227","confidence":0.95,"file":"x.ts","why":"long fn"}]}')
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S4" "$HOOK")
[ -z "$OUT4" ] || { echo "FAIL: R-227 warn rule should not produce deny output; got: $OUT4"; exit 1; }

echo "llm-rule-judge.test.sh PASS"
