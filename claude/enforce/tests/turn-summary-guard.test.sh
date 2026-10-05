#!/usr/bin/env bash
# Covers: hook:turn-summary-guard
# Verifies the Stop hook turn-summary-guard.sh requires every main-session turn
# to end with the Done / Decide / Next lines, blocks with the template when it
# does not, and fails open on anything it cannot read.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/turn-summary-guard.sh"
SETTINGS="$CLAUDE_HARNESS_ROOT/settings.json"

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

FAILS=0
CASES=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# Child processes must not inherit git state from an enclosing hook.
run_hook() { # stdin JSON on $1; sets OUT and RC
  local input="$1"
  OUT=$(printf '%s' "$input" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR "$HOOK" 2>/dev/null)
  RC=$?
}

event() { # transcript path, stop_hook_active
  jq -cn --arg p "$1" --argjson a "${2:-false}" \
    '{session_id:"s",transcript_path:$p,hook_event_name:"Stop",stop_hook_active:$a}'
}

user_line() { jq -cn '{type:"user",message:{role:"user",content:"hi"}}'; }
text_entry() { # one or more text items
  jq -cn '{type:"assistant",message:{role:"assistant",content:($ARGS.positional | map({type:"text",text:.}))}}' --args "$@"
}
tool_entry() {
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:"ls"}}]}}'
}

# transcript_with <name> <final text>: user turn, a tool-only entry, then the final text.
transcript_with() {
  local f="$WORK/$1.jsonl"
  { user_line; tool_entry; text_entry "$2"; } > "$f"
  printf '%s' "$f"
}

expect_allow() { # name, message
  CASES=$((CASES + 1))
  run_hook "$(event "$(transcript_with "$1" "$2")")"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "$1: expected no output and exit 0, got rc=$RC out=$OUT"; fi
}

expect_block() { # name, message
  CASES=$((CASES + 1))
  run_hook "$(event "$(transcript_with "$1" "$2")")"
  check_block "$1"
}

check_block() {
  local name="$1" decision reason
  if [ "$RC" -ne 0 ]; then fail "$name: expected exit 0, got $RC"; return; fi
  decision=$(printf '%s' "$OUT" | jq -r '.decision // "none"' 2>/dev/null || echo invalid)
  [ "$decision" = "block" ] || { fail "$name: expected block, got decision=$decision out=$OUT"; return; }
  reason=$(printf '%s' "$OUT" | jq -r '.reason // ""')
  for want in '**Done:**' '**Decide:**' '**Next:**'; do
    case "$reason" in *"$want"*) ;; *) fail "$name: reason lacks template line $want"; return ;; esac
  done
}

if [ ! -f "$HOOK" ]; then
  fail "hook file missing: $HOOK"
fi

# ---- T-1: well-formed endings are allowed
expect_allow t1-bold $'Fixed the parser.\n\n**Done:** fixed the parser (`src/parse.js`)\n**Decide:** none\n**Next:** run the full suite'
expect_allow t1-plain $'All set.\n\nDone: fixed the parser (src/parse.js)\nDecide: none\nNext: run the full suite'
expect_allow t1-trailing-blank $'**Done:** wrote tests (`a.test.sh`)\n**Decide:** none\n**Next:** implement\n\n\n'

# ---- T-1 realistic: long multi-paragraph answer, table before the lines, PR link, commit sha
LONG=$'First I read the config loader and found the cause.\n\nThe retry path swallowed errors, so callers saw success.\n\nSecond paragraph with detail about the fix and why it is safe.\n\n**Done:** fixed retry error handling (`lib/retry.js`)\n**Decide:** none\n**Next:** add a regression test'
expect_allow realistic-long "$LONG"
TABLE=$'| file | change |\n|------|--------|\n| a.js | fixed |\n| b.js | added |\n\n**Done:** updated two files (`a.js`)\n**Decide:** merge now or wait for review (https://github.com/o/r/pull/42)\n**Next:** merge'
expect_allow realistic-table "$TABLE"
expect_allow realistic-pr-link $'**Done:** opened the PR (https://github.com/o/r/pull/123)\n**Decide:** approve the design (#123)\n**Next:** wait for review'
expect_allow realistic-sha $'**Done:** committed the change (3f2a9bc)\n**Decide:** none (nothing open)\n**Next:** open a PR'

