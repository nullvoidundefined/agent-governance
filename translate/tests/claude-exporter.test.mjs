import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { renderGeneratedHeaderFor } from "../exporter-core.mjs";

const repo = path.resolve(fileURLToPath(import.meta.url), "../../..");
const script = path.join(repo, "translate", "claude.mjs");
const BUILDER = "translate/claude.mjs";

const GLOBAL_SRC =
  "# Global\n\nkeep me\n<!-- only: codex -->\ncodex only text\n<!-- /only -->\nuntagged paragraph\n";
const GLOBAL_EXPECTED = "# Global\n\nkeep me\nuntagged paragraph\n";
const STACK_SRC = "# Backend\n\nbackend rules\n";
const AGENT_FM = "---\nname: rev\ndescription: d\n---\n";
const AGENT_SRC = `${AGENT_FM}body\n`;
const SKILL_SRC = "---\nname: s1\ndescription: skill one\n---\nskill body\n";
const RUN_SH = "#!/bin/sh\necho hi\n";

function put(root, rel, text, mode) {
  const full = path.join(root, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, text);
  if (mode !== undefined) fs.chmodSync(full, mode);
}

function makeFixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "claude-exp-")));
  put(root, "rules/GLOBAL.md", GLOBAL_SRC);
  put(root, "rules/stacks/BACKEND.md", STACK_SRC);
  put(root, "rules/CLOUD-DEPLOYMENT.md", "# Cloud\n\ncloud text\n");
  put(root, "rules/PROTOCOL.md", "# Protocol\n\nprotocol text\n");
  put(root, "rules/agents/rev.md", AGENT_SRC);
  put(root, "rules/skills/s1/SKILL.md", SKILL_SRC);
  put(root, "rules/skills/s1/scripts/run.sh", RUN_SH, 0o755);
  put(root, "rules/prompts/p.md", "# Prompt\n\nprompt text\n");
  put(root, "claude/hooks/keep.sh", "#!/bin/sh\necho keep\n", 0o755);
  put(root, "claude/settings.json", '{"hooks":{}}\n');
  put(root, "claude/README.md", "# Hand authored readme\n");
  put(root, "translate/claude-port-map.json", '{"hand_authored":[]}\n');
  return root;
}

function run(root, mode) {
  return spawnSync(process.execPath, [script, mode, "--root", root], { encoding: "utf8" });
}

function read(root, rel) {
  return fs.readFileSync(path.join(root, rel), "utf8");
}

function written() {
  const root = makeFixture();
  const r = run(root, "--write");
  assert.equal(r.status, 0, `--write failed: ${r.stdout}${r.stderr}`);
  return root;
}

test("CLAUDE.md has the header on line 1 and GLOBAL.md minus the codex-only block", () => {
  const root = written();
  const out = read(root, "claude/CLAUDE.md");
  const header = renderGeneratedHeaderFor(BUILDER, "rules/GLOBAL.md");
  assert.equal(out.split("\n")[0], header);
  assert.equal(out, `${header}\n${GLOBAL_EXPECTED}`);
  assert.ok(!out.includes("codex only text"));
  assert.ok(!out.includes("only:"));
});

test("CLAUDE-BACKEND.md is generated from rules/stacks/BACKEND.md", () => {
  const root = written();
  const out = read(root, "claude/CLAUDE-BACKEND.md");
  const header = renderGeneratedHeaderFor(BUILDER, "rules/stacks/BACKEND.md");
  assert.equal(out.split("\n")[0], header);
  assert.equal(out, `${header}\n${STACK_SRC}`);
});

test("agent keeps frontmatter first, then the header, then the body", () => {
  const root = written();
  const out = read(root, "claude/agents/rev.md");
  const header = renderGeneratedHeaderFor(BUILDER, "rules/agents/rev.md");
  assert.ok(out.startsWith(AGENT_FM));
  assert.equal(out.slice(AGENT_FM.length).split("\n")[0], header);
  assert.equal(out, `${AGENT_FM}${header}\nbody\n`);
});

test("skill support file is byte-identical with mode 0755", () => {
  const root = written();
  const dest = path.join(root, "claude/skills/s1/scripts/run.sh");
  const src = path.join(root, "rules/skills/s1/scripts/run.sh");
  assert.ok(fs.readFileSync(dest).equals(fs.readFileSync(src)));
  assert.equal(fs.statSync(dest).mode & 0o777, 0o755);
});

