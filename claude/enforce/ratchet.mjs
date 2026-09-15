/**
 * Full-tree violation ratchet. The answer to "how does enforcement hold over
 * years, not one diff": a diff-scoped gate leaves the untouched majority free
 * to drift, and turning a rule on across a legacy codebase all at once is a
 * refactor nobody schedules. This runs every enforcement rule over every
 * tracked source file, records the count per rule in a checked-in baseline, and
 * fails when a count RISES. Existing debt is grandfathered, new debt is not,
 * and the number only ever descends.
 *
 * Usage, from the repo root:
 *   node ~/.claude/enforce/ratchet.mjs            check against the baseline
 *   node ~/.claude/enforce/ratchet.mjs --update   write/lock in the baseline
 *   node ~/.claude/enforce/ratchet.mjs --strict   also fail on unlocked improvements
 *
 * Baseline: .enforce-baseline.json at the repo root, committed. Keys are sorted
 * and no timestamp is written, so the file is a pure function of the tree and a
 * re-run on an unchanged tree produces a byte-identical file (no diff churn,
 * and no merge conflicts from a clock).
 *
 * Counts errors only (severity 2). Warnings are advisory by definition and
 * would make the gate fail on advice.
 *
 * Known limit, stated rather than hidden: the gate compares per-rule totals, so
 * deleting one violation and adding another under the same rule nets to zero
 * and passes. Per-file keying would catch that and would also churn on every
 * rename. Totals are the deliberate trade; the push gate (lint.mjs
 * --added-only) is what catches the newly added line.
 */
import { ESLint } from "eslint";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { buildEslintOptions } from "./eslintOptions.mjs";

const BASELINE_FILENAME = ".enforce-baseline.json";
const SOURCE_EXTENSION_PATTERN = /\.tsx?$/;
const EXCLUDED_PATH_PATTERN = /(^|\/)(node_modules|dist|build|coverage|\.next)(\/|$)/;

const args = process.argv.slice(2);
const shouldUpdate = args.includes("--update");
const isStrict = args.includes("--strict");
const repoRoot = resolve(args.find((arg) => !arg.startsWith("--")) ?? process.cwd());
const baselinePath = join(repoRoot, BASELINE_FILENAME);

/** Tracked .ts/.tsx files, from git so .gitignore is honored for free. */
function collectSourceFiles(root) {
  const listed = execFileSync("git", ["ls-files", "-z", "--", "*.ts", "*.tsx"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return listed
    .split("\0")
    .filter((path) => path !== "" && SOURCE_EXTENSION_PATTERN.test(path))
    .filter((path) => !EXCLUDED_PATH_PATTERN.test(path))
    .sort()
    .map((path) => join(root, path));
}

/** Error counts keyed by rule id, sorted, over the whole tree. */
async function countViolations(files) {
  const eslint = new ESLint(buildEslintOptions(repoRoot));
  const results = await eslint.lintFiles(files);
  const tally = new Map();
  for (const result of results) {
    for (const message of result.messages) {
      if (message.severity !== 2) continue;
      const ruleId = message.ruleId ?? "(parse-error)";
      tally.set(ruleId, (tally.get(ruleId) ?? 0) + 1);
    }
  }
  return Object.fromEntries([...tally].sort(([left], [right]) => left.localeCompare(right)));
}

/** Writes the baseline with sorted keys and a trailing newline. */
function writeBaseline(counts, fileCount) {
  const total = Object.values(counts).reduce((sum, count) => sum + count, 0);
  writeFileSync(baselinePath, `${JSON.stringify({ counts, files: fileCount, total }, null, 2)}\n`);
}

const sourceFiles = collectSourceFiles(repoRoot);
if (sourceFiles.length === 0) {
  console.log("ratchet: no tracked .ts/.tsx files under this root; nothing to baseline.");
  process.exit(0);
}

const currentCounts = await countViolations(sourceFiles);
const currentTotal = Object.values(currentCounts).reduce((sum, count) => sum + count, 0);

if (shouldUpdate) {
  writeBaseline(currentCounts, sourceFiles.length);
  console.log(
    `ratchet: baseline written to ${BASELINE_FILENAME} (${currentTotal} violations across ${sourceFiles.length} files, ${Object.keys(currentCounts).length} rules). Commit it.`,
  );
  process.exit(0);
}

if (!existsSync(baselinePath)) {
  console.error(
    `ratchet: no ${BASELINE_FILENAME} at ${repoRoot}. Run with --update to record the current ${currentTotal} violations as the starting line, then commit it.`,
  );
  process.exit(1);
}

const baselineCounts = JSON.parse(readFileSync(baselinePath, "utf8")).counts ?? {};
const ruleIds = [...new Set([...Object.keys(baselineCounts), ...Object.keys(currentCounts)])].sort();

const regressions = [];
const improvements = [];
for (const ruleId of ruleIds) {
  const before = baselineCounts[ruleId] ?? 0;
  const after = currentCounts[ruleId] ?? 0;
  if (after > before) regressions.push({ after, before, ruleId });
  if (after < before) improvements.push({ after, before, ruleId });
}

for (const { after, before, ruleId } of improvements) {
  console.log(`ratchet: improved  ${ruleId}  ${before} -> ${after}`);
}

if (regressions.length > 0) {
  console.error(`\nratchet: ${regressions.length} rule(s) regressed against ${BASELINE_FILENAME}:\n`);
  for (const { after, before, ruleId } of regressions) {
    console.error(`  ${ruleId}  ${before} -> ${after}  (+${after - before})`);
  }
  console.error(
    "\nFix the new violations. Raising the baseline is not the fix (R-204): --update is for locking in an improvement, never for absorbing a regression.",
  );
  process.exit(1);
}

if (isStrict && improvements.length > 0) {
  console.error(
    `\nratchet --strict: ${improvements.length} rule(s) improved but the baseline still carries the old count. Run --update and commit so the gain cannot be spent later.`,
  );
  process.exit(1);
}

console.log(
  `ratchet: no regressions (${currentTotal} violations across ${sourceFiles.length} files).${improvements.length > 0 ? " Run --update to lock in the improvements above." : ""}`,
);
process.exit(0);
