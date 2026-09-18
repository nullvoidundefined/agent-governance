# Product docs: features list and user stories in every application repo (R-607)

**Ticket:** none opened (the Linear MCP server was not authenticated in the session that wrote this spec; the ticket fields are recorded in the handoff per `skills/ticket-lifecycle/SKILL.md`)
**Branch:** `feat/product-docs-rule`
**Requested:** 2026-09-18, by the owner, from the Voyager 2.0 session.

## Goal

Every application repository keeps two product documents, a features list and a set of user stories, and a push that adds a new user-facing route is refused unless the same branch also touched the features list, a user story, and an end-to-end spec. Doppelscript has done this by hand since 2026 with a Next-only pre-push script, and Voyager 2.0's spec (`production/voyager_2.0/docs/superpowers/specs/2026-09-18-voyager-2-agent-design.md`, section "Product documentation") adopts the same set for Nuxt and FastAPI. This spec generalizes that practice into a global rule, R-607, with a stack-aware check that runs in every repository at push time, and wires the repository and feature skills so the documents are created when a repository is created and updated when a feature starts and when it closes, rather than depending on recall.

## Decisions taken with the owner (2026-09-18)

| Question | Decision |
|---|---|
| Rule number and section | R-607, in Lifecycle and memory (R-6xx), beside the handoff and ticket rules. |
| Block or warn | Block. The push is denied until the three artifacts are touched. |
| Story granularity | One file per product area (`docs/user-stories/<area>.md`), each holding several `US-<AREA>-NNN` stories; `README.md` indexes the files. |
| Where the check lives | One canonical script in the harness, run by a harness push gate in every repository; `repo-setup` also copies it into the repository as `scripts/require-feature-checklist.sh` for the repository's own git hook and CI. |
| Which repositories get the documents | Every repository by default; `repo-setup --no-product-docs` opts a library or tooling repository out by recording `"productDocs": false` in `.enforce.json`. |
| How feature-create picks the area | A required `--area <name>` flag; without it the scaffold exits 2 and lists the areas that already exist. |

One refinement of the "where the check lives" answer follows from an existing constraint rather than from a new choice. The 2026-07-31 security audit established that push gates never execute code from the target repository (`claude/PROTOCOL.md`, the entry that banned `bundle exec`; `enforce/gate-trusted-repos.txt` exists for the one exception). The gate therefore always runs the harness's canonical script and never the repository's copy. A repository that needs different trigger paths declares them as data in `.enforce.json` (`productDocs.extraTriggers`), which the canonical script reads as regular expressions and never evaluates as code. The repository's own copy is run only by the repository's own git hook and CI, where the repository's code is already trusted.

## Inputs

- The push gate receives the Claude Code `PreToolUse` payload for a Bash call; it acts only when the command is a `git push`, resolved with the existing `hooks/git-invocation.sh` normalizer so that `git -C <dir> push` targets the named repository.
- The check script receives a base ref (argument or `FEATURE_CHECKLIST_BASE`, default `origin/main`) and reads the diff from the merge base to `HEAD` in the current repository.
- `.enforce.json` at the repository root, optional: `{"productDocs": false}` disables the check; `{"productDocs": {"extraTriggers": ["^src/views/.+\\.tsx$"]}}` adds trigger patterns.
- `repo-setup`'s `setup.sh` gains `--no-product-docs`.
- `feature-create`'s `scaffold.sh` gains a required `--area <name>`.

## Outputs

- The check script exits 0 when nothing is required or everything required is present, and exits 1 with a report naming the triggering files and each missing artifact.
- The push gate emits a `PreToolUse` deny whose reason carries the script's report and names R-607; it emits nothing otherwise.
- `repo-setup` writes `docs/feature-list/features.md`, `docs/user-stories/README.md`, and `scripts/require-feature-checklist.sh` when absent, and reports the `product-docs` item as `OK`, `MISSING`, or `SKIPPED`.
- `feature-create` appends one feature row into the area's section of `features.md`, one story to the area's story file, and one index row to the README when the area file is new.

## Trigger paths

