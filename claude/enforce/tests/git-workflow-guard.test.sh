#!/usr/bin/env bash
# git-workflow-guard: a push to main or master or a force push asks, a
# gh pr merge with a recorded review passes, a merge without one or with a
# merge-commit strategy is denied, everything else passes.
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
# A stub gh serves the PR body: with a Review section the merge passes (owner,
# 2026-10-04: Claude merges without asking); without one it is denied; when gh
# cannot read the body the merge asks.
STUB=$(mktemp -d); trap 'rm -rf "$REPO" "$STUB"' EXIT
cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
[ -n "${GH_BODY_FAIL:-}" ] && exit 1
# Serve the body only for the expected PR (and repo, when one is expected).
[ "$3" = "${GH_EXPECT_PR:-5}" ] || exit 1
[ -z "${GH_EXPECT_REPO:-}" ] || [ "$4 $5" = "--repo $GH_EXPECT_REPO" ] || exit 1
printf '%s\n' "$GH_BODY"
GH
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"
export GH_BODY=$'## Summary\nx\n\n## Review\n- reviewer: pr-reviewer'
expect none "gh pr merge 5 --squash"
expect deny "gh pr merge 5 --merge"
GH_BODY=$'## Summary\nno review here\n### Review notes' expect deny "gh pr merge 5 --squash"
GH_BODY_FAIL=1 expect ask "gh pr merge 5 --squash"
expect deny "gh pr merge 5 -m"
NO_REVIEW=$'## Summary\nnone'
GH_BODY="$NO_REVIEW" GH_EXPECT_REPO=o/r expect deny "gh pr merge --repo o/r 5 --squash"
GH_BODY="$NO_REVIEW" GH_EXPECT_REPO=o/r expect deny "gh pr merge -R o/r 5 -t title --squash"
GH_EXPECT_REPO=o/r expect none "gh pr merge --repo o/r 5 --squash"
# --admin skips branch protection, including required CI, so it still asks.
expect ask "gh pr merge 5 --squash --admin"
git -C "$REPO" checkout -q -b main
expect ask "git push"
expect ask "git push origin HEAD"
# The settings.json ask rule would prompt for the merge the hook now passes.
SETTINGS="$(dirname "$HOOK")/../settings.json"
if jq -e '.permissions.ask | index("Bash(gh pr merge*)") == null' "$SETTINGS" >/dev/null; then
  echo "PASS: settings.json does not ask before gh pr merge"
else
  echo "FAIL: settings.json still asks before gh pr merge"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS: git-workflow-guard"
exit "$fail"
