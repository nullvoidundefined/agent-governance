# Track contract, convention correctness, new stacks, and release prep

Captured 2026-09-20. Sixteen work items in four workstreams, arising from the
assessment of whether this harness has value as a shared open-source
configuration. Each item carries the canonical field set from
`claude/skills/ticket-lifecycle/SKILL.md` so it can be opened in a tracker
without rewriting.

All sixteen are open in Linear as IAN-202 to IAN-217, in the Agent Governance
project. Linear is authoritative from here; this file is the record of origin and
the reasoning behind each item. Dependencies are carried as Linear blocking
relations as well as being stated below.

## Estimates, re-baselined against history on 2026-09-20

This section originally said the estimates below were the R-906 3-5x division,
labelled a heuristic "because the tracker history that R-906 prefers was
unreachable at capture", with `n` of 2.

That was wrong, and IAN-254 corrected it. The history existed. Two families of
closed tickets in this tracker carry real `actual_minutes` and both clear
R-906's five-sample minimum, so the history path was open the whole time. Every
figure below now carries `(from history, n=N)` or, where the comparable count is
genuinely under five, `(heuristic retained, n=N)` so the number is never mistaken
for evidence it does not have. Each ticket in Linear carries an
`## Estimate basis` section with its comparables table and a component breakdown.

**Family T, convention-track and conventions-document work.** n=7: IAN-159 (43),
IAN-90 (48), IAN-145 (49), IAN-92 (50), IAN-73 (55), IAN-95 (55), IAN-97 (55).
Median 50, 80th percentile 55. The distribution is remarkably tight: those seven
were estimated anywhere from 15 to 90 minutes and every one landed between 43 and
55. IAN-72 is the saga check, delivering two tracks end to end in 228 actual.

**Family H, hook, gate, enforcement and runner work.** n=12: IAN-115 (35),
IAN-119 (39), IAN-174 (65), IAN-116 (69), IAN-99 (76), IAN-100 (94), IAN-175
(130), IAN-137 (150), IAN-156 (170), IAN-152 (195), IAN-94 (327), IAN-141 (519).
Median 112, 80th percentile 190. Wide, with a tail driven by guard work against
an adversarial surface.

Two corrections to the record that the original capture got wrong. IAN-97 and
IAN-73 do carry actuals, 55 each, rather than none. And the premise that these
estimates were uniformly inflated does not survive the comparables: across the
sixteen items re-baselined by IAN-254, nine came down, five went up, and two were
left at the heuristic. Their total moved from 3,125 minutes to 2,930, about 6
percent, while individual items moved by up to 39 percent downward (D2) and 78
percent upward (C0). IAN-205, corrected separately beforehand, is not in those
totals.

Retroactive R-605 backfill tickets (IAN-102 to IAN-113, IAN-226 to IAN-249) are
excluded from both families: they closed with `actual_minutes` deliberately unset
as not attributable, so they price nothing.

## Dependency order

A3 gates the question of whether the conventions layer can honestly be called a
baseline, so it precedes D2. C0 gates every C item. B1's first decision
(add Django, or narrow the Python detection row) changes B1's own tier by an
order of magnitude and should be settled before it is scheduled.

---

## Workstream A: the track contract

The mechanism that lets someone else's stack work without a pull request here.

### A1. Register a local convention track through `.enforce.json`

- **Ticket:** IAN-202
- **Tier:** complex
- **Assist:** llm
- **Model:** opus (schema design plus gate wiring)
- **Estimate:** 195 minutes (from history, n=12)
- **Human estimate:** 180 minutes
- **Repo:** agent-governance
- **Branch:** `feat/local-convention-tracks`
- **State:** backlog
- **Depends on:** none

**Problem.** Adding a stack track today is a nine-step change inside this
repository (`claude/skills/add-stack-track/SKILL.md`): a `claude/CLAUDE-<TRACK>.md`,
a `claude/rules/<track>.md` symlink, a detection row in
`claude/rules/session-types.md`, enforcer analogs with fixtures, a
`structure-gate.sh` block, repo docs, an invariant test, regenerated Codex and
Cursor ports, and a `hook-hashes.txt` update. An adopter whose stack is not one
of the four supported ones has no path except a pull request to a stranger's
repository, and the maintainer has no way to validate conventions for a stack
they do not write.

