// build-manifest.mjs: renders codex/.claude-port.json, the manifest that
// hashes every generated file so a later --check can detect drift, and
// lists the hand-authored files the port map carries verbatim (those are
// never hashed: a human edits them directly, so their content is expected
// to move independently of the generator).
//
// It also hashes the generator's own modules, under builder_files. The
// enforcement surface's hash manifest (claude/enforce/hook-hashes.txt) cannot
// reach them: sync.sh copies claude/ only, so translate/ never exists beside a
// live install and any entry for it would read as permanent drift there
// (2026-09-17 audit, the integrity-coverage item the extended globs could not
// close). This manifest is the right home instead, because it is the one
// artifact that always sits in the same checkout as the generator, and
// `--check` already runs in CI and at pre-push, so an edit to the translator
// that was never blessed by a `--write` now fails there. The limit is the same
// one hook-hashes.txt has: a `--write` re-blesses whatever the author changed,
// and the committed diff of this file is the review surface.
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Exported: render-codex-gitignore.mjs must name the manifest in the
// allowlist, and the manifest is planned after the gitignore (it hashes it),
// so the path cannot come from the planned list.
export const MANIFEST_PATH = ".claude-port.json";
const BUILDER_NAME = "translate/codex.mjs";

// sha256Hex(content): the manifest's digest format for one generated file's
// content, "sha256:<hex>".
function sha256Hex(content) {
  return `sha256:${createHash("sha256").update(content).digest("hex")}`;
}

// hashBuilderFiles() -> { "translate/<name>.mjs": "sha256:<hex>" }: every
// module of the generator, keyed by repo-relative path and sorted. Resolved
// from this file's own location rather than from the caller's --root, so the
// hashes describe the translator that actually ran, which is also what keeps
// the hermetic fixture's sandbox runs deterministic.
function hashBuilderFiles() {
  const builderDir = path.dirname(fileURLToPath(import.meta.url));
  const names = fs.readdirSync(builderDir).filter((name) => name.endsWith(".mjs")).sort();
  const hashes = {};
  for (const name of names) {
    hashes[`translate/${name}`] = sha256Hex(fs.readFileSync(path.join(builderDir, name)));
  }
  return hashes;
}

// buildManifest(plannedFiles, portMap) -> { path: ".claude-port.json",
// content }: one hash per planned file, keyed by its codex-relative path,
// keys sorted lexicographically so the output is deterministic regardless
// of render order. The manifest cannot hash itself, so it is never in
// plannedFiles when this runs (the caller computes it last, over the
// non-manifest planned list) and never appears in its own files map.
// hand_authored is copied from the port map verbatim, order preserved.
// builder_files hashes the generator itself; see the file header.
export function buildManifest(plannedFiles, portMap) {
  const files = {};
  for (const file of plannedFiles) {
    files[file.path] = sha256Hex(file.content);
  }
  const sorted = {};
  for (const key of Object.keys(files).sort()) sorted[key] = files[key];
  const manifest = {
    builder: BUILDER_NAME,
    builder_files: hashBuilderFiles(),
    files: sorted,
    hand_authored: [...portMap.hand_authored],
  };
  const content = `${JSON.stringify(manifest, null, 2)}\n`;
  return { path: MANIFEST_PATH, content };
}
