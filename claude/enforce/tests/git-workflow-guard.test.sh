#!/usr/bin/env bash
# Verifies git-workflow-guard.sh: asks before a push to main and before any PR
# merge (R-514), denies a non-squash merge (R-512), and warns on a cross-cutting
# commit to main (R-511) and a surface-adding commit with no README (R-508).
set -euo pipefail
HOOK="$HOME/.claude/hooks/git-workflow-guard.sh"
payload() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
decision() {
  local out
  out=$(payload "$1" "${2:-/x}" | "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
warning() { payload "$1" "${2:-/x}" | "$HOOK" 2>&1 >/dev/null; }
warns() {   # warns <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) return 0 ;; *) echo "expected a $1 warning for: $2" >&2; return 1 ;; esac
}
silent_on() {   # silent_on <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) echo "unexpected $1 warning for: $2" >&2; return 1 ;; *) return 0 ;; esac
}

[ "$(decision 'gh pr merge 42 --merge')" = "deny" ]        # wrong strategy (R-512)
[ "$(decision 'gh pr merge 42 --rebase')" = "deny" ]       # wrong strategy, 2nd form
[ "$(decision 'gh pr merge 42 --squash')" = "ask" ]        # right strategy, still needs authorization (R-514)
[ "$(decision 'gh pr view 42')" = "none" ]                 # read-only gh call untouched

# Fixture repo on main, with a remote-free push and a feature branch to compare.
REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/src/routes" "$REPO/src/handlers" "$REPO/src/services"
: >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "chore: seed"

[ "$(decision 'git push' "$REPO")" = "ask" ]                    # implicit target is main (R-514)
[ "$(decision 'git push origin main' "$REPO")" = "ask" ]        # explicit target
[ "$(decision 'git push origin HEAD:main' "$REPO")" = "ask" ]   # refspec form
[ "$(decision 'git push origin HEAD' "$REPO")" = "ask" ]         # HEAD resolves to the checked-out branch
[ "$(decision 'git push origin refs/heads/main' "$REPO")" = "ask" ]     # fully qualified ref
[ "$(decision 'git push origin +main' "$REPO")" = "ask" ]               # force marker on the refspec
[ "$(decision "git -C $REPO push origin main" /tmp)" = "ask" ]          # -C form names the repo, not the cwd
[ "$(decision 'git push origin feature/scoring' "$REPO")" = "ask" ] && exit 1  # a feature branch is not gated
[ "$(decision 'git push' "$HOME/.claude")" = "none" ]           # global repo exempt: R-106 owns its pushes

# R-511: five files across three directories staged on main.
for path in src/routes/jobs.ts src/routes/users.ts src/handlers/scoreJob.ts src/services/score.ts src/services/rank.ts; do
  : >"$REPO/$path"
done
git -C "$REPO" add src
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
# R-508: the staged routes are new surface and no README is staged.
warns R-508 'git commit -m "feat: scoring"' "$REPO"
# Staging the README silences R-508 but not R-511.
printf 'docs\n' >"$REPO/README.md"
git -C "$REPO" add README.md
silent_on R-508 'git commit -m "feat: scoring"' "$REPO"
warns R-511 'git commit -m "feat: scoring"' "$REPO"

# A path holding an apostrophe must not crash the advisory pass.
: >"$REPO/src/services/o'brien.ts"
git -C "$REPO" add "src/services/o'brien.ts"
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
git -C "$REPO" rm -q --cached "src/services/o'brien.ts"
rm -f "$REPO/src/services/o'brien.ts"

# A narrow commit on a feature branch warns about neither.
git -C "$REPO" commit -qm "feat: scoring"
git -C "$REPO" checkout -q -b feature/next
: >"$REPO/src/services/notify.ts"
git -C "$REPO" add src/services/notify.ts
[ -z "$(warning 'git commit -m "feat: notify"' "$REPO")" ]
rm -rf "$REPO"

echo "git-workflow-guard.test.sh PASS"
