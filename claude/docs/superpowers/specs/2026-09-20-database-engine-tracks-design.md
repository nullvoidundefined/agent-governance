# Database Engine Tracks: Design

Date: 2026-09-20
Status: draft, awaiting owner review
Ticket: IAN-173
Blocked on: the R-334 amendment ticket (engine case convention), which must merge first

## Summary

`CLAUDE-DATABASE.md` is named for a layer but written entirely against one engine. Its 336 lines open with "These rules apply to all PostgreSQL schemas", and every rule below that line is expressed in `node-pg-migrate` builder calls, `pg` pool calls, or SQL syntax. The consequence is that the rules which are actually about the database layer, rather than about PostgreSQL, are only reachable through Postgres syntax: that every schema change is a reversible checked-in migration, that repositories are the only code that touches the database, that every query carries an owner scope, that every entity carries creation and update timestamps, and that the API server is the only database client. A project on another engine has no conventions to read at all, and a reader who wants the layer rule has to mentally subtract the syntax from it.

This spec splits the file into an engine-agnostic base and two engine siblings, following the base-plus-framework pattern `CLAUDE-FRONTEND.md` already uses for React, Next, Vite, Vue, and Nuxt. The base keeps the name `CLAUDE-DATABASE.md` and carries the layer rules and the engine dispatch table. `CLAUDE-DATABASE-POSTGRES.md` carries the current content, reorganized to the base's section order. `CLAUDE-DATABASE-MONGODB.md` is a new track at parity with the Postgres file.

The 2026-09-17 Python and Vue track spec listed "Changing `CLAUDE-DATABASE.md`" as an explicit non-goal and deferred it. This is that deferred work.
## Domain vocabulary

| Term | Meaning in this spec |
|---|---|
| Base file | `CLAUDE-DATABASE.md` after the split: the engine-agnostic database conventions plus the Engine Files dispatch table. Named for the layer, read by every project with a database. chosen over: `CLAUDE-DATABASE-CORE.md`, because renaming the existing file would break the six citations that already point at it and would leave the most-read name pointing at nothing. |
| Engine file | `CLAUDE-DATABASE-POSTGRES.md` or `CLAUDE-DATABASE-MONGODB.md`: one file per storage engine, read alongside the base file, never instead of it. chosen over: "track", because a track in this corpus is a language stack (`CLAUDE-PYTHON.md`) and an engine crosses tracks: a Postgres project can be TypeScript or Python. |
| Engine | The storage product itself (PostgreSQL, MongoDB), as distinct from the driver, the migration tool, and the host. chosen over: "database", because "database" also names one logical database inside an engine instance and the ambiguity matters in the migration sections. |
| Layer rule | A rule that holds whatever the engine is (migrations are reversible, repositories own access, every query is owner-scoped). Lives in the base file. |
| Engine rule | A rule whose statement requires engine syntax or an engine-specific type (`pgm.func()`, `$jsonSchema`, `timestamptz`, `ObjectId`). Lives in an engine file. |
| Restatement | An engine file's concrete form of a layer rule, citing the base rule rather than re-arguing it. |
| Dispatch table | The Engine Files table in the base file: root marker, engine, file to read. The database analog of the Framework Files table in `CLAUDE-FRONTEND.md`. chosen over: "marker table", because the table's job is selecting a file to read and the marker is only its left column. |
| Auto-load glob | A `paths:` frontmatter pattern. These, and not the dispatch table, are what actually load a convention file into a session. The distinction is load-bearing: see finding 1. |
| Heading parity | The property that both engine files carry the same `##` heading set in the same order, so a reader moving between engines finds the same section in the same place. Asserted mechanically, not by review. |
| Expand and contract | The staged process for a schema change that cannot be applied in one step: add the new shape, backfill, dual-write, switch reads, drop the old shape, each stage its own migration and its own deploy. chosen over: "risky migration", because the risk is the property and the staging is the rule, and `CLAUDE-PYTHON.md` already cites it as a process. |
| Pinned pre-split copy | `git show 48f3b5c:claude/CLAUDE-DATABASE.md`, the version this split starts from. The line-coverage assertion reads it so the check survives the rewrite. |
## Goals