A trigger is a file **added** on the branch (`git diff --diff-filter=A`), matched anywhere in the tree so that monorepo prefixes such as `apps/client/web/` match. Test files (`*.test.*`, `*.spec.*`, anything under `__tests__/`, `test_*.py`) never trigger.

| Stack | Pattern (extended regex, anchored at a path-segment boundary) | Source of the convention |
|---|---|---|
| Next (App Router) | `(src/)?app/(.+/)?(page\|route)\.(tsx\|ts\|jsx\|js)$` | Doppelscript; `CLAUDE-FRONTEND-NEXT.md` |
| Nuxt | `app/pages/.+\.vue$`, `server/api/.+\.(ts\|js)$`, `server/routes/.+\.(ts\|js)$` | `CLAUDE-FRONTEND-NUXT.md` path scopes; Voyager spec |
| FastAPI | `app/routers/[^/]+\.py$`, excluding `__init__.py` | `CLAUDE-PYTHON.md` layout; Voyager spec |
| Express | `src/routes/.+\.(ts\|js)$`, `src/handlers/.+\.(ts\|js)$` | `CLAUDE-BACKEND.md` layout |

## Required artifacts

All three must appear in `git diff --name-only <merge-base>..HEAD` (added or modified), at the repository root:

1. `docs/feature-list/features.md`.
2. A story file `docs/user-stories/<name>.md` other than `README.md`; editing only the index does not count, because the index carries no story.
3. An end-to-end spec: `e2e/**/*.spec.(ts|js|mjs)`, `e2e/**/*.test.(ts|js|mjs)`, or `e2e/**/test_*.py`, at any depth prefix (a monorepo keeps `apps/e2e/`).

## Document formats

`docs/feature-list/features.md`:

```markdown
# <Project> Feature List

Status key: **Complete** | **Partial** | **Planned**

Last updated: YYYY-MM-DD (<what changed>)

---

## <Area>

| Feature | Status | Notes |
| ------- | ------ | ----- |
| <feature> | **Planned** | US-<AREA>-NNN; <notes> |
```

`docs/user-stories/<area>.md` holds one or more stories in this shape:

```markdown
## US-<AREA>-NNN: <title>

**As** <role>
**I want to** <action>
**So that** <benefit>

**Acceptance criteria:**

- [ ] <one testable behavior>

**E2E test:** `e2e/<spec>.spec.ts`
**Ticket:** <ticket-key>
```

The checkbox form is chosen over Doppelscript's numbered list because the owner's request names "an acceptance-criteria checklist" and Voyager's spec says each slice "ticks its stories' criteria"; a numbered list cannot be ticked. A story may add a `**Covers:** B-n` line, which Voyager uses to map stories to its spec's behaviors; the rule does not require it.

`AREA` is the area name upper-cased with hyphens kept (`chat` gives `US-CHAT-001`, `admin-dashboard` gives `US-ADMIN-DASHBOARD-001`). `NNN` is one more than the highest number already used in that area file, zero-padded to three digits. An identifier is never reused or renumbered once written.

The templates live in `claude/prompts/`: `feature-list-template.md`, `user-story-area-template.md`, and `user-stories-readme-template.md`. `repo-setup` and `feature-create` both read them from `~/.claude/prompts/`, so there is one copy of each shape.

## Acceptance criteria

Check script (`claude/enforce/require-feature-checklist.sh`):

