#!/usr/bin/env bash
# Verifies audit-signal-check.sh: a push from a repo where a surface has 5+
# commits since the last engineering audit emits an R-801/R-904 advisory via
# additionalContext, names only the surfaces over threshold, never blocks, and
# stays silent after a fresh audit or for non-push commands.
set -euo pipefail
HOOK="$HOME/.claude/hooks/audit-signal-check.sh"

advisory() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // "none"'; fi
}

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

TMP=$(mktemp -d)
cd "$TMP"
git init -q
git config user.email t@t && git config user.name t

# Stale audit on record; 5 commits on src/handlers, 4 on src/services since.
mkdir -p docs/audits src/handlers src/services
echo stub > docs/audits/2020-01-01-engineering.md
git add -A && git commit -qm "chore: init"
for i in 1 2 3 4 5; do
  echo "change $i" > "src/handlers/handler$i.ts"
  git add -A && git commit -qm "feat: handler $i"
done
for i in 1 2 3 4; do
  echo "change $i" > "src/services/service$i.ts"
  git add -A && git commit -qm "feat: service $i"
done

GOT=$(advisory 'git push origin main')
printf '%s' "$GOT" | grep -q 'src/handlers' || { echo "FAIL: advisory missing src/handlers, got: $GOT"; exit 1; }
printf '%s' "$GOT" | grep -q 'R-801' || { echo "FAIL: advisory missing R-801, got: $GOT"; exit 1; }
printf '%s' "$GOT" | grep -q 'src/services' && { echo "FAIL: under-threshold src/services flagged: $GOT"; exit 1; }

# Advisory only: the permission decision is never set.
GOT=$(decision 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected no permission decision, got $GOT"; exit 1; }

# Fresh audit dated today covers all commits -> silent.
echo stub > "docs/audits/$(date +%F)-engineering.md"
git add -A && git commit -qm "docs(audit): engineering report"
GOT=$(advisory 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected silence after fresh audit, got: $GOT"; exit 1; }

# No audit on record -> 30-day fallback window catches the commits and says so.
rm docs/audits/*-engineering.md
GOT=$(advisory 'git push origin main')
printf '%s' "$GOT" | grep -qi 'no engineering audit' || { echo "FAIL: expected no-audit-on-record advisory, got: $GOT"; exit 1; }

# Non-push commands untouched.
GOT=$(advisory 'git status')
[ "$GOT" = "none" ] || { echo "FAIL: expected none for non-push, got $GOT"; exit 1; }

cd / && rm -rf "$TMP"
echo "audit-signal-check.test.sh PASS"
