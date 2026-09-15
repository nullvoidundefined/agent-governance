---
name: structure-conventions
description: The stack-specific structural and syntax rules (R-304, R-305, R-309 to R-314, R-319, R-321, R-323, R-324, R-326 to R-329, R-407). Use before creating, moving, splitting, or renaming a directory, module, migration, or test tree in a TypeScript server or web client, before writing a pg migration default, and when planning a package layout. Each rule here is also enforced mechanically at the tool call, so this skill is the pre-emptive read, not the backstop.
---

# Structure Conventions

The conditional half of the R-3xx block, moved out of the always-loaded
`CLAUDE.md` on 2026-09-04. Every rule below has a hook or an ESLint rule that
fires on the file when it is written, so forgetting one costs a blocked tool
call rather than a shipped mistake. Reading this first turns that block into a
non-event.

Full Spec, Scope, and Enforcement for each: `~/.claude/rulebook/reference.md`.

## Directory vocabulary

R-304: Use the fixed top-level vocabulary in the Express server's `src/` (`config`, `constants`, `types`, `schemas`, `middleware`, `routes`, `handlers`, `services`, `repositories`, `clients`, `database`, `dependencyInjection`, `prompts`, `workers`); extra dirs only for a real domain responsibility; the root holds directories, not loose modules (entry point and `.d.ts` excepted). [hook:structure-gate]
R-305: Use the fixed vocabulary in the web client's `src/` (`app`, `components`, `features`, `services`, `api`, `clients`, `state`, `config`, `constants`, `data`, `styles`); context providers live in `state/`; one component per folder (`components/Header/Header.tsx`). [hook:structure-gate]
R-311: Full-word directory names, never abbreviations: `database/` not `db/`. [hook:structure-gate]
R-312: Multi-word directories are camelCase in every source tree; exceptions: Next.js URL route segments keep kebab-case, Python and Ruby trees use snake_case, Go is waived (lowercase packages, kebab cmd/ binaries). [hook:structure-gate]

## Directory shape

R-309: Collapse any domain folder holding exactly one source module into a flat file; a folder needs 2+ sibling source files. [hook:single-file-folder-gate]
R-310: Regroup any source directory past 20 sibling source modules into domain subfolders (count excludes `__tests__/`, barrels, sibling `constants.ts`/`types.ts`). [hook:flat-directory-reminder]

## Test placement

R-313: Test files live in a conventional sibling test directory (`__tests__/` TS, `tests/` py, `spec/` rb), never co-located beside source; exception: Go co-locates `*_test.go` (toolchain requirement). [hook:structure-gate]
R-314 [ts]: One top-level `__tests__/` tree per package's `src/`, mirroring the source layout; fixtures in a sibling `src/__fixtures__/`. [hook:structure-gate]
R-407 [ts]: Add a build-smoke test asserting every runtime-loaded non-code asset exists under `dist/` and `dist/` holds no `.env*` or secret matches. [manual]

## Module and file internals

R-319: Export exactly one public function per module across `services/`, `api/`, and `clients/`; shared helpers and shared state move to their own modules. [eslint:one-export-per-file]
R-321 [ts]: File order: imports, types, `ALL_CAPS` constants, primary export, helpers (caller above callee); in bodies: guards, hooks in fixed order, `const` then `let`, main logic; helpers are `function` declarations. [eslint:member-ordering]
R-323: Sort sibling keys deterministically where order is semantically free (default alphabetical); never reorder where position carries meaning. [eslint:sort-keys]
R-324: Extract every meaningful literal to a named constant; exempt `0`, `1`, `-1`, `''`, booleans, and test/fixture literals. [eslint:no-magic-numbers, ruff:PLR2004, golangci:mnd]

## Syntax bans

R-326 [ts]: Never write IIFEs; declare a named `async function` and call it. [eslint:no-restricted-syntax, ruff:E731]
R-327 [ts]: Never nest ternaries. [eslint:no-nested-ternary, rubocop:Style/NestedTernaryOperator]
R-329 [ts]: Never `any` or `@ts-ignore`/`@ts-nocheck`; type the value or narrow `unknown`; `@ts-expect-error` with a description is the only permitted suppression. [eslint:no-explicit-any, eslint:ban-ts-comment, ruff:ANN401, golangci:nolintlint]

## Migrations

R-328 [ts]: Migration defaults: bare strings for constants, `pgm.func()` for SQL expressions, never nested quotes. [hook:migration-defaults-guard]

## What stayed in CLAUDE.md

The R-3xx rules with no mechanical enforcer at the tool call stay always-loaded,
because for those the norm line is what prevents the mistake rather than what
explains the block: R-301, R-302, R-303, R-306, R-307, R-308, R-315, R-316,
  R-317, R-318, R-320, R-322, R-325, and R-330.
