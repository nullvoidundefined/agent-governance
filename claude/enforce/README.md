# Rule Enforcement

Mechanical, manifest-driven enforcement of the global rules in `~/.claude/CLAUDE.md`, so compliance does not depend on recall. Every mechanizable rule is enforced by a hook or the bundled linter; the irreducibly-judgment rules are checked by an LLM judge at the push boundary.

## Why

Rules that had automation behind them (the em-dash hook, Prettier) never slipped. Rules re-listed from memory per task did. This system gives every mechanizable rule the em-dash property: it fires every time, independent of memory.

## Manifest

`manifest.json` is the single source of enforcement *mapping*. Rule *text* stays in the rule files (one-line norms in `CLAUDE.md`, full Specs in `rulebook/reference.md`) and is never duplicated here. The enforcement guard and the LLM judge read rule text from `rulebook/reference.md`. Each entry:

```json
{ "id": "R-323", "tier": "ast", "enforcer": "eslint:sort-keys", "severity": "error", "autofix": true }
```

## Tiers

| Tier | Enforced by | When | Examples |
|------|-------------|------|----------|
| `regex` | a hook doing cheap path/string checks | per edit (Write/Edit) or per Bash call | R-312, R-306, R-311, R-103 |
| `ast` | the bundled ESLint config (`lint.mjs`) run by `push-eslint-gate.sh` | per push | R-323, R-321, R-319, R-326, R-324, R-303 |
| `llm-judge` | `llm-rule-judge.sh` (a fast model over the diff) | per push | R-315, R-316, R-317, R-322, R-318, R-325, R-320 |
| `advisory` | a non-blocking warning or confirm prompt (reminder, push-time stderr, or `ask`) | per edit or per push | R-310, R-309, R-506, R-513, R-801 |

Per-edit checks must stay cheap (no Node, no network). All heavy work (ESLint, the model call) runs once per push.

## Per-repo config: `.enforce.json`

Some rules are repo-specific. A repo may place an optional `.enforce.json` at its root; the global engine reads it (the push gate `cd`s to the repo root first). It is data, not a hook, so "global hooks only" still holds.

```json
{
  "importZones": [
    { "target": "src/services", "from": "src/handlers", "message": "services must not import handlers (R-303)" }
  ],
  "singleFileFolderExemptions": ["src/services/auth", "src/services/email"]
}
```

