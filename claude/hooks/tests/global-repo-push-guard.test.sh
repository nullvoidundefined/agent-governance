#!/usr/bin/env bash
# Covers: hook:global-repo-push-guard
# Test harness for global-repo-push-guard.sh (backs R-106).
#
# R-106: before pushing the public agent-governance repo, verify the
# outgoing diff carries no secrets and no local filesystem paths. The hook
# gates `git push` when (and only when) the repo is the governance repo,
# recognized per repo-identity.sh by its `origin` remote URL (durable) or
# the legacy ~/.claude toplevel path. Fixtures drive the REMOTE identity:
# the 2026-09-16 audit (P0-1) found the previous fixture building the
# vanished "~/.claude is the repo" world, keeping the suite green while
# the live guard was dead. The origin path embeds the remote ID substring
# so recognition works exactly the way a real clone's origin URL does.
#
# Fixtures are generated at runtime so this test file never embeds a
# literal secret or a real home path that the guard would later flag on
# its own push.
#
# Run: hooks/tests/global-repo-push-guard.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../global-repo-push-guard.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

# The origin path carries the governance remote ID, so `git remote get-url
# origin` identifies the checkout the same way a real GitHub URL would.
ORIGIN="$SANDBOX/nullvoidundefined/agent-governance.git"
REPO="$SANDBOX/checkout"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

setup_repo() { # repo-dir, origin-dir
    rm -rf "$1" "$2"
    mkdir -p "$(dirname "$2")"
    git init -q --bare "$2"
    git init -q -b main "$1"
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name test
    git -C "$1" remote add origin "$2"
    printf 'clean rule content\n' > "$1/rules.md"
    git -C "$1" add rules.md
    git -C "$1" commit -qm init
    git -C "$1" push -q origin main
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
setup_repo "$REPO" "$ORIGIN"
commit_to "$REPO" "doc reference: $HOME/projects/notes.md"
check "deny real home-path leak" emits_deny "$REPO" "git push origin main"

# 2. DENY: outgoing diff contains a secret (built at runtime, not literal).
setup_repo "$REPO" "$ORIGIN"
FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 35))"
commit_to "$REPO" "token = $FAKE_TOKEN"
check "deny planted secret" emits_deny "$REPO" "git push"

# 3. ALLOW: clean diff with only a generic example path.
setup_repo "$REPO" "$ORIGIN"
commit_to "$REPO" "example: import from /Users/someuser/app/x"
check "allow clean diff with generic example path" emits_nothing "$REPO" "git push"

# 4. PASSTHROUGH: a repo whose origin is NOT the governance remote is ignored.
OTHER="$SANDBOX/other-checkout"
OTHER_ORIGIN="$SANDBOX/other-origin.git"
setup_repo "$OTHER" "$OTHER_ORIGIN"
commit_to "$OTHER" "doc reference: $HOME/projects/notes.md"
check "passthrough push from unrelated repo" emits_nothing "$OTHER" "git push"

# 5. LEGACY: a repo at ~/.claude with an unrelated origin is still gated.
LEGACY="$HOME/.claude"
LEGACY_ORIGIN="$SANDBOX/legacy-origin.git"
setup_repo "$LEGACY" "$LEGACY_ORIGIN"
commit_to "$LEGACY" "doc reference: $HOME/projects/notes.md"
check "deny leak from legacy ~/.claude layout" emits_deny "$LEGACY" "git push"

# 6. PASSTHROUGH: a non-push command from the governance repo is ignored.
setup_repo "$REPO" "$ORIGIN"
commit_to "$REPO" "doc reference: $HOME/projects/notes.md"
check "passthrough non-push command" emits_nothing "$REPO" "git status"

# 7. FAIL CLOSED: a copy of the guard with no repo-identity.sh beside it asks
# instead of silently allowing (2026-09-16: a bare `source` of a missing file
# kills the shell under set -e with no output, which is an allow).
ORPHAN_DIR="$SANDBOX/orphan-hooks"
mkdir -p "$ORPHAN_DIR"
cp "$HOOK" "$ORPHAN_DIR/global-repo-push-guard.sh"
setup_repo "$REPO" "$ORIGIN"
commit_to "$REPO" "doc reference: $HOME/projects/notes.md"
ORPHAN_OUT=$(jq -n --arg cwd "$REPO" --arg cmd "git push" \
    '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}' | bash "$ORPHAN_DIR/global-repo-push-guard.sh")
if grep -q '"permissionDecision": "ask"' <<< "$ORPHAN_OUT"; then
    echo "PASS: missing identity helper fails closed to ask"
else
    echo "FAIL: missing identity helper must ask, got: $ORPHAN_OUT"; fail=1
fi

exit "$fail"
