#!/usr/bin/env bash
# Test harness for git-invocation.sh (backs the 2026-09-16 audit P2-1 fix).
#
# The 2026-08-21 audit closed the `git -C` / `git -c` push-boundary bypass by
# enumerating those two options; every other global option (`--no-pager`,
# `--git-dir=...`, `--work-tree`, `-p`, ...) reopened the same class. The
# normalizer strips the whole class once; this corpus pins it, and two
# integration cases prove the strip reaches a real guard's decision.
#
# Run: hooks/tests/git-global-option-bypass.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../git-invocation.sh"

fail=0
expect() { # name, input, want
    local got
    got=$(printf '%s' "$2" | strip_git_global_options)
    if [ "$got" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1: got [$got] want [$3]"; fail=1; fi
}

# Option-prefixed invocations normalize to adjacency.
expect "plain push untouched"        "git push origin main"                       "git push origin main"
expect "-C with arg"                 "git -C /x/repo push origin main"            "git push origin main"
expect "-c key=value"                "git -c user.email=t@t commit -m x"          "git commit -m x"
expect "--no-pager"                  "git --no-pager push origin main"            "git push origin main"
expect "--git-dir joined"            "git --git-dir=/x/.git push origin main"     "git push origin main"
expect "--git-dir separate"          "git --git-dir /x/.git push origin main"     "git push origin main"
expect "--work-tree + --git-dir"     "git --work-tree=/x --git-dir=/x/.git push" "git push"
expect "short flag -p"               "git -p push origin main"                    "git push origin main"
expect "--exec-path with value"      "git --exec-path=/opt/git push"              "git push"
expect "mixed run of options"        "git --no-pager -C /x -c a=b push"           "git push"
expect "later segment normalized"    "cd /x && git --no-pager push"               "cd /x && git push"
# Text mentioning git in prose still normalizes (same over-match direction as
# the pre-helper -C strip: guards may fire on a quoted string, never miss a
# real invocation); text without a git token is untouched.
expect "git-free text untouched"     "echo no version control words here"         "echo no version control words here"

# Integration: the strip reaches a real decision. git-workflow-guard must ask
# on an option-prefixed direct push to main from a non-exempt repo, exactly
# the case the audit verified as SILENT before the fix.
GUARD="$SCRIPT_DIR/../git-workflow-guard.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"
REPO="$SANDBOX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
echo x > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init

guard_decision() { # command
    jq -n --arg cwd "$REPO" --arg cmd "$1" \
        '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}' | bash "$GUARD" \
        | jq -r '.hookSpecificOutput.permissionDecision // "none"'
}

for cmd in "git push origin main" "git --no-pager push origin main" "git --git-dir=$REPO/.git push origin main"; do
    got=$(guard_decision "$cmd")
    if [ "$got" = "ask" ]; then echo "PASS: guard asks on [$cmd]"; else echo "FAIL: guard must ask on [$cmd], got $got"; fail=1; fi
done

exit "$fail"