1. A reader on any engine can find the layer rules without reading another engine's syntax, and an engine file never restates a layer rule it could cite.
2. A MongoDB project auto-loads database conventions at the same depth a Postgres project does today, and a Postgres project never auto-loads MongoDB rules.
3. The split loses no rule that `CLAUDE-DATABASE.md` states today. Every one of its 24 headings below the title lands somewhere nameable, and every non-blank line of the pinned pre-split copy appears in the base or the Postgres file.
4. Both engine files stay structurally parallel as they are edited, enforced mechanically rather than by recall.
5. Every existing citation of `CLAUDE-DATABASE.md` elsewhere in the corpus still resolves after the split, including the one that does not resolve today.

## Non-goals

- Adding a third engine (SQLite, DynamoDB, Redis-as-store). The dispatch table is built to take one, but this spec ships two.
- Firebase, and any other backend-as-a-service. A BaaS bundles auth, hosting, and functions with its datastore, so its conventions are not database conventions and would not fit this file's frontmatter or its dispatch table. Considered and rejected on 2026-09-20.
- Rewriting `CLAUDE-PYTHON.md`. Its SQLAlchemy and Alembic sections already restate the Postgres rules by citation; they gain corrected citation targets, nothing more.
- Amending R-334 itself. The engine case convention is its own ticket and its own PR, and this work waits for it.
- Changing the position of any rule that moves. The additions this spec does make are listed exhaustively in Design 4; anything not on that list keeps its current wording and its current position. Two corrections of fact travel with the move and are named there.
- Building any project on MongoDB. This ships conventions, not an application.

## Decisions already made

Settled with the owner on 2026-09-20, before and during this spec. Inputs, not open questions.

| Decision | Choice | Consequence in this spec |
|---|---|---|
| Second engine | MongoDB, not Firebase | Design 3 |
| Mongo data access | Official `mongodb` driver with repositories and `$jsonSchema` collection validators; no Mongoose, no ODM | Mirrors the Postgres file's no-ORM stance, so the two engine files stay parallel in kind and not only in shape |
| Mongo document identity | Driver-generated `ObjectId` as `_id`, serialized to a string at every API boundary | The base identity rule is stated as "one stable primary key per record, opaque to clients", and each engine file names its own key type |
| Mongo migrations | Retained, versioned, reversible, through `migrate-mongo` | The base file's migration discipline applies unchanged to both engines |
| Mongo field and collection casing | `camelCase` (`tripLegs`, `userId`), with R-334 amended first, in its own ticket and PR, to say the separator follows the engine's case convention while word order stays base noun first | This spec is blocked until that PR merges; Design 3 and the acceptance criteria assume the amended rule |

## Current state (findings)

- `claude/CLAUDE-DATABASE.md` is 336 lines with 24 headings below the title, frontmatter globs `**/migrations/**`, `**/*.sql`, `**/src/database/**`, `**/src/repositories/**`.
- Auto-loading is done by those globs, through the path-scoped symlinks in `rules/` (`claude/rules/session-types.md:18`, `claude/README.md:185`). A dispatch table is a reading instruction for a human or an agent, and loads nothing. The frontend siblings this split copies carry globs only they match (`CLAUDE-FRONTEND-NEXT.md:2-6`, `CLAUDE-FRONTEND-VITE.md:2-6`).
- `claude/CLAUDE-PYTHON.md:705` cites "the staged process in `CLAUDE-DATABASE.md`" for risky migrations. No such section exists or ever existed. The citation is dangling today.
- `claude/CLAUDE-PYTHON.md:609` and `:699` cite the file for owner-scoped queries and for table, column, constraint, timestamp, and access-control naming. All five targets are layer rules and stay in the base file, so both citations keep resolving unchanged. `claude/CLAUDE-PYTHON.md:8` says the Python file "restates the parts of `CLAUDE-DATABASE.md` that change shape under SQLAlchemy", which points at Postgres content after the split and is retargeted.
- `claude/rulebook/reference.md:390` cites the file for the `{referenced_table_singular}_id` foreign-key form, and `:391` for the `link_tags` junction convention. Both are engine-specific in their current wording and would dangle if the partition moved them wholesale. The cursor port repeats both at `cursor/rules/rulebook-reference-r3xx-architecture-and-naming.mdc:257-258`.
- `claude/CLAUDE-DATABASE.md:236` names the pool module `src/db/pool/pool.ts`. R-311 forbids `db/`, R-304's vocabulary is `database`, `structure-gate.sh:119-122` denies a new `db` directory in a TypeScript server, and this file's own glob is `**/src/database/**`. `CLAUDE-BACKEND.md` carries the same drift at `:716` against its own `:47-48`.
- `claude/CLAUDE-DATABASE.md:333-334` states `No RLS policies` and `user_id = $N` inside Access Control, which the partition otherwise treats as engine-neutral. Both are Postgres-specific.
- `claude/enforce/tests/convention-track-invariants.test.sh` asserts, for every `CLAUDE-*.md`: path frontmatter, a resolving `rules/*.md` symlink, and a mention in either the Stack detection section of `rules/session-types.md` or the Framework Files section of `CLAUDE-FRONTEND.md`. Its Python block (`:161-183`) hard-codes a heading list, which is the pattern the database block copies.
- The only database-keyed enforcer in `enforce/manifest.json` is R-328, `hook:migration-defaults-guard` (`manifest.json:354`). The hook triggers on any path containing `/migrations/` (`migration-defaults-guard.sh:36`) and applies its `pgm` regexes to `.js` files there (`:59-66`), so migrate-mongo migrations are already inside its trigger and simply never match.
- Six files name `CLAUDE-DATABASE.md` in a list of convention files: `claude/README.md:81`, `claude/SETUP.md:53`, `claude/PROTOCOL.md:70`, `claude/rulebook/reference.md:734`, `claude/rules/session-types.md:22`, `claude/agents/audit-engineering.md:90`.
- Two translators generate ports from `claude/`: `translate/codex.mjs` and `translate/cursor.mjs`, the latter discovering `CLAUDE-*.md` by readdir (`cursor.mjs:46-55`) and emitting five files that carry the base name. Neither translator's `--check` runs in CI or in any hook, so a stale port ships silently.

