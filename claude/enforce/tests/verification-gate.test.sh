#!/usr/bin/env bash
# Covers: hook:verification-gate
# Verifies verification-gate.sh (R-509 Stop gate). Invariants:
#   1. A clean working tree is silent (no check runs, nothing to verify).
#   2. A dirty tree with a passing check is silent.
#   3. A dirty tree with a failing check blocks and pastes the real output.
#   4. stop_hook_active short-circuits, so a red suite cannot loop forever.
#   5. CLAUDE_SKIP_VERIFY bypasses.
#   6. A repo with no discoverable check command fails open.
#   7. .claude/verify.sh wins over package.json discovery.
#   8. A tree the checks already passed on is not re-run until it changes.
#   9. SubagentStop is gated like Stop for a writing subagent, and skipped
#      for a role the policy marks as non-writing (deny ["any"]).
#   10. A check failing once but passing on the automatic retry does not block
#       (2026-09-15 retry addition).
#   11. A check failing twice in a row blocks, naming the retry in the reason.
#   12. A hard timeout (124) never retries.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/verification-gate.sh"
# The sweep that bound HOOK to this checkout left the DATA the hook reads at
# runtime still resolving to the installed tree: role-policy.json comes from
# $HOME/.claude unless this override names another copy, so the fixture would
# exercise checkout code against whatever policy the last sync happened to
# write. Pin it to the checkout for the same reason HOOK is pinned.
export CLAUDE_ROLE_POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
export CLAUDE_VERIFY_MEMO_DIR CLAUDE_VERIFY_RETRY_DELAY
CLAUDE_VERIFY_MEMO_DIR=$(mktemp -d)
# Zero by default so tests 1-9 (which don't exercise retry behavior at all)
# don't each pay the real 10s pause on every failing-check assertion. Tests
# 10 and 11 already set this explicitly for clarity; the export just makes
# it the file-wide default too.
CLAUDE_VERIFY_RETRY_DELAY=0

