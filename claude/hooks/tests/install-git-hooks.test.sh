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
    grep -q "Git pre-push hook for the agent-governance repo" "$TARGET"
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
    grep -q "Git pre-push hook for the agent-governance repo" "$TARGET"
check "upgrade reports itself as an upgrade" \
    grep -qi "upgrad" <<<"$out"

# 5. The replaced legacy hook is recoverable.
check "legacy hook is backed up" test -f "$TARGET.legacy.bak"
check "backup holds the original legacy body" \
    grep -q "2026-07-31 engineering audit P1" "$TARGET.legacy.bak"

# 5b. The pre-monorepo sample header is also a superseded predecessor
# (2026-09-16 audit P1-2: the sample was rewritten to validate the pushed
# repo, and installed copies of the old sample must upgrade, not refuse).
fresh_repo "$REPO"
printf '#!/usr/bin/env bash\n# Git pre-push hook for the ~/.claude repo: a red fixture suite aborts the push.\nexit 0\n' > "$TARGET"; chmod +x "$TARGET"
run_install "$REPO"
check "upgrades the pre-monorepo sample instead of refusing" test "$rc" -eq 0
check "pre-monorepo upgrade carries the current marker" \
    grep -q "Git pre-push hook for the agent-governance repo" "$TARGET"

# 6. A non-repo target is still rejected.
NON_REPO="$SANDBOX/plain"; mkdir -p "$NON_REPO"
run_install "$NON_REPO"
check "rejects a path that is not a git work tree" test "$rc" -eq 1

# A relative core.hooksPath beginning .git/ is the form that silently disables
# every hook in a linked worktree, where .git is a file rather than a directory.
# The installer must name that specifically rather than emitting only its
# generic "hooksPath is set" note, because the generic note reads as harmless
# and this form is not (2026-09-18: a full session of lane worktrees pushed
# with no pre-push gate).
RELATIVE_REPO=$(mktemp -d)
git -C "$RELATIVE_REPO" init -q .
git -C "$RELATIVE_REPO" config core.hooksPath ".git/hooks"
run_install "$RELATIVE_REPO"
relativeFormWarned() { grep -q "runs NO hooks there" <<< "$out"; }
relativeFormNamesRepair() { grep -q -- "--unset core.hooksPath" <<< "$out"; }
check "a relative .git/ hooksPath is called out, not merely noted" relativeFormWarned
check "the warning names the repair" relativeFormNamesRepair

# An absolute hooksPath inside the repo is fine in both layouts and must keep
# getting the generic note only, so the new warning cannot become noise.
ABSOLUTE_REPO=$(mktemp -d)
git -C "$ABSOLUTE_REPO" init -q .
mkdir -p "$ABSOLUTE_REPO/githooks"
git -C "$ABSOLUTE_REPO" config core.hooksPath "$ABSOLUTE_REPO/githooks"
run_install "$ABSOLUTE_REPO"
absoluteFormNotWarned() { ! grep -q "runs NO hooks there" <<< "$out"; }
check "an absolute hooksPath draws no worktree warning" absoluteFormNotWarned

# The installed pre-push runs no fixture suite (IAN-98, 2026-09-18): the full
# suite is CI's required "fixtures" check, and the local copy doubled every
# push's wait. Each stub suite would leave SUITE_RAN behind if it ran.
SUITE_REPO=$(mktemp -d)
git -C "$SUITE_REPO" init -q .
mkdir -p "$SUITE_REPO/claude/enforce/tests" "$SUITE_REPO/claude/hooks/tests"
for suite in enforce hooks; do
  printf 'touch "%s/SUITE_RAN"\nexit 0\n' "$SUITE_REPO" > "$SUITE_REPO/claude/$suite/tests/run-tests.sh"
done
run_install "$SUITE_REPO"
( cd "$SUITE_REPO" && bash .git/hooks/pre-push origin example </dev/null >/dev/null 2>&1 ) || true
noSuiteRan() { [ ! -e "$SUITE_REPO/SUITE_RAN" ]; }
check "the pre-push runs no fixture suite" noSuiteRan

exit "$fail"
