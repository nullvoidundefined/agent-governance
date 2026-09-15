---
name: feedback_gh_cli_bot_review_false_negative
description: gh pr view --json reviews/reviewRequests can omit bot (Copilot) reviews; confirm via the REST API before asserting none exist
metadata:
  type: feedback
---

`gh pr view <n> --json reviews` and `--json reviewRequests` can return `[]` even when a bot (e.g. Copilot) review exists and is visible in the GitHub UI. Confirm bot review state with the REST API: `gh api /repos/<owner>/<repo>/pulls/<n>/reviews` and `.../pulls/<n>/comments`.

**Why:** A "Copilot is not reviewing PRs" conclusion was drawn from `gh pr view --json reviews` returning `[]`. A screenshot proved Copilot had in fact reviewed; the REST `/reviews` endpoint showed the review plainly (author with a `[bot]` suffix, state COMMENTED) plus an inline comment. The `--json` field gave a false negative and a confident wrong answer was built on it.

**How to apply:** Never assert "no review / not running" from `gh pr view --json` alone; verify with the REST reviews and comments endpoints first. The bot login carries a `[bot]` suffix in REST output and in webhook `review.user.login` payloads, which also breaks naive `if:` string matches in GitHub Actions, so match bot logins with `startsWith`, not exact equality.
