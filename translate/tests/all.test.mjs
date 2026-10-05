import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repo = path.resolve(fileURLToPath(import.meta.url), "../../..");
const script = path.join(repo, "translate", "all.mjs");

// The real repo is the fixture: copy everything the three builders read or own.
function makeFixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "all-builder-")));
  for (const rel of ["rules", "translate", "codex", "cursor", "claude"]) {
    fs.cpSync(path.join(repo, rel), path.join(root, rel), { recursive: true });
  }
  return root;
}

function run(root, mode) {
  return spawnSync(process.execPath, [script, mode, "--root", root], { encoding: "utf8" });
}

function out(r) {
  return `status=${r.status}\n${r.stdout}${r.stderr}`;
}

function editGlobal(root) {
  fs.appendFileSync(path.join(root, "rules/GLOBAL.md"), "\nan appended line\n");
}

test("--check on the untouched copy exits 0", () => {
  const root = makeFixture();
  const r = run(root, "--check");
  assert.equal(r.status, 0, out(r));
});

test("--check after a rules/GLOBAL.md edit exits 1 with prefixed stale lines from all builders", () => {
  const root = makeFixture();
  editGlobal(root);
  const r = run(root, "--check");
  assert.equal(r.status, 1, out(r));
  assert.match(r.stdout, /^claude\.mjs: stale: CLAUDE\.md$/m, out(r));
  assert.match(r.stdout, /^codex\.mjs: stale: /m, out(r));
  assert.match(r.stdout, /^cursor\.mjs: stale: /m, out(r));
});

test("--write reports regenerated N files, then --check exits 0", () => {
  const root = makeFixture();
  editGlobal(root);
  const w = run(root, "--write");
  assert.equal(w.status, 0, out(w));
  assert.match(w.stdout, /^regenerated [1-9]\d* files$/m, out(w));
  const c = run(root, "--check");
  assert.equal(c.status, 0, out(c));
});

test("an unclosed only: block makes --check exit 2", () => {
  const root = makeFixture();
  fs.appendFileSync(path.join(root, "rules/GLOBAL.md"), "\n<!-- only: codex -->\nnever closed\n");
  const r = run(root, "--check");
  assert.equal(r.status, 2, out(r));
});
