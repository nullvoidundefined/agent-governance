#!/usr/bin/env bash
# Verifies the 2026-09-06 test-quality and dependency rules:
#   R-401 item 1  no-self-mock: a test that vi.mock()s / jest.mock()s the module it
#                 is named for reports; mocking a sibling dependency passes.
#   R-401 item 5  no-self-mock: a repository test that mocks the database pool reports.
#   R-401 item 3  behavior-assertion-required: a test whose only expect() matchers are
#                 mock-call matchers reports; one behavior assertion beside them passes;
#                 a test with no expect() at all is not judged.
#   R-303         import-x/no-cycle: two modules importing each other report; a plain
#                 dependency passes.
#   R-344         no-swallowed-catch and no-empty now cover services/ and clients/ under
#                 any src/, not only the server trees; no-console stays server-scoped.
set -euo pipefail
E="$HOME/.claude/enforce"
TMP=$(mktemp -d)
mkdir -p "$TMP/src/__tests__/services" "$TMP/src/__tests__/repositories" "$TMP/src/services" "$TMP/src/clients" "$TMP/src/database"

reports() {
  local report
  report=$(node "$E/lint.mjs" "$TMP/$1" 2>&1 || true)
  printf '%s' "$report" | grep -q "$2"
}
passes() { node "$E/lint.mjs" "$TMP/$1" >/dev/null 2>&1; }
show() { node "$E/lint.mjs" "$TMP/$1" 2>&1 || true; }

VI='import { describe, expect, it, vi } from "vitest";'

# R-401 item 1: self-mock.
printf '%s\nvi.mock("../../services/score");\nimport { score } from "../../services/score";\nit("scores", () => { expect(score()).toBe(2); });\n' "$VI" > "$TMP/src/__tests__/services/score.test.ts"
reports src/__tests__/services/score.test.ts "no-self-mock" || { echo "FAIL: mocking the module under test must report (R-401 item 1)"; show src/__tests__/services/score.test.ts; exit 1; }
printf '%s\nvi.mock("../../clients/emailClient");\nimport { score } from "../../services/score";\nit("scores", () => { expect(score()).toBe(2); });\n' "$VI" > "$TMP/src/__tests__/services/scoreDependency.test.ts"
passes src/__tests__/services/scoreDependency.test.ts || { echo "FAIL: mocking a sibling dependency must pass"; show src/__tests__/services/scoreDependency.test.ts; exit 1; }
printf '%s\njest.mock("./rank.js");\nimport { rank } from "./rank";\nit("ranks", () => { expect(rank()).toBe(1); });\n' 'import { expect, it, jest } from "@jest/globals";' > "$TMP/src/__tests__/services/rank.spec.ts"
reports src/__tests__/services/rank.spec.ts "no-self-mock" || { echo "FAIL: jest.mock of the module under test (with extension) must report"; show src/__tests__/services/rank.spec.ts; exit 1; }

# R-401 item 5: repository test mocking the pool.
printf '%s\nvi.mock("../../database/pool");\nimport { getJobById } from "../../repositories/jobsRepository";\nit("loads", async () => { expect(await getJobById("1", "u")).toBeNull(); });\n' "$VI" > "$TMP/src/__tests__/repositories/jobsRepository.test.ts"
reports src/__tests__/repositories/jobsRepository.test.ts "R-401 item 5" || { echo "FAIL: a repository test mocking the pool must report (R-401 item 5)"; show src/__tests__/repositories/jobsRepository.test.ts; exit 1; }
printf '%s\nvi.mock("../../database/pool");\nimport { score } from "../../services/score";\nit("scores", () => { expect(score()).toBe(2); });\n' "$VI" > "$TMP/src/__tests__/services/poolInService.test.ts"
passes src/__tests__/services/poolInService.test.ts || { echo "FAIL: mocking the pool from a non-repository test is not item 5"; show src/__tests__/services/poolInService.test.ts; exit 1; }