- B-1: The script exits 0 and prints nothing when the branch adds no trigger file.
- B-2: The script exits 1 when the branch adds a Next `page.tsx` or `route.ts` and changes none of the three artifacts, and its report names the triggering file and all three missing artifacts.
- B-3: The script triggers on an added Nuxt `app/pages/**/*.vue`, `server/api/**`, or `server/routes/**` file.
- B-4: The script triggers on an added FastAPI `app/routers/<name>.py` and does not trigger on an added `app/routers/__init__.py`.
- B-5: The script triggers on an added Express `src/routes/**` or `src/handlers/**` file and does not trigger on an added test file in those trees.
- B-6: The script exits 0 when the branch adds a trigger and also changes `features.md`, a non-README story file, and an e2e spec.
- B-7: The script names only the artifacts actually missing when one or two of the three are present, and treats a README-only change under `docs/user-stories/` as a missing story.
- B-8: The script triggers on a trigger path under a monorepo prefix (`apps/client/web/src/app/trips/page.tsx`) and still requires the artifacts at the repository root.
- B-9: The script does not trigger when a trigger-path file is modified rather than added.
- B-10: The script exits 0 without checking when `HEAD` is on `main`, when the base ref does not resolve, or when `.enforce.json` sets `"productDocs": false`.
- B-11: The script triggers on a file matching a `productDocs.extraTriggers` pattern from `.enforce.json`.

Push gate (`claude/hooks/push-feature-docs-gate.sh`):

- B-12: The gate denies a `git push` whose outgoing diff fails the canonical script, and the deny reason contains the script's report and the string `R-607`.
- B-13: The gate emits nothing for a push whose outgoing diff passes, and for any Bash command that is not a `git push`.
- B-14: The gate runs the harness's canonical script even when the target repository carries its own `scripts/require-feature-checklist.sh`, and never executes the repository's copy.
- B-15: The gate emits nothing for a repository whose origin URL is listed in `enforce/exempt-repos.txt`, matching the other push gates.

`repo-setup` (`claude/skills/repo-setup/scripts/setup.sh`):

- B-16: `--check` reports `product-docs MISSING` naming each absent file of the three, and exits 1.
- B-17: Apply writes each absent file from the templates and the canonical script (the script copy executable), never overwrites an existing one, and a following `--check` reports `product-docs OK`.
- B-18: `--no-product-docs` writes nothing under `docs/` or `scripts/`, records `"productDocs": false` in `.enforce.json` (merging with an existing file), and `--check` then reports `product-docs SKIPPED`.

`feature-create` (`claude/skills/feature-create/scripts/scaffold.sh`):

- B-19: The scaffold exits 2 without creating a worktree when `--area` is absent, and lists the area files that already exist under `docs/user-stories/`.
- B-20: The scaffold appends a story `US-<AREA>-NNN` with the next free number to `docs/user-stories/<area>.md`, creating the file from the template when it is new, and adds the new file to the README index.
- B-21: The scaffold inserts the feature row, status **Planned** and the story id in its notes, into the table under the `## <Area>` heading of `features.md`, creates that section at the end when absent, and rewrites the `Last updated:` line with today's date.
- B-22: The scaffold creates `features.md` and the README from the templates when they are absent, instead of skipping the scaffold as it does today.

Registration:

- B-23: `enforce/manifest.json` carries an R-607 entry with enforcer `hook:push-feature-docs-gate` whose note names its fixture, and `hooks/enforcement-guard-check.sh` resolves that enforcer to a hook registered in `settings.json`.
- B-24: `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` exit 0 after the change.

## Wiring that is prose, not behavior

These edits are skill and rule text, verified by review rather than by a test:

- `claude/CLAUDE.md` gains the R-607 norm line; `claude/rulebook/reference.md` gains its Spec, Scope, and Enforcement.
- `task-start`: a Standard-tier task that adds user-facing behavior adds its feature row (**Planned**, or **Partial** when it extends an existing feature) and its story to the area file before the first slice opens. Complex and Saga tiers get the same through `feature-create`.
- `task-cleanup`: its "user-facing behavior shipped" step moves the row to **Complete** (or **Partial** with the gap in the notes), ticks the story's criteria that shipped, fills the real `**E2E test:**` path, and refreshes `Last updated:`, citing R-607 and pointing at the templates.
- `feature-create` SKILL: documents `--area`, the per-area file, and how to choose an area from the `## ` headings of `features.md`.
- `repo-setup` SKILL: the `product-docs` baseline row and the `--no-product-docs` flag.

## Invariants

- A story identifier, once written, is never renumbered or reused.
- The gate never executes code from the target repository.
- `repo-setup` and `feature-create` never overwrite an existing product document; they only append or insert.

