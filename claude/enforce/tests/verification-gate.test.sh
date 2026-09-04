#!/usr/bin/env bash
# Verifies verification-gate.sh (R-509 Stop gate). Seven invariants:
#   1. A clean working tree is silent (no check runs, nothing to verify).
#   2. A dirty tree with a passing check is silent.
#   3. A dirty tree with a failing check blocks and pastes the real output.
#   4. stop_hook_active short-circuits, so a red suite cannot loop forever.
#   5. CLAUDE_SKIP_VERIFY bypasses.
#   6. A repo with no discoverable check command fails open.
#   7. .claude/verify.sh wins over package.json discovery.
#   8. A tree the checks already passed on is not re-run until it changes.
set -euo pipefail
HOOK="$HOME/.claude/hooks/verification-gate.sh"
export CLAUDE_VERIFY_MEMO_DIR
CLAUDE_VERIFY_MEMO_DIR=$(mktemp -d)

# Runs the hook against a repo and echoes the block reason, or "none".
gate() {
  local dir="$1" active="${2:-false}"
  local out
  out=$(jq -n --arg c "$dir" --argjson a "$active" '{hook_event_name:"Stop",cwd:$c,stop_hook_active:$a}' | "$HOOK")
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.reason // "none"'; fi
}

new_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo base > "$dir/tracked.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "chore: init"
  echo "$dir"
}

# A node project whose `npm test` exits with the given status and marker.
write_package_json() {
  local dir="$1" status="$2"
  cat > "$dir/package.json" <<EOF
{ "name": "fixture", "version": "1.0.0", "scripts": { "test": "echo GATE_MARKER_OUTPUT; exit $status" } }
EOF
}

# 1. Clean tree stays silent even though a failing check is discoverable.
REPO=$(new_repo)
write_package_json "$REPO" 1
git -C "$REPO" add -A && git -C "$REPO" commit -qm "chore: add package"
GOT=$(gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: expected silence on a clean tree, got: $GOT"; exit 1; }

# 2. Dirty tree, passing check -> silent.
REPO=$(new_repo)
write_package_json "$REPO" 0
GOT=$(gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: expected silence on a passing check, got: $GOT"; exit 1; }

# 3. Dirty tree, failing check -> block carrying R-509 and the real output.
REPO=$(new_repo)
write_package_json "$REPO" 1
GOT=$(gate "$REPO")
printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: expected an R-509 block, got: $GOT"; exit 1; }
printf '%s' "$GOT" | grep -q 'GATE_MARKER_OUTPUT' || { echo "FAIL: block must paste the real command output, got: $GOT"; exit 1; }

# 4. stop_hook_active short-circuits the same failing repo.
GOT=$(gate "$REPO" true)
[ "$GOT" = "none" ] || { echo "FAIL: stop_hook_active must short-circuit, got: $GOT"; exit 1; }

# 5. CLAUDE_SKIP_VERIFY bypasses the same failing repo.
GOT=$(CLAUDE_SKIP_VERIFY=1 gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: CLAUDE_SKIP_VERIFY must bypass, got: $GOT"; exit 1; }

# 6. Dirty tree with nothing discoverable fails open.
REPO=$(new_repo)
echo drift >> "$REPO/tracked.txt"
GOT=$(gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: a repo with no check command must fail open, got: $GOT"; exit 1; }

# 7. .claude/verify.sh overrides package.json discovery.
REPO=$(new_repo)
write_package_json "$REPO" 0
mkdir -p "$REPO/.claude"
printf 'echo VERIFY_SH_MARKER\nexit 1\n' > "$REPO/.claude/verify.sh"
GOT=$(gate "$REPO")
printf '%s' "$GOT" | grep -q 'VERIFY_SH_MARKER' || { echo "FAIL: .claude/verify.sh must win over package.json, got: $GOT"; exit 1; }

# 8. Memo: a passing check runs once per tree state. The script logs each run.
REPO=$(new_repo)
RUN_LOG=$(mktemp)
cat > "$REPO/package.json" <<EOF
{ "name": "fixture", "version": "1.0.0", "scripts": { "test": "echo run >> $RUN_LOG; exit 0" } }
EOF
gate "$REPO" >/dev/null; gate "$REPO" >/dev/null
RUNS=$(wc -l < "$RUN_LOG" | tr -d ' ')
[ "$RUNS" = "1" ] || { echo "FAIL: expected one run on an unchanged green tree, got $RUNS"; exit 1; }
echo drift >> "$REPO/tracked.txt"
gate "$REPO" >/dev/null
RUNS=$(wc -l < "$RUN_LOG" | tr -d ' ')
[ "$RUNS" = "2" ] || { echo "FAIL: expected a re-run after the tree changed, got $RUNS runs"; exit 1; }
# A red run must not be memoized: flip the check to failing, then back.
write_package_json "$REPO" 1
GOT=$(gate "$REPO"); printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: expected a block after the check turned red"; exit 1; }
GOT=$(gate "$REPO"); printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: a red tree was memoized as green"; exit 1; }

echo "verification-gate.test.sh PASS"
