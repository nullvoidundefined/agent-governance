#!/usr/bin/env bash
# credential-shape-scan.test.sh: every tracked text file of the checkout,
# pushed through hooks/secret-scan.sh as a Write payload, must not deny
# (R-102 full-length secrets, R-108 credential-shaped literals). The hook
# only runs in a live session; this closes the gap for a file written
# elsewhere (a merge, a port, an editor, a cloud session without the hooks
# installed), which is how the R-108 Spec's own first draft, quoting the
# literal it forbids as its example, reached a PR and turned GitGuardian red
# on 2026-09-17. Runs in CI and at push through enforce/tests/run-tests.sh.
#
# The checkout is found from the resolved ~/.claude (a symlink into it in
# CI; the sync.sh stamp on a synced install); a synced tree with no
# reachable checkout scans ~/.claude itself, which is the same content.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/secret-scan.sh"
CLAUDE_DIR="${CLAUDE_SHAPE_SCAN_ROOT:-$CLAUDE_HARNESS_ROOT}"

if [ -f "$CLAUDE_DIR/.sync-source" ] && [ -d "$(cat "$CLAUDE_DIR/.sync-source")/.git" ]; then
  ROOT=$(cat "$CLAUDE_DIR/.sync-source")
elif git -C "$(readlink -f "$CLAUDE_DIR")" rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT=$(git -C "$(readlink -f "$CLAUDE_DIR")" rev-parse --show-toplevel)
else
  ROOT="$CLAUDE_DIR"
fi

fail=0
scanned=0
while IFS= read -r file; do
  [ -f "$ROOT/$file" ] || continue
  # Binary content is not a place a literal is typed; skip it by the null test.
  if grep -qI . "$ROOT/$file" 2>/dev/null; then :; else continue; fi
  scanned=$((scanned + 1))
  out=$(jq -n --arg p "$ROOT/$file" --rawfile c "$ROOT/$file" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | bash "$HOOK" 2>/dev/null)
  if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = "deny" ]; then
    echo "FAIL: $file carries a secret-shaped literal: $(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | cut -c1-160)"
    fail=1
  fi
done < <(cd "$ROOT" && { git ls-files 2>/dev/null || find . -type f | sed 's#^\./##'; })

[ "$scanned" -gt 0 ] || { echo "FAIL: scanned no files under $ROOT"; exit 1; }
[ "$fail" -eq 0 ] && echo "credential-shape-scan.test.sh PASS ($scanned tracked text files clean under secret-scan.sh)"
exit "$fail"
