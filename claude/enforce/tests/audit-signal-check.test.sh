#!/usr/bin/env bash
# Covers: hook:audit-signal-check
# Verifies audit-signal-check.sh: a push from a repo where a surface has 5+
# commits since the last engineering audit emits an R-801/R-904 advisory via
# additionalContext, names only the surfaces over threshold, never blocks, and
# stays silent after a fresh audit or for non-push commands.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/audit-signal-check.sh"

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
grep -q 'src/handlers' <<< "$GOT" || { echo "FAIL: advisory missing src/handlers, got: $GOT"; exit 1; }
grep -q 'R-801' <<< "$GOT" || { echo "FAIL: advisory missing R-801, got: $GOT"; exit 1; }
grep -q 'src/services' <<< "$GOT" && { echo "FAIL: under-threshold src/services flagged: $GOT"; exit 1; }

# Advisory only: the permission decision is never set.
GOT=$(decision 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected no permission decision, got $GOT"; exit 1; }

# Fresh audit dated today covers all commits -> silent.
echo stub > "docs/audits/$(date +%F)-engineering.md"
git add -A && git commit -qm "docs(audit): engineering report"
GOT=$(advisory 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected silence after fresh audit, got: $GOT"; exit 1; }

# Suffixed report filename counts as an audit on record (2026-07-31 audit P3:
# the glob missed 2026-07-31-engineering-harness.md and would have re-signaled
# immediately after a full-harness audit).
rm docs/audits/*-engineering.md
echo stub > "docs/audits/$(date +%F)-engineering-harness.md"
git add -A && git commit -qm "docs(audit): full-harness engineering report"
GOT=$(advisory 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected silence with fresh suffixed audit, got: $GOT"; exit 1; }

# No audit on record -> 30-day fallback window catches the commits and says so.
rm docs/audits/*-engineering*.md
GOT=$(advisory 'git push origin main')
grep -qi 'no engineering audit' <<< "$GOT" || { echo "FAIL: expected no-audit-on-record advisory, got: $GOT"; exit 1; }

# Nested docs trees are excluded like the top-level one (2026-09-16 audit
# P1-3: claude/docs was counted as an engineering surface despite the header
# promising docs are excluded).
for i in 1 2 3 4 5; do
  mkdir -p claude/docs/handoffs
  echo "note $i" > "claude/docs/handoffs/note$i.md"
  git add -A && git commit -qm "docs: note $i"
done
GOT=$(advisory 'git push origin main')
grep -q 'claude/docs' <<< "$GOT" && { echo "FAIL: nested docs tree counted as a surface: $GOT"; exit 1; }

# Non-push commands untouched.
GOT=$(advisory 'git status')
[ "$GOT" = "none" ] || { echo "FAIL: expected none for non-push, got $GOT"; exit 1; }

cd / && rm -rf "$TMP"
echo "audit-signal-check.test.sh PASS"
