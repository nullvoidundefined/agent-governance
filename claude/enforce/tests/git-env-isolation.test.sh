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
SUITE_REACHED_MARKER="$SANDBOX/suite-reached-fixture"
git init -q -b main "$DECOY"
git -C "$DECOY" config user.email sentinel@example.com
git -C "$DECOY" config user.name sentinel

run_suite_with_leaked_git_dir() { # run-tests.sh path, tree name (enforce/tests or hooks/tests)
    local runner="$1" tree="$2"
    # The sandbox mirrors the checkout's layout because run-tests.sh finds its
    # sibling enforce/run-fixture-shards.sh by relative path.
    local claude_dir="$SANDBOX/tree/claude"
    local suite_dir="$claude_dir/$tree"
    rm -rf "$SANDBOX/tree"; mkdir -p "$suite_dir" "$claude_dir/enforce"
    cp "$runner" "$suite_dir/run-tests.sh"
    cp "$SCRIPT_DIR/../run-fixture-shards.sh" "$claude_dir/enforce/run-fixture-shards.sh"
    # A synthetic fixture reproducing the vulnerable pattern used throughout
    # this repo's real fixtures: build a sandbox repo with `git -C`.
    cat > "$suite_dir/zzz-vulnerable.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
SANDBOX=$(mktemp -d)
git -C "$SANDBOX" init -q -b main
git -C "$SANDBOX" config user.email should-not-leak@example.com
git -C "$SANDBOX" config user.name should-not-leak
touch "$SUITE_REACHED_MARKER"
echo PASS
FIXTURE
    chmod +x "$suite_dir/run-tests.sh" "$suite_dir/zzz-vulnerable.test.sh"
    rm -f "$SUITE_REACHED_MARKER"
    GIT_DIR="$DECOY/.git" SUITE_REACHED_MARKER="$SUITE_REACHED_MARKER" bash "$suite_dir/run-tests.sh" >/dev/null 2>&1
    SUITE_STATUS=$?
}

for RUNNER in "$SCRIPT_DIR/run-tests.sh" "$SCRIPT_DIR/../../hooks/tests/run-tests.sh"; do
    NAME=$(basename "$(dirname "$(dirname "$RUNNER")")")/$(basename "$(dirname "$RUNNER")")
    run_suite_with_leaked_git_dir "$RUNNER" "$NAME"
    # Without these two, a suite that exits before reaching the synthetic
    # fixture passes both decoy checks below without testing anything (PR #42
    # review: run-tests.sh gained a sibling runner the old sandbox lacked).
    check "$NAME runs to completion in the sandbox" [ "$SUITE_STATUS" -eq 0 ]
    check "$NAME reaches the synthetic fixture" [ -e "$SUITE_REACHED_MARKER" ]
    check "$NAME does not leak GIT_DIR into a fixture's sandbox repo" \
        [ "$(git -C "$DECOY" config user.email)" = "sentinel@example.com" ]
    check "$NAME leaves the decoy repo non-bare" \
        [ "$(git -C "$DECOY" config core.bare)" = "false" ]
done

exit "$fail"
