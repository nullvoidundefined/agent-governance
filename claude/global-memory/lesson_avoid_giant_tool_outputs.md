---
name: Avoid tool calls that produce giant outputs
description: Broad scans (secret scans, repo-wide greps, whole-directory reads) can produce hundreds of kilobytes of output that bill against the context budget even when most of the output is noise
type: feedback
---

**Rule:** Do not run tool calls whose output is likely to be very large
unless you have a concrete plan to use most of the output. If the goal
is to find a handful of matches in a large surface, scope the query or
pipe through a narrowing filter before the result lands in context.

**Why:** Tool results are billed against the context window in full.
Observed incident on 2026-04-07: a repo-wide secret scan produced a
~246KB tool result, nearly all of which was paste-cache noise that was
never read or acted on. The tokens were
spent regardless. The same investigation could have been done with a
targeted Grep for the specific credential patterns of interest
(`AKIA`, `sk-ant-`, `Bearer `, etc.) producing a few kilobytes.

**How to apply:**

- Before running a broad scan, estimate output size. Anything that
  might exceed ~50KB should be scoped tighter or narrowed with
  `head_limit`, file globs, or a more specific pattern.
- For secret scans specifically, grep for concrete credential prefixes
  (`AKIA`, `ghp_`, `sk-`, `Bearer `, `eyJ`, `-----BEGIN `) instead of
  running a generic "find anything suspicious" scan.
- For repo-wide searches, prefer `files_with_matches` mode first, then
  Read only the files that matter.
- For "what's in this directory" questions, use Glob before Read. Do
  not Read every file in a directory to understand its shape.
- If a broad scan is genuinely necessary, dispatch it to a subagent so
  the giant result lives in the subagent context, not the main one.
  The subagent returns a summary to the main context.
