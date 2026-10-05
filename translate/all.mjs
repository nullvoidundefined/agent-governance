#!/usr/bin/env node
// all.mjs: runs every generator (claude.mjs, codex.mjs, cursor.mjs) so one
// command keeps claude/, codex/ and cursor/ in step with rules/. Each
// builder's stdout line is prefixed with its name; the exit code is the worst
// of the three (2 source error, 1 stale, 0 current). --write first counts
// the stale and orphaned files each builder's --check reports, then writes,
// and ends with "regenerated N files".
//
//   node translate/all.mjs --write|--check [--root <repo-dir>]
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BUILDERS = ["claude.mjs", "codex.mjs", "cursor.mjs"];
const USAGE = "usage: node translate/all.mjs --write|--check [--root <repo-dir>]";
const translateDir = path.dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const mode = args.find((arg) => arg === "--write" || arg === "--check");
if (!mode || args.filter((arg) => arg === "--write" || arg === "--check").length !== 1) {
  console.error(`all.mjs: exactly one of --write or --check\n${USAGE}`);
  process.exit(2);
}
const passThrough = args.filter((arg) => arg !== mode);

// runBuilder(builder, builderMode) -> { status, stdout }: the builder's own
// stderr goes straight to ours, so source errors name their file unchanged.
function runBuilder(builder, builderMode) {
  const result = spawnSync(process.execPath, [path.join(translateDir, builder), builderMode, ...passThrough], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
  return { status: result.status ?? 2, stdout: result.stdout ?? "" };
}

function printPrefixed(builder, stdout) {
  for (const line of stdout.split("\n")) if (line) console.log(`${builder}: ${line}`);
}

let worst = 0;
let regenerated = 0;
for (const builder of BUILDERS) {
  const check = runBuilder(builder, "--check");
  if (mode === "--check" || check.status === 2) {
    printPrefixed(builder, check.stdout);
    worst = Math.max(worst, check.status);
    continue;
  }
  regenerated += check.stdout.split("\n").filter((line) => /^(stale|orphaned): /.test(line)).length;
  const write = runBuilder(builder, "--write");
  printPrefixed(builder, write.stdout);
  worst = Math.max(worst, write.status);
}
if (mode === "--write" && worst !== 2) console.log(`regenerated ${regenerated} files`);
process.exit(worst);
