# PR: R-607, a features list and user stories in every application repository

Ticket: none opened; the Linear MCP server was not authenticated in the session that did this work, so the ticket fields are recorded in the handoff instead. Branch: `feat/product-docs-rule`. Spec: `claude/docs/superpowers/specs/2026-09-18-product-docs-design.md` (B-1 to B-24).

## Summary

The owner asked, from the Voyager 2.0 session on 2026-09-18, that every application keep a features list and a set of user stories, and that both be updated automatically when a repository is created and when a feature starts or closes. Doppelscript already kept these documents by hand, with a pre-push script that only knew Next.js routes. This PR turns that practice into global rule R-607. The rule is enforced by a push gate that knows the route layouts of Next, Nuxt, FastAPI, and Express, and `repo-setup`, `feature-create`, `task-start`, and `task-cleanup` are wired so that the documents exist from the first commit and move with the work. The rule is compatible with the "Product documentation" section of Voyager 2.0's spec, which already adopts the same document set for Nuxt and FastAPI.

## What changed

- `claude/enforce/require-feature-checklist.sh` (new): the canonical checklist. When the branch adds a route file (Next `page`/`route`, Nuxt `app/pages`, `server/api`, `server/routes`, FastAPI `app/routers/*.py`, Express `src/routes`, `src/handlers`), it requires the same branch to change `docs/feature-list/features.md`, a story file under `docs/user-stories/` other than the README, and an e2e spec. It matches trigger paths under any monorepo prefix, never triggers on test files, skips `main`, skips when the base ref is missing, and reads a `.enforce.json` opt-out and extra trigger patterns as data.
- `claude/hooks/push-feature-docs-gate.sh` (new): runs that script on every `git push` Claude Code makes, against the repository the push names, and denies with the script's report. It is registered in `settings.json`, has a manifest entry for R-607, and is covered by the hash manifest.
- `claude/prompts/`: three templates (`feature-list-template.md`, `user-story-area-template.md`, `user-stories-readme-template.md`). Both scripts below read the document shapes from these files, so each shape exists in one place.
- `repo-setup`: a new `product-docs` baseline item seeds the features list, the stories README, and a copy of the checklist as `scripts/require-feature-checklist.sh`. It never overwrites an existing file. `--no-product-docs` records `"productDocs": false` in `.enforce.json` for a library or tooling repository, and `--check` then reports `SKIPPED` without counting the item as missing.
- `feature-create`: the scaffold now requires `--area`. It appends the next free `US-<AREA>-NNN` story to `docs/user-stories/<area>.md`, indexes a new area file in the README, inserts a **Planned** row into the matching `## <Area>` section of the features list (or creates that section), and rewrites the `Last updated:` line. Before this change it wrote one story file per feature and silently skipped repositories without the docs; now it seeds the missing docs from the templates.
- `task-start` and `task-cleanup`: a Standard-tier task adds its feature row and story before the first slice. At close, the row moves to **Complete** or **Partial**, the criteria that shipped are ticked, and the real e2e path is filled in. The `scan.sh` hint now points at the area file.
- `claude/CLAUDE.md` (R-607 norm line), `claude/rulebook/reference.md` (Spec, Scope, Enforcement), and `claude/README.md` (the push-gate paragraph).
- The Codex and Cursor ports are regenerated from these sources.

## Architectural decisions

- **The gate runs only the harness copy of the checklist.** The owner chose "both, one source": a harness gate plus a copy of the script in each repository. The owner's first description of that option had the repository's copy take precedence when present. The 2026-07-31 security audit established that push gates never execute code from the target repository, because that is a code-execution path for any cloned repository. The gate therefore always runs the harness copy. Per-repository differences are expressed as data (`productDocs.extraTriggers`), which the script passes to `grep -E` and never evaluates. The repository's copy exists for that repository's own git hook and CI, where its code is already trusted. The owner approved the spec with this change stated.
- **The check blocks rather than warns, and has no bypass flag.** The owner chose to block. When an existing story and spec already cover a new route, the fix is to update them, which also leaves a record of the coverage. `git push --no-verify` in a terminal skips only the repository's own hook and never the harness gate.
- **Stories are grouped one file per area, and `feature-create` requires `--area`.** The owner chose per-area files, which match Doppelscript's newer files and Voyager's spec. If `--area` were optional and defaulted to the slug, the scaffold would quietly go back to one file per feature. Area headings are matched by slug, so `## Authentication & Account` is the area `authentication-account` and existing Doppelscript-style headings keep working.
- **Seeding is on by default, with an explicit opt-out.** The owner chose this over detecting the stack from the layout, because a new repository has no routes to detect at creation time, which is exactly when seeding matters.
- **Acceptance criteria are a checkbox list, not a numbered list.** The request asks for "an acceptance-criteria checklist", and Voyager's spec ticks criteria as slices ship. A numbered list cannot be ticked.
- **Ported copies fall back to `~/.claude` for the templates.** A Codex or Cursor copy of `setup.sh` or `scaffold.sh` lives under `~/.codex` or `~/.cursor`, and neither carries `prompts/` or `enforce/`. Each script looks for its sibling tree first, then falls back to the synced `~/.claude`. If neither has the templates, the scaffold stops with exit 8 and `repo-setup` reports the item as missing, instead of writing empty files.

## Testing

- Every behavior was written test-first. The fixture was run and seen to fail for the stated reason, the code was written, the fixture was run and seen to pass, and both went into one commit. `enforce/tdd.sh` could not hold the lock for these slices, because it only drives Vitest and Jest and every fixture here is a bash test.
- `require-feature-checklist.test.sh` (new, 32 assertions) covers B-1 to B-11: each stack's triggers, test-file exclusion, partial artifacts, README-only story changes, monorepo prefixes, modified-versus-added files, the skip rules, the opt-out, extra triggers, and an invalid pattern.
- `push-feature-docs-gate.test.sh` (new, `# Covers: hook:push-feature-docs-gate`) covers B-12 to B-15, including a repository copy that would pass and writes a marker file. The gate still denies, and the marker file is never written.
- `repo-setup.test.sh` gained cases 8 and 9 (B-16 to B-18), and `product-docs` joined its item loops.
- `feature-create-scaffold.test.sh` was rewritten for areas (B-19 to B-22) and gained the fallback for ported copies. That case was confirmed to fail with the fallback code removed.
- The full enforce suite and the full hooks suite pass after rebasing onto `372e782` (#40). `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` exit 0.

## Reflection

About 40 minutes have passed since implementation started: work began at 12:12Z, and this document was written at about 12:52Z.

The security constraint is what I understand better now than I did when I asked the owner where the check should live. My first option description said a repository's copy would take precedence over the harness copy. Only when I read `gate-trusted-repos.txt` did I see that this would reopen the code-execution path the July audit had closed. I also first ran `hook-integrity-check.sh --update` with `CLAUDE_DIR` set, a variable the script does not read. It overwrote the live `~/.claude/enforce/hook-hashes.txt`, and I restored that file byte for byte from the sync source before continuing. The correct variable is `CLAUDE_INTEGRITY_ROOT`. Two more mistakes were caught by the harness's own checks. The glossary check rejected the first Domain vocabulary because each entry lacked the `chosen over:` form. `claude-md-lint` read a skill sentence that began with `R-607` as a second norm line.

## Follow-ups

- The CI templates (`template-ci-*.yml`) could run `scripts/require-feature-checklist.sh`, so that the check also covers pushes made outside Claude Code.
- `tdd.sh` could learn a bash-fixture runner, so that slices in this repository can run under the R-412 lock.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
