/**
 * Runs the bundled enforcement ESLint config against arbitrary absolute file
 * paths via the ESLint Node API. Setting cwd to "/" makes the flat-config
 * basePath the filesystem root, so files in any repo are in scope without
 * patching the eslint binary. Exits 1 (printing the report) when any
 * error-level rule is violated; exits 0 when clean.
 */
import { ESLint } from "eslint";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const configPath = fileURLToPath(new URL("./eslint.config.mjs", import.meta.url));
const files = process.argv.slice(2).map((arg) => resolve(arg));

if (files.length === 0) process.exit(0);

const eslint = new ESLint({ cwd: "/", overrideConfigFile: configPath });
const results = await eslint.lintFiles(files);
const errorCount = results.reduce((sum, result) => sum + result.errorCount, 0);

if (errorCount > 0) {
  const formatter = await eslint.loadFormatter("stylish");
  process.stdout.write(await formatter.format(results));
  process.exit(1);
}
process.exit(0);
