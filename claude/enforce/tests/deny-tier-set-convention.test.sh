#!/usr/bin/env bash
# Verifies the P2-8 convention (enforce/README.md, 2026-09-16 audit): every
# hook that can emit a permissionDecision runs without `set -e`, so an
# internal error cannot kill it before it decides (an emitting hook that dies
# silently is an allow, i.e. a guard failing open). Also: no hook sources a
# helper without an -f guard, because a failed `source` aborts the shell even
# behind `|| true`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../../hooks"

# A convention check that inspected nothing must never report PASS. With
# HOOKS_DIR absent or empty the glob below leaves its own literal pattern,
# every grep then fails on a nonexistent file, no check fires, and this
# fixture printed PASS and exited 0 having read zero hooks; the runner could
# not see it either, because the resulting stderr carries neither PASS nor
# FAIL (2026-09-17 audit P1-4). The floor is a real count rather than merely
# non-zero, so a truncated or wrong tree fails just as loudly as an empty one.
MIN_HOOKS=20

fail=0
inspected=0
for hook in "$HOOKS_DIR"/*.sh; do
  [ -f "$hook" ] || continue
  name=$(basename "$hook")
  case "$name" in install-git-hooks.sh|pre-push.sample) continue ;; esac
  inspected=$((inspected + 1))
  # Blocking guards emit either shape: `permissionDecision` on PreToolUse, or
  # the top-level `decision: "block"` that ConfigChange takes. Keying on the
  # first spelling alone left settings-change-guard.sh, which blocks a bad
  # settings file, outside the convention written to cover it (audit P1-4).
  if grep -qE 'permissionDecision|decision: "block"' "$hook" && grep -q '^set -euo pipefail' "$hook"; then
    echo "FAIL: $name emits decisions but runs set -e (fails open on internal error, P2-8)"
    fail=1
  fi
  if grep -qE '^\s*source [^;]*\|\| true' "$hook"; then
    echo "FAIL: $name sources a helper behind || true; a missing file still aborts the shell. Use an [ -f ] guard."
    fail=1
  fi
done

if [ "$inspected" -lt "$MIN_HOOKS" ]; then
  echo "FAIL: inspected $inspected hooks, expected at least $MIN_HOOKS; HOOKS_DIR=$HOOKS_DIR is absent, empty, or not the hook tree, so this fixture proved nothing"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "deny-tier-set-convention.test.sh PASS ($inspected hooks inspected)"
exit "$fail"
