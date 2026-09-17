// render-cursor-stack-rules.mjs: renders claude/CLAUDE-*.md stack convention
// files (plus the CLOUD-DEPLOYMENT.md no-paths outlier) to cursor/rules/
// <kebab>.mdc, and the structure-conventions skill to
// cursor/rules/structure-conventions.mdc. Cursor-shapes-study Class B
// (globs from the source's own paths: list) and Class D (skill-derived
// description).
import path from "node:path";
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";
import { requireRuleDescription } from "./render-cursor-rules.mjs";

const BUILDER_NAME = "translate/cursor.mjs";

// stackRuleBasename(sourceFile): CLAUDE-BACKEND.md -> backend,
// CLAUDE-FRONTEND-NEXT.md -> frontend-next, CLOUD-DEPLOYMENT.md ->
// cloud-deployment (no CLAUDE- prefix to strip, so it passes through
// lowercased only). sourceFile may be a full path or a bare basename; only
// the basename matters.
export function stackRuleBasename(sourceFile) {
  const base = path.basename(sourceFile, ".md");
  const stripped = base.startsWith("CLAUDE-") ? base.slice("CLAUDE-".length) : base;
  return stripped.toLowerCase();
}

// splitStackFrontmatter(text): stack sources carry an optional YAML
// frontmatter block holding only a paths: list; CLOUD-DEPLOYMENT.md carries
// none at all. Returns { paths, body } with any frontmatter block stripped
// from body. Distinct from parse-sources.mjs's splitFrontmatter, which
// requires a name: field these sources never carry and throws when the
// block is absent instead of tolerating it.
export function splitStackFrontmatter(text) {
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (!match) return { paths: [], body: text };
  const paths = [...match[1].matchAll(/^\s*-\s*"(.*)"\s*$/gm)].map((m) => m[1]);
  return { paths, body: text.slice(match[0].length) };
}

// renderStackRule(stackFile, portMap) -> { path: "rules/<kebab>.mdc",
// content }: stackFile is { file, text } where file names the claude/
// source (CLAUDE-BACKEND.md, CLOUD-DEPLOYMENT.md, ...), full path or bare
// basename either way. description comes from the port map's
// rule_descriptions, keyed by the rendered .mdc filename, and fails fast
// via requireRuleDescription (imported from render-cursor-rules.mjs, R-308:
// reuse rather than re-deriving the same guard) when a CLAUDE-*.md source
// has no matching entry, since this class's filenames are driven by
// whatever stack sources happen to exist under claude/ (review I-1: this
// used to read the map unguarded and could render the literal string
// "undefined" into the frontmatter). globs is the source's own paths:
// list, comma-joined (empty when the source carries no paths:, e.g.
// CLOUD-DEPLOYMENT.md); alwaysApply is always false for this class. The
// GENERATED header follows the .mdc frontmatter directly (no blank line
// between), then a blank line, then the source body verbatim with its own
// frontmatter block stripped.
export function renderStackRule(stackFile, portMap) {
  const sourceBasename = path.basename(stackFile.file);
  const mdcName = `${stackRuleBasename(sourceBasename)}.mdc`;
  const description = requireRuleDescription(mdcName, portMap);
  const { paths, body } = splitStackFrontmatter(stackFile.text);
  const globs = paths.join(",");
  const frontmatter = `---\ndescription: ${description}\nglobs:${globs ? ` ${globs}` : ""}\nalwaysApply: false\n---\n`;
  const content = `${frontmatter}${renderGeneratedHeaderFor(BUILDER_NAME, sourceBasename)}\n\n${body.trimStart()}`;
  return { path: `rules/${mdcName}`, content };
}

// renderSkillRule(skill) -> { path: "rules/structure-conventions.mdc",
// content }: description is copied verbatim from the skill's own
// frontmatter (not the port map's rule_descriptions), globs is always
// empty and alwaysApply always false for this class. Body verbatim, the
// skill's own frontmatter already stripped by splitFrontmatter upstream.
export function renderSkillRule(skill) {
  const { name, description } = skill.frontmatter;
  const frontmatter = `---\ndescription: ${description}\nglobs:\nalwaysApply: false\n---\n`;
  const content = `${frontmatter}${renderGeneratedHeaderFor(BUILDER_NAME, `skills/${name}/SKILL.md`)}\n\n${skill.body.trimStart()}`;
  return { path: "rules/structure-conventions.mdc", content };
}
