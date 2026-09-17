#!/usr/bin/env bash
# Covers: hook:handoff-check
# handoff-check.test.sh: verifies hooks/handoff-check.sh (R-602 reminder,
# 2026-09-17 skills audit S-5): silent on a handoff that meets the Spec and on
# any other path; reminds naming the miss on an oversized file, a missing
# section, sections out of order, a missing SHA, and a SHA that does not
# resolve; exits 0 on malformed input.
set -uo pipefail
HOOK="$HOME/.claude/hooks/handoff-check.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }
silent() { [ -z "$OUT" ]; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/docs/session-handoff"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"
SHA=$(git -C "$REPO" rev-parse --short HEAD)
FILE="$REPO/docs/session-handoff/session-handoff.md"

good() {
cat <<EOF
# Session Handoff: test

## 1. Last commit
- \`$SHA\` init

## 2. Production state
- fine

## 3. Session metrics
- Commits this session: 1

## 4. What shipped
- a.txt

## 5. Pending
- nothing

## 6. Next session: read first
- README
EOF
}
run() { jq -n --arg p "$1" --rawfile c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | bash "$HOOK" 2>&1; }

good > "$SB/good.md"
OUT=$(run "$FILE" "$SB/good.md")
check "compliant handoff is silent" silent

OUT=$(run "$REPO/docs/other.md" "$SB/good.md")
check "other path is silent" silent

good | sed 's/^## 3. Session metrics/## 3. Timings/' > "$SB/nometrics.md"
OUT=$(run "$FILE" "$SB/nometrics.md")
check "missing section named" reports "no section for: session metrics"
check "reminder is PostToolUse json" bash -c "printf '%s' \"\$0\" | jq -e '.hookSpecificOutput.hookEventName == \"PostToolUse\"' >/dev/null" "$OUT"

good | awk '/^## 4\. What shipped/{buf=$0; getline; buf=buf"\n"$0; getline; buf=buf"\n"$0; hold=buf; next} /^## 5\. Pending/{print; getline; print; getline; print; print hold; next} {print}' > "$SB/disordered.md"
OUT=$(run "$FILE" "$SB/disordered.md")
check "out-of-order section named" reports "out of order: pending"

good | sed "s/\`$SHA\`/\`deadbeef0\`/" > "$SB/badsha.md"
OUT=$(run "$FILE" "$SB/badsha.md")
check "unresolvable sha named" reports "deadbeef0 does not resolve"

good | sed "s/\`$SHA\` init/no sha here/" > "$SB/nosha.md"
OUT=$(run "$FILE" "$SB/nosha.md")
check "missing sha named" reports "no commit SHA in backticks"

{ good; printf 'x%.0s' $(seq 1 8200); printf '\n'; } > "$SB/big.md"
OUT=$(run "$FILE" "$SB/big.md")
check "oversized handoff named" reports "over the 8 KB cap"

OUT=$(printf 'not json' | bash "$HOOK" 2>&1); ST=$?
check "malformed input exits 0" test "$ST" -eq 0
check "malformed input is silent" silent

[ "$fail" -eq 0 ] && echo "handoff-check.test.sh PASS"
exit "$fail"