# ---- T-2: missing, misordered, trailing text, empty label
expect_block t2-missing-next $'Work done.\n\n**Done:** did it (`a.js`)\n**Decide:** none'
expect_block t2-missing-done $'**Decide:** none\n**Next:** go'
expect_block t2-missing-decide $'**Done:** did it (`a.js`)\n**Next:** go'
expect_block t2-no-summary 'I made the change and everything works.'
expect_block t2-out-of-order $'**Next:** go\n**Done:** did it (`a.js`)\n**Decide:** none'
expect_block t2-text-after-next $'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:** go\nThanks for your patience.'
expect_block t2-empty-label $'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:**'
expect_block t2-empty-done $'**Done:**\n**Decide:** none\n**Next:** go'

# ---- T-3: pointers
expect_block t3-done-no-pointer $'**Done:** fixed the bug\n**Decide:** none\n**Next:** go'
expect_block t3-decide-no-pointer $'**Done:** fixed the bug (`a.js`)\n**Decide:** pick a color\n**Next:** go'
expect_allow t3-decide-none-upper $'**Done:** fixed the bug (`a.js`)\n**Decide:** None.\n**Next:** go'
expect_allow t3-decide-none-paren $'**Done:** fixed the bug (`a.js`)\n**Decide:** none (all settled)\n**Next:** go'
expect_allow t3-pointer-url $'**Done:** deployed (http://example.com/x)\n**Decide:** none\n**Next:** go'
expect_allow t3-pointer-issue $'**Done:** closed the bug (#45)\n**Decide:** none\n**Next:** go'
expect_allow t3-pointer-path $'**Done:** edited src/app/main.js\n**Decide:** none\n**Next:** go'
expect_allow t3-pointer-file-ext $'**Done:** edited README.md\n**Decide:** none\n**Next:** go'
expect_block t3-short-hex-not-sha $'**Done:** fixed it (abc12)\n**Decide:** none\n**Next:** go'
expect_block t3-none-with-extra-text $'**Done:** fixed it (`a.js`)\n**Decide:** none of the options fit\n**Next:** go'

# ---- T-4: stop_hook_active suppresses everything
CASES=$((CASES + 1))
run_hook "$(event "$(transcript_with t4-active 'no summary at all')" true)"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t4: stop_hook_active must produce no output, got rc=$RC out=$OUT"; fi

# ---- T-5: fail open
CASES=$((CASES + 1))
run_hook "$(event "$WORK/does-not-exist.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t5 missing transcript: got rc=$RC out=$OUT"; fi

CASES=$((CASES + 1))
printf 'not json\n{broken\n' > "$WORK/bad.jsonl"
run_hook "$(event "$WORK/bad.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t5 malformed jsonl: got rc=$RC out=$OUT"; fi

CASES=$((CASES + 1))
{ user_line; tool_entry; } > "$WORK/notext.jsonl"
run_hook "$(event "$WORK/notext.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t5 no assistant text: got rc=$RC out=$OUT"; fi

CASES=$((CASES + 1))
run_hook '{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}'
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t5 no transcript_path: got rc=$RC out=$OUT"; fi

CASES=$((CASES + 1))
run_hook 'not json at all'
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t5 malformed event: got rc=$RC out=$OUT"; fi

# ---- T-6: which message counts
# Earlier compliant text does not satisfy a later non-compliant final message.
CASES=$((CASES + 1))
{ user_line
  text_entry $'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:** go'
  tool_entry
  text_entry 'Just a chatty final message.'
} > "$WORK/earlier.jsonl"
run_hook "$(event "$WORK/earlier.jsonl")"
check_block t6-earlier-does-not-count

# A trailing tool_use-only entry is skipped, so the earlier compliant text is the final message.
CASES=$((CASES + 1))
{ user_line
  text_entry $'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:** go'
  tool_entry
} > "$WORK/toolfinal.jsonl"
run_hook "$(event "$WORK/toolfinal.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t6 tool-only tail skipped: got rc=$RC out=$OUT"; fi

# Several text items in one entry are joined with newlines.
CASES=$((CASES + 1))
{ user_line
  text_entry 'Here is the result.' $'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:** go'
} > "$WORK/joined.jsonl"
run_hook "$(event "$WORK/joined.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t6 joined text items: got rc=$RC out=$OUT"; fi

