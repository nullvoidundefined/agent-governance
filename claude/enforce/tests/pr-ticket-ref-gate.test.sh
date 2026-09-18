#!/usr/bin/env bash
# Covers: hook:pr-ticket-ref-gate
# Verifies hooks/pr-ticket-ref-gate.sh (R-605): `gh pr create` is denied when
# neither a commit in the pull request's range nor the body passed with
# --body or --body-file carries a `Refs: <KEY>` line; a docs-only range, a
# trivial-tier ledger for the current branch, and an absent tracker config are
# the three exemptions, and the last one allows with a warning rather than in
# silence. A bare rule ID or a string such as SHA-256 is never read as a key,
# and a command that is not `gh pr create` is left alone. Every repository and
# every HOME is a sandbox; the real ~/.claude is never read or written.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/pr-ticket-ref-gate.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY CLAUDE_ENFORCE_BASE
export CLAUDE_FIRE_LOG=/dev/null

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
OUT=""
TRACKED_HOME="$SB/home"
UNTRACKED_HOME="$SB/home-without-tracker"
mkdir -p "$TRACKED_HOME/.claude" "$UNTRACKED_HOME/.claude"
printf '{"tracker":"linear"}\n' > "$TRACKED_HOME/.claude/TICKET-TRACKER.json"

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }

# is_deny: true when the last gate output is a PreToolUse deny.
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "$OUT"; }

# is_silent: true when the last gate output is empty, which is an allow.
is_silent() { [ -z "$OUT" ]; }

# is_warning: true when the last output is non-blocking context, not a deny.
is_warning() {
  jq -e '.hookSpecificOutput.additionalContext != null and .hookSpecificOutput.permissionDecision == null' >/dev/null 2>&1 <<< "$OUT"
}

# output_has <text>: true when the deny reason or the context contains the text.
output_has() {
  jq -r '.hookSpecificOutput | (.permissionDecisionReason // "") + (.additionalContext // "")' <<< "$OUT" | grep -qF -- "$1"
}

# make_repo <name> <commit-message> <path>...: a repository on feat/x whose
# one branch commit adds each path with the given message; prints its path.
make_repo() {
  local dir="$SB/$1" message="$2"; shift 2
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '# app\n' > "$dir/README.md"; git -C "$dir" add -A; git -C "$dir" commit -qm init
  git -C "$dir" switch -q -c feat/x
  local path
  for path in "$@"; do mkdir -p "$dir/$(dirname "$path")"; printf 'x\n' > "$dir/$path"; done
  git -C "$dir" add -A; git -C "$dir" commit -qm "$message"
  printf '%s' "$dir"
}

# payload_for <command>: the PreToolUse Bash payload for one command string.
payload_for() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# run_gate <repo> <command> [home] [base]: runs the hook from inside the
# repository; the base defaults to main, and an empty base leaves the hook to
# resolve it; sets OUT.
run_gate() {
  local base="${4-main}"
  if [ -n "$base" ]; then
    OUT=$(cd "$1" && payload_for "$2" | HOME="${3:-$TRACKED_HOME}" CLAUDE_ENFORCE_BASE="$base" "$HOOK" 2>/dev/null)
  else
    OUT=$(cd "$1" && payload_for "$2" | HOME="${3:-$TRACKED_HOME}" "$HOOK" 2>/dev/null)
  fi
}

CREATE='gh pr create --base main --title "feat: x"'

# No reference anywhere: denied, and the reason names R-605 and the fix.
R=$(make_repo none "feat: add the service" src/service.ts)
run_gate "$R" "$CREATE --body 'Adds the service.'"
check "no reference denies" is_deny
check "deny reason names R-605" output_has "R-605"
check "deny reason names the fix" output_has "/ticket-lifecycle"
check "deny reason names the trailer form" output_has "Refs: <KEY>"

# A Refs trailer on a commit in the range allows.
R=$(make_repo trailer "$(printf 'feat: add the service\n\nBody.\n\nRefs: IAN-119\n')" src/service.ts)
run_gate "$R" "$CREATE --body 'Adds the service.'"
check "commit Refs trailer allows silently" is_silent

