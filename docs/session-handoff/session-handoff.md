# Session Handoff: 2026-09-17 ticket-lifecycle skill, translator allowlist, enforce audit

## 1. Last commit

- `c247a3f fix(hooks): R-103 covers the suffixed, long-form, and perl in-place edit spellings (audit P2-6)`, on branch `claude/ticket-lifecycle-skill-ourn3y`. Fifteen commits ahead of `origin/main` (`2cd9219`), 41 files, NOT merged, no PR opened.
- Local `main` is stale at `be7b5f0`; `origin/main` already carries the hygiene-audit and codex-translator workstreams the prior handoff called unmerged. Run `git fetch origin main` first.
- No ticket key for this session's work: no tracker is configured yet (`~/.claude/TICKET-TRACKER.json` is absent), which is exactly the degraded path R-605 describes.

## 2. Production state

- Both fixture suites fully green (`claude/enforce/tests/run-tests.sh`, `claude/hooks/tests/run-tests.sh`), and `node translate/codex.mjs --check` exits 0, so the codex port matches its `claude/` sources.
- The translator fixture's six failures are fixed and were never a renderer defect: an escaped backtick is GNU grep's buffer-start anchor, so they matched nothing on `ubuntu-latest` while passing on the BSD grep they were written against.
- `./sync.sh` could NOT run in this container (no `rsync`), so the tracked `claude/` files were hand-copied into `~/.claude` and `claude/enforce/node_modules` installed and symlinked there to make the suites runnable. Re-run `./sync.sh` on a real machine before trusting the live harness.

## 3. Session metrics

- Commits: 15 (one more with this handoff). Specs written 1, amended 1. Skills added 1. Rules added 3. Audits run 1. Harness defects fixed 10 (4 found by verification, 4 audit P1, 1 audit P2, 1 phantom-manifest).
- Rework: 1 (the `feature-create` ticket step was first placed under a heading that reads as refusal conditions, and was moved).
- Velocity: normal. Both suites green at the end (55 enforcement fixtures, 15 hook fixtures), no reverts. Every fix was driven by a failing assertion written first, and each audit P1 was reproduced independently before being acted on (R-804d).

## 4. What shipped

Each item below has a durable home in the repo, so this section names the work and points at it rather than restating it.

**Ticket lifecycle** (`50072fa`): the `ticket-lifecycle` skill (five operations, eight canonical states, and the field set that makes day/week/month rollups and tier estimates possible), provider-neutral through a gitignored instance config with `claude/TICKET-TRACKER.template.json` tracked, specced in `claude/docs/superpowers/specs/2026-09-17-ticket-lifecycle-design.md`, ruled by R-605 and R-606, and wired into `task-start`, `feature-create`, `task-cleanup` and `cleanup-specs-plans`. R-906's Spec now names the ticket history as what recalibration reads.

**R-211** (`64da708`): every judgment call is asked as its own option-tile question. Canonical detail in `claude/global-memory/feedback_ask_judgment_calls.md`, bounded against `feedback_be_proactive.md` so an obvious call is not turned into a prompt.

**Four defects found by verifying each other** (`90b6996`, `c8b0555`, `a5b4ff1`, `7eb41b5`): six `translate-codex.test.sh` assertions matched nothing under GNU grep, so CI had accepted a red translator fixture since the translator landed; `codex/.gitignore` is now generated from the planned tree, closing the hole that nearly lost this session's own new skill from the port; `--write` removes the directories its orphan deletions empty; and the four phantom hash entries from the kebab-casing rename are gone.

**Engineering audit of `claude/enforce`** (`cfe62fe`): 0 P0, 4 P1, 8 P2, 7 P3. Read the report for the findings; its executive summary names the one shape behind four of them. Every P1 was reproduced independently before being acted on (R-804d) and one doc-drift row was dropped as verified false. Remediation, one commit per finding: `024dfd5` P1-3 (a credential file in a subdirectory was writable through a redirect), `0dd342f` P1-4 (a fixture passing on zero hooks, and a blocking guard outside the convention), `aff6d75` P1-1 (an absent manifest was silent, and `--update` had no floor), `857a374` P1-2 (the manifest now covers both fixture suites, 73 entries to 148, with a closure fixture that fails CI), `c247a3f` P2-6 (three in-place-edit spellings, fixed on your call rather than filed).

