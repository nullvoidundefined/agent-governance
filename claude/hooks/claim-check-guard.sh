#!/usr/bin/env bash
# claim-check-guard.sh: Stop and SubagentStop hook. A final message that claims
# something verified, fixed, or passing must cite a command that ran this turn
# (a backtick span of at least 6 characters that is a substring of a Bash
# command run, or a span equal to a whole command), or hedge ("assumed", "not
# run", ...). It runs nothing; it compares the message with the turn's own Bash
# calls. See docs/specs/2026-10-05-claim-check.md.
#
# Turn = transcript entries after the last genuine user message (text, not a
# tool_result, meta, compact summary, or injected marker); only the transcript
# tail back to that boundary is read. Trailing Done/Decide/Next lines are not
# searched. Citable: Bash command, Read/Grep/Glob file_path/path/pattern. Claim words inside fenced code blocks and in a few idioms
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

CLAIM = re.compile(r"\b(verified|confirmed|tests? pass|passed|passing|is working|"
                   r"now works|works now|deployed|all good|is green|are green|turned green|"
                   r"(?:is|are|was|were|now|been) fixed|fixed (?:it|this|that|the|in)|"
                   r"now passes|passes now|(?:test|suite|check) passes)\b", re.I)
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


SUMMARY = re.compile(r"^\s*([-*>]\s+)?(\*\*(Done|Decide|Next):\*\*|\*\*(Done|Decide|Next)\*\*:|(Done|Decide|Next):)")
MARKERS = ("<task-notification", "<system-reminder", "<command-", "Stop hook feedback",
           "[SYSTEM NOTIFICATION", "Another Claude session sent a message")


def strip_summary(text):
    lines = text.split("\n")
    seen = 0
    for i in range(len(lines) - 1, -1, -1):
        if not lines[i].strip():
            continue
        if seen < 3 and SUMMARY.match(lines[i]):
            lines[i] = ""
            seen += 1
        else:
            break
    return "\n".join(lines)


def is_user_text(e):
    if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
        return False
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        text = c
    elif isinstance(c, list):
        if any(isinstance(i, dict) and i.get("type") == "tool_result" for i in c):
            return False
        texts = [i.get("text", "") for i in c if isinstance(i, dict) and i.get("type") == "text"]
        if not texts:
            return False
        text = texts[0] if isinstance(texts[0], str) else ""
    else:
        return False
    return not text.lstrip().startswith(MARKERS)


def load(line):
    try:
        e = json.loads(line.decode("utf-8", errors="replace"))
    except ValueError:
        return None
    return e if isinstance(e, dict) else None


def is_boundary(line):
    # cheap filter first: a boundary is a user entry and never a tool_result
    if b'"user"' not in line or b"tool_result" in line:
        return False
    e = load(line)
    return e is not None and is_user_text(e)


def read_tail(path):
    """Read blocks backwards from the end until a genuine boundary line is found.
    Returns the complete non-empty lines read and the index after the boundary."""
    block = 256 * 1024
    with open(path, "rb") as f:
        f.seek(0, 2)
        pos = f.tell()
        tail = []      # complete lines already scanned, in file order
        carry = b""    # partial first line of what has been read so far
        while True:
            n = min(block, pos)
            pos -= n
            f.seek(pos)
            parts = (f.read(n) + carry).split(b"\n")
            if pos > 0:
                carry, parts = parts[0], parts[1:]
            else:
                carry = b""
            new = [l for l in parts if l.strip()]
            for i in range(len(new) - 1, -1, -1):
                if is_boundary(new[i]):
                    lines = new + tail
                    return lines, i + 1
            tail = new + tail
            if pos == 0:
                return tail, 0
            block *= 2


lines, start = read_tail(sys.argv[1])
turn = [e for e in (load(l) for l in lines[start:] if b'"tool_use"' in l) if e]

final = os.environ.get("CLAIM_PAYLOAD_MSG", "")
if not final:
    for l in reversed(lines):
        if b'"assistant"' not in l or b'"text"' not in l:
            continue
        e = load(l)
        if e is None:
            continue
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
            if not (isinstance(i, dict) and i.get("type") == "tool_use"):
                continue
            inp = i.get("input") or {}
            keys = ("command",) if i.get("name") == "Bash" else \
                ("file_path", "path", "pattern") if i.get("name") in ("Read", "Grep", "Glob") else ()
            for k in keys:
                v = inp.get(k)
                if isinstance(v, str):
                    commands.append(v)

text = strip_summary(strip_fences(final))
if not CLAIM.search(IDIOM.sub(" ", text)):
    sys.exit(0)
if HEDGE.search(text):
    sys.exit(0)
for span in re.findall(r"`([^`\n]+)`", text):
    s = span.strip()
    for cmd in commands:
        if s and s == cmd.strip():
            sys.exit(0)
        if len(s) >= 6 and s in cmd:
            sys.exit(0)
print(json.dumps({"decision": "block", "reason": REASON}))
PY
exit 0
