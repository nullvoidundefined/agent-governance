#!/usr/bin/env bash
# Test harness for pre-push.sample.
#
# Since 2026-09-18 (IAN-98) the sample runs no fixture suite: the full suites
# are CI's required `fixtures` check, and the local copy doubled every push's
# wait. It still runs the port checks from enforce/port-checks.sh. These cases
# pin both halves: red suites in either governance layout no longer block a
# push, and a red port check still does.
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

# write_port_checks <repo> <exit status>: a port-check inventory whose one
# check exits with the given status, standing in for node translate/*.mjs.
write_port_checks() {
    mkdir -p "$1/claude/enforce"
    printf 'listPortChecks() { echo "exit %s"; }\n' "$2" > "$1/claude/enforce/port-checks.sh"
}

# 1. Monorepo layout, red claude/ suites: push proceeds; suites run in CI.
REPO=$(new_repo mono-red)
write_suites "$REPO/claude" 1 1
if run_sample "$REPO"; then echo "PASS: monorepo red suites no longer block the push"; else echo "FAIL: pre-push must not run the monorepo suites"; fail=1; fi

# 2. Toplevel governance layout, red suites: push proceeds too.
REPO=$(new_repo legacy-red)
write_suites "$REPO" 1 1
if run_sample "$REPO"; then echo "PASS: toplevel red suites no longer block the push"; else echo "FAIL: pre-push must not run the toplevel suites"; fail=1; fi

# 3. A red port check aborts the push.
REPO=$(new_repo port-red)
write_port_checks "$REPO" 1
if run_sample "$REPO"; then echo "FAIL: a red port check must abort"; fail=1; else echo "PASS: a red port check aborts"; fi

# 4. A green port check proceeds.
REPO=$(new_repo port-green)
write_port_checks "$REPO" 0
if run_sample "$REPO"; then echo "PASS: a green port check proceeds"; else echo "FAIL: a green port check must proceed"; fail=1; fi

# 5. Nothing to check: fail open.
REPO=$(new_repo bare)
if run_sample "$REPO"; then echo "PASS: a repo with nothing to check proceeds"; else echo "FAIL: a repo with nothing to check must proceed"; fail=1; fi

exit "$fail"
