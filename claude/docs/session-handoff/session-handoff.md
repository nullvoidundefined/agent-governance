# Session Handoff: 2026-09-04 Configuration Audit and Determinism Pass

## 1. Last commit

- `0b25e96` chore(repo): ignore per-session uploads (#7)
- Merged from this session's work: #2 (`b1a1241`), #3 (`7b55cdf`) and #6 (`e5b9da3`). Landed separately: #4 (`bd604c7`, install-git-hooks upgrades a superseded pre-push in place instead of refusing, with a fixture), #5 (`04dd4f5`) and #7 (`0b25e96`).
- In `nullvoidundefined/doppelscript`: #359 (`88cee3c`), #361 and #363 (`f95414f`).

## 2. Production state

- **Live.** Merged, pulled to `~/.claude`, dependencies installed, git hooks installed, and `/context` and `/hooks` run and confirmed by Ian. This is the one thing the session could not verify itself: the work was done in a remote container where the repo sits outside `~/.claude`, so `settings.json` was never loaded by the session that wrote it.
- Both fixture suites green: 38 enforcement, 12 hook. Green in CI on `main` (`.github/workflows/enforce.yml`, job `fixtures`). The twelfth hook fixture arrived with #4.
- Also shipped, in `nullvoidundefined/doppelscript`: `88cee3c` cuts GitHub Actions spend (see section 4).

## 3. What shipped

**doppelscript `/feature-cleanup` step 6, fixed (#363, merged).** The step could never remove a branch, for four independent reasons rather than the one first recorded: it gated on `git branch --merged`, which a squash merge never satisfies; it then deleted with `git branch -d`, which refuses for the same ancestry reason; the whole step sat inside "if a worktree is found", so branches without a worktree were never considered at all; and it deleted only the local branch. It now confirms merge state from the PR, refuses to delete what it cannot confirm, and removes the remote branch too. It keys on `mergedAt` rather than `merged`, because the PR list endpoint populates the timestamp and leaves the boolean false, so a check written against `.merged` reads correctly in review and then silently never fires.

**Turn-level test gate (R-509).** `hooks/verification-gate.sh`, a `Stop` hook. Discovers the project's own checks (`.claude/verify.sh`, then this repo's two suites, then `package.json` test/typecheck, pytest/mypy, go test/vet, rspec). Runs only when the tree is dirty or the branch carries unpushed commits. Silent on success; blocks with the failing command's real output. Fails open when nothing is discoverable. `CLAUDE_SKIP_VERIFY=1` bypasses. Closes the hole where four push gates linted and nothing ran tests.

**Naming as data (R-316, R-317).** `enforce/lexicon.json` plus `enforce/rules/naming-lexicon.mjs`. Decides verb membership, the mandatory noun, banned synonyms with their canonical replacement, boolean prefixes, and the glossary head noun. Read and persistence verbs are bound to the R-304 layer that gives them meaning (`fetch` under clients/api, `load` under repositories/database/config/prompts, `get` elsewhere; `insert`/`upsert`/`drop` reserved to the persistence trees), so synonyms cannot be freely substituted. Opt-in per repo via the `naming` key in `.enforce.json`.

**The registry is the single source.** `enforce/renderLexiconSpec.mjs` generates the R-316 verb lists in `rulebook/reference.md` between `<!-- lexicon:begin -->` markers. `--check` fails on divergence, `--write` reconciles and is idempotent. `validateLexicon()` additionally rejects a registry that contradicts itself (a banned verb still bound to a layer by `verbGroups` or `scopeVerbs`). Covered by `lexicon-spec-sync.test.sh`.

**Long-term drift (the ratchet).** `enforce/ratchet.mjs`. Full-tree counts per rule against a committed `.enforce-baseline.json`; fails when a count rises. Sorted keys, no timestamp, so repeated runs are byte-identical. `--update` locks in; `--strict` also fails on unlocked improvements.

**Two rules off the judge.** `enforce/rules/destructure-object-reads.mjs` (R-325, default-on) and `enforce/rules/file-header-comment.mjs` (R-320, opt-in via `fileHeaders`). Both were previously decided by nothing.

**Two rules honestly reclassified.** R-318 and R-322 left the llm-judge tier. Both are undecidable; the only deterministic checks available are proxies that enforce a different rule under the original rule's id. R-318 is now `[manual]`, R-322 keeps its advisory nudge. The judge tier is now exactly R-315, R-316, R-317.

**CLAUDE.md pruned.** 118 lines / 15,129 chars to 100 lines / 11,738 chars. 17 conditional rules moved to the new `structure-conventions` skill, every one still caught mechanically at the tool call. `claude-md-lint.test.sh` extended: a norm line may live in `CLAUDE.md` or a skill, and a rule carried in both now fails.

**New agent and skills.** `agents/spec-conformance-review.md` (diff against a named spec, R-804 output discipline, literal "No gaps found."). `skills/spec-grounding` (grounds an externally written spec via read-only subagents). `skills/structure-conventions`.

**CI and the pre-push installer.** `.github/workflows/enforce.yml` (the repo had no CI at all). `hooks/pre-push.sample` plus `hooks/install-git-hooks.sh`, replacing SETUP.md step 3's prose description of a script that did not exist in the checkout.

**README reconciled.** Nine pre-existing errors fixed, including `enforce/` missing from the layout entirely and a `global-memory/user_profile.md` that has never existed in git history.

## 4. Pending

**Outstanding, user-side:**
- Name the `fixtures` job as a required status check under branch protection (Settings > Branches). Without it the ratchet is advisory, since a local hook is `--no-verify`-able. Green on six commits, so it will not block.
- Delete the merged branches still on both remotes, and turn on Settings > General > Automatically delete head branches so it stops recurring. This session's git proxy returns 403 on delete-ref and rejects force-push, so it cannot do either.
- doppelscript issue #364: `e2e/navigation.spec.ts` flakes on `main` through `waitUntil: 'networkidle'`. The fix is one line and is written out in the issue; it is application test code, so it was not folded into #363.

**Adoption, per project (~15 min each):**
- Add the `.enforce.json` keys wanted (`naming` with a `glossary`, `fileHeaders`, `importZones`). Omitting `glossary` skips head-noun checking rather than passing it.
- `node ~/.claude/enforce/ratchet.mjs --update`, commit `.enforce-baseline.json`. Expect a large first baseline; that is the design.

**Untested, and only a real event will settle it:**
- doppelscript's Dependabot e2e skip. Every check on PR #359 ran as the maintainer, not as `dependabot[bot]`, so only the normal path is proven. The first real Dependabot PR tests whether a skipped job satisfies the required checks. If it blocks, delete the one `if:` in `ci.yml`.

**Open, unreproduced:**
- `enforce/tests/eslint.test.sh` failed once on the first run after a cold install and has passed every run since. The cold-`node_modules` hypothesis was tested directly (delete, reinstall, run immediately, twice) and eliminated. The one condition not reproduced is that the original install was network-bound at 5 minutes against 4 seconds warm, which points at contention during that install. Not worth more time without a second sighting.

## 5. Next-session tasks, with files to read

- **First real adoption of the lexicon.** Read `enforce/README.md` ("The naming lexicon"), pick one project, write its `glossary`, run the ratchet.
- **Do not mechanize R-318 or R-322.** The reasoning is recorded in each rule's Spec in `rulebook/reference.md`. A line-count proxy enforces a different rule than the one written, under that rule's id.
- **Do not hand-edit the R-316 verb bullets** in `rulebook/reference.md`. They are generated; change `enforce/lexicon.json` and run `node enforce/renderLexiconSpec.mjs --write`. The suite fails if they diverge.
- **When adding an enforcer,** R-516 still binds: a `manifest.json` entry naming tier and enforcer, plus a fixture under `enforce/tests/`. The manifest closure test will say so if you forget.
