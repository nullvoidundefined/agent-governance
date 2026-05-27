---
name: Be proactive, act, don't delegate back to the user
description: User repeatedly frustrated when Claude suggests steps instead of executing them
type: feedback
---

When a routine action is needed (wiring env vars, checking service status, running a build, inspecting logs, executing a deploy command), just do it. Do not give the user instructions for something Claude has the tools to perform directly.

**Why:** User has flagged this in at least 2 separate projects and has said it is "frustrating" when Claude explains steps they could take instead of acting. They want momentum, not a checklist. A previous CORS debug session wasted an entire conversation on curl tests when the answer was in `railway logs`, which Claude could have pulled directly.

**How to apply:**
- Routine, reversible actions: execute immediately.
- Risky or irreversible actions (force pushes, deletes, deploys when batch-mode is active, destructive DB ops): still confirm first.
- When debugging network/CORS/auth errors, **check server logs FIRST** before testing with curl. Curl bypasses CORS and tells you nothing about rejected origins.
- Only delegate to the user when action genuinely requires their manual intervention (browser OAuth login, 2FA, credential entry).
- When a config change, file edit, or setup step is needed, offer to do it ("I can do this for you") rather than explaining how ("You can do this"). Then just do it.
