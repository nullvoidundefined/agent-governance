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
    """Approve exactly one pending request and freeze its observed hook groups.

    Record the prompt turn before selection so duplicate delivery cannot rearm
    a request. Bare consent requires one candidate; an exact request identifier
    selects among candidates. Other prompts revoke all outstanding consent.
    """
    prompt_id = get_digest(event["turn_id"])
    if prompt_id in state["prompts"]:
        return {"permitted": False}
    state["prompts"][prompt_id] = time.time()
    phrase = " ".join(event.get("prompt", "").split()).casefold()
    candidates = [request for request in state["requests"] if request["status"] == "pending" and request["cwd"] == get_digest(os.path.realpath(event["cwd"]))]
    if phrase.startswith("approve "):
        candidates = [request for request in candidates if phrase == "approve " + request["id"]]
    elif phrase not in ("approve", "approved", "i approve", "yes"):
        candidates = []
    if len(candidates) != 1:
        for request in state["requests"]:
            request["status"] = "consumed"
        return {"permitted": False}
    candidates[0].update(status="approved", turn=prompt_id, retry=None, consumed=[])
    return {"permitted": False}


def get_group_permission(request, event, group, decisions):
    """Reserve an approved snapshot to one retry and consume one group slot.

    Check the full group decision digest before reservation. The first eligible
    retry claims the request, and later groups must carry that same tool-use
    identifier. Consumed groups remain recorded until the request expires.
    """
    retry_id = get_digest(event["tool_use_id"])
    if request["status"] != "approved" or request["turn"] != get_digest(event["turn_id"]):
        return False
    if retry_id == request["original"] or request["retry"] not in (None, retry_id):
        return False
    if request["groups"].get(group) != decisions or group in request["consumed"]:
        return False
    request["retry"] = retry_id
    request["consumed"].append(group)
    if len(request["consumed"]) == len(request["groups"]):
        request["status"] = "consumed"
    return True


def update_pending_request(state, event, fingerprint, group, decisions):
    """Collect group observations for an original action without reopening it.

    The request identifier excludes the group, joining observations from the
    same original tool event. Only pending snapshots may change. Approved or
    consumed snapshots are immutable, including on replay of the original event.
    """
    request_id = get_digest([fingerprint, event["tool_use_id"]])
    request = next((item for item in state["requests"] if item["id"] == request_id), None)
    if request is None:
        request = {"id": request_id, "action": fingerprint, "original": get_digest(event["tool_use_id"]), "cwd": get_digest(os.path.realpath(event["cwd"])), "created": time.time(), "status": "pending", "groups": {}}
        state["requests"].append(request)
    if request["status"] != "pending":
        return {"permitted": False}
    request["groups"][group] = decisions
    return {"permitted": False, "request_id": request_id}


def update_tool(state, envelope):
    """Resolve a literal action against its immutable approved group snapshot.

    Bind arguments and directory separately from hook groups so every asking
    group from one original tool event belongs to one request. Hard denial
    revokes that action. Otherwise try one approved slot, then record a pending
    request if this observation has no matching permission.
    """
    event = envelope["event"]
    fingerprint = get_digest([os.path.realpath(event["cwd"]), event["tool_name"], event["tool_input"]])
    if envelope["decision"] == "deny":
        for request in state["requests"]:
            if request["action"] == fingerprint:
                request["status"] = "consumed"
        return {"permitted": False}
    group = get_digest(envelope["group"])
    decisions = get_digest(envelope["decisions"])
    for request in state["requests"]:
        if request["action"] == fingerprint and get_group_permission(request, event, group, decisions):
            return {"permitted": True}
    return update_pending_request(state, event, fingerprint, group, decisions)


def set_exclusive_lock(lock):
    """Acquire the stable session lock within one second, or fail closed.

    Nonblocking attempts avoid an unbounded wait on a stale or stalled holder.
    The adapter also imposes a separate process deadline so this helper cannot
    prevent the caller from receiving an explicit denial.
    """
    deadline = time.monotonic() + 1
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError("Approval state is busy.")
            time.sleep(0.02)


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
        set_exclusive_lock(lock)
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
    # Stdout carries one machine-readable response, not diagnostic logging.
    # Preserve the trailing newline on both protocol outcomes.
    try:
        sys.stdout.write(json.dumps(update_state(json.load(sys.stdin))) + "\n")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        sys.stdout.write(json.dumps({"permitted": False, "error": "Scoped approval state or runtime identity is unavailable; this call remains denied."}) + "\n")
        sys.exit(1)
