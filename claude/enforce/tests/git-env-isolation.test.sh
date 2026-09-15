#!/usr/bin/env bash
# Regression test for the 2026-09-16 incident: a real `git push` from a
# linked worktree sets GIT_DIR in the pre-push hook's environment, pointing
# at the real repo. Fixture tests build their own throwaway repos with
# `git -C "$sandbox" init`/`config`, but `-C` loses to an inherited GIT_DIR:
# git silently targets GIT_DIR instead of the `-C` path, so a fixture meant
# to touch only its own sandbox reconfigures the real repo instead. That is
# exactly how this repo's own .git/config ended up with core.bare=true and a
# fixture's dummy git identity. Both enforce/tests/run-tests.sh and
# hooks/tests/run-tests.sh now unset GIT_DIR (and friends) before running any
# fixture; this proves that guard actually stops the leak, using a synthetic
# fixture that reproduces the vulnerable `git -C` pattern.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

# A decoy "real" repo, standing in for the repo a worktree push's GIT_DIR
# would point at. Its identity is a sentinel: if any fixture's `git -C`
# targets this repo instead of its own sandbox, the sentinel gets clobbered.
DECOY="$SANDBOX/decoy-real-repo"
git init -q -b main "$DECOY"
git -C "$DECOY" config user.email sentinel@example.com
git -C "$DECOY" config user.name sentinel

run_suite_with_leaked_git_dir() { # run-tests.sh path
    local runner="$1"
    local suite_dir="$SANDBOX/suite"
    rm -rf "$suite_dir"; mkdir -p "$suite_dir"
    cp "$runner" "$suite_dir/run-tests.sh"
    # A synthetic fixture reproducing the vulnerable pattern used throughout
    # this repo's real fixtures: build a sandbox repo with `git -C`.
    cat > "$suite_dir/zzz-vulnerable.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
SANDBOX=$(mktemp -d)
git -C "$SANDBOX" init -q -b main
git -C "$SANDBOX" config user.email should-not-leak@example.com
git -C "$SANDBOX" config user.name should-not-leak
echo PASS
FIXTURE
    chmod +x "$suite_dir/run-tests.sh" "$suite_dir/zzz-vulnerable.test.sh"
    GIT_DIR="$DECOY/.git" bash "$suite_dir/run-tests.sh" >/dev/null 2>&1
}

for RUNNER in "$SCRIPT_DIR/run-tests.sh" "$SCRIPT_DIR/../../hooks/tests/run-tests.sh"; do
    NAME=$(basename "$(dirname "$(dirname "$RUNNER")")")/$(basename "$(dirname "$RUNNER")")
    run_suite_with_leaked_git_dir "$RUNNER"
    check "$NAME does not leak GIT_DIR into a fixture's sandbox repo" \
        [ "$(git -C "$DECOY" config user.email)" = "sentinel@example.com" ]
    check "$NAME leaves the decoy repo non-bare" \
        [ "$(git -C "$DECOY" config core.bare)" = "false" ]
done

exit "$fail"
