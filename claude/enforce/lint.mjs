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
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const configPath = fileURLToPath(new URL("./eslint.config.mjs", import.meta.url));
const files = process.argv.slice(2).map((arg) => resolve(arg));

if (files.length === 0) process.exit(0);

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
const errorCount = results.reduce((sum, result) => sum + result.errorCount, 0);

if (errorCount > 0) {
  const formatter = await eslint.loadFormatter("stylish");
  process.stdout.write(await formatter.format(results));
  process.exit(1);
}
process.exit(0);
