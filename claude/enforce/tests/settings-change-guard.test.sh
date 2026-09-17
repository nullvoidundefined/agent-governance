#!/usr/bin/env bash
# Verifies settings-change-guard.sh (ConfigChange, R-516). Five invariants:
#   1. The live settings.json, which registers every manifest-required hook, passes.
#   2. A copy that drops a required hook is blocked, naming the hook.
#   3. A non-user source is ignored even when the file is broken.
#   4. A file that does not parse is blocked.
#   5. The committed permission shape keeps the inline interpreter form out of
#      auto-approval, checked against the repo checkout rather than $HOME so a
#      local edit cannot decide the verdict.
set -euo pipefail
HOOK="$HOME/.claude/hooks/settings-change-guard.sh"
LIVE="$HOME/.claude/settings.json"
TMP=$(mktemp -d)

run() { jq -n --arg s "$1" --arg f "$2" '{hook_event_name:"ConfigChange",source:$s,file_path:$f}' | CLAUDE_FIRE_LOG=/dev/null "$HOOK" 2>/dev/null; }

# 1. Live settings pass.
OUT=$(run user_settings "$LIVE")
[ -z "$OUT" ] || { echo "FAIL: live settings.json was blocked: $OUT"; exit 1; }

# 2. Dropping git-workflow-guard is blocked and named.
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("git-workflow-guard") | not))' "$LIVE" > "$TMP/dropped.json"
OUT=$(run user_settings "$TMP/dropped.json")
printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null || { echo "FAIL: expected a block when a required hook is dropped, got: $OUT"; exit 1; }
printf '%s' "$OUT" | grep -q 'git-workflow-guard.sh' || { echo "FAIL: block must name the dropped hook, got: $OUT"; exit 1; }

# 3. Other sources are ignored.
OUT=$(run project_settings "$TMP/dropped.json")
[ -z "$OUT" ] || { echo "FAIL: project_settings must not be judged, got: $OUT"; exit 1; }

# 4. Unparseable user settings are blocked.
printf '{ "permissions": { "allow": ["Bash"], }\n' > "$TMP/broken.json"
OUT=$(run user_settings "$TMP/broken.json")
printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null || { echo "FAIL: expected a block on unparseable settings, got: $OUT"; exit 1; }

# 5. The permission shape cannot auto-approve an interpreter wrapper.
#
# Two properties, both learned the hard way and recorded in ISSUES.md before
# this fixture existed. A blanket "Bash" allow entry makes auto mode skip its
# own classifier for every Bash command (ISSUES.md:69, the stated reason the
# lenient list was reversed on 2026-09-15), and `bash -c '...'` wraps its inner
# text away from permission-rule matching (ISSUES.md:11), so an interpreter
# wrapper with no ask entry carries a denied command straight past the deny
# list. Neither property is visible in a diff that only removes an ask line,
# which is exactly how both were reopened on 2026-09-17.
REPO_SETTINGS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/settings.json"
assert_interpreter_guarded() {
  local file="$1" label="$2" blanket asks
  blanket=$(jq -r '[.permissions.allow[]? | select(. == "Bash")] | length' "$file")
  [ "$blanket" -eq 0 ] || { echo "FAIL: $label carries a blanket \"Bash\" allow entry, which makes auto mode skip its classifier for every Bash command (ISSUES.md:69)"; return 1; }
  asks=$(jq -r '[.permissions.ask[]? | select(test("^Bash\\((bash|sh) -l?c "))] | length' "$file")
  [ "$asks" -gt 0 ] || { echo "FAIL: $label has no ask entry on the inline interpreter form, so bash -c can carry a denied command past the deny list (ISSUES.md:11)"; return 1; }
  return 0
}

assert_interpreter_guarded "$REPO_SETTINGS" "the committed settings.json" || exit 1

# The same assertions must reject the shape that reopened both holes, or they
# would pass without testing anything.
jq '.permissions.allow = ["Bash"] | .permissions.ask = [.permissions.ask[] | select(startswith("Bash(bash") or startswith("Bash(sh") | not)]' \
  "$REPO_SETTINGS" > "$TMP/lenient.json"
if assert_interpreter_guarded "$TMP/lenient.json" "the lenient shape" >/dev/null 2>&1; then
  echo "FAIL: invariant 5 accepted a blanket Bash allow with no interpreter ask, so it proves nothing"; exit 1
fi

echo "settings-change-guard.test.sh PASS (5 invariants, interpreter shape checked against the checkout)"
