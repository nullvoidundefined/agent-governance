# Rule Enforcement

Mechanical, manifest-driven enforcement of the global rules in `~/.claude/CLAUDE.md`, so compliance does not depend on recall. Every mechanizable rule is enforced by a hook or the bundled linter; the irreducibly-judgment rules are checked by an LLM judge at the push boundary.

## Why

Rules that had automation behind them (the em-dash hook, Prettier) never slipped. Rules re-listed from memory per task did. This system gives every mechanizable rule the em-dash property: it fires every time, independent of memory.

## Manifest

`manifest.json` is the single source of enforcement *mapping*. Rule *text* stays in `CLAUDE.md` and is never duplicated here. Each entry:

```json
{ "id": "R-323", "tier": "ast", "enforcer": "eslint:sort-keys", "severity": "error", "autofix": true }
```

## Tiers

| Tier | Enforced by | When | Examples |
|------|-------------|------|----------|
| `regex` | a hook doing cheap path/string checks | per edit (Write/Edit) or per Bash call | R-312, R-306, R-311, R-103 |
| `ast` | the bundled ESLint config (`lint.mjs`) run by `push-eslint-gate.sh` | per push | R-323, R-321, R-319, R-326, R-324, R-303 |
| `llm-judge` | `llm-rule-judge.sh` (a fast model over the diff) | per push | R-315, R-316, R-317, R-322, R-318, R-325, R-320 |
| `advisory` | a non-blocking warning or confirm prompt (reminder, push-time stderr, or `ask`) | per edit or per push | R-310, R-309, R-506, R-513 |

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
- `judge-prompt.md` -- instructions for the semantic-rule judge.
- `tests/` -- one fixture test per enforcer; `run-tests.sh` runs them all.
- Hooks live in `~/.claude/hooks/` and are registered in `~/.claude/settings.json`.
- `enforcement-guard-check.sh` verifies at session start that every manifest hook is still registered.

## Adding a rule

1. Add the rule text to `~/.claude/CLAUDE.md` as usual.
2. Add a `manifest.json` entry: pick a tier and name its enforcer.
3. Ship the enforcer (extend an existing hook, add an ESLint rule, or add the rule id to the judge tier) AND a fixture test under `tests/`. A rule with no manifest entry is unenforced and depends on recall.

## Running the tests

```
bash ~/.claude/enforce/tests/run-tests.sh
```
