#!/usr/bin/env bash
# Verifies parallel-session-check.sh warns when another live session holds the
# same working tree (R-501), stays silent when it is alone or when the other
# registration is a dead process, and keys on the tree rather than the session.
set -euo pipefail
HOOK="$HOME/.claude/hooks/parallel-session-check.sh"
LOCK_DIR=$(cd "$(mktemp -d)" && pwd -P)
export CLAUDE_SESSION_LOCK_DIR="$LOCK_DIR"
TREE_A=$(cd "$(mktemp -d)" && pwd -P)
TREE_B=$(cd "$(mktemp -d)" && pwd -P)

run() { printf '{"cwd":"%s"}' "$1" | "$HOOK"; }
key_for() { printf '%s' "$1" | shasum | awk '{print $1}'; }

# A solitary session registers itself and says nothing.
[ -z "$(run "$TREE_A")" ]
[ -s "$LOCK_DIR/$(key_for "$TREE_A")" ]

# A live foreign PID on the same tree is a parallel session.
sleep 30 &
LIVE_PID=$!
printf '%s\n' "$LIVE_PID" >"$LOCK_DIR/$(key_for "$TREE_A")"
case "$(run "$TREE_A")" in *R-501*) ;; *) echo "expected an R-501 warning" >&2; exit 1 ;; esac

# The same live PID registered against a different tree is not a collision.
[ -z "$(run "$TREE_B")" ]

# A dead PID is pruned rather than reported.
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
printf '%s\n' "$LIVE_PID" >"$LOCK_DIR/$(key_for "$TREE_A")"
[ -z "$(run "$TREE_A")" ]
grep -qx "$LIVE_PID" "$LOCK_DIR/$(key_for "$TREE_A")" && { echo "dead PID survived the prune" >&2; exit 1; }

rm -rf "$LOCK_DIR" "$TREE_A" "$TREE_B"
echo "parallel-session-check.test.sh PASS"
