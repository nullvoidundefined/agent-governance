#!/usr/bin/env bash
# Covers: hook:llm-rule-judge
# Verifies llm-rule-judge.sh denies a push when the judge returns a high-confidence
# violation, and allows below-threshold or empty verdicts. Uses CLAUDE_JUDGE_CMD to
# stub the model, so no live API call.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/llm-rule-judge.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init
printf 'export function generate(){}\n' > generate.ts; git add .; git commit -q -m x

# A stub that prints the given JSON verdict to stdout.
mkstub() { local j f; j=$(mktemp); printf '%s' "$1" > "$j"; f=$(mktemp); printf '#!/usr/bin/env bash\ncat %q\n' "$j" > "$f"; chmod +x "$f"; echo "$f"; }

# High confidence -> ask (the human adjudicates; 2026-09-05).
S1=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.ts","why":"vague filename"}]}')
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S1" "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null

# Below threshold -> allow (no output).
S2=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.5,"file":"generate.ts","why":"maybe"}]}')
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S2" "$HOOK")
[ -z "$OUT2" ]

# No violations -> allow.
S3=$(mkstub '{"violations":[]}')
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S3" "$HOOK")
[ -z "$OUT3" ]

# High confidence violation whose manifest severity is warn -> allow (no deny
# output). R-322 left the llm-judge tier in the 2026-09-04 reclassification, so
# this now covers the severity-lookup FALLBACK: an id the judge returns that has
# no llm-judge row still resolves through its remaining row (advisory, warn) and
# must not ask. A judge that hallucinates a rule id must never gate a push.
S4=$(mkstub '{"violations":[{"rule":"R-322","confidence":0.95,"file":"x.ts","why":"long fn"}]}')
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S4" "$HOOK")
[ -z "$OUT4" ] || { echo "FAIL: a warn-severity id should not produce ask output; got: $OUT4"; exit 1; }

# R-325 joined the llm-judge tier on 2026-09-17 (audit P2-4): CLAUDE.md tagged
# it `judge` and reference.md documented exactly what the judge decides for it
# ("never destructure a method"), while the manifest carried no llm-judge row,
# so that half of the rule was evaluated by nothing. Its row is warn, because
# the eslint row remains the hard guarantee for the syntax half, so a
# high-confidence verdict must report without losing the push.
S4c=$(mkstub '{"violations":[{"rule":"R-325","confidence":0.95,"file":"x.ts","why":"method destructured off its object"}]}')
OUT4c=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S4c" "$HOOK" 2>/dev/null)
[ -z "$OUT4c" ] || { echo "FAIL: R-325 is warn severity and must not gate the push; got: $OUT4c"; exit 1; }
ERR4c=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S4c" "$HOOK" 2>&1 >/dev/null)
printf '%s' "$ERR4c" | grep -q "R-325" || { echo "FAIL: a warn-severity judge verdict must still reach stderr; got: $ERR4c"; exit 1; }

# An id with no manifest row at all defaults to error severity and DOES deny,
# so an unknown id is not a silent bypass of the gate.
S4b=$(mkstub '{"violations":[{"rule":"R-999","confidence":0.95,"file":"x.ts","why":"unknown id"}]}')
OUT4b=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S4b" "$HOOK")
[ -n "$OUT4b" ] || { echo "FAIL: an unknown rule id should default to error severity and ask"; exit 1; }

# Python-only diff still reaches the judge (the diff scope includes *.py).
printf 'def generate():\n    pass\n' > generate.py; git add .; git commit -q -m y
S5=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.py","why":"vague filename"}]}')
OUT5=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S5" "$HOOK")
printf '%s' "$OUT5" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null || { echo "FAIL: py-only diff should reach the judge and ask"; exit 1; }

# Ruby-only and Go-only diffs reach the judge too (*.rb and *.go in scope).
printf 'def generate\nend\n' > generate.rb; git add .; git commit -q -m z
S6=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.rb","why":"vague filename"}]}')
OUT6=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S6" "$HOOK")
printf '%s' "$OUT6" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null || { echo "FAIL: rb-only diff should reach the judge and deny"; exit 1; }
printf 'package x\n\nfunc Generate() {}\n' > generate.go; git add .; git commit -q -m w
S7=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.go","why":"vague filename"}]}')
OUT7=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S7" "$HOOK")
printf '%s' "$OUT7" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null || { echo "FAIL: go-only diff should reach the judge and deny"; exit 1; }

# Multi-row manifest id (R-324 has eslint+ruff+golangci rows, all error): the
# severity lookup must not collapse to warn on the multiline jq result
# (2026-07-31 criticism audit P1).
S8=$(mkstub '{"violations":[{"rule":"R-324","confidence":0.9,"file":"generate.go","why":"magic number"}]}')
OUT8=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_JUDGE_CMD="$S8" "$HOOK")
printf '%s' "$OUT8" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null || { echo "FAIL: multi-row error rule should deny, not downgrade to warn"; exit 1; }

# PR #8 review (Copilot, claude/hooks/enforcement-guard-check.sh): the
# session-start guard counts a secret-tool or pass entry as a live judge, so the
# judge has to be able to read a key out of the same stores. While it resolved
# only ANTHROPIC_API_KEY and the macOS keychain, a Linux host with a provisioned
# entry saw no degraded-judge warning and still got a judge that fail-opened on
# every push. Every binary the resolution path touches is stubbed on PATH, so no
# real keychain is read and no request leaves the machine.
STUB_DIR=$(mktemp -d)
VERDICT='{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.ts","why":"vague filename"}]}'
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/security"
printf '#!/usr/bin/env bash\nprintf "%%s" %q\n' "$(jq -n --arg t "$VERDICT" '{content:[{text:$t}]}')" > "$STUB_DIR/curl"
chmod +x "$STUB_DIR/security" "$STUB_DIR/curl"

# judgeDecisionWithStore <store-name>: the hook's permissionDecision with only
# that store holding a key, or "none" when the hook stayed silent. A single
# function because the stub setup and the jq read must both sit inside one
# assertion, and a pipeline cannot.
judgeDecisionWithStore() {
  local store="$1" out
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "sk-ant-stub-key"\n' > "$STUB_DIR/$store"
  chmod +x "$STUB_DIR/$store"
  out=$(printf '%s' "$PAYLOAD" | env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD \
    PATH="$STUB_DIR:$PATH" CLAUDE_ENFORCE_BASE=HEAD~1 \
    CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" "$HOOK" 2>/dev/null)
  rm -f "$STUB_DIR/$store"
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

for store in secret-tool pass; do
  GOT=$(judgeDecisionWithStore "$store")
  [ "$GOT" = "ask" ] || { echo "FAIL: a key held by $store must reach the judge; got $GOT"; exit 1; }
done

# With no store holding a key the judge still fails open, and says so, so the
# stubs above cannot be passing for the wrong reason.
ERRNONE=$(printf '%s' "$PAYLOAD" | env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD \
  PATH="$STUB_DIR:$PATH" CLAUDE_ENFORCE_BASE=HEAD~1 \
  CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" "$HOOK" 2>&1 >/dev/null)
printf '%s' "$ERRNONE" | grep -q "no API key" \
  || { echo "FAIL: with no store holding a key the judge must report that it skipped; got $ERRNONE"; exit 1; }
rm -rf "$STUB_DIR"

echo "llm-rule-judge.test.sh PASS"