test("hand-authored hooks, settings and README are unchanged", () => {
  const root = makeFixture();
  const files = ["claude/hooks/keep.sh", "claude/settings.json", "claude/README.md"];
  const before = files.map((f) => fs.readFileSync(path.join(root, f)));
  const r = run(root, "--write");
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
  files.forEach((f, i) => {
    assert.ok(fs.readFileSync(path.join(root, f)).equals(before[i]), `${f} changed`);
  });
});

test("--write removes a stale generated agent and keeps a headerless root file", () => {
  const root = makeFixture();
  put(root, "claude/agents/old.md",
    `---\nname: old\ndescription: o\n---\n${renderGeneratedHeaderFor(BUILDER, "rules/agents/old.md")}\nold\n`);
  put(root, "claude/NOTES.md", "my notes\n");
  const r = run(root, "--write");
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
  assert.ok(!fs.existsSync(path.join(root, "claude/agents/old.md")));
  assert.equal(read(root, "claude/NOTES.md"), "my notes\n");
});

test("--check exits 0 after --write and 1 with a stale line after a source edit", () => {
  const root = written();
  const ok = run(root, "--check");
  assert.equal(ok.status, 0, `${ok.stdout}${ok.stderr}`);
  fs.appendFileSync(path.join(root, "rules/stacks/BACKEND.md"), "one more line\n");
  const stale = run(root, "--check");
  assert.equal(stale.status, 1, `${stale.stdout}${stale.stderr}`);
  assert.match(stale.stdout, /stale:/);
  assert.match(stale.stdout, /CLAUDE-BACKEND\.md/);
});

test("an unclosed only: block makes --check and --write exit 2 naming file and line", () => {
  const root = makeFixture();
  put(root, "rules/GLOBAL.md", "# Global\n<!-- only: codex -->\nnever closed\n");
  for (const mode of ["--check", "--write"]) {
    const r = run(root, mode);
    assert.equal(r.status, 2, `${mode}: ${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /GLOBAL\.md/);
    assert.match(r.stderr, /line/);
  }
});

// Regression guard (passes on current code): Claude Code path-scoped rules need
// the frontmatter fence on line 1, so the GENERATED header goes after it.
test("a stack source with frontmatter keeps --- on line 1 and puts the header after the block", () => {
  const root = makeFixture();
  const fm = '---\npaths:\n  - "**/*.go"\n---\n';
  put(root, "rules/stacks/X.md", `${fm}body\n`);
  const r = run(root, "--write");
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
  const out = read(root, "claude/CLAUDE-X.md");
  assert.equal(out.split("\n")[0], "---");
  assert.ok(out.startsWith(fm), out);
  const header = renderGeneratedHeaderFor(BUILDER, "rules/stacks/X.md");
  assert.equal(out, `${fm}${header}\nbody\n`);
});

test("orphan sweep keeps hand-authored files and removes only generated ones", () => {
  const root = makeFixture();
  const hdr = renderGeneratedHeaderFor(BUILDER, "rules/agents/old.md");
  put(root, "claude/agents/mine.md", `---\nname: mine\ndescription: m\n---\nhand written\n`);
  put(root, "claude/prompts/notes.md", "my prompt notes\n");
  put(root, "claude/skills/handmade/SKILL.md", "---\nname: handmade\ndescription: h\n---\nmine\n");
  put(root, "claude/skills/handmade/run.sh", "#!/bin/sh\necho mine\n", 0o755);
  put(root, "claude/agents/old.md", `---\nname: old\ndescription: o\n---\n${hdr}\nold\n`);
  put(root, "claude/skills/s1/scripts/old.sh", "#!/bin/sh\necho stale\n", 0o755);
  const chk = run(root, "--check");
  assert.doesNotMatch(chk.stdout, /mine\.md|notes\.md|handmade/, `${chk.stdout}${chk.stderr}`);
  const r = run(root, "--write");
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
  for (const f of ["claude/agents/mine.md", "claude/prompts/notes.md",
    "claude/skills/handmade/SKILL.md", "claude/skills/handmade/run.sh"]) {
    assert.ok(fs.existsSync(path.join(root, f)), `${f} was deleted`);
  }
  assert.ok(!fs.existsSync(path.join(root, "claude/agents/old.md")), "old.md survived");
  assert.ok(!fs.existsSync(path.join(root, "claude/skills/s1/scripts/old.sh")), "old.sh survived");
});
