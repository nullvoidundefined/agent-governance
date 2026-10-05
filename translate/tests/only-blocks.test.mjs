import { test } from "node:test";
import assert from "node:assert/strict";
import { selectForTarget } from "../only-blocks.mjs";
import { SourceError } from "../exporter-core.mjs";

const doc =
  "a\n" +
  "<!-- only: codex -->\ncodex line\n<!-- /only -->\n" +
  "b\n" +
  "<!-- only: claude,cursor -->\nshared line\n<!-- /only -->\n" +
  "c\n";

test("untagged lines are kept for every target", () => {
  for (const target of ["claude", "codex", "cursor"]) {
    const lines = selectForTarget(doc, target, "f.md").split("\n");
    for (const keep of ["a", "b", "c"]) assert.ok(lines.includes(keep), `${target} lost ${keep}`);
  }
});

test("a block is kept only for the targets it names and its tag lines are dropped", () => {
  assert.equal(selectForTarget(doc, "codex", "f.md"), "a\ncodex line\nb\nc\n");
  assert.equal(selectForTarget(doc, "claude", "f.md"), "a\nb\nshared line\nc\n");
  assert.equal(selectForTarget(doc, "cursor", "f.md"), "a\nb\nshared line\nc\n");
});

test("a comma list names several targets and excludes the rest", () => {
  const text = "<!-- only: claude,codex -->\nboth\n<!-- /only -->\n";
  assert.equal(selectForTarget(text, "claude", "f.md"), "both\n");
  assert.equal(selectForTarget(text, "codex", "f.md"), "both\n");
  assert.equal(selectForTarget(text, "cursor", "f.md"), "");
});

test("text with no tags is returned byte-identical, CRLF included", () => {
  const plain = "x\r\ny\n\r\nz";
  for (const target of ["claude", "codex", "cursor"]) {
    assert.equal(selectForTarget(plain, target, "f.md"), plain);
  }
});

test("CRLF tag lines are accepted and the kept content keeps its CRLF", () => {
  const text = "p\r\n<!-- only: codex -->\r\nk\r\n<!-- /only -->\r\nq\r\n";
  assert.equal(selectForTarget(text, "codex", "f.md"), "p\r\nk\r\nq\r\n");
  assert.equal(selectForTarget(text, "claude", "f.md"), "p\r\nq\r\n");
});

test("an unclosed block throws a SourceError naming the file and the opening line", () => {
  assert.throws(
    () => selectForTarget("x\n<!-- only: codex -->\ny\n", "codex", "rules/f.md"),
    (e) => e instanceof SourceError && /rules\/f\.md/.test(e.message) && /line 2/.test(e.message),
  );
});

test("a nested block throws a SourceError naming the file and the inner line", () => {
  const text = "<!-- only: codex -->\n<!-- only: claude -->\n<!-- /only -->\n<!-- /only -->\n";
  assert.throws(
    () => selectForTarget(text, "codex", "rules/f.md"),
    (e) => e instanceof SourceError && /rules\/f\.md/.test(e.message) && /line 2/.test(e.message) && /nested/.test(e.message),
  );
});

test("a stray close throws a SourceError naming the file and line", () => {
  assert.throws(
    () => selectForTarget("ok\n<!-- /only -->\n", "codex", "rules/f.md"),
    (e) => e instanceof SourceError && /rules\/f\.md/.test(e.message) && /line 2/.test(e.message),
  );
});

test("an unknown target in a tag throws a SourceError", () => {
  assert.throws(
    () => selectForTarget("<!-- only: gemini -->\nx\n<!-- /only -->\n", "codex", "f.md"),
    (e) => e instanceof SourceError && /unknown target gemini/.test(e.message) && /line 1/.test(e.message),
  );
});

test("a tag line inside a code fence is still a directive (no fence awareness)", () => {
  const text = "```\n<!-- only: codex -->\nin fence\n<!-- /only -->\n```\n";
  assert.equal(selectForTarget(text, "codex", "f.md"), "```\nin fence\n```\n");
  assert.equal(selectForTarget(text, "claude", "f.md"), "```\n```\n");
  assert.throws(
    () => selectForTarget("```\n<!-- only: codex -->\n```\n", "codex", "f.md"),
    (e) => e instanceof SourceError && /line 2/.test(e.message),
  );
});