# R-401 item 3: mock-call-only assertions.
printf '%s\nimport { notify } from "../../services/notify";\nit("notifies", () => { const send = vi.fn(); notify(send); expect(send).toHaveBeenCalledWith("hi"); expect(send).toHaveBeenCalledTimes(1); });\n' "$VI" > "$TMP/src/__tests__/services/mockOnly.test.ts"
reports src/__tests__/services/mockOnly.test.ts "behavior-assertion-required" || { echo "FAIL: mock-call-only assertions must report (R-401 item 3)"; show src/__tests__/services/mockOnly.test.ts; exit 1; }
printf '%s\nimport { notify } from "../../services/notify";\nit("notifies", () => { const send = vi.fn(); const result = notify(send); expect(send).toHaveBeenCalled(); expect(result).toBe(true); });\n' "$VI" > "$TMP/src/__tests__/services/mixed.test.ts"
passes src/__tests__/services/mixed.test.ts || { echo "FAIL: a behavior assertion beside a mock assertion must pass"; show src/__tests__/services/mixed.test.ts; exit 1; }
printf '%s\nimport { notify } from "../../services/notify";\nit("skips", () => { const send = vi.fn(); notify(send); expect(send).not.toHaveBeenCalled(); });\n' "$VI" > "$TMP/src/__tests__/services/notCalled.test.ts"
reports src/__tests__/services/notCalled.test.ts "behavior-assertion-required" || { echo "FAIL: .not.toHaveBeenCalled() alone is still a mock-only assertion"; show src/__tests__/services/notCalled.test.ts; exit 1; }
printf '%s\nimport { load } from "../../services/load";\nit("resolves", async () => { await expect(load()).resolves.toBe(1); });\ndescribe("group", () => { test("throws", () => { expect(() => load()).toThrow(); }); });\n' "$VI" > "$TMP/src/__tests__/services/behavior.test.ts"
passes src/__tests__/services/behavior.test.ts || { echo "FAIL: resolves/toThrow chains are behavior assertions"; show src/__tests__/services/behavior.test.ts; exit 1; }
printf '%s\nimport { run } from "../../services/run";\nit("runs without throwing", () => { run(); });\n' "$VI" > "$TMP/src/__tests__/services/noExpect.test.ts"
passes src/__tests__/services/noExpect.test.ts || { echo "FAIL: a test with no expect() is not judged by the rule"; show src/__tests__/services/noExpect.test.ts; exit 1; }
# Production files are never in scope for the two test rules.
printf 'declare const vi: { mock: (s: string) => void };\nvi.mock("./score");\nexport function score() { return 1; }\n' > "$TMP/src/services/score.ts"
passes src/services/score.ts || { echo "FAIL: the test-quality rules must not apply outside test trees"; show src/services/score.ts; exit 1; }

# R-303: import cycles.
printf 'import { b } from "./b";\nexport function a() { return b(); }\n' > "$TMP/src/services/a.ts"
printf 'import { a } from "./a";\nexport function b() { return a(); }\n' > "$TMP/src/services/b.ts"
printf 'export function c() { return 1; }\n' > "$TMP/src/services/c.ts"
printf 'import { c } from "./c";\nexport function d() { return c(); }\n' > "$TMP/src/services/d.ts"
reports src/services/a.ts "no-cycle" || { echo "FAIL: a two-module import cycle must report (R-303)"; show src/services/a.ts; exit 1; }
passes src/services/d.ts || { echo "FAIL: a plain dependency must pass no-cycle"; show src/services/d.ts; exit 1; }

# R-344 widened to services/ and clients/ outside a server root; R-342 stays server-scoped.
printf 'export async function fetchNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch {}\n  return "";\n}\n' > "$TMP/src/clients/fetchNote.ts"
reports src/clients/fetchNote.ts "no-empty\|R-344" || { echo "FAIL: an empty catch under src/clients must report (R-344)"; show src/clients/fetchNote.ts; exit 1; }
printf 'export async function getNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch (err) {\n    return "";\n  }\n}\n' > "$TMP/src/services/getNote.ts"
reports src/services/getNote.ts "never used" || { echo "FAIL: an unreferenced catch binding under src/services must report (R-344)"; show src/services/getNote.ts; exit 1; }
printf 'export function logNote() {\n  console.log("x");\n}\n' > "$TMP/src/services/logNote.ts"
passes src/services/logNote.ts || { echo "FAIL: no-console stays scoped to the server trees (R-342)"; show src/services/logNote.ts; exit 1; }

rm -rf "$TMP"
echo "test-quality-rules.test.sh PASS"
