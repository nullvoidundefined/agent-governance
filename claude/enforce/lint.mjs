/**
 * Runs the bundled enforcement ESLint config against arbitrary absolute file
 * paths via the ESLint Node API. Setting cwd to "/" makes the flat-config
 * basePath the filesystem root, so files in any repo are in scope without
 * patching the eslint binary. Exits 1 (printing the report) when any
 * error-level rule is violated; exits 0 when clean.
 *
 * The opt-in rules a repo declares in .enforce.json (R-303 import zones,
 * R-316 naming lexicon) are wired by eslintOptions.mjs, shared with ratchet.mjs
 * so the single-file gate and the full-tree baseline enforce the same set.
 */
import { ESLint } from "eslint";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { buildEslintOptions } from "./eslintOptions.mjs";

// --added-only <base>: report only violations on lines the diff base..HEAD ADDS.
// Added 2026-07-10 (Ian-approved reconciliation): the push gate previously linted
// whole files, so pre-existing debt in a barely-touched file denied unrelated
// pushes. Changed-line scoping keeps the no-new-violations guarantee.
let addedOnlyBase = null;
let fileArgs = process.argv.slice(2);
if (fileArgs[0] === "--added-only") {
  addedOnlyBase = fileArgs[1];
  fileArgs = fileArgs.slice(2);
}
const files = fileArgs.map((arg) => resolve(arg));

if (files.length === 0) process.exit(0);

/** Parses `git diff -U0` hunk headers into the set of line ranges added in HEAD. */
function collectAddedLineRanges(base, file, cwd) {
  const diffText = execFileSync("git", ["diff", "-U0", "-M", base, "HEAD", "--", file], {
    cwd,
    encoding: "utf8",
  });
  const ranges = [];
  for (const match of diffText.matchAll(/^@@ [^+]*\+(\d+)(?:,(\d+))? @@/gm)) {
    const start = Number(match[1]);
    const count = match[2] === undefined ? 1 : Number(match[2]);
    if (count > 0) ranges.push([start, start + count - 1]);
  }
  return ranges;
}

/** True when a reported line falls inside any added range. */
function isLineAdded(ranges, line) {
  return ranges.some(([start, end]) => line >= start && line <= end);
}

const repoRoot = process.cwd();
const eslint = new ESLint(buildEslintOptions(repoRoot));
const results = await eslint.lintFiles(files);

if (addedOnlyBase !== null) {
  for (const result of results) {
    const addedRanges = collectAddedLineRanges(addedOnlyBase, result.filePath, repoRoot);
    result.messages = result.messages.filter((message) => isLineAdded(addedRanges, message.line));
    result.errorCount = result.messages.filter((message) => message.severity === 2).length;
    result.warningCount = result.messages.filter((message) => message.severity === 1).length;
    result.fixableErrorCount = 0;
    result.fixableWarningCount = 0;
  }
}

// Local ESLint wins on import ordering. When the repo ships its own ESLint
// config, its opinion is authoritative and is applied automatically by that
// project's own tooling (lint-staged, CI). Enforcing R-321's ordering on top of
// it is unwinnable: the project's `eslint --fix` rewrites the order on every
// commit and this gate rejects the result on every push. Every other enforcement
// rule still applies, including sort-keys and no-magic-numbers, which catch real
// defects that project configs typically ignore.
// Added 2026-07-21 (Ian-approved): "deberiamos siempre optar por el local ESLint".
const LOCAL_ESLINT_CONFIG_NAMES = [
  "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts",
  ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yml", ".eslintrc.yaml",
];
const DEFERRED_TO_LOCAL_ESLINT = new Set(["import/order", "sort-imports", "simple-import-sort/imports"]);

function hasLocalEslintConfig(root) {
  return LOCAL_ESLINT_CONFIG_NAMES.some((name) => existsSync(`${root}/${name}`));
}

if (hasLocalEslintConfig(repoRoot)) {
  for (const result of results) {
    result.messages = result.messages.filter(
      (message) => !DEFERRED_TO_LOCAL_ESLINT.has(message.ruleId),
    );
    result.errorCount = result.messages.filter((message) => message.severity === 2).length;
    result.warningCount = result.messages.filter((message) => message.severity === 1).length;
  }
}

const errorCount = results.reduce((sum, result) => sum + result.errorCount, 0);

if (errorCount > 0) {
  const formatter = await eslint.loadFormatter("stylish");
  process.stdout.write(await formatter.format(results));
  process.exit(1);
}
process.exit(0);
