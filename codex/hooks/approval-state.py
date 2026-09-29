"""Store scoped MCP consent outside workspace state.

The runtime must protect HOME/.claude from sandboxed tool writes. Event parsing
alone does not authenticate a user. This helper receives runtime hook envelopes,
keeps only hashes of action contents, and serializes the request lifecycle with
one stable lock per session. It has no command-line grant interface.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time


LIFETIME_SECONDS = 600


def get_digest(value):
    """Hash canonical JSON without altering strings or the order of arrays."""
    serialized = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def get_private_file(path):
    """Open a regular, owner-only state file without following a symlink."""
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        os.close(descriptor)
        raise ValueError("Approval state must be private and owned by the runtime user.")
    return os.fdopen(descriptor, "r+")


def get_state_directory():
    """Create the private approval directory under the runtime home.

    The location deliberately ignores workspace and adapter state overrides.
    Check each created component without following symlinks, and reject an
    existing approval directory whose ownership or permissions are unsafe.
    """
    home = Path.home()
    for directory in (home / ".claude", home / ".claude" / ".codex-approvals"):
        directory.mkdir(mode=0o700, exist_ok=True)
        metadata = directory.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ValueError("Approval directory ownership is invalid.")
        if directory.name == ".codex-approvals" and metadata.st_mode & 0o077:
            raise ValueError("Approval directory is not private.")
    return directory


def update_prompt(state, event):
    """Turn one direct approval into consent for one pending request.

    Remember the prompt identity before processing it so repeated delivery does
    not mint another grant. An unrelated prompt cancels outstanding requests.
    Bare approval applies only to a unique pending request in this directory.
    """
    prompt_id = get_digest(event["turn_id"])
    if prompt_id in state["prompts"]:
        return {"permitted": False}
    state["prompts"][prompt_id] = time.time()
    phrase = " ".join(event.get("prompt", "").split()).casefold()
    candidates = [request for request in state["requests"] if request["status"] == "pending" and request["cwd"] == get_digest(os.path.realpath(event["cwd"]))]
    if phrase not in ("approve", "approved", "i approve", "yes") or len(candidates) != 1:
        for request in state["requests"]:
            request["status"] = "consumed"
        return {"permitted": False}
    candidates[0]["status"] = "approved"
    candidates[0]["turn"] = prompt_id
    return {"permitted": False}


def update_tool(state, envelope):
    """Record an ask or consume the matching approval before permitting a retry.

    Action hashes include the working directory, literal tool arguments, and
    structured hook decisions. Only the approved prompt turn may consume the
    request. Keep consumed entries until expiry to retain the lifecycle history.
    """
    event = envelope["event"]
    fingerprint = get_digest([os.path.realpath(event["cwd"]), event["tool_name"], event["tool_input"], envelope["group"], envelope["decisions"]])
    if envelope["decision"] == "deny":
        for request in state["requests"]:
            request["status"] = "consumed"
        return {"permitted": False}
    for request in state["requests"]:
        if request["action"] == fingerprint and request["status"] == "approved" and request["turn"] == get_digest(event["turn_id"]):
            request["status"] = "consumed"
            return {"permitted": True}
    request_id = get_digest([fingerprint, event["tool_use_id"]])
    if not any(request["id"] == request_id for request in state["requests"]):
        state["requests"].append({"id": request_id, "action": fingerprint, "cwd": get_digest(os.path.realpath(event["cwd"])), "created": time.time(), "status": "pending"})
    return {"permitted": False, "request_id": request_id}


def update_state(envelope):
    """Validate event identity and commit its transition under a stable lock.

    The separate lock inode remains unchanged for the session. Read and prune
    state while holding it, apply the event, then persist and fsync before any
    permission result escapes. Invalid state or failed writes deny the action.
    """
    event = envelope["event"]
    fields = ["session_id", "turn_id", "cwd"]
    if event.get("hook_event_name") == "PreToolUse":
        fields += ["tool_use_id", "tool_name"]
        if not event.get("tool_name", "").startswith("mcp__") or not isinstance(event.get("tool_input"), dict):
            raise ValueError("Scoped approval requires a literal MCP call.")
    elif event.get("hook_event_name") != "UserPromptSubmit":
        raise ValueError("Unsupported approval event.")
    if any(not isinstance(event.get(field), str) or not event[field].strip() for field in fields):
        raise ValueError("Scoped approval requires runtime session, turn, directory and tool identity.")
    directory = get_state_directory()
    session = get_digest(event["session_id"])
    with get_private_file(directory / (session + ".lock")) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with get_private_file(directory / (session + ".json")) as state_file:
            contents = state_file.read()
            state = json.loads(contents) if contents else {"requests": [], "prompts": {}}
            now = time.time()
            state["requests"] = [request for request in state["requests"] if now - request["created"] < LIFETIME_SECONDS]
            state["prompts"] = {key: timestamp for key, timestamp in state["prompts"].items() if now - timestamp < LIFETIME_SECONDS}
            result = update_prompt(state, event) if event["hook_event_name"] == "UserPromptSubmit" else update_tool(state, envelope)
            state_file.seek(0)
            json.dump(state, state_file, allow_nan=False)
            state_file.truncate()
            state_file.flush()
            os.fsync(state_file.fileno())
            return result


if __name__ == "__main__":
    try:
        print(json.dumps(update_state(json.load(sys.stdin))))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print(json.dumps({"permitted": False, "error": "Scoped approval state or runtime identity is unavailable; this call remains denied."}))
        sys.exit(1)