# Refs in --body allows, both inline and as a heredoc substitution.
R=$(make_repo body "feat: add the service" src/service.ts)
run_gate "$R" "$CREATE --body 'Refs: IAN-119'"
check "inline --body Refs allows silently" is_silent
run_gate "$R" "$(printf '%s --body "$(cat <<'"'"'EOF'"'"'\n## Summary\n\nAdds the "service".\n\nRefs: IAN-119\nEOF\n)"' "$CREATE")"
check "heredoc --body Refs allows silently" is_silent
run_gate "$R" "gh pr create -b 'Refs: IAN-119'"
check "short -b Refs allows silently" is_silent
run_gate "$R" "gh pr create --body='Refs: IAN-119'"
check "--body= Refs allows silently" is_silent

# Refs in --body-file allows; a body file without it still denies.
printf '## Summary\n\nAdds it.\n\nRefs: IAN-119\n' > "$SB/body-with-ref.md"
printf '## Summary\n\nAdds it.\n' > "$SB/body-without-ref.md"
run_gate "$R" "$CREATE --body-file $SB/body-with-ref.md"
check "--body-file Refs allows silently" is_silent
run_gate "$R" "$CREATE -F \"$SB/body-with-ref.md\""
check "short -F Refs allows silently" is_silent
run_gate "$R" "$CREATE --body-file $SB/body-without-ref.md"
check "--body-file without Refs denies" is_deny

# A -b belonging to an earlier command in the chain is not the PR body.
run_gate "$R" "git checkout -q -b other; gh pr create --body 'Refs: IAN-119'"
check "earlier -b in the chain does not hide the body" is_silent

# Refs only in the title is not a body reference.
run_gate "$R" "gh pr create --body 'Adds it.' --title 'Refs: IAN-119'"
check "Refs in the title alone denies" is_deny

# A docs-only range allows; a mixed range does not.
R=$(make_repo docs "docs: explain it" docs/guide.md NOTES.md)
run_gate "$R" "$CREATE --body 'Docs.'"
check "docs-only range allows silently" is_silent
R=$(make_repo mixed "docs: explain it" docs/guide.md src/service.ts)
run_gate "$R" "$CREATE --body 'Docs.'"
check "docs plus code denies" is_deny

# A trivial-tier ledger for the current branch allows; one left over from
# another branch does not, and neither does a standard tier.
R=$(make_repo trivial "fix: typo" src/service.ts)
mkdir -p "$R/.claude"
printf '{"tier":"trivial","reason":"one line","branch":"feat/x"}\n' > "$R/.claude/task-tier.json"
run_gate "$R" "$CREATE --body 'Typo.'"
check "trivial tier allows silently" is_silent
printf '{"tier":"trivial","reason":"one line","branch":"feat/old"}\n' > "$R/.claude/task-tier.json"
run_gate "$R" "$CREATE --body 'Typo.'"
check "trivial ledger from another branch denies" is_deny
printf '{"tier":"standard","reason":"a feature","branch":"feat/x"}\n' > "$R/.claude/task-tier.json"
run_gate "$R" "$CREATE --body 'Typo.'"
check "standard tier denies" is_deny

# No tracker config: allow, but say so, naming R-605's degraded path.
R=$(make_repo untracked "feat: add the service" src/service.ts)
run_gate "$R" "$CREATE --body 'Adds it.'" "$UNTRACKED_HOME"
check "absent tracker config warns instead of denying" is_warning
check "warning names R-605" output_has "R-605"
check "warning names the tracker config" output_has "TICKET-TRACKER.json"
check "warning names the handoff" output_has "session-handoff.md"

# Strings that look like keys but are not a Refs line never allow.
R=$(make_repo lookalike "feat: enforce R-605 with SHA-256 hashes" src/service.ts)
run_gate "$R" "$CREATE --body 'Implements R-605 (see SHA-256 and IAN-119).'"
check "bare R-605, SHA-256, and IAN-119 deny" is_deny
run_gate "$R" "$CREATE --body 'Refs: R-605'"
check "Refs naming a one-letter prefix denies" is_deny

# Commands that are not gh pr create are untouched.
run_gate "$R" "gh pr view 3 --json body"
check "gh pr view emits nothing" is_silent
run_gate "$R" "git status"
check "git status emits nothing" is_silent
run_gate "$R" "echo gh pr create"
check "gh pr create as an echo argument emits nothing" is_silent

# The command may cd into the repository first; the hook judges that one.
R=$(make_repo cdtarget "feat: add the service" src/service.ts)
OUT=$(cd "$SB" && payload_for "cd $R && gh pr create --body 'Adds it.'" | HOME="$TRACKED_HOME" CLAUDE_ENFORCE_BASE=main "$HOOK" 2>/dev/null)
check "cd into a repository then create denies" is_deny

# A chain of cd commands is followed to the directory gh actually runs in.
OUT=$(cd "$SB" && payload_for "cd $SB && cd $R && gh pr create --body 'Adds it.'" | HOME="$TRACKED_HOME" CLAUDE_ENFORCE_BASE=main "$HOOK" 2>/dev/null)
check "cd chain ending in the repository denies" is_deny
OUT=$(cd "$SB" && payload_for "cd $SB && cd $(basename "$R") && gh pr create --body 'Adds it.'" | HOME="$TRACKED_HOME" CLAUDE_ENFORCE_BASE=main "$HOOK" 2>/dev/null)
check "relative cd resolved against the previous cd denies" is_deny

# Outside any repository the body is still checked rather than skipped.
mkdir -p "$SB/not-a-repo"
OUT=$(cd "$SB/not-a-repo" && payload_for "gh pr create -R o/r --head feat/x --body 'Adds it.'" | HOME="$TRACKED_HOME" "$HOOK" 2>/dev/null)
check "no repository and no body reference denies" is_deny
OUT=$(cd "$SB/not-a-repo" && payload_for "gh pr create -R o/r --head feat/x --body 'Refs: IAN-119'" | HOME="$TRACKED_HOME" "$HOOK" 2>/dev/null)
check "no repository with a body reference allows silently" is_silent

# Text from a later command in the chain is not the pull request's body.
run_gate "$R" "$(printf "gh pr create --body 'No ref.' && cat <<'EOF'\nRefs: IAN-119\nEOF")"
check "a later heredoc is not the body" is_deny
run_gate "$R" "gh pr create --body 'No ref.' && curl -F $SB/body-with-ref.md https://example.invalid"
check "a later -F is not the body file" is_deny
run_gate "$R" "gh pr create --body 'No ref.'; echo 'Refs: IAN-119'"
check "a later quoted Refs line is not the body" is_deny
run_gate "$R" "$(printf '%s --body "$(cat <<'"'"'EOF'"'"'\nSays "a && b"; then | c.\n\nRefs: IAN-119\nEOF\n)" && echo done' "$CREATE")"
check "a heredoc body holding quotes and separators still allows" is_silent

# The registration reaches compound commands: no prefix `if` filter.
check "settings registers the gate without an if filter" jq -e '[.hooks.PreToolUse[].hooks[] | select(.command | endswith("/pr-ticket-ref-gate.sh"))] | length == 1 and (.[0].if == null)' "$CLAUDE_HARNESS_ROOT/settings.json"

# With no base override, a branch already pushed is judged against the pull
# request's base, not its own tracking ref (which would be an empty range).
R=$(make_repo pushed "$(printf 'feat: add the service\n\nRefs: IAN-119\n')" src/service.ts)
git init -q --bare "$SB/pushed-origin.git"
git -C "$R" remote add origin "$SB/pushed-origin.git"
git -C "$R" push -q origin main feat/x 2>/dev/null
git -C "$R" branch -q --set-upstream-to=origin/feat/x feat/x
run_gate "$R" "gh pr create --base main --body 'Adds it.'" "$TRACKED_HOME" ""
check "pushed branch with a Refs commit allows against the PR base" is_silent
R2=$(make_repo pushednoref "feat: add the service" src/service.ts)
git init -q --bare "$SB/pushednoref-origin.git"
git -C "$R2" remote add origin "$SB/pushednoref-origin.git"
git -C "$R2" push -q origin main feat/x 2>/dev/null
git -C "$R2" branch -q --set-upstream-to=origin/feat/x feat/x
run_gate "$R2" "gh pr create --body 'Adds it.'" "$TRACKED_HOME" ""
check "pushed branch with no reference denies against the default base" is_deny

[ "$fail" -eq 0 ] && echo "pr-ticket-ref-gate.test.sh PASS"
exit "$fail"
