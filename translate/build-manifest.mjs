// build-manifest.mjs: renders codex/.claude-port.json, the manifest that
// hashes every generated file so a later --check can detect drift, and
// lists the hand-authored files the port map carries verbatim (those are
// never hashed: a human edits them directly, so their content is expected
// to move independently of the generator).
import { createHash } from "node:crypto";

const MANIFEST_PATH = ".claude-port.json";
const BUILDER_NAME = "translate/codex.mjs";

// sha256Hex(content): the manifest's digest format for one generated file's
// content, "sha256:<hex>".
function sha256Hex(content) {
  return `sha256:${createHash("sha256").update(content).digest("hex")}`;
}

// buildManifest(plannedFiles, portMap) -> { path: ".claude-port.json",
// content }: one hash per planned file, keyed by its codex-relative path,
// keys sorted lexicographically so the output is deterministic regardless
// of render order. The manifest cannot hash itself, so it is never in
// plannedFiles when this runs (the caller computes it last, over the
// non-manifest planned list) and never appears in its own files map.
// hand_authored is copied from the port map verbatim, order preserved.
export function buildManifest(plannedFiles, portMap) {
  const files = {};
  for (const file of plannedFiles) {
    files[file.path] = sha256Hex(file.content);
  }
  const sorted = {};
  for (const key of Object.keys(files).sort()) sorted[key] = files[key];
  const manifest = {
    builder: BUILDER_NAME,
    files: sorted,
    hand_authored: [...portMap.hand_authored],
  };
  const content = `${JSON.stringify(manifest, null, 2)}\n`;
  return { path: MANIFEST_PATH, content };
}