## Design

### 1. Partition

Every section of today's file lands in exactly one place. `Base` means the rule is stated there in engine-neutral terms; `Postgres` means the current text moves; `Both` means the base states the rule and the Postgres file restates it concretely, reusing the current wording for the concrete part.

| Today's section | Lands | Note |
|---|---|---|
| Stack | Both | Base states one engine per service, connection string from the environment, the API server as sole client. Postgres names Neon, `node-pg-migrate`, `pg`, and the no-ORM stance. |
| Migration Files: Location, Naming, Structure, Rules | Both | Base states versioned, reversible, one logical change per file, never edit a merged migration. Postgres keeps the timestamp filename format, the ESM export shape, and the `pgm` builder rules. |
| Schema Conventions: Table Naming, Column Naming | Both | Base states R-334 word order, plural collections, one case convention per engine, `is_`/`has_` for booleans, and the reference-key form as "the referenced entity's singular plus the engine's id suffix". Postgres keeps `snake_case`, junction tables, and `{singular}_id`. |
| Schema Conventions: Primary Keys | Both | Base states one stable primary key per record, opaque to clients, serialized as a string at the API boundary. Postgres keeps `uuid` and `gen_random_uuid()`. |
| Schema Conventions: Timestamps | Both | Base requires creation and update timestamps on every entity, set by the engine and never by the caller. Postgres keeps `timestamptz` and the `set_updated_at` trigger. |
| Schema Conventions: Foreign Keys, Constraints, Array Columns, JSONB Columns, Custom ENUM Types | Postgres | Engine syntax throughout. The base states the one layer rule behind them: a constraint the engine can enforce is enforced by the engine, not only in application code. |
| Indexes | Both | Base requires an index on every reference key and on every field used in a filter, sort, or join, created in the same migration as the collection or table. Postgres keeps `pgm.createIndex` and the auto-generated-name rule. |
| Query Patterns: Connection | Both | Base requires a single pooled connection module, a timeout on every call, and repositories as the only callers. Postgres keeps the `query` and `withTransaction` signatures, at the corrected path. |
| Query Patterns: SQL Formatting, Common Patterns, Dynamic Updates | Postgres | SQL syntax throughout. The base states the layer rule: input never chooses the query's structure. |
| Type Mapping | Both | Base states one engine type maps to one TypeScript type and one Zod schema, defined once, and that where a driver can return two representations the engine file names the one repositories return. Each engine file carries its own table. |
| Access Control | Both | Base keeps the engine-neutral rules: access control in the API layer, owner scope on every query, no direct frontend-to-database connection, the API server as sole client. Postgres restates `No RLS policies` and the `user_id = $N` form. |

### 2. Base file outline

`CLAUDE-DATABASE.md`, in this order. Frontmatter globs are unchanged: the shared globs stay here and nowhere else.

