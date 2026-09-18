# Session Handoff: 2026-09-18, R-607 product docs and its follow-ups

## 1. Last commit

- `cc7e7b2 feat(rules): R-607 features list and user stories in every application repo (#44)`, squash-merged by the owner at 15:02Z. `main` has since moved to `b7ed743` (#50).

## 2. Production state

- `~/.claude`, `~/.codex`, and `~/.cursor` were synced from `cc7e7b2`. The live harness carries the R-607 norm line, `hooks/push-feature-docs-gate.sh`, `enforce/require-feature-checklist.sh`, and the three templates in `prompts/`.
- CI (`fixtures`, GitGuardian) passed on the final head `96975e3`. The merged tree is identical to that head.

## 3. Session metrics

- Branch `feat/product-docs-rule`: 14 commits, of which 4 merged a fast-moving `main` (#41, #42, #43, #45, #47). The final PR diff touched 47 files. Rework count 2 (two Copilot rounds sent the work back).
- `session-metrics.sh` has no session-start SHA for this repository, because the session ran from the Voyager 2.0 directory. `--since d2937ce` reports 11 commits and 177 files, but that count includes other sessions' squashed PRs, so it is not attributable to this session.
- Ticket IAN-96: 125 working minutes against a 45-minute heuristic estimate (ratio 2.78). Closed.

## 4. What shipped

- R-607 (`claude/CLAUDE.md`, `claude/rulebook/reference.md`): every application repository keeps `docs/feature-list/features.md` and per-area `docs/user-stories/<area>.md` files with `US-<AREA>-NNN` stories.
- The push gate `push-feature-docs-gate` runs the harness copy of the checklist on every Claude Code `git push`. It never runs the repository's own copy. Triggers cover Next, Nuxt, FastAPI, and Express, at any monorepo prefix.
- `repo-setup`: a `product-docs` item, and a `--no-product-docs` opt-out recorded in `.enforce.json`.
- `feature-create`: a required `--area`, per-area story append, and sectioned feature rows.
- `task-start` and `task-cleanup`: add the row and story at task start, and mark them **Complete** or **Partial** at close.
- Design: `claude/docs/superpowers/specs/2026-09-18-product-docs-design.md`. PR doc: `docs/prs/2026-09-18-product-docs-rule.md`.

## 5. Pending, by urgency

- **Close IAN-99** (#46, here-string conversion). The PR merged as `b6a2ebc`, but the ticket still says In Progress. It needs actuals from its own session, which started at 13:58:11Z. About 5 minutes.
- **R-607 follow-up 1: CI templates.** `claude/skills/repo-setup/scripts/template-ci-*.yml` do not run `scripts/require-feature-checklist.sh`, so a push made outside Claude Code (a terminal, or another agent) is unchecked. Add one step per template, and a `repo-setup.test.sh` assertion that the step is present. About 30 minutes, Standard tier.
- **R-607 follow-up 2: the R-508 surface list.** `claude/hooks/git-workflow-guard.sh:165` still recognizes only `routes/`, `handlers/`, `page.tsx`, and `route.ts`. It misses Nuxt `app/pages/**/*.vue` and `server/(api|routes)/`, and FastAPI `app/routers/*.py`, so the R-508 README reminder never fires for those stacks. `task-cleanup/scripts/scan.sh` already has the extended regex; the two lists could share one source. About 30 minutes, Standard tier, test first.
- **Carried from the previous handoff:** 117 `| grep -q` pipelines under `claude/` read from a non-`printf` upstream (`jq`, `head`, `git`). Audit the ones that can emit more than 64 KB under pipefail. About 60 minutes.
- **Voyager 2.0:** its first `feature-create` call needs `--area` (for example `--area chat`), and its spec's per-area story files already match R-607.
- Dropped from the list: the `tdd.sh` bash-runner follow-up, which #49 shipped.

## 6. Next session

1. Close IAN-99 through `/ticket-lifecycle close`.
2. Do follow-up 2 first, because its test pattern exists: read `claude/hooks/git-workflow-guard.sh` (around line 165), `claude/skills/task-cleanup/scripts/scan.sh` (`SURFACE_RE`), and `claude/enforce/tests/git-workflow-guard.test.sh`.
3. Then follow-up 1: read `claude/skills/repo-setup/scripts/template-ci-node.yml` and `template-ci-python.yml`, and `claude/enforce/tests/repo-setup.test.sh`.
4. Open a ticket for each follow-up at classification (R-605).
