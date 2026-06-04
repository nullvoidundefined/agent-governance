#!/usr/bin/env bash
# ntfy hook for Claude Code. Wired to two events in settings.json:
#   Notification -> permission requests and the idle-input prompt (has a "message")
#   Stop         -> Claude finished a response (no "message"; we supply one)
# Claude Code delivers the event as JSON on stdin. Topic comes from the
# gitignored ~/.claude/.env (NTFY_TOPIC). Silent if the topic is unset.

env_file="$HOME/.claude/.env"
[ -f "$env_file" ] && . "$env_file"
[ -z "${NTFY_TOPIC:-}" ] && exit 0

payload="$(cat)"
message="$(printf '%s' "$payload" | python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
event = d.get("hook_event_name") or ""
msg = d.get("message") or ""
cwd = d.get("cwd") or ""
proj = os.path.basename(cwd.rstrip("/")) if cwd else ""
if not msg:
    msg = "Claude finished responding" if event == "Stop" else "Claude Code needs you"
print(f"{msg} ({proj})" if proj else msg)
' 2>/dev/null)"
[ -z "$message" ] && message="Claude Code needs you"

curl -fsS -H "Title: Claude Code" -d "$message" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
exit 0