**Acceptance criteria.**
- A repository can declare a convention track in its own `.enforce.json`, naming
  a local convention file path and the `paths:` globs that auto-load it.
- The declared file auto-loads on a matching path with no change to
  `claude/rules/`, `claude/rules/session-types.md`, or any file in this repository.
- A declared track that names a missing file fails loudly at SessionStart rather
  than loading nothing silently.
- The local track cannot override or disable a safety-floor rule (R-101 to R-108);
  an attempt is denied with the rule id named.
- Fixture tests cover: a valid local track loading, a missing file, a glob that
  matches nothing, and an attempted safety-floor override.
- `claude/skills/add-stack-track/SKILL.md` gains a section stating when to use
  the local mechanism instead of the nine-step in-repo path.

### A2. Drive structure-gate vocabulary from configuration

- **Ticket:** IAN-203
- **Tier:** complex
- **Assist:** llm
- **Model:** opus
- **Estimate:** 150 minutes (from history, n=12)
- **Human estimate:** 150 minutes
- **Repo:** agent-governance
- **Branch:** `feat/structure-gate-vocabulary-config`
- **State:** backlog
- **Depends on:** A1 (shares the config surface)

**Problem.** Step 5 of `add-stack-track` requires editing
`claude/hooks/structure-gate.sh` to add a per-stack conditional block and its
directory vocabulary. Every new stack therefore edits a hook, which changes
`hook-hashes.txt`, which is the file touched by 89 of 282 commits and the largest
single source of the maintenance tax. A locally registered track from A1 cannot
reach this file at all, so A1 without A2 gives adopters conventions with no
structure enforcement behind them.

**Acceptance criteria.**
- The per-stack directory vocabulary moves from conditionals in
  `structure-gate.sh` into data the hook reads.
- A locally registered track (A1) can supply its own vocabulary without editing
  any file in this repository.
- The four existing stacks produce byte-identical deny and allow decisions before
  and after the change, proven by the existing
  `claude/hooks/tests/structure-gate.test.sh` cases passing unmodified.
- Adding a stack's vocabulary no longer changes `hook-hashes.txt`.

### A3. Local override contract for synced rule files

- **Ticket:** IAN-204
- **Tier:** complex
- **Assist:** llm
- **Model:** opus (sync semantics, prior destructive incident in this area)
- **Estimate:** 200 minutes (from history, n=12)
- **Human estimate:** 180 minutes
- **Repo:** agent-governance
- **Branch:** `feat/local-override-contract`
- **State:** backlog
- **Depends on:** none

**Problem.** `sync.sh:161` runs `rsync -a --checksum` from the staging tree into
the live directory with no `--ignore-existing` and no `--backup`. The advertised
protection at `sync.sh:122` (`KEPT:`) applies only to files the repository has
stopped tracking. A live file that is still tracked upstream and was edited by
the person using it is overwritten without notice, and R-003 runs that sync
automatically at SessionStart whenever the live directory differs from the
checkout. An adopter can therefore tune the knobs a rule chose to expose, and
cannot disagree with a rule and keep the disagreement. This is the single fact
that keeps the conventions layer from being callable a baseline.

**Acceptance criteria.**
- An edited live file that is still tracked upstream is either preserved or
  backed up before being replaced, never silently overwritten.
- The person is told, at the sync that does it, which of their edits diverged
  from upstream and where the previous content went.
- A documented mechanism exists for keeping a local edit across syncs
  indefinitely, without disabling the sync.
- The safety floor is exempt from that mechanism: a local edit weakening R-101
  to R-108 is refused rather than preserved.
- Fixtures cover: an unedited tracked file (replaced silently, as today), an
  edited tracked file (preserved or backed up plus reported), a deliberate
  local override (survives two consecutive syncs), and an attempted safety-floor
  override (refused).
- `claude/SETUP.md` and `claude/README.md` describe the contract.