1. Engine Files (dispatch table)
2. Stack (shared)
3. Access Control
4. Migration Discipline
5. Risky Changes (expand and contract)
6. Naming
7. Identity
8. Timestamps
9. Indexes
10. Repository Layer
11. Transactions
12. Type Mapping
13. Observability (R-341 to R-346)
14. Testing Against a Real Database
15. Enforcement

The dispatch table:

| Marker | Engine | Read |
|---|---|---|
| `pg` in `package.json` dependencies | PostgreSQL, TypeScript | `~/.claude/CLAUDE-DATABASE-POSTGRES.md` |
| `mongodb` in `package.json` dependencies, or `migrate-mongo-config.js` in the package root | MongoDB | `~/.claude/CLAUDE-DATABASE-MONGODB.md` |
| `sqlalchemy` in `pyproject.toml` dependencies | PostgreSQL, Python | `~/.claude/CLAUDE-PYTHON.md`, its Migrations, Repository, and Session sections |

The third row exists because a Python project's Postgres restatement is already written, in `CLAUDE-PYTHON.md`, and sending it to a file of `node-pg-migrate` and `pg` syntax would be wrong. A `DATABASE_URL` naming `postgres` is not a marker for either row on its own, since both Python and TypeScript projects set it.

### 3. Engine file outlines

Both engine files carry the same `##` headings, in this order, each opening with a line naming the base file and stating that its rules apply unrestated:

1. Stack
2. Migration Files
3. Schema Conventions
4. Indexes
5. Query Patterns
6. Type Mapping
7. Enforcement

Auto-load globs are disjoint, per finding 1. Postgres takes `**/*.sql` and `**/node-pg-migrate*`; MongoDB takes `**/migrate-mongo-config.*` and `**/migrations/**/*.mongo.js`. The shared `**/migrations/**`, `**/src/database/**`, and `**/src/repositories/**` globs stay on the base file alone, so a repository or migration edit loads the layer rules, and the engine file is reached through the dispatch table or through a glob only that engine's project has.

The Postgres file is today's content redistributed under those headings, with the `###` subsections kept as they are and the two corrections named in Design 4.

The MongoDB file is new, at parity section for section. Casing below assumes the amended R-334.

- **Stack.** MongoDB Atlas hosted, official `mongodb` Node driver, `migrate-mongo` migrations pinned to the driver major this section names, no Mongoose and no other ODM, Zod at the API boundary. Local development runs a single-node replica set in `docker-compose.yml` (R-351), because multi-document transactions and migration sessions are rejected by a standalone `mongod`.
- **Migration Files.** `migrations/` at the package root, `{timestamp}-{description}.js`, `up` and `down` both required, collection creation with its `$jsonSchema` validator and its indexes in one migration, every write inside the migration's session. Validators are created with `validationLevel: "strict"` and `validationAction: "error"`; adding or tightening a validator on a populated collection is a Risky Change under the base file's section 5, with the backfill stage landing before the validator.
- **Schema Conventions.** `camelCase` plural collection names, `camelCase` fields, `ObjectId` `_id` serialized to a hex string at the boundary and validated inbound against a 24-character hex pattern before `new ObjectId()` is called, `createdAt` and `updatedAt` on every document set server-side (`$currentDate` on update, `$currentDate` under `$setOnInsert` for upserts; `new Date()` in repository code is forbidden for both), reference fields as `{singular}Id` holding the referenced `ObjectId`, `$jsonSchema` validators with `bsonType` and `required`, enumerated values as an `enum` in the validator and a Zod enum at the boundary, embedded documents for data owned by exactly one parent and referenced documents otherwise.
- **Indexes.** Every reference field indexed, compound indexes ordered equality then sort then range, unique indexes for natural keys, TTL indexes for expiring data, all declared in the collection's migration.
- **Query Patterns.** One `MongoClient` per process with a timeout on every call, repositories as the only callers, and the base file's structure rule in its Mongo form: every filter value is a Zod-validated scalar or `ObjectId`, and operator keys never come from request input, because an operator object arriving in a request field is this engine's injection vector. Every handler carries the R-406 negative-input test that sends one. Projections on every read that does not need the whole document, `findOneAndUpdate` with `returnDocument: "after"` for update-and-return, multi-document writes inside a session transaction, bulk writes for batches.
- **Type Mapping.** BSON type to TypeScript type to Zod schema, including both directions of the `ObjectId` boundary conversion.
- **Enforcement.** The rule IDs this file's rules carry, and the R-328 note: the guard fires on migrate-mongo files by path and never denies, because `$jsonSchema` has no `default:` key for it to check.

