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

fail=0
for hook in "$HOOKS_DIR"/*.sh; do
  name=$(basename "$hook")
  case "$name" in install-git-hooks.sh|pre-push.sample) continue ;; esac
  if grep -lq 'permissionDecision' "$hook" && grep -q '^set -euo pipefail' "$hook"; then
    echo "FAIL: $name emits decisions but runs set -e (fails open on internal error, P2-8)"
    fail=1
  fi
  if grep -qE '^\s*source [^;]*\|\| true' "$hook"; then
    echo "FAIL: $name sources a helper behind || true; a missing file still aborts the shell. Use an [ -f ] guard."
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "deny-tier-set-convention.test.sh PASS"
exit "$fail"
