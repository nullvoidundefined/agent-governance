#!/usr/bin/env bash
# Test harness for pre-push.sample (backs R-509 at the git pre-push boundary).
#
# 2026-09-16 audit P1-2: the sample resolved suites from $HOME/.claude (the
# synced live copy) instead of the repo being pushed, so an unsynced change
# was validated against stale code. These cases pin the resolution order:
# claude/ monorepo layout first, toplevel governance layout second, and the
# live-copy fallback only when the checkout carries no suites.
#
# Run: hooks/tests/pre-push-sample.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE="$SCRIPT_DIR/../pre-push.sample"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

fail=0

new_repo() {
    local dir="$SANDBOX/$1"
    rm -rf "$dir"
    git init -q -b main "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name test
    echo "$dir"
}

write_suites() { # root, enforce-exit, hooks-exit
    mkdir -p "$1/enforce/tests" "$1/hooks/tests"
    printf 'exit %s\n' "$2" > "$1/enforce/tests/run-tests.sh"
    printf 'exit %s\n' "$3" > "$1/hooks/tests/run-tests.sh"
}

run_sample() { (cd "$1" && bash "$SAMPLE" >/dev/null 2>&1); }

# 1. Monorepo layout, red claude/ suite: push aborts.
REPO=$(new_repo mono-red)
write_suites "$REPO/claude" 1 0
if run_sample "$REPO"; then echo "FAIL: monorepo red suite must abort"; fail=1; else echo "PASS: monorepo red suite aborts"; fi

# 2. Monorepo layout, green suites: push proceeds.
REPO=$(new_repo mono-green)
write_suites "$REPO/claude" 0 0
if run_sample "$REPO"; then echo "PASS: monorepo green suites proceed"; else echo "FAIL: monorepo green suites must proceed"; fail=1; fi

# 3. The pushed repo wins over a red live copy: an unsynced green checkout
#    must not be failed by stale ~/.claude state.
REPO=$(new_repo checkout-wins)
write_suites "$REPO/claude" 0 0
write_suites "$HOME/.claude" 1 1
if run_sample "$REPO"; then echo "PASS: pushed repo wins over red live copy"; else echo "FAIL: pushed repo must win over the live copy"; fail=1; fi
rm -rf "$HOME/.claude"

# 4. Toplevel governance layout is still recognized.
REPO=$(new_repo legacy-red)
write_suites "$REPO" 1 0
if run_sample "$REPO"; then echo "FAIL: toplevel red suite must abort"; fail=1; else echo "PASS: toplevel red suite aborts"; fi

# 5. No suites anywhere: fail open (a suite-less repo is not blocked).
REPO=$(new_repo bare)
if run_sample "$REPO"; then echo "PASS: suite-less repo proceeds"; else echo "FAIL: suite-less repo must proceed"; fail=1; fi

exit "$fail"