# Runs the hook against a repo and echoes the block reason, or "none".
gate() {
  local dir="$1" active="${2:-false}" event="${3:-Stop}" agent="${4:-}"
  local out
  out=$(jq -n --arg c "$dir" --argjson a "$active" --arg e "$event" --arg g "$agent" \
    '{hook_event_name:$e,cwd:$c,stop_hook_active:$a} + (if $g=="" then {} else {agent_type:$g} end)' | "$HOOK")
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

# 10. A check failing once but passing on the automatic retry does not block.
REPO=$(new_repo)
FLAG_FILE=$(mktemp -u)
cat > "$REPO/package.json" <<EOF
{ "name": "fixture", "version": "1.0.0", "scripts": { "test": "if [ -f $FLAG_FILE ]; then exit 0; else touch $FLAG_FILE; exit 1; fi" } }
EOF
GOT=$(CLAUDE_VERIFY_RETRY_DELAY=0 gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: a check passing on retry must not block, got: $GOT"; exit 1; }
rm -f "$FLAG_FILE"

# 11. A check failing twice in a row blocks and names the retry in the reason.
REPO=$(new_repo)
write_package_json "$REPO" 1
GOT=$(CLAUDE_VERIFY_RETRY_DELAY=0 gate "$REPO")
printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: expected an R-509 block after two failures, got: $GOT"; exit 1; }
printf '%s' "$GOT" | grep -q 'automatic retry' || { echo "FAIL: block reason must note the automatic retry, got: $GOT"; exit 1; }

# 12. A hard timeout (124) never retries: runs exactly once.
REPO=$(new_repo)
RUN_LOG=$(mktemp)
cat > "$REPO/package.json" <<EOF
{ "name": "fixture", "version": "1.0.0", "scripts": { "test": "echo run >> $RUN_LOG; sleep 2" } }
EOF
GOT=$(CLAUDE_VERIFY_TIMEOUT=1 CLAUDE_VERIFY_RETRY_DELAY=0 gate "$REPO")
printf '%s' "$GOT" | grep -q 'CLAUDE_VERIFY_TIMEOUT' || { echo "FAIL: expected a timeout block, got: $GOT"; exit 1; }
printf '%s' "$GOT" | grep -qv 'automatic retry' || { echo "FAIL: a timeout must not report an automatic retry"; exit 1; }
RUNS=$(wc -l < "$RUN_LOG" | tr -d ' ')
[ "$RUNS" = "1" ] || { echo "FAIL: a timeout must not retry, expected 1 run, got $RUNS"; exit 1; }

# 9. SubagentStop: a writing subagent is gated; a non-writing role is skipped.
REPO=$(new_repo)
write_package_json "$REPO" 1
GOT=$(gate "$REPO" false SubagentStop implementer)
printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: SubagentStop for an implementer must block on red, got: $GOT"; exit 1; }
GOT=$(gate "$REPO" false SubagentStop general-purpose)
printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: SubagentStop for an unlisted agent type must block on red, got: $GOT"; exit 1; }
GOT=$(gate "$REPO" false SubagentStop)
printf '%s' "$GOT" | grep -q 'R-509' || { echo "FAIL: SubagentStop with no agent_type must block on red, got: $GOT"; exit 1; }
GOT=$(gate "$REPO" false SubagentStop slice-critic)
[ "$GOT" = "none" ] || { echo "FAIL: SubagentStop for the critic must be skipped, got: $GOT"; exit 1; }
GOT=$(gate "$REPO" false SubagentStop spec-conformance-review)
[ "$GOT" = "none" ] || { echo "FAIL: SubagentStop for the conformance reviewer must be skipped, got: $GOT"; exit 1; }
GOT=$(gate "$REPO" true SubagentStop implementer)
[ "$GOT" = "none" ] || { echo "FAIL: stop_hook_active must short-circuit SubagentStop too, got: $GOT"; exit 1; }

# 13. Monorepo layout: the governance suites one level down under claude/ are
# discovered (2026-09-16 audit P1-1: the toplevel-only lookup found nothing at
# the agent-governance root, so R-509 ran no checks in the one repo that
# enforces it).
REPO=$(new_repo)
mkdir -p "$REPO/claude/enforce/tests" "$REPO/claude/hooks/tests"
touch "$REPO/claude/CLAUDE.md"
printf 'echo MONOREPO_SUITE_MARKER\nexit 1\n' > "$REPO/claude/enforce/tests/run-tests.sh"
printf 'exit 0\n' > "$REPO/claude/hooks/tests/run-tests.sh"
GOT=$(gate "$REPO")
printf '%s' "$GOT" | grep -q 'MONOREPO_SUITE_MARKER' || { echo "FAIL: monorepo claude/ suites must be discovered and block on red, got: $GOT"; exit 1; }

# 14. P2-5 (2026-09-17 audit): the turn-end gate ran two checks in this repo
# while pre-push and CI ran three, so a turn could end green on a tree whose
# codex port was stale. The translator check joins the monorepo branch, and
# only there: a checkout with no translate/ must not gain a failing check.
REPO=$(new_repo)
mkdir -p "$REPO/claude/enforce/tests" "$REPO/claude/hooks/tests" "$REPO/translate"
touch "$REPO/claude/CLAUDE.md"
printf 'exit 0
' > "$REPO/claude/enforce/tests/run-tests.sh"
printf 'exit 0
' > "$REPO/claude/hooks/tests/run-tests.sh"
printf 'console.log("TRANSLATOR_MARKER"); process.exit(1);
' > "$REPO/translate/codex.mjs"
GOT=$(gate "$REPO")
printf '%s' "$GOT" | grep -q 'TRANSLATOR_MARKER' || { echo "FAIL: a stale codex port must block the turn, got: $GOT"; exit 1; }

REPO=$(new_repo)
mkdir -p "$REPO/claude/enforce/tests" "$REPO/claude/hooks/tests"
touch "$REPO/claude/CLAUDE.md"
printf 'exit 0
' > "$REPO/claude/enforce/tests/run-tests.sh"
printf 'exit 0
' > "$REPO/claude/hooks/tests/run-tests.sh"
GOT=$(gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: a checkout with no translate/ must stay green, got: $GOT"; exit 1; }

echo "verification-gate.test.sh PASS"