---

## Workstream B: correctness of the tracks already claimed

These fix advice that is currently wrong, not advice that is missing.

### B1. The Python track serves FastAPI conventions to every Django repository

- **Ticket:** IAN-205
- **Tier:** complex (settled 2026-09-20: add Django; the narrow path is rejected)
- **Assist:** llm
- **Model:** opus
- **Estimate:** 180 minutes (from history, n=5)
- **Human estimate:** 240 minutes
- **Repo:** agent-governance
- **Branch:** `feat/python-track-framework-split`
- **State:** backlog
- **Depends on:** a decision on which path to take, before scheduling

**Problem.** `claude/rules/session-types.md:23` fires `CLAUDE-PYTHON.md` on
`pyproject.toml`, `requirements.txt` or `setup.py`, which every Django
repository has. The file is 1000 lines naming FastAPI 18 times, SQLAlchemy 17,
Alembic 13, Pydantic 13 and pytest 11, and naming Django, Flask and Celery zero
times. A Django session therefore loads a thousand lines of confidently
incorrect conventions covering an ORM, a migration system, an app layout and a
settings module that Django does not use. A track that claims a language and
serves the wrong framework's rules is worse than an absent track, because the
absent track fails loudly.

**Acceptance criteria (add path).**
- A Django repository auto-loads Django conventions and does not auto-load the
  SQLAlchemy and Alembic sections.
- The shared Python conventions (naming, testing, typing, structure) stay in one
  file rather than being duplicated per framework.
- The R-304 and R-305 directory vocabulary has a documented Django analog, or a
  stated exemption where Django's layout wins.
- `enforce/tdd.sh` classifies a Django test project.

**Acceptance criteria (narrow path).**
- The detection row names FastAPI rather than Python, so a Django repository
  loads nothing and is told why.
- `claude/SETUP.md`'s stack table matches.

### B2. The Go track is 145 lines and has no TDD runner

- **Ticket:** IAN-206
- **Tier:** complex
- **Assist:** llm
- **Model:** sonnet (well-scoped once the parity target is fixed)
- **Estimate:** 205 minutes (from history, n=7 file half, n=1 runner half)
- **Human estimate:** 180 minutes
- **Repo:** agent-governance
- **Branch:** `feat/go-track-parity`
- **State:** backlog
- **Depends on:** none

**Problem.** `claude/CLAUDE-GO.md` is 145 lines against `CLAUDE-BACKEND.md`'s 818
and `CLAUDE-PYTHON.md`'s 1000, and names no router, no ORM and no toolchain
beyond the golangci push gate. Separately, `claude/ISSUES.md` carries an open P2
from the 2026-09-06 TDD harness assessment: `enforce/tdd.sh` refuses `go test`
projects rather than guessing. The thin file and the refused classifier are the
same gap seen twice, so they should close together.

**Acceptance criteria.**
- `CLAUDE-GO.md` carries every `##` and `###` heading its parity target carries,
  with the track's analog or a one-line reason for the gap.
- Router, data access and test-layout conventions are named rather than implied.
- `enforce/tdd.sh` classifies a `go test` project, with a fixture driving the
  real runner as `tdd-red-green.test.sh` does for Vitest.
- The corresponding `ISSUES.md` P2 line is deleted in the same commit.

### B3. The Ruby track is 170 lines and has no TDD runner

- **Ticket:** IAN-207
- **Tier:** standard
- **Assist:** llm
- **Model:** sonnet
- **Estimate:** 185 minutes (from history, n=7 file half, n=1 runner half)
- **Human estimate:** 120 minutes
- **Repo:** agent-governance
- **Branch:** `feat/ruby-track-parity`
- **State:** backlog
- **Depends on:** none

**Problem.** As B2, for `claude/CLAUDE-RUBY.md` (170 lines, Rails 20, RSpec 5,
Sidekiq 3) and the RSpec half of the same `ISSUES.md` P2.

**Acceptance criteria.** As B2, substituting RSpec for `go test`.

### B4. The TypeScript backend track assumes Express

