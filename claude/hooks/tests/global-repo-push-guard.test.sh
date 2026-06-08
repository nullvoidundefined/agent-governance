#!/usr/bin/env bash
# Test harness for global-repo-push-guard.sh (backs R-108).
#
# R-108: before pushing the public ~/.claude repo, verify the outgoing
# diff carries no secrets and no local filesystem paths. This hook gates
# `git push` when (and only when) the repo root is ~/.claude, scanning
# `git diff origin/main` for known secret patterns and for THIS machine's
# real home path (the actual leak vector). Generic example paths like
# /Users/someuser in docs are intentionally allowed.
#
# Fixtures are generated at runtime so this test file never embeds a
# literal secret or a real home path that the guard would later flag on
# its own push.
#
# Run: ~/.claude/hooks/tests/global-repo-push-guard.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../global-repo-push-guard.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

ORIGIN="$SANDBOX/origin.git"
REPO="$HOME/.claude"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

setup_clean_repo() {
    rm -rf "$REPO" "$ORIGIN"
    git init -q --bare "$ORIGIN"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    git -C "$REPO" remote add origin "$ORIGIN"
    printf 'clean rule content\n' > "$REPO/rules.md"
    git -C "$REPO" add rules.md
    git -C "$REPO" commit -qm init
    git -C "$REPO" push -q origin main
}

commit_to() { # repo, line
    printf '%s\n' "$2" >> "$1/rules.md"
    git -C "$1" add rules.md
    git -C "$1" commit -qm change
}

run_guard() { # cwd, command
    jq -n --arg cwd "$1" --arg cmd "$2" \
        '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}' | bash "$HOOK"
}
emits_deny()    { run_guard "$@" | grep -q '"permissionDecision": "deny"'; }
emits_nothing() { [ -z "$(run_guard "$@")" ]; }

# 1. DENY: outgoing diff leaks this machine's real home path.
setup_clean_repo
commit_to "$REPO" "doc reference: $HOME/projects/notes.md"
check "deny real home-path leak" emits_deny "$REPO" "git push origin main"

# 2. DENY: outgoing diff contains a secret (built at runtime, not literal).
setup_clean_repo
FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 35))"
commit_to "$REPO" "token = $FAKE_TOKEN"
check "deny planted secret" emits_deny "$REPO" "git push"

# 3. ALLOW: clean diff with only a generic example path.
setup_clean_repo
commit_to "$REPO" "example: import from /Users/someuser/app/x"
check "allow clean diff with generic example path" emits_nothing "$REPO" "git push"

# 4. PASSTHROUGH: push from a repo that is NOT ~/.claude is ignored.
OTHER="$SANDBOX/other"
rm -rf "$OTHER"; git init -q -b main "$OTHER"
git -C "$OTHER" config user.email t@example.com; git -C "$OTHER" config user.name test
commit_to "$OTHER" "doc reference: $HOME/projects/notes.md"
check "passthrough push from non-claude repo" emits_nothing "$OTHER" "git push"

# 5. PASSTHROUGH: a non-push command from ~/.claude is ignored.
setup_clean_repo
commit_to "$REPO" "doc reference: $HOME/projects/notes.md"
check "passthrough non-push command" emits_nothing "$REPO" "git status"

exit "$fail"
