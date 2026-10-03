#!/usr/bin/env bash
# git-workflow-guard: a push to main or master or a force push asks, every
# gh pr merge asks, a merge-commit strategy is denied, everything else passes.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)/git-workflow-guard.sh"
REPO=$(mktemp -d); trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q -b feature && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
fail=0
decision() {
  jq -n --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$HOOK" |
    jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null | grep . || echo none
}
expect() {
  got=$(decision "$2")
  if [ "$got" = "$1" ]; then echo "PASS: $1 for: $2"; else echo "FAIL: expected $1, got $got for: $2"; fail=1; fi
}
expect none "git push origin feature"
expect none "git status"
expect none "echo git push origin main"
expect none "git commit -m 'push to main'"
expect ask "git push origin main"
expect ask "git push origin HEAD:master"
expect ask "git push -f origin feature"
expect ask "git push origin +feature"
expect ask "git push --delete origin feature"
expect ask "bash -c 'git push origin main'"
expect ask "sudo env A=1 /usr/bin/git -C . push origin feature:main"
expect ask "gh pr merge 5 --squash"
expect deny "gh pr merge 5 --merge"
git -C "$REPO" checkout -q -b main
expect ask "git push"
expect ask "git push origin HEAD"
[ "$fail" -eq 0 ] && echo "PASS: git-workflow-guard"
exit "$fail"