- **Ticket:** IAN-208
- **Tier:** standard
- **Assist:** llm
- **Model:** sonnet
- **Estimate:** 160 minutes (from history, n=7; prices the covered path, narrow path about 45)
- **Human estimate:** 90 minutes
- **Repo:** agent-governance
- **Branch:** `feat/ts-backend-framework-assumption`
- **State:** backlog
- **Depends on:** none

**Problem.** `CLAUDE-BACKEND.md` names Express 28 times and Fastify, NestJS and
Hono essentially not at all, while detection fires on `package.json` for all of
them. NestJS is the sharp case: it organizes around modules, providers and
controllers, which contradicts the `handlers -> services -> repositories`
layering R-303 enforces through the `no-restricted-paths` ESLint rule. A NestJS
repository today gets layering denials for following its own framework.

**Acceptance criteria.**
- Either the track states its Express assumption explicitly and NestJS
  repositories are detected and told the track does not cover them, or NestJS
  gets its layering analog and R-303's zones accept it.
- Fastify and Hono are named where their idioms differ from Express, or the
  track states that they share Express's shape closely enough.

### B5. ORM conventions are absent while two rules depend on them

- **Ticket:** IAN-209
- **Tier:** standard
- **Assist:** llm
- **Model:** sonnet
- **Estimate:** 145 minutes (from history, n=7)
- **Human estimate:** 120 minutes
- **Repo:** agent-governance
- **Branch:** `feat/orm-conventions`
- **State:** backlog
- **Depends on:** IAN-173 (the database engine split lands first)

**Problem.** `CLAUDE-DATABASE.md` mentions Prisma, Drizzle, TypeORM and Knex once
each across 336 lines, while R-303's repository layer and R-334's
plural-table/singular-model convention both need the ORM's own idioms to be
actionable. The guidance stops exactly where the generated client, the schema
file and the migration tool start.

**Acceptance criteria.**
- Prisma and Drizzle each have a named convention for schema file location,
  generated client placement, migration naming and how R-334's word order maps
  onto that ORM's model naming.
- A generated client directory is exempt from the structure and naming gates,
  with a fixture proving the exemption does not leak to hand-written code.

---

## Workstream C: new language tracks

### C0. Require a push lint gate before a track is accepted

- **Ticket:** IAN-210
- **Tier:** standard
- **Assist:** llm
- **Model:** sonnet
- **Estimate:** 80 minutes (from history, n=12)
- **Human estimate:** 30 minutes
- **Repo:** agent-governance
- **Branch:** `feat/track-requires-push-gate`
- **State:** backlog
- **Depends on:** none

**Problem.** Nothing stops a track shipping as prose with no enforcer. 29 of the
81 rules already carry `[manual]` tags, and a convention file with no mechanical
backing adds to that pile while looking like enforcement. The three existing
language gates (`push-ruff-gate.sh`, `push-rubocop-gate.sh`,
`push-golangci-gate.sh`) are the pattern a new language should match before its
conventions are written.

**Acceptance criteria.**
- `add-stack-track` states the precondition and its rationale.
- The invariant test in step 7 fails a track that has neither a push gate nor a
  recorded R-516 gap note naming why the language has none.

### C1 to C4. Candidate languages

Each is a separate ticket, each tier complex, each 180 human minutes, each on
branch `feat/<language>-track`, each in state `backlog`, and each depending on C0
plus its own lint gate landing first. Ordered by adoption surface per unit of
maintenance:

| Ticket | Language | Marker | Gate | Estimate | Note |
|---|---|---|---|---|---|
| IAN-212 | Rust | `Cargo.toml` | clippy | 195 | Cleanest fit; strong existing conventions culture maps well onto this rule style |
| IAN-213 | Java / Kotlin | `pom.xml`, `build.gradle` | spotless or ktlint | 260 | Largest enterprise surface, heaviest to do properly |
| IAN-214 | C# / .NET | `*.csproj` | `dotnet format` plus Roslyn analyzers | 215 | Roslyn analyzer config and a multi-project solution layout both cost more than clippy's |
| IAN-215 | PHP / Laravel | `composer.json` | Pint plus PHPStan | 195 | Laravel's fixed layout makes the structure-gate vocabulary the most mechanical of the four |