### 4. Additions and corrections

Everything this spec adds beyond moving text, exhaustively. Nothing else changes.

Added layer rules, new statements in the base file, none of which contradict a rule in the current file:

1. Risky Changes (expand and contract), section 5. The target of the dangling `CLAUDE-PYTHON.md:705` citation: a change that renames or drops a field or column, moves data between entities, changes a reference key, or tightens a constraint on populated data is staged as add, backfill, dual-write, switch reads, drop, each stage its own migration and its own deploy, and no stage assuming the previous one has finished deploying.
2. A timeout on every database call (Repository Layer). Implied by R-346 for `clients/`; stated here because repositories are not `clients/`.
3. Observability, section 13, citing R-341 to R-346 rather than restating them: every query carries the request ID, every call logs operation, duration, and outcome, and the readiness endpoint checks the database.
4. Testing Against a Real Database, section 14. Already the portfolio's practice in the project `CLAUDE.md`; stated here so it survives outside that file.
5. "Input never chooses the query's structure" as the engine-neutral form of the parameterization rule, because MongoDB has no binding mechanism for the rule's current wording to name.
6. Timestamps are set by the engine, not the caller. The current file's Postgres trigger already does this; the base states the intent so the Mongo restatement has something to satisfy.

Corrections of fact travelling with the move:

1. `src/db/pool/pool.ts` becomes `src/database/pool.ts`. A path that R-311, R-304, the structure gate, and this file's own glob all forbid is a typo against four enforcers, not a rule position. `CLAUDE-BACKEND.md:716` carries the same drift and is out of scope here; it gets its own ticket.
2. The `timestamptz` type-map row keeps both `Date` and `string`, and the base rule is worded to permit it: the engine file names which representation repositories return.

### 5. Wiring

The `add-stack-track` checklist, step by step, for both new files.

- **Step 1, convention file.** Both written, with the disjoint frontmatter of Design 3.
- **Step 2, rules symlink.** Tracked `claude/rules/database-postgres.md` and `claude/rules/database-mongodb.md`.
- **Step 3, detection.** A row per engine file in the Stack detection section of `rules/session-types.md` (the invariants test reads that section and the Framework Files section of `CLAUDE-FRONTEND.md`, and nowhere else), and the engine files named in the stack-detection sentence of `claude/CLAUDE.md`. The Framework Files table in `CLAUDE-FRONTEND.md` is untouched: an engine is not a frontend framework.
- **Step 4, enforcer analogs.** R-328 gains the manifest `note` worded in Design 3. No other manifest rule is keyed on a database path.
- **Step 5, structure gate.** Not applicable, recorded rather than skipped: an engine file introduces no new root trigger and no new directory vocabulary. Both engines use the `database/`, `repositories/`, and `migrations/` directories the gate already knows, and `structure-conventions` already carries them under R-304. The one directory question in scope, `db/` against `database/`, is a correction under Design 4 rather than a new rule.
- **Step 6, repo docs.** `claude/README.md`'s convention-file table gains both files. `claude/enforce/README.md:84` and the header comment of `convention-track-invariants.test.sh:4-5` both describe the test without its track blocks; both are updated in the same commit as the new block (R-332).
- **Step 7, verify.** The three suites, with the new database block.
- **Step 8, ports and manifest.** Both translators run (`codex.mjs` and `cursor.mjs`), then the hash manifest, then `git diff origin/main` before the push.

The six convention-file lists each name the three files where they name one today. `agents/audit-engineering.md` is edited in `claude/` only; `cursor/` and `codex/` are regenerated.

### 6. Enforcement

The database block added to `enforce/tests/convention-track-invariants.test.sh`, in the shape of its Python block:

