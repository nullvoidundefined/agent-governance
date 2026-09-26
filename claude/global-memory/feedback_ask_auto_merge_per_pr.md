---
name: feedback-ask-auto-merge-per-pr
description: After opening any PR, ask the owner with an AskUserQuestion card whether to enable auto-merge for it; never enable it unasked, never skip the question
metadata:
  type: feedback
---

Every time a PR is opened, whether by me, by the draft-PR hook, or in any repo, ask the owner with an AskUserQuestion card whether to enable auto-merge for that PR. Do it right after the PR opens, alongside turning on the PR monitor.

**Why:** stated 2026-09-26 in doppelscript. The desktop app forbids polling CI and its monitor reports only failures, so without auto-merge a "merge when green" request stalls until the owner sends another message. The owner wants to choose auto-merge per PR up front instead.

**How to apply:**
- Offer options such as "Auto-merge on green (Recommended when review is done)", "I'll merge by hand" and "Hold". One question per card ([[feedback_card_whenever_waiting]]).
- On yes, call `mcp__ccd_pr__set_auto_merge` with `enabled: true` and the repo's merge method (squash by default; bundle PRs rebase).
- Known blockers:
  - "Auto merge is not allowed for this repository" means the repo setting "Allow auto-merge" is off. The doppelscript repo was off on 2026-09-26. Say so and fall back to merging by hand.
  - "Pull request is in clean status" means it is already mergeable. Merge it directly if the owner authorized it.
- Merge gates still apply: the R-517 and R-109 review sections must be in the PR body before auto-merge can land anything the hooks would block.
