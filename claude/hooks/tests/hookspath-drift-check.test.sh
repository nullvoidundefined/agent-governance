#!/usr/bin/env bash
# Test harness for hookspath-drift-check.sh (backs R-107).
#
# R-107: a git core.hooksPath that points outside the repo tree is a
# supply-chain signal. This SessionStart hook emits an additionalContext
# warning (never blocks) when the current repo's core.hooksPath resolves
# outside the repo, and stays silent when hooksPath is unset, points
# inside the repo, or the cwd is not a git repo.
#
# Run: ~/.claude/hooks/tests/hookspath-drift-check.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hookspath-drift-check.sh"

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

run_in() { ( cd "$1" && echo '{}' | bash "$HOOK" ); }
warns()         { run_in "$1" | grep -q 'hooksPath'; }
emits_nothing() { [ -z "$(run_in "$1")" ]; }

REPO="$SANDBOX/proj"
OUTSIDE="$SANDBOX/evil-hooks"

# 1. WARN: hooksPath points to an absolute path outside the repo.
fresh_repo "$REPO"
git -C "$REPO" config core.hooksPath "$OUTSIDE"
check "warn when hooksPath is outside the repo" warns "$REPO"

# 2. SILENT: hooksPath unset (default).
fresh_repo "$REPO"
check "silent when hooksPath unset" emits_nothing "$REPO"

# 3. SILENT: hooksPath inside the repo (.git/hooks).
fresh_repo "$REPO"
git -C "$REPO" config core.hooksPath ".git/hooks"
check "silent when hooksPath is inside the repo" emits_nothing "$REPO"

# 4. SILENT: not a git repo.
NON_REPO="$SANDBOX/plain"
mkdir -p "$NON_REPO"
check "silent when cwd is not a git repo" emits_nothing "$NON_REPO"

exit "$fail"
