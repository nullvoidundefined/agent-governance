#!/usr/bin/env bash
# turn-summary-guard.sh: Stop hook. Every main-session turn ends with three
# one-line summaries, so the owner can see at a glance what happened, what
# needs them, and what comes next (owner decision 2026-10-05):
#
#   **Done:** <what was done> (<pointer>)
#   **Decide:** <decisions needed, or none> (<pointer>)
#   **Next:** <next available steps>
#
# The final assistant message (the last transcript entry of type assistant
# that holds text; its text items joined by newlines) must end, as its last
# three non-blank lines, with those three lines in order. Labels may be bold
# or plain. Done carries a pointer, and so does Decide unless it is "none":
# a backtick span, an http(s) URL, #<digits>, a 7 to 40 character hex sha,
# or a path-like token (contains / or is name.ext).
#
# A miss blocks the stop with the template, so the model adds the lines. It
# fails open: when stop_hook_active is set (the model already retried once),
# or the transcript is missing, unreadable, or holds no assistant text, the
# stop is allowed. A format check must never trap a turn. Bash 3.2.
set -uo pipefail

TEMPLATE='End the turn with exactly these three lines, last, one line each:
**Done:** <what was done> (<pointer: PR, commit, file, or URL>)
**Decide:** <decisions the owner must make, or none> (<pointer>)
**Next:** <next available steps>'

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)" || exit 0

# Prefer the final message the Stop payload carries; fall back to the
# transcript, reading only its tail so a long session stays cheap (a partial
# first line is dropped by the fromjson? guard).
final_text="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty | strings' 2>/dev/null)"
if [ -z "$final_text" ]; then
    [ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
    final_text="$(tail -n 400 "$transcript" | jq -Rrs '
      split("\n") | map(fromjson? // empty)
      | map(select(.type == "assistant"
                   and (.message.content | type) == "array"
                   and any(.message.content[]; .type == "text")))
      | last // empty
      | .message.content | map(select(.type == "text") | .text) | join("\n")
    ' 2>/dev/null)" || exit 0
fi
[ -n "$final_text" ] || exit 0

block() {
    jq -n --arg r "Turn summary missing or malformed: $1
$TEMPLATE" '{decision: "block", reason: $r}'
    exit 0
}

# has_pointer <text>: true when text names somewhere to read more.
has_pointer() {
    # A backtick span, a URL, #<digits>, a 7 to 40 character hex sha word, a
    # path with two or more slashes or ending in name.ext, or a bare name.ext
    # (name of 2+ characters starting with a letter, lowercase extension of 1
    # to 5 letters, ending the word). Excludes prose like it.Then, e.g., 3.5x,
    # v1.2 and and/or.
    printf '%s' "$1" | grep -Eq \
        -e '`[^`]+`' -e 'https?://' -e '#[0-9]+' \
        -e '(^|[^0-9A-Za-z])[0-9a-f]{7,40}([^0-9A-Za-z]|$)' \
        -e '(^|[[:space:](])[^[:space:]/]+/[^[:space:]/]+/[^[:space:]]+' \
        -e '(^|[[:space:](])([^[:space:]]+/)?[A-Za-z][A-Za-z0-9_-]+\.[a-z]{1,5}([[:space:]),;:!?]|[.]?$|[.][[:space:]])'
}

# label_text <label> <line>: prints the text after the label, or fails.
label_text() {
    local text
    text="$(printf '%s' "$2" | sed -nE "s/^[[:space:]]*([-*>][[:space:]]+)?(\*\*$1:\*\*|\*\*$1\*\*:|$1:)[[:space:]]*(.*)$/\3/p")"
    [ -n "$text" ] || return 1
    printf '%s' "$text"
}

last_three="$(printf '%s\n' "$final_text" | tr -d '\r' | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*```[[:space:]]*$' | tail -n 3)"
[ "$(printf '%s\n' "$last_three" | wc -l | tr -d ' ')" -eq 3 ] || block "fewer than three lines."
line_done="$(printf '%s\n' "$last_three" | sed -n 1p)"
line_decide="$(printf '%s\n' "$last_three" | sed -n 2p)"
line_next="$(printf '%s\n' "$last_three" | sed -n 3p)"

done_text="$(label_text Done "$line_done")" || block "the third-to-last line is not a Done line with text."
decide_text="$(label_text Decide "$line_decide")" || block "the second-to-last line is not a Decide line with text."
label_text Next "$line_next" >/dev/null || block "the last line is not a Next line with text."

has_pointer "$done_text" || block "the Done line has no pointer to the full context."
if ! printf '%s' "$decide_text" | grep -Eiq '^none[.]?([[:space:]]*\(.*\))?[.]?$'; then
    has_pointer "$decide_text" || block "the Decide line has no pointer (say none when nothing needs deciding)."
fi
exit 0
