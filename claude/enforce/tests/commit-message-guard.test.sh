#!/usr/bin/env bash
# Covers: hook:commit-message-guard
# Verifies commit-message-guard.sh: conventional subject and max-2 triage IDs (deny, R-505),
# oversized body (ask, R-506), everything else untouched.
set -euo pipefail
HOOK="$HOME/.claude/hooks/commit-message-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}
expect() {
  GOT=$(decision "$2")
  [ "$GOT" = "$1" ] || { echo "FAIL: expected $1, got $GOT for: $2"; exit 1; }
}

expect none 'git status'
expect none 'git commit -m "feat(auth): add login handler"'
expect none 'git commit -m "fix(B5, B12): repair pagination and sorting"'
expect none 'git commit --amend --no-edit'
expect none 'git add x && git commit -m "chore: bump deps" && git push'
expect deny 'git commit -m "update stuff"'
expect deny 'git commit -m "Fixed the login bug"'
expect deny 'git commit -m "fix(B1, B2, B3): three triage ids"'

# P2-7 (2026-09-17 audit): `-F -` fed by a heredoc carries the subject in the
# command text, and the guard exited before reading it, so R-505 and R-506 were
# inert for every commit written that way. The heredoc branch also keyed on the
# literal delimiter EOF, so any other delimiter word fell through to the -m
# extractor and out. Subjects are assembled at runtime so this fixture's own
# text does not trip the live guard on the way in.
BAD_SUBJECT="update stuff"
GOOD_SUBJECT="feat(auth)$(printf ':') add login handler"
THREE_IDS="fix(B1, B2, B3)$(printf ':') three triage ids"
expect deny "$(printf 'git commit -q -F - <<MSG\n%s\nMSG' "$BAD_SUBJECT")"
expect none "$(printf 'git commit -q -F - <<MSG\n%s\nMSG' "$GOOD_SUBJECT")"
expect deny "$(printf 'git commit -q -F - <<MSG\n%s\nMSG' "$THREE_IDS")"
expect deny "$(printf "git commit -F - <<'ANYWORD'\n%s\nANYWORD" "$BAD_SUBJECT")"
expect none "$(printf 'git commit -F /tmp/prepared-message.txt')"
# A command whose first heredoc belongs to something else entirely: the payload
# must not be read as the commit message. The first version of the P2-7 fix did
# read it that way and blocked its own commit over a line of python.
expect none "$(printf 'python3 - <<PYEOF\nprint("hello")\nPYEOF\ngit status')"
expect deny "$(printf 'python3 - <<PYEOF\nprint("hello")\nPYEOF\ngit commit -q -F - <<MSG\n%s\nMSG' "$BAD_SUBJECT")"
expect none "$(printf 'python3 - <<PYEOF\nprint("hello")\nPYEOF\ngit commit -q -F - <<MSG\n%s\nMSG' "$GOOD_SUBJECT")"

# PR #8 review (Copilot, claude/hooks/commit-message-guard.sh): the heredoc
# detector matched any `<<` sitting anywhere on the `git commit` line, so a
# compound command that commits and then opens an unrelated heredoc had that
# other payload's first line read as the commit subject. Observed live on
# 2026-09-17, when the guard denied its own well-formed commit over a line of
# someone else's heredoc body. The delimiter search now stops at the first
# command separator, so only a heredoc belonging to the commit itself counts.
PAYLOAD_HEREDOC='cat > /tmp/commit-message-guard-fixture-out <<PAYLOAD'
expect none "$(printf 'git commit -m "%s" && %s\n%s\nPAYLOAD' "$GOOD_SUBJECT" "$PAYLOAD_HEREDOC" "$BAD_SUBJECT")"
expect deny "$(printf 'git commit -m "%s" && %s\n%s\nPAYLOAD' "$BAD_SUBJECT" "$PAYLOAD_HEREDOC" "$GOOD_SUBJECT")"
# The message extractor reads only from the `git commit` token onward, so an
# unrelated `-m` earlier in the same compound command is not this commit's
# message either.
expect deny "$(printf '%s\n-m "%s"\nPAYLOAD\ngit commit -q -F - <<MSG\n%s\nMSG' "$PAYLOAD_HEREDOC" "$GOOD_SUBJECT" "$BAD_SUBJECT")"
# A heredoc delimiter ends the message at its own line; further commands may
# follow it in the same Bash call.
expect deny "$(printf 'git commit -q -F - <<MSG\n%s\nMSG\ngit push origin main' "$BAD_SUBJECT")"
expect none "$(printf 'git commit -q -F - <<MSG\n%s\nMSG\ngit push origin main' "$GOOD_SUBJECT")"
MULTILINE='git commit -m "feat(core): add feature

First body sentence here.
Second body sentence here.
Third body sentence here.
Fourth body sentence here.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"'
expect ask "$MULTILINE"
SHORTBODY='git commit -m "feat(core): add feature

One sentence body.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"'
expect none "$SHORTBODY"
echo "commit-message-guard.test.sh PASS"