## 5. Pending (by urgency)

Deferred findings live in `claude/ISSUES.md`; this section carries what needs a decision or an action.

- **User, now (P0-2, unchanged since 2026-09-16)**: rotate the GitHub PAT and purge the transcripts named under PENDING USER ACTION in `claude/ISSUES.md`. About 10 minutes, and no lower-risk work should displace a known leaked credential.
- **User, workflow change now live**: editing any fixture under `claude/enforce/tests/` or `claude/hooks/tests/` now needs `hooks/hook-integrity-check.sh --update` and the manifest in the same commit, or session start warns and `hook-hashes-closure.test.sh` fails CI. You chose this cost when the P1-2 options were put to you; hook edits already had it.
- **User, before the ticket skill can do anything**: pick a tracker, copy `claude/TICKET-TRACKER.template.json` to `~/.claude/TICKET-TRACKER.json`, and fill in the container plus that server's real tool names. The tracker also needs the canonical fields as properties; the skill names what is missing rather than creating them. About 20 minutes.
- **User decision**: merge this branch (squash per R-512) or open a PR. R-514 needs explicit authorization in the turn, so nothing was merged. The squash will carry a feature, six harness fixes, an audit report and its remediation in one commit, which you accepted when you chose this branch over a dedicated one.
- **User, one command**: delete the four renamed leftovers from the live tree (`~/.claude/enforce/eslintOptions.mjs`, `renderLexiconSpec.mjs`, `resolveOutgoingBase.sh`, `~/.claude/hooks/single-file-folder-gate.sh`). `sync.sh` never deletes, so the kebab-casing left them behind.
- **Next session, once a tracker exists**: dry-run `open` on a real task and check the field mapping against the live database before it writes for real. About 15 minutes. The first few tasks fall back to the R-906 heuristic, because `estimate <tier>` quotes no number from history below five comparable closed tickets.
- **Audit residue, all in `claude/ISSUES.md`**: seven P2 and seven P3, none blocking. Read P2-1 first (a positional argument to `translate/codex.mjs` is silently ignored and `--write` then prunes the real tree), then the note that `translate/*.mjs` cannot be hashed at all, since it sits outside the surface `sync.sh` copies.
- **Deferred by design**: the mechanical tier for R-605 and R-606. A hook can only read a local signal, and the only candidate is a per-branch link file whose shape depends on the tracker chosen. Recorded in the spec's Non-goals so an audit reads a decision, not an R-516 gap.
- **Inherited workstream, unchanged**: the Claude config public hardening work lives in `claude/docs/superpowers/specs/2026-09-17-claude-config-public-hardening-design.md` plus the open P2 items in `claude/ISSUES.md`.
- **Inherited P2, unchanged**: decide resurrect-versus-retire for the `cursor/` port pipeline. The codex half is resolved; roughly 60 `cursor/` files still name a builder retired in the monorepo migration.

## 6. Next session: read first

- `docs/audits/2026-09-17-engineering.md`, whose executive summary names the one pattern behind four of its findings: a mechanism that enumerates what it protects with nothing checking the enumeration.
- `claude/ISSUES.md` Open section, for the PAT rotation and the audit residue.
- `claude/hooks/hook-integrity-check.sh` and `claude/enforce/tests/hook-hashes-closure.test.sh`, before editing any hook or fixture, because the manifest contract changed this session.
- `claude/skills/ticket-lifecycle/SKILL.md` and its spec, before touching anything the lifecycle names.
- `claude/rulebook/reference.md` R-211, R-605 and R-606, and `claude/TICKET-TRACKER.template.json` beside the chosen tracker's tool list.