# Joined with newlines, not spaces: the labels must land on separate lines.
CASES=$((CASES + 1))
{ user_line
  text_entry '**Done:** did it (`a.js`)' '**Decide:** none' '**Next:** go'
} > "$WORK/joined3.jsonl"
run_hook "$(event "$WORK/joined3.jsonl")"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "t6 three text items as three lines: got rc=$RC out=$OUT"; fi

# ---- Review round: label style, markdown wrapping, tighter pointers, payload field
# Colon outside the bold.
expect_allow r-colon-outside $'**Done**: fixed it (`a.md`)\n**Decide**: none\n**Next**: go'
expect_block r-colon-outside-missing-next $'**Done**: fixed it (`a.md`)\n**Decide**: none'

# Markdown wrapping of the three lines.
expect_allow r-bullet-dash $'- **Done:** fixed it (`a.md`)\n- **Decide:** none\n- **Next:** go'
expect_allow r-bullet-star $'* **Done:** fixed it (`a.md`)\n* **Decide:** none\n* **Next:** go'
expect_allow r-blockquote $'> **Done:** fixed it (`a.md`)\n> **Decide:** none\n> **Next:** go'
expect_allow r-closing-fence $'Result below.\n\n**Done:** fixed it (`a.md`)\n**Decide:** none\n**Next:** go\n```'
expect_block r-bullet-missing-next $'- **Done:** fixed it (`a.md`)\n- **Decide:** none'

# Done texts with no pointer must block.
expect_block r-nopointer-dot-then $'**Done:** fixed it.Then moved on\n**Decide:** none\n**Next:** go'
expect_block r-nopointer-eg $'**Done:** see e.g. the notes\n**Decide:** none\n**Next:** go'
expect_block r-nopointer-decimal $'**Done:** cost 3.5x less\n**Decide:** none\n**Next:** go'
expect_block r-nopointer-version $'**Done:** upgraded node v1.2 to v1.3\n**Decide:** none\n**Next:** go'
expect_block r-nopointer-and-or $'**Done:** handled and/or skipped\n**Decide:** none\n**Next:** go'

# Real pointers still pass.
expect_allow r-ptr-readme $'**Done:** updated README.md\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-path $'**Done:** edited src/app/main.js\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-hook $'**Done:** added claude/hooks/x.sh\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-spec $'**Done:** wrote docs/specs/a.md\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-issue $'**Done:** closed the bug #206\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-url $'**Done:** opened https://example.com/pr/9\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-backtick $'**Done:** ran `make test`\n**Decide:** none\n**Next:** go'
expect_allow r-ptr-sha $'**Done:** committed 3f2a9bc\n**Decide:** none\n**Next:** go'

# last_assistant_message in the event wins over the transcript.
GOOD=$'**Done:** did it (`a.js`)\n**Decide:** none\n**Next:** go'
CASES=$((CASES + 1))
run_hook "$(event "$(transcript_with lam-pass 'chatty non-compliant text')" | jq -c --arg m "$GOOD" '. + {last_assistant_message:$m}')"
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "lam compliant payload over bad transcript: got rc=$RC out=$OUT"; fi

CASES=$((CASES + 1))
run_hook "$(event "$(transcript_with lam-block "$GOOD")" | jq -c '. + {last_assistant_message:"chatty non-compliant text"}')"
check_block lam-block-payload-over-good-transcript

# ---- T-7: settings registration
CASES=$((CASES + 1))
STOP_HITS=$(jq '[.hooks.Stop // [] | .[] | select(.matcher == null or .matcher == "") | .hooks[]? | select((.command // "") | contains("turn-summary-guard.sh"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
[ "$STOP_HITS" -ge 1 ] || fail "t7: turn-summary-guard.sh not registered under hooks.Stop with empty or omitted matcher"

CASES=$((CASES + 1))
SUB_HITS=$(jq '[.hooks.SubagentStop // [] | .[] | .hooks[]? | select((.command // "") | contains("turn-summary-guard.sh"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
[ "$SUB_HITS" -eq 0 ] || fail "t7: turn-summary-guard.sh must not be registered under SubagentStop"

echo "$CASES cases, $FAILS failures"
[ "$FAILS" -eq 0 ]