1. **Heading parity.** Both engine files carry the same `##` heading set in the same order. Mutation case: a heading added to one file alone is rejected, naming that file.
2. **Postgres heading coverage.** The `###` headings of the pinned pre-split copy are hard-coded, and every one is present in `CLAUDE-DATABASE-POSTGRES.md`.
3. **Line coverage.** Every non-blank, non-heading line of the pinned pre-split copy appears in the base file or the Postgres file. Feasible only because Design 3 rewords nothing; the handful of lines the corrections change are listed as expected exceptions in the test, so an unexpected loss fails.
4. **Base neutrality.** Outside the `## Engine Files` section, the base file matches none of the engine-name and engine-syntax patterns: `pgm.`, `SELECT `, `timestamptz`, `jsonb`, `ObjectId`, `$jsonSchema`, `Postgres`, `PostgreSQL`, `Neon`, `Mongo`, `Atlas`, `node-pg-migrate`, `migrate-mongo`.
5. **Base citation.** Each engine file's first paragraph names `CLAUDE-DATABASE.md`.

## Acceptance criteria

B-1. Outside its `## Engine Files` section, `CLAUDE-DATABASE.md` matches none of the engine-name or engine-syntax patterns in Design 6.4. Asserted by the invariants test, not by a one-time grep.
B-2. Every `###` heading of the pinned pre-split copy is present in `CLAUDE-DATABASE-POSTGRES.md`, and every non-blank, non-heading line of that copy appears in the base or the Postgres file, outside the listed correction exceptions.
B-3. `CLAUDE-DATABASE-POSTGRES.md` and `CLAUDE-DATABASE-MONGODB.md` carry identical `##` heading sets in identical order, and a heading added to one alone fails the suite.
B-4. Each engine file's first paragraph names `CLAUDE-DATABASE.md` and states that its rules apply unrestated.
B-5. `**/migrations/**`, `**/src/database/**`, and `**/src/repositories/**` appear in the base file's frontmatter and in neither engine file's.
B-6. `bash claude/enforce/tests/convention-track-invariants.test.sh` prints PASS with no FAIL line, including all five database assertions and the heading-parity mutation case.
B-7. `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh` both pass.
B-8. `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` both pass after `--write`, and `claude/enforce/hook-hashes.txt` matches the tree.
B-9. Within `claude/`, `cursor/`, and `codex/`, excluding `docs/superpowers/specs/` and `docs/audits/`, no list of convention files names `CLAUDE-DATABASE.md` without also naming both engine files.
B-10. `CLAUDE-PYTHON.md:705`'s cited staged process resolves to a real section, and `:8`'s claim points at `CLAUDE-DATABASE-POSTGRES.md`.
B-11. `claude/rulebook/reference.md:390` and `:391` resolve: either to the base file's engine-neutral reference-key rule, or to the Postgres file.
B-12. `ls -l claude/rules/` shows `database-postgres.md` and `database-mongodb.md` resolving to their targets, and both files appear in the `README.md` convention-file table.
B-13. The MongoDB file states, in its Query Patterns section, that operator keys never come from request input, and names the R-406 negative-input test that proves it.
B-14. The MongoDB file sets `updatedAt` and `createdAt` server-side in every example it shows, and forbids `new Date()` for both in repository code.

## Slice and PR breakdown

One PR, after the R-334 amendment PR merges. Slices are review checkpoints inside it. Slices 2 and 3 of the first draft are merged: the invariants test cannot be green with only one engine file present, and ending a slice on a red suite violates R-509.

| Slice | Content | Exit |
|---|---|---|
| 1 | The database block in the invariants test (all five assertions), its mutation case, the `enforce/README.md` line, and the test's own header comment | Block fails naming the missing engine files; the rest of the suite stays green |
| 2 | Base file rewrite, both engine files, both symlinks, both detection rows, `CLAUDE.md`'s detection sentence | Full invariants test passes |
| 3 | The six convention-file lists, the R-328 manifest note, `README.md`, both translator ports, the hash manifest | Both suites pass, both `--check` runs clean |

## Risks

| Risk | Mitigation |
|---|---|
| A Postgres rule is silently dropped while redistributing 336 lines | B-2's line-coverage assertion against the pinned pre-split copy, which a heading diff alone would not catch |
| The base file drifts back toward Postgres as future edits land, because Postgres is the portfolio default | B-1 is a permanent assertion in the invariants test, not a one-time check |
| Both engine files auto-load in every project, making the split cosmetic | B-5 asserts the globs stay disjoint; this was the review's HIGH finding and is the failure mode most likely to recur silently |
| The MongoDB file states something the owner would not choose | The four load-bearing choices (driver, identity, migrations, casing) were asked and answered; no assumption remains unasked |
| The R-334 amendment lands differently than assumed, invalidating the Mongo casing | This spec is blocked on that PR and its casing lines are read against the merged rule before slice 2 starts |
| A stale cursor port ships silently, since no CI check runs either translator | B-8 covers this PR; a CI step running both `--check` is out of scope here and is filed as its own ticket |

