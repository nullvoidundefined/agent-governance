// build-manifest.mjs: codex's manifest builder. Adapts the port map's flat
// hand_authored list into exporter-core's B-9 classifications map, then
// delegates to the shared target-agnostic buildManifest. Kept as its own
// module (rather than inlined into codex.mjs) so codex.mjs's existing call
// site, buildManifest(plannedFiles, portMap), stays valid unchanged.
import { buildManifest as buildManifestFor } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/codex.mjs";

// buildManifest(plannedFiles, portMap) -> { path: ".claude-port.json",
// content }: classifies every planned file "generated" and every
// portMap.hand_authored path "hand-authored-mapped" (codex's port map
// carries no finer B-9 distinction than the flat hand_authored list), then
// hands both to exporter-core's buildManifest.
export function buildManifest(plannedFiles, portMap) {
  const classifications = {};
  for (const file of plannedFiles) classifications[file.path] = "generated";
  for (const handAuthoredPath of portMap.hand_authored) classifications[handAuthoredPath] = "hand-authored-mapped";
  return buildManifestFor(BUILDER_NAME, plannedFiles, classifications);
}
