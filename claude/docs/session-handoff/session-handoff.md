# Session Handoff: 2026-09-04 Configuration Audit and Determinism Pass

## 1. Last commit

- `7b4cc42` docs(readme): reconcile the README with the repo it describes
- Branch `claude/config-audit-plan-b7lfb5`, 6 commits ahead of `main`, pushed. No PR opened.

## 2. Production state

- Both fixture suites green: 37 enforcement, 11 hook (48 total).
- Nothing in this branch is live until it is merged and pulled to `~/.claude`. The work was done in a remote container where the repo sits at `/home/user/claude-global-rules`, not `~/.claude`, so `settings.json` was never loaded by the session that wrote it.
- Every new enforcer was proven by direct invocation with a real payload, not by observing it fire naturally. See section 5.

## 3. What shipped

**Turn-level test gate (R-509).** `hooks/verification-gate.sh`, a `Stop` hook. Discovers the project's own checks (`.claude/verify.sh`, then this repo's two suites, then `package.json` test/typecheck, pytest/mypy, go test/vet, rspec). Runs only when the tree is dirty or the branch carries unpushed commits. Silent on success; blocks with the failing command's real output. Fails open when nothing is discoverable. `CLAUDE_SKIP_VERIFY=1` bypasses. Closes the hole where four push gates linted and nothing ran tests.

**Naming as data (R-316, R-317).** `enforce/lexicon.json` plus `enforce/rules/naming-lexicon.mjs`. Decides verb membership, the mandatory noun, banned synonyms with their canonical replacement, boolean prefixes, and the glossary head noun. Read and persistence verbs are bound to the R-304 layer that gives them meaning (`fetch` under clients/api, `load` under repositories/database/config/prompts, `get` elsewhere; `insert`/`upsert`/`drop` reserved to the persistence trees), so synonyms cannot be freely substituted. Opt-in per repo via the `naming` key in `.enforce.json`.

**Long-term drift (the ratchet).** `enforce/ratchet.mjs`. Full-tree counts per rule against a committed `.enforce-baseline.json`; fails when a count rises. Sorted keys, no timestamp, so repeated runs are byte-identical. `--update` locks in; `--strict` also fails on unlocked improvements.

**Two rules off the judge.** `enforce/rules/destructure-object-reads.mjs` (R-325, default-on) and `enforce/rules/file-header-comment.mjs` (R-320, opt-in via `fileHeaders`). Both were previously decided by nothing.

**Two rules honestly reclassified.** R-318 and R-322 left the llm-judge tier. Both are undecidable; the only deterministic checks available are proxies that enforce a different rule under the original rule's id. R-318 is now `[manual]`, R-322 keeps its advisory nudge. The judge tier is now exactly R-315, R-316, R-317.

**CLAUDE.md pruned.** 118 lines / 15,129 chars to 100 lines / 11,738 chars. 17 conditional rules moved to the new `structure-conventions` skill, every one still caught mechanically at the tool call. `claude-md-lint.test.sh` extended: a norm line may live in `CLAUDE.md` or a skill, and a rule carried in both now fails.

**New agent and skills.** `agents/spec-conformance-review.md` (diff against a named spec, R-804 output discipline, literal "No gaps found."). `skills/spec-grounding` (grounds an externally written spec via read-only subagents). `skills/structure-conventions`.

**CI and the pre-push installer.** `.github/workflows/enforce.yml` (the repo had no CI at all). `hooks/pre-push.sample` plus `hooks/install-git-hooks.sh`, replacing SETUP.md step 3's prose description of a script that did not exist in the checkout.

**README reconciled.** Nine pre-existing errors fixed, including `enforce/` missing from the layout entirely and a `global-memory/user_profile.md` that has never existed in git history.

## 4. Pending

**Blocking merge (user-side, minutes):**
- Merge the branch. Pull to `~/.claude`. `npm install --prefix enforce` (node_modules is gitignored; six fixtures fail without it).
- `bash hooks/install-git-hooks.sh`.
- Name the `fixtures` job as a required status check under branch protection. Without this the ratchet is advisory, since a local hook is `--no-verify`-able.

**Verification not performed (user-side, minutes):**
- `/context` and `/hooks` were never run. They are TUI commands, not callable from a remote session. They are the two steps of the original task that remain unverified.

**Adoption, per project (user-side, ~15 min each):**
- Add the `.enforce.json` keys wanted (`naming` with a `glossary`, `fileHeaders`, `importZones`). Omitting `glossary` skips head-noun checking rather than passing it.
- `node ~/.claude/enforce/ratchet.mjs --update`, commit `.enforce-baseline.json`.

**Open decision (one line):**
- `global-memory/user_profile.md` was referenced by the README but has never been tracked. References removed. If a local untracked copy exists deliberately, it belongs in the SETUP.md "what does not ship" table instead.

**Unchased (low):**
- `enforce/tests/eslint.test.sh` failed once on the first run immediately after `npm install` ("expected relative-before-alias import order to be flagged") and passed on every run since, in isolation and in six full-suite runs. The case reproduces correctly when run directly. Cause not found.

## 5. Next-session tasks, with files to read

- **Confirm the harness actually loads.** Read `settings.json` (Stop chain), run `/hooks` and `/context`. The verification gate was proven by feeding `hooks/verification-gate.sh` a real Stop payload against a deliberately broken fixture; it returned `{"decision":"block"}` with the suite output and was silent on green. It has never been observed firing from a live turn.
- **First real adoption of the lexicon.** Read `enforce/README.md` ("The naming lexicon"), then pick one project, write its `glossary`, and run the ratchet. Expect a large first baseline; that is the design.
- **Watch for the reverse drift.** `enforce/lexicon.json` and the R-316 Spec bullet in `rulebook/reference.md` are one rule in two forms. They were already out of sync once this session: the first draft of the registry banned `fetch`, `drop`, and `remove`, which R-316 explicitly approves. Nothing mechanically enforces their agreement.
- **Do not mechanize R-318 or R-322.** The reasoning is recorded in each rule's Spec in `rulebook/reference.md`. A line-count proxy enforces a different rule than the one written.
