#!/usr/bin/env bash
# Test harness for install-git-hooks.sh.
#
# The installer shipped untested on 2026-09-04 and its refusal path cost a
# manual `mv` the first time it met the legacy hook it was written to replace.
# The refusal is the point and must survive: a repo carrying its own pre-push
# chain is never silently overwritten. The one exception is this repo's own
# superseded hook, which is identifiable by its header and is upgraded in
# place, backed up first.
#
# Run: ~/.claude/hooks/tests/install-git-hooks.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../install-git-hooks.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

fresh_repo() {
    local dir="$1"
    rm -rf "$dir"; git init -q -b main "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name test
}

# Captures stdout+stderr so the refusal text is assertable; exit code in $rc.
run_install() { out=$(bash "$HOOK" "$1" 2>&1); rc=$?; }

LEGACY_BODY='#!/usr/bin/env bash
# Unversioned git pre-push hook for the ~/.claude repo (documented in SETUP.md;
# 2026-07-31 engineering audit P1: nothing ran the fixture suites automatically).
set -euo pipefail
bash "$HOME/.claude/enforce/tests/run-tests.sh"'

FOREIGN_BODY='#!/usr/bin/env bash
# Some other project hook chain that this installer must never touch.
exec ./scripts/their-own-gate.sh'

REPO="$SANDBOX/proj"
TARGET="$REPO/.git/hooks/pre-push"

# 1. Clean install into a repo with no pre-push.
fresh_repo "$REPO"
run_install "$REPO"
check "installs into a repo with no pre-push" test "$rc" -eq 0
check "installed hook carries the current marker" \
    grep -q "Git pre-push hook for the ~/.claude repo" "$TARGET"
check "installed hook is executable" test -x "$TARGET"

# 2. Re-running over its own output is idempotent.
run_install "$REPO"
check "re-install over its own hook succeeds" test "$rc" -eq 0

# 3. A foreign pre-push is refused, not overwritten.
fresh_repo "$REPO"
printf '%s\n' "$FOREIGN_BODY" > "$TARGET"; chmod +x "$TARGET"
run_install "$REPO"
check "refuses a foreign pre-push" test "$rc" -eq 1
check "foreign pre-push is left byte-for-byte intact" \
    grep -q "their-own-gate" "$TARGET"
check "refusal names the recovery command" \
    grep -q "mv " <<<"$out"

# 4. The superseded legacy hook is upgraded in place.
fresh_repo "$REPO"
printf '%s\n' "$LEGACY_BODY" > "$TARGET"; chmod +x "$TARGET"
run_install "$REPO"
check "upgrades the legacy hook instead of refusing" test "$rc" -eq 0
check "upgraded hook carries the current marker" \
    grep -q "Git pre-push hook for the ~/.claude repo" "$TARGET"
check "upgrade reports itself as an upgrade" \
    grep -qi "upgrad" <<<"$out"

# 5. The replaced legacy hook is recoverable.
check "legacy hook is backed up" test -f "$TARGET.legacy.bak"
check "backup holds the original legacy body" \
    grep -q "2026-07-31 engineering audit P1" "$TARGET.legacy.bak"

# 6. A non-repo target is still rejected.
NON_REPO="$SANDBOX/plain"; mkdir -p "$NON_REPO"
run_install "$NON_REPO"
check "rejects a path that is not a git work tree" test "$rc" -eq 1

exit "$fail"
