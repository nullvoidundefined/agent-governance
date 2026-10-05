#!/usr/bin/env bash
# claim-check-guard.sh: Stop and SubagentStop hook. A final message that claims
# something verified, fixed, or passing must cite a command that ran this turn
# (a backtick span of at least 6 characters that is a substring of a Bash
# command run, or a span equal to a whole command), or hedge ("assumed", "not
# run", ...). It runs nothing; it compares the message with the turn's own Bash
# calls. See docs/specs/2026-10-05-claim-check.md.
#
# Turn = transcript entries after the last genuine user message (text, not a
# tool_result). Claim words inside fenced code blocks and in a few idioms
# (working on, works by, how it works, fixed-width, fixed point) do not count.
#
# Fails open: stop_hook_active, no jq or python3, a missing or unreadable
# transcript, or a malformed payload exits 0 with no output, so it never traps
# a turn or blocks twice. The message comes from last_assistant_message when
# the payload carries it, else from the transcript. SubagentStop reads
# agent_transcript_path when present. Bash 3.2; python3 does the transcript
# parse so a 5 MB file stays well under the 300 ms budget.
set -uo pipefail

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
transcript="$(printf '%s' "$input" | jq -r '.agent_transcript_path // .transcript_path // empty' 2>/dev/null)" || exit 0
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0
payload_msg="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty | strings' 2>/dev/null)"

CLAIM_PAYLOAD_MSG="$payload_msg" python3 - "$transcript" <<'PY' 2>/dev/null
import json, os, re, sys

REASON = ("Completion claim without evidence: the final message says something is "
          "verified, fixed, or passing but cites no command run this turn. Cite the "
          "command you ran (in backticks) and its result, or say \"assumed, not run\".")

CLAIM = re.compile(r"\b(verified|confirmed|fixed|tests? pass|passes|passed|passing|is working|"
                   r"now works|works now|deployed|all good|is green|are green|turned green)\b", re.I)
IDIOM = re.compile(r"working on|works by|how it works|fixed-width|fixed point", re.I)
HEDGE = re.compile(r"assumed|not verified|unverified|did not run|not run|not rerun|"
                   r"not re-run|reported by|per the", re.I)


def strip_fences(text):
    out, fenced = [], False
    for line in text.split("\n"):
        s = line.lstrip()
        if s.startswith("```") or s.startswith("~~~"):
            fenced = not fenced
            continue
        if not fenced:
            out.append(line)
    return "\n".join(out)


def is_user_text(e):
    if e.get("type") != "user":
        return False
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        return True
    if isinstance(c, list):
        return not any(isinstance(i, dict) and i.get("type") == "tool_result" for i in c) \
            and any(isinstance(i, dict) and i.get("type") == "text" for i in c)
    return False


entries = []
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            entries.append(e)

start = 0
for i in range(len(entries) - 1, -1, -1):
    if is_user_text(entries[i]):
        start = i + 1
        break
turn = entries[start:]

final = os.environ.get("CLAIM_PAYLOAD_MSG", "")
if not final:
    for e in reversed(entries):
        c = (e.get("message") or {}).get("content")
        if e.get("type") == "assistant" and isinstance(c, list):
            texts = [i.get("text", "") for i in c if isinstance(i, dict) and i.get("type") == "text"]
            if texts:
                final = "\n".join(texts)
                break
if not final:
    sys.exit(0)

commands = []
for e in turn:
    c = (e.get("message") or {}).get("content")
    if e.get("type") == "assistant" and isinstance(c, list):
        for i in c:
            if isinstance(i, dict) and i.get("type") == "tool_use" and i.get("name") == "Bash":
                cmd = (i.get("input") or {}).get("command")
                if isinstance(cmd, str):
                    commands.append(cmd)

text = strip_fences(final)
if not CLAIM.search(IDIOM.sub(" ", text)):
    sys.exit(0)
if HEDGE.search(text):
    sys.exit(0)
for span in re.findall(r"`([^`\n]+)`", text):
    s = span.strip()
    for cmd in commands:
        if s == cmd.strip() and s:
            sys.exit(0)
        if len(span) >= 6 and span in cmd:
            sys.exit(0)
print(json.dumps({"decision": "block", "reason": REASON}))
PY
exit 0
