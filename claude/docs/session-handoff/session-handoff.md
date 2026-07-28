# Session handoff: 2026-07-29 rules-vs-industry audit execution

## Last commit
- `c4e0ee8` fix(enforce): normalize hook-latency budget against a same-environment spawn control

## Production state
- Config repo only; no deploy surfaces touched. 8 commits on local `main`, NOT pushed (R-106 diff review pending; run `git diff origin/main` before push).

## What shipped
- Prior session's uncommitted work: committed (enforce gate scoping, settings additions); runtime artifacts and client-identifying lists gitignored.
- CLAUDE.md: 458 -> 118 lines, one norm line per rule with inline enforcer tag; full Specs verbatim in `rulebook/reference.md`; guard and push judge now read the rulebook file (judge upgraded from norm lines to full Spec blocks).
- Tier 2 files (`agents.md`, `audits.md`, `cost.md`) moved to `rulebook/` after confirming un-frontmattered `rules/*.md` auto-load every session; stack `CLAUDE-*.md` files gained `paths:` frontmatter and load mechanically via `rules/` symlinks.
- Permissions: `Bash(*)` replaced with usage-mined allowlist + ask (force-push, --no-verify, gh pr merge, sudo, rm -rf) + deny (catastrophic deletes, repo-destroying commands).
- Hook dispatcher consolidation REJECTED on evidence (~6ms idle chain); standing guards added instead: `hook-latency.test.sh` (load-normalized) and `claude-md-lint.test.sh` (size, norm/Spec sync, rules/ auto-load zone).
- Native `/code-review` + `/security-review` documented as the default diff-review path in `rulebook/audits.md`; cost tracking (`/usage`, ccusage) in README; Playwright MCP evaluated and skipped (claude-in-chrome + CLI Playwright cover it cheaper).

## Pending (by urgency)
1. Push `main` to origin after R-106 review (S effort). Includes prior session's work.
2. Sandbox trial: `sandbox.enabled` with tuned `network.allowedDomains` for Railway/Vercel/gh/npm/Anthropic; run supervised, expect breakage on first pass (M).
3. Untracked `daemon/`, `jobs/`, `chrome/` trees: verify against native background/scheduled agents before investing further; possibly delete (M).
4. Allowlist tuning: expect occasional prompts for unlisted commands (heredocs, loops with unusual heads); add to allow as they surface (S, ongoing).

## Next session, read first
- `rulebook/reference.md` header (new rule-edit workflow: norm line in CLAUDE.md + Spec block in rulebook, lint test enforces sync).
- `PROTOCOL.md` "What changed on 2026-07-29".
