---
name: Batch deploys, deploy only at the end
description: During multi-task sessions, test/build/commit only; hold git push + deploy until explicitly requested
type: feedback
---

During multi-task sessions: test, build, commit. Do NOT `git push` or deploy (Vercel/Railway) until the user explicitly says to.

**Why:** User prefers batching pushes and deploys rather than doing them incrementally. Reduces deploy noise, avoids mid-session Railway/Vercel builds eating time, and groups related changes into a single production event.

**How to apply:**
- After completing a task: verify tests pass, build succeeds, commit the work. Stop there.
- Do not push until user says "push," "deploy," "ship," or similar.
- This overrides any default "commit and push" behavior from slash commands like `/ship` unless the user invokes them directly.
- When the user does request a deploy, follow the full deploy monitoring protocol: poll GitHub Actions, Railway deployment status, Vercel deployment status, and production health endpoints until all four are green or 5 minutes have elapsed.
