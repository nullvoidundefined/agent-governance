// render-cursor-rules.mjs: renders the two Class A always-on Cursor rule
// files: claude/CLAUDE.md -> rules/000-global-rules.mdc and
// claude/global-memory/INDEX.md -> rules/002-global-memory-index.mdc. Both
// share one frontmatter shape (a hand-authored description from the port
// map's rule_descriptions, empty globs, alwaysApply: true).
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";
import { SourceError } from "./parse-sources.mjs";

const BUILDER_NAME = "translate/cursor.mjs";
const PORT_MAP_PATH = "translate/cursor-port-map.json";

// renderClassAFrontmatter(mdcName, portMap): the frontmatter block shared by
// every Class A rule file: a hand-authored description keyed by the
// rendered .mdc filename, empty globs (Class A rules are never path-
// scoped), alwaysApply always true.
function renderClassAFrontmatter(mdcName, portMap) {
  const description = requireRuleDescription(mdcName, portMap);
  return `---\ndescription: ${description}\nglobs:\nalwaysApply: true\n---\n`;
}

// renderGlobalRules(claudeMdText, portMap) -> {
// path: "rules/000-global-rules.mdc", content }: the Class A frontmatter,
// the GENERATED header, the port map's cursor_preamble paragraph, then
// CLAUDE.md's body with every unported hook:<name> tag rewritten to name
// the Cursor gap explicitly.
export function renderGlobalRules(claudeMdText, portMap) {
  const frontmatter = renderClassAFrontmatter("000-global-rules.mdc", portMap);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "CLAUDE.md");
  const content = `${frontmatter}${header}\n\n${portMap.cursor_preamble}\n\n${claudeMdText}`;
  return { path: "rules/000-global-rules.mdc", content };
}

// renderMemoryIndex(indexText, portMap) -> {
// path: "rules/002-global-memory-index.mdc", content }: the Class A
// frontmatter, the GENERATED header, then global-memory/INDEX.md's body
// verbatim, with the port map's index_trailing_paragraph appended as the
// Cursor-specific addendum (sessionStart re-injection, no per-project auto
// memory under Cursor) that the source itself has no way to describe.
export function renderMemoryIndex(indexText, portMap) {
  const frontmatter = renderClassAFrontmatter("002-global-memory-index.mdc", portMap);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "global-memory/INDEX.md");
  const content = `${frontmatter}${header}\n\n${indexText.trimEnd()}\n\n${portMap.index_trailing_paragraph}\n`;
  return { path: "rules/002-global-memory-index.mdc", content };
}

// requireRuleDescription(mdcName, portMap): looks up the hand-authored
// description for a produced .mdc file and fails fast, naming the port map
// file and the missing key, rather than writing a frontmatter block with an
// undefined description or silently dropping the file. loadCursorPortMap's
// presence check only proves the rule_descriptions object exists, not that
// every filename a renderer produces has an entry in it, so any class whose
// filenames are source-driven (Class C's rulebook fan-out here, and Class
// B's stack rules in render-cursor-stack-rules.mjs, which imports this)
// needs its own per-file guard rather than trusting the raw lookup (review
// I-1: Class B originally read rule_descriptions[mdcName] unguarded and
// rendered the literal string "undefined" into the frontmatter).
export function requireRuleDescription(mdcName, portMap) {
  const description = portMap.rule_descriptions[mdcName];
  if (description === undefined) {
    throw new SourceError(PORT_MAP_PATH, `rule_descriptions missing entry for ${mdcName}`);
  }
  return description;
}