## Failure modes

- Base ref absent (fresh clone, detached CI checkout): the script exits 0 silently, the documented Doppelscript behavior, because refusing an unrelated push is worse than missing one.
- `jq` absent while `.enforce.json` exists: the script cannot read the opt-out, so it proceeds with the check (fails closed for a guard); the gate already requires `jq` for its own payload.
- Malformed `extraTriggers` regular expression: `grep -E` returns 2; the script reports the bad pattern on stderr and ignores it, so one bad entry does not disable the built-in triggers.
- The owner genuinely has no user story to write (a health route, an internal proxy): touch the covering story or spec with a note, or opt the path out through a narrower route layout. There is no bypass flag in the gate, matching the "block" decision; the terminal `git push --no-verify` bypasses only the repository's own git hook, never the harness gate.

## State transitions

None. The feature list's **Planned**, **Partial**, and **Complete** statuses are document content that the skills write; no code owns them.

## Non-goals

- Checking that a story's criteria are true, that the named e2e spec exists, or that it covers the story. The check is a diff-presence check, as in Doppelscript; content quality stays with review and `task-cleanup`.
- Triggering on feature work that adds no route. This is Doppelscript's accepted false-negative cost for a near-zero false-positive rate.
- Migrating Doppelscript's existing per-story files (`US-EXT-001.md` and similar) into area files. Existing repositories keep their files; the rule governs new stories.
- Wiring the repository's copy into a git hook manager (husky, lefthook, pre-commit) or into the CI templates. `repo-setup` seeds the script; the repository's own hook configuration calls it. A follow-up can add a CI step to the `template-ci-*.yml` files.
- Ruby and Go trigger paths. No application in this tree uses them for a web surface today; `extraTriggers` covers a repository that does.

## Dependencies

- Reuses `hooks/git-invocation.sh` (push detection and target repository), `enforce/resolve-outgoing-base.sh` (base resolution), `hooks/log-rule-fire.sh`, and the exemption file convention shared by the other push gates.
- Reuses `feature-create`'s existing scaffold and test, and `repo-setup`'s item framework.
- No new third-party dependency (R-331): bash, git, grep, and jq, which every existing gate already requires.

## Observability

The gate logs a deny through `log_rule_fire "feature-docs" "push-feature-docs-gate" "deny"`, the same channel the other gates use. Request IDs, analytics, and health checks do not apply to a local hook.

## Security

The gate reads the diff and `.enforce.json` and never executes repository code (B-14). `extraTriggers` entries are passed to `grep -E` as patterns, never to `eval`. `.enforce.json` is a gate input under R-410, which the session never edits with Write or Edit; `repo-setup` writes it only when the owner invokes the skill with `--no-product-docs`, the same way the owner creates the file today.

## Compatibility with Voyager 2.0

Voyager's spec names `docs/feature-list/features.md`, per-area files under `docs/user-stories/` with `US-CHAT-001`-style identifiers, a Playwright spec under `e2e/`, and triggers `app/pages/**/*.vue` and `app/routers/*.py`. Every one is a subset of this rule. Voyager's "Every B-number maps to a story" requirement is stricter than R-607 and stays a project rule, expressed through the optional `**Covers:**` line.

## Domain vocabulary

- product docs - the features list and the user stories together - chosen over: feature docs because the pair describes the product rather than one feature.
- feature list - the file `docs/feature-list/features.md` - chosen over: feature matrix, roadmap because Doppelscript already uses the name and the path.
- area - a product area, which is one `## ` section of the feature list and one story file - chosen over: surface, domain because both already mean a deploy target and an R-307 service domain in this harness.
- story - one `US-<AREA>-NNN` entry in an area file - chosen over: user flow because the request uses both words for the same thing and the identifier prefix already says story.
- trigger - a file whose addition signals a new user-facing route - chosen over: route file because FastAPI routers and Nuxt pages are not all named routes.
- feature checklist - the three required artifacts - chosen over: product docs check because Doppelscript's script already carries the name, so `scripts/require-feature-checklist.sh` means the same thing in every repository.
