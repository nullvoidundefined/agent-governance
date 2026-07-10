/**
 * Runs the bundled enforcement ESLint config against arbitrary absolute file
 * paths via the ESLint Node API. Setting cwd to "/" makes the flat-config
 * basePath the filesystem root, so files in any repo are in scope without
 * patching the eslint binary. Exits 1 (printing the report) when any
 * error-level rule is violated; exits 0 when clean.
 *
 * When the repo root contains a .enforce.json with an importZones array, the
 * import/no-restricted-paths rule is activated for those zones (R-303). The
 * node resolver with .ts/.tsx extensions resolves TypeScript imports that
 * omit the file extension (e.g. "../handlers/authHandler" -> authHandler.ts).
 */
import { ESLint } from "eslint";
import importPlugin from "eslint-plugin-import";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const configPath = fileURLToPath(new URL("./eslint.config.mjs", import.meta.url));

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

// Read per-repo import zones from .enforce.json (R-303); absent or malformed -> no zones.
const repoRoot = process.cwd();
let importZones = [];
try {
  const enforceConfig = JSON.parse(readFileSync(`${repoRoot}/.enforce.json`, "utf8"));
  if (Array.isArray(enforceConfig.importZones) && enforceConfig.importZones.length > 0) {
    importZones = enforceConfig.importZones.map((zone) => ({
      from: resolve(repoRoot, zone.from),
      message: zone.message,
      target: resolve(repoRoot, zone.target),
    }));
  }
} catch {
  // No .enforce.json present or JSON is malformed; skip import-direction enforcement.
}

const eslintOptions = {
  cwd: "/",
  overrideConfigFile: configPath,
};

if (importZones.length > 0) {
  eslintOptions.overrideConfig = [
    {
      files: ["**/*.ts", "**/*.tsx"],
      plugins: { import: importPlugin },
      rules: {
        "import/no-restricted-paths": ["error", { zones: importZones }],
      },
      settings: {
        "import/resolver": {
          node: { extensions: [".js", ".ts", ".tsx"] },
        },
      },
    },
  ];
}

const eslint = new ESLint(eslintOptions);
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

const errorCount = results.reduce((sum, result) => sum + result.errorCount, 0);

if (errorCount > 0) {
  const formatter = await eslint.loadFormatter("stylish");
  process.stdout.write(await formatter.format(results));
  process.exit(1);
}
process.exit(0);