## Spec review

Reviewer: Claude subagent (fable). Fallback reason: Codex hit its ChatGPT usage limit (retry at 2026-09-21 02:26); it exits 0 while failing, so the log, not the exit status, is the verdict. 21 findings, all dispositioned below.

| # | Severity | Disposition |
|---|---|---|
| 1 | HIGH | Fixed. Engine globs are disjoint (Design 3); shared globs stay on the base alone; B-5 asserts it. The dispatch table is now described as a reading instruction, and the Auto-load glob term names the distinction. |
| 2 | MEDIUM | Fixed. `reference.md:390` and `:391` added to Current state; the base keeps an engine-neutral reference-key rule so both resolve (B-11). |
| 3 | MEDIUM | Owner decided: camelCase, with R-334 amended first in its own ticket and PR. This spec is blocked on it. |
| 4 | MEDIUM | Fixed. B-2 adds hard-coded `###` headings plus line coverage against the pinned pre-split copy. Heading count corrected to 24. |
| 5 | MEDIUM | Fixed. Design 4 lists all six added layer rules and both corrections; Non-goals reworded to match; the `timestamptz` row keeps both types and the base rule permits it. |
| 6 | MEDIUM | Fixed. Base rule restated as "input never chooses the query's structure"; the Mongo section names the operator-injection vector and the R-406 test (B-13). |
| 7 | MEDIUM | Fixed. `$currentDate` on update and under `$setOnInsert`, `new Date()` forbidden in repository code (B-14). |
| 8 | MEDIUM | Fixed. `validationLevel: "strict"`, `validationAction: "error"`, and validator tightening named as a Risky Change with a backfill stage. |
| 9 | MEDIUM | Fixed. Slices 2 and 3 merged; no slice now ends red. |
| 10 | MEDIUM | Fixed. `cursor.mjs` runs in slice 3 and its `--check` is in B-8. The missing CI check for both translators is filed as its own ticket. |
| 11 | MEDIUM | Fixed. Design 5 walks all eight checklist steps; step 5 is recorded as not applicable with the reason; the enforce README line and the test header are in slice 1. |
| 12 | MEDIUM | Fixed. The neutrality check gains the engine-name pattern and becomes assertion 4 of the test block; `No RLS policies` and `user_id = $N` move to the Postgres restatement. |
| 13 | MEDIUM | Fixed. `src/database/pool.ts` in the move, recorded as a correction in Design 4. The identical `CLAUDE-BACKEND.md:716` drift gets its own ticket. |
| 14 | LOW | Fixed. The claim was wrong and is removed. The hashes match and the check exits 0 in this tree. |
| 15 | LOW | Fixed. B-12 asserts the symlinks resolve and the README table lists both. |
| 16 | LOW | Fixed. B-9 scopes the search to `claude/`, `cursor/`, `codex/`, excluding specs and audits; `CLAUDE-PYTHON.md:8` is retargeted under B-10. |
| 17 | LOW | Fixed. A third dispatch row sends SQLAlchemy projects to `CLAUDE-PYTHON.md`; `DATABASE_URL` is no longer a marker. |
| 18 | LOW | Fixed. Five `chosen over:` entries added; criteria renumbered B-1 to B-14. |
| 19 | LOW | Fixed. The R-328 note now says the guard fires by path and never denies, rather than that no analog exists. |
| 20 | LOW | Fixed. Inbound `ObjectId` validated against a 24-character hex pattern before construction, with the R-406 case. |
| 21 | LOW | Fixed. A single-node replica set in `docker-compose.yml` is named in the Mongo Stack section (R-351). |

Stack and build-versus-buy options, all seven reviewed. Six are "keep current" and were accepted as such: the driver-plus-repositories stance, `migrate-mongo` (with the driver major pinned in the Stack section), shell-based test assertions, the glob-plus-marker dispatch, and the Postgres stack. Two carry a note rather than a change: `ObjectId` embeds a creation timestamp and a per-process counter, so the base file's "opaque to clients" rule is worded as an interface rule and not as a secrecy guarantee; and generating `$jsonSchema` from the Zod schema with `zod-to-json-schema` was declined for now, since `ObjectId` and `Date` fields need hand overrides anyway, to be revisited if a project reaches ten or more collections.
