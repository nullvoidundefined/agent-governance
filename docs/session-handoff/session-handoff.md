# Session Handoff: 2026-09-16 engineering-audit remediation (all P findings addressed)

## 1. Last commit

- `6e201f5` `chore(ci): shellcheck at error severity over hooks and enforce scripts (audit Code Quality)`, on `main`, with this handoff and the ISSUES.md maintenance bundled into the commit after it. No branch is open.

## 2. Production state

- The repo is `agent-governance` (public remote); `~/.claude`, `~/.codex`, `~/.cursor` are synced copies, refreshed via `./sync.sh` after every fix this session. `sync.sh` now stamps `~/.claude/.sync-source` so `hook-integrity-check.sh` verifies live == repo at every session start (audit P2-11).
- Both fixture suites green at handoff time (enforce + hooks, run via the Stop gate and pre-push). CI `fixtures` is a required status check on `main` (branch protection enabled 2026-09-16, `enforce_admins` off to preserve the R-514 owner exemption). The local pre-push hook is installed in this checkout and validates the pushed tree, not the synced copy.
- The R-106 publish guard is live again: it recognizes the repo by origin remote (`repo-identity.sh`) and scans the whole monorepo diff. It was inert from the 2026-09-15 migration until this session (audit P0-1).
- CI went red mid-session on `27b8e7c` (a fixture pinned the old pre-push marker string); repaired in `030ac31` and green since.

## 3. What shipped (all on `main`, one commit per finding)

- **P0/P1**: publish guard by remote identity + fixture rebuilt around remote identity (P0-1); verification gate discovers `claude/` suites (P1-1); pre-push validates the pushed repo, installed here, branch protection + required check (P1-2); audit-signal baseline advances and nested `docs/` excluded (P1-3); session handoff moved to root `docs/session-handoff/` where `session-start.sh` reads it (P1-4); nine prior audit reports moved to root `docs/audits/`, `audits.md` path made unambiguous (P2-12).
- **Hooks hardening**: git global-option strip generalized once in `git-invocation.sh` across ten push-boundary hooks with a bypass-corpus fixture (P2-1); `core.hooksPath` read/write split keys on the value token in hook and settings (P2-2); decision-emitting hooks dropped `set -e` with the convention documented in `enforce/README.md` and enforced by `deny-tier-set-convention.test.sh` (P2-8); all helper sourcing sits behind `[ -f ]` guards because a failed `source` aborts the shell even behind `|| true`; the publish guard asks (fails closed) when its helper is missing.
- **Docs/config drift**: INDEX.md model-routing line matches `settings.json` with a sync fixture (P2-3, P2-4); `strict-permissions.json` retired (P2-5); `claude/README.md` title and five counts corrected (P2-6); `structure-gate.test.sh` no longer mutates live config (P2-7); `dependabot.yml` restored at root `.github/` (P2-9); `build-by-slice-require-review` defers in-harness TDD to tdd-gated-dispatch and ports re-cloned (P2-10).
- **P3s**: fixture credential literals built at runtime (P3-3); session SHA stamp keyed per repo toplevel (P3-4); R-203 bracket and `manifest.test.sh` docstring corrected (P3-5); suite runners reject partial passes; shellcheck (errors) added to CI, clean locally on 0.11.0.
- P3-1 resolved as a false positive: Claude Code decomposes compound commands per subcommand for permission matching (recorded in ISSUES.md).

## 4. Pending (by urgency)

- **User, now (P0-2)**: rotate the GitHub PAT in `GITHUB_ACCESS_TOKEN` (leaked into transcripts, including this session's), purge the two transcripts named in ISSUES.md, run the vendor CLI config scan in a terminal. ~15 minutes.
- User decision: `skipDangerousModePermissionPrompt` recorded as an accepted risk in ISSUES.md; remove the key if the acceptance no longer holds.
- Small residue in ISSUES.md: confirm PreModelSwitch event reality (one command); consider generating README inventory counts.
- Unexplained once: `.git/config` flipped `bare = true` mid-session (restored, never recurred across four subsequent suite runs). A parallel session was active in the same tree; if it recurs, suspect a fixture running `git init --bare` with an empty target variable.

## 5. Next session: read first

- `docs/audits/2026-09-16-engineering.md` (the report; all P findings remediated, prioritized table at the end).
- `claude/ISSUES.md` Open section (the pending user actions above).
- `claude/hooks/repo-identity.sh` and `claude/hooks/git-invocation.sh` (the two new shared helpers every push-boundary hook now consumes).