All four are from history, n=7. The flat 240 these previously carried
contradicted the ranking in this very table: the estimates now differ because the
work differs. IAN-213 is the only one that rose, and it rose because it is not one
track: Java and Kotlin are two languages, two build markers, two lint gates and
two source layouts, where the other three are one of each.

**Standing risk on all four.** None of these will be written on real work by the
maintainer, so none gets the validation that produced the roughly 13 commits
tuning rules after contact with real code. Shipping conventions for a language
one does not write reproduces the unmeasured-claim problem the 2026-09-18
criticism audit named, in a new place. A1 is the mitigation: prefer a local
track written by someone who writes that language.

---

## Workstream D: release preparation

### D1. Extract the safety floor and fixture mechanism as the publishable unit

- **Ticket:** IAN-217
- **Tier:** saga
- **Assist:** llm
- **Model:** opus
- **Estimate:** 480 minutes (heuristic retained, n=1)
- **Human estimate:** 480 minutes
- **Repo:** agent-governance
- **Branch:** `feat/publishable-unit`
- **State:** backlog, blocked by IAN-121 and IAN-204 as Linear relations
- **Depends on:** the IAN-121 verdict, due 2026-09-26, and on IAN-204

**Problem.** The assessment concluded that the publishable product is the safety
floor (R-101 to R-108, with a twelve-fix bypass-closing history) plus the
enforcement mechanism (hooks, fixtures, the R-516 manifest discipline, the
three-tool projection), with the 81 rules shipping as an example profile rather
than as the product. Nothing is extracted today.

**Blocked because** IAN-121 decides on 2026-09-26 whether the maintenance tax is
one-time architecture debt or structural. That answer is the first thing a
serious adopter asks and it is not yet known, and publishing the current
copy-based sync design freezes a distribution model already slated for
replacement.

**Acceptance criteria.**
- The safety floor plus fixture harness installs and passes its suite without
  the 81 rules present.
- The rules ship under a profile directory, loaded by opt-in rather than by
  default.
- The README states the per-layer labels from D2.

### D2. Label the three layers explicitly in the documentation

- **Ticket:** IAN-216
- **Tier:** standard
- **Assist:** llm
- **Model:** sonnet
- **Estimate:** 55 minutes (from history, n=7)
- **Human estimate:** 60 minutes
- **Repo:** agent-governance
- **Branch:** `feat/layer-labels`
- **State:** backlog
- **Depends on:** A3 (the conventions layer cannot be labelled a baseline until the override contract exists)

**Problem.** `claude/SETUP.md` currently says the framework is generic, which
overstates the conventions layer and understates the safety floor. The
2026-09-19 maintenance-tax audit already wrote the three-layer model with a
"who decides" column; the documentation does not carry it. The label sets the
adopter's expectation and therefore the maintenance burden that arrives with it.

**Acceptance criteria.**
- README and SETUP state, per layer, which of baseline, starter template and
  example applies, and what is owed at the next version under each.
- The safety floor is labelled baseline, the stack conventions starter template
  (or baseline once A3 lands), and the personal profile example.

### D3. De-hardcode the governance remote id

- **Ticket:** IAN-211
- **Tier:** trivial
- **Assist:** llm
- **Model:** haiku
- **Estimate:** 20 minutes (heuristic retained, n=0)
- **Human estimate:** 15 minutes
- **Repo:** agent-governance
- **Branch:** `fix/repo-identity-configurable`
- **State:** backlog
- **Depends on:** none

**Problem.** `claude/hooks/repo-identity.sh:13` pins
`GOVERNANCE_REMOTE_ID='nullvoidundefined/agent-governance'` as the one definition
of the public governance repository. Every guard keyed on that identity, the
R-106 push guard among them, behaves differently for anyone else, which makes
the push protections untestable on a fork.

**Acceptance criteria.**
- The remote id comes from configuration with the current value as the default.
- A fork gets the same guard behavior once it sets its own id.
- A fixture covers both the default and an overridden id.