- `importZones` (R-303): drives ESLint `import/no-restricted-paths`. Files under `target` may not import from `from`. Paths are relative to the repo root. With no zones, import-direction is not enforced.
- `singleFileFolderExemptions` (R-309): folders that are allowed to hold a single source module (e.g. the portfolio project's intentional single-file service folders, which override R-309 by project convention).

## Push gate scope

The push gates are an **anti-accident layer**, not a hard security boundary. They fire when Claude Code runs `git push` via the Bash tool and intercepts the PreToolUse hook. They are evadable by running git directly in a terminal, using shell aliases, or passing `-c core.hooksPath=/dev/null`. The goal is to catch rule violations committed in the normal Claude Code workflow, not to enforce policy against a determined actor.

**New-branch behaviour:** when a branch has no remote tracking ref and no `@{push}` ref exists, the push gate resolves a merge-base fallback (first existing of `origin/main`, `main`, `origin/master`, `master`). On a first push from a brand-new branch with none of those reachable, the gate fails open (skips the check) to avoid blocking legitimate work.

## Components

- `manifest.json` -- rule id to tier/enforcer mapping.
- `eslint.config.mjs` + `rules/` -- bundled flat config and custom rules.
- `lint.mjs` -- runs the config against any absolute file path via the ESLint Node API (`cwd:/`), so files in any repo are in scope. Invoked by the push gate.
- `eslintOptions.mjs` -- builds the ESLint options shared by `lint.mjs` and `ratchet.mjs`, including the two opt-in rules. Both must activate the identical rule set or the baseline counts violations the push gate never reports.
- `lexicon.json` -- the naming registry backing R-316 and half of R-317.
- `ratchet.mjs` -- full-tree violation baseline (see below).
- `judge-prompt.md` -- instructions for the semantic-rule judge.
- `tests/` -- one fixture test per enforcer; `run-tests.sh` runs them all.
- Hooks live in `~/.claude/hooks/` and are registered in `~/.claude/settings.json`.
- `enforcement-guard-check.sh` verifies at session start that every manifest hook is still registered.

## Adding a rule

1. Add the one-line norm to `~/.claude/CLAUDE.md` and the full Spec block to `~/.claude/rulebook/reference.md`.
2. Add a `manifest.json` entry: pick a tier and name its enforcer.
3. Ship the enforcer (extend an existing hook, add an ESLint rule, or add the rule id to the judge tier) AND a fixture test under `tests/`. A rule with no manifest entry is unenforced and depends on recall.

## Running the tests

```
bash ~/.claude/enforce/tests/run-tests.sh
```

## Repo exemptions

Repos listed by origin remote URL (one per line, exact match) in `exempt-repos.txt` are treated as team codebases where this operator's personal gates do not govern. Matching is by remote URL, so every worktree of a listed repo is covered.

Two hooks honour the list:

- `push-eslint-gate.sh` (added 2026-07-22): the repo's own lint conventions govern instead.
- `audit-signal-check.sh` (added 2026-07-27): repo-wide audit signals are noise in a team codebase, where per-surface commit counts reflect the whole team's work rather than one operator's. Branch-scoped audits stay available on request; only the automatic push-time nudge is suppressed.

`exempt-repos.txt` is deliberately untracked: it holds client-identifying remote URLs and this repo is public (R-106). The hooks that read it are tracked; the list itself is not.

## The observability rules (R-342, R-343, R-344)

Three custom rules under `rules/` plus `no-console` and `no-empty`, active only in the server trees (`apps/server`, `packages/worker`, `server/src`, and any `src/handlers`, `src/repositories`, `src/middleware`, `src/workers`; tests, `bin/`, and `scripts/` exempt). `structured-log-call` reports an interpolated log message and a context object placed after the message (Pino drops it). `analytics-event-name` reports a string or template literal as the event name at `.track(`, `.capture(`, or `trackEvent(`. `no-swallowed-catch` reports an unbound `catch` and a bound error that is never referenced. What each rule does not decide is stated in its header and in the R-34x Spec blocks of `rulebook/reference.md`; R-341, R-345, and R-346 stay manual. Fixture: `tests/observability-rules.test.sh`.

## The test-quality rules (R-401 items 1, 3, 5) and no-cycle (R-303)

Two custom rules under `rules/`, active only in test trees. `no-self-mock` reports a `vi.mock`/`jest.mock`/`.doMock` whose specifier names the module the test file is named for (`score.test.ts` mocking `../services/score`, item 1) and a repository test mocking the pool or anything under `database/` (item 5). `behavior-assertion-required` reports a test whose every `expect()` matcher is a mock-call matcher (`toHaveBeenCalled*`, `toBeCalled*`, item 3); one behavior assertion beside them passes, and a test with no `expect()` is not judged. Items 2, 4, 6, and 7 need the test's intent and stay with the slice critic and the judge. `import-x/no-cycle` runs in every tree with `maxDepth: 8`; it needs the `import-x/parsers`, `import-x/extensions`, and TS-aware `resolver-next` settings in `eslint.config.mjs`, without which it silently reports nothing. The R-344 catch rules now also cover every `src/services` and `src/clients` tree, server or not. Fixture: `tests/test-quality-rules.test.sh`.

## The Dockerization reminder (R-351)

`hooks/dockerfile-reminder.sh` runs after every Write or Edit. When the written file marks a deployable artifact (a server or worker entry file, a `package.json` with a `start` script, a Next or Vite config, or a platform deploy config such as `railway.toml`) it walks from that file's directory to the repo root looking for a `Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, or `Containerfile`, and reminds when none exists or when the one it finds has no `.dockerignore` beside it. When the written file is itself a Dockerfile it reminds on a missing `USER` instruction and on any `FROM` that is untagged or `:latest` (stage aliases and digest pins pass). Advisory only; the compose file, the CI image build, and the platform wiring stay manual. Fixture: `tests/dockerfile-reminder.test.sh`.

## The slice lock (R-410, R-411, R-412)

`hooks/protected-path-guard.sh` runs on every Write, Edit, and Bash call and decides from two inputs. The first is `.claude/tdd-lock.json` at the repo root, written by `enforce/tdd.sh`: phase `open` (a slice is declared, its failing test not yet proven) denies production writes; phases `red` and `green` deny every test-tree write plus the fixture prefixes and spec path the lock lists, so the tests are the contract from `tdd.sh red` to `tdd.sh close`. The second is the `agent_type` field the hook input carries in subagent context, matched against `role-policy.json`: `test-author` writes only test and fixture trees, `implementer` never writes tests, fixtures, specs, or the lock, `slice-critic` writes nothing; an absent or unlisted type carries no role restriction. Independently of both, the gate inputs (`.claude/verify.sh`, `.enforce.json`, `.enforce-baseline.json`, the lock) are never written by a session, and test-runner configs plus the `package.json` test and typecheck scripts ask. Bash is judged by its write targets: redirections, `tee`, and every path operand beside `rm`, `mv`, `cp`, `sed -i`, or `git rm|mv|checkout|restore|clean|stash`. An interpreter writing a file from its own source is not seen here; `tdd.sh green` compares locked-file hashes against the RED commit for that case. Paths outside the repository root are not governed. Fixture: `tests/protected-path-guard.test.sh`.

`tdd.sh` is the evidence half. `tdd.sh open "<slice>" [--spec <path>]` writes the lock in phase `open`. `tdd.sh red <test file>...` runs the whole suite once (Vitest or Jest from the project's `node_modules/.bin`, else the copy bundled here) and accepts only when every test in the named files fails for an assertion or a missing-module reason and no other file fails; a syntax error, a file with no tests, a passing test, or a skipped test is refused with the reason. It records the pass count outside the named files as the baseline and the sha256 of each named file, and moves to `red`. `tdd.sh green` first compares the named files against the lock and, when the lock is committed, against the commit that introduced it (the RED commit), then runs the suite and requires every named test to pass, none skipped, no other failure, and the outside count at or above the baseline; it moves to `green` and is re-run after every refactor. `tdd.sh close` removes the lock only from `green`. pytest, go test, and RSpec are refused until a project on that stack exists. Fixture: `tests/tdd-red-green.test.sh`, which drives the Vitest pinned in `package.json` against a throwaway project.

`role-policy.json` is data: `patterns` are extended regexes over the root-relative path, `roles` map an `agent_type` to an `allow` or `deny` list of pattern names. A new role is a new key.

## The naming lexicon (R-316, R-317)

"Is this a good name" is undecidable. "Is this verb in the lexicon" is set membership. `lexicon.json` is that set, so the check is a pure function of `(AST, config)` and gives the same verdict on every machine and every run.

It decides: the leading word of a named function is an approved verb or a boolean prefix; a noun follows it; the verb is not a banned synonym (the report names the canonical replacement); a function annotated `: boolean` leads with `is`/`has`/`can`/`should`; with a glossary configured, the head noun is a declared domain term. For variables it decides two things only: a collection is named in the plural, and a single-word name is not a bare adjective.

It does not decide whether the lexicon carves the domain well, nor R-318/R-322 (one responsibility), which are undecidable and stay with the judge rather than being faked with a line-count proxy.

`lexicon.json` is the single source. The R-316 verb lists in `rulebook/reference.md` are generated from it by `renderLexiconSpec.mjs` between `<!-- lexicon:begin -->` markers: change the registry, run `node enforce/renderLexiconSpec.mjs --write`, commit both. `lexicon-spec-sync.test.sh` fails the suite if they diverge, and `--check`/`--write` also reject a registry that contradicts itself (a banned verb still bound to a layer by `verbGroups` or `scopeVerbs`).

Opt in per repo, because the vocabulary is the repo's:

```json
{
  "naming": {
    "enabled": true,
    "glossary": ["note", "job", "resume"],
    "extend": { "verbs": ["score", "tailor"] }
  }
}
```

### Synonyms are bound to a layer

Four interchangeable read verbs is a four-way drift surface, so the registry binds each to the R-304/R-305 directory that gives it meaning. The layer is a path predicate, which is what makes "remote" versus "in memory" decidable from the tree instead of from intent:

| Tree | Read verb | Also reserved here |
|---|---|---|
| `clients/`, `api/` | `fetch` | |
| `repositories/`, `database/` | `load` | `insert`, `upsert`, `drop` |
| `config/`, `prompts/` | `load` | |
| everywhere else | `get` | |

`getNote` under `clients/` reports `The read verb here is "fetch", not "get"`; `insertNote` under `services/` reports `Verb "insert" belongs to database/repositories: use "create" here`. `list` stays unrestricted in every layer because it encodes cardinality, not transport. `record`, `persist`, and `remove` are banned outright as bare synonyms of `save`, `save`, and `delete`.

Retarget any of this per repo: `scopeVerbs` maps a directory to the verb its group must use, `defaultVerbs` sets the fallback, `verbGroups` says which verbs form a substitutable set, and `verbScopes` restricts a single verb to named directories with a fallback suggestion.

A top-level list (`verbs`, `bannedVerbs`, `bareAdjectives`, `irregularPlurals`) replaces the shipped one; map-valued fields (`bannedVerbs`, `defaultVerbs`, `scopeVerbs`, `verbGroups`, `verbScopes`) merge key by key, so retargeting one verb does not mean restating the table; `extend` adds to any of them. Omitting `glossary` skips head-noun checking rather than passing it. A repo with no `naming` key gets exactly the behavior it had before the rule existed. Tests, fixtures, mocks, `e2e/`, and `.d.ts` are exempt. PascalCase is skipped, so React components and classes are untouched.

## The ratchet (long-term enforcement)

A diff-scoped gate leaves the untouched majority of a codebase free to drift, and turning a rule on across a legacy tree in one pass is a refactor nobody schedules. `ratchet.mjs` runs every rule over every tracked `.ts`/`.tsx` file, records the count per rule in a committed `.enforce-baseline.json`, and fails when a count RISES. Existing debt is grandfathered; new debt is not; the number only ever descends.

```
node ~/.claude/enforce/ratchet.mjs            # check against the baseline
node ~/.claude/enforce/ratchet.mjs --update   # write or lock in the baseline, then commit it
node ~/.claude/enforce/ratchet.mjs --strict   # also fail on improvements not yet locked in
```

Counts errors only; warnings are advisory and would make the gate fail on advice. The baseline has sorted keys and no timestamp, so a re-run on an unchanged tree is byte-identical: no diff churn, no clock-driven merge conflicts.

Run it as a required status check on the protected branch. A local hook is `--no-verify`-able, which makes it advisory no matter how it is written; determinism needs the check to run where it cannot be skipped.

Known limit, stated rather than hidden: the gate compares per-rule totals, so deleting one violation and adding another under the same rule nets to zero and passes. Per-file keying would catch that and would churn on every rename. Totals are the deliberate trade, and the push gate (`lint.mjs --added-only`) is what catches the newly added line.
