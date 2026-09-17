// render-cursor-rules.mjs: renders the three Class A always-on Cursor rule
// files (cursor-shapes-study Class A): claude/CLAUDE.md ->
// rules/000-global-rules.mdc, claude/rules/session-types.md ->
// rules/001-session-types.mdc, claude/global-memory/INDEX.md ->
// rules/002-global-memory-index.mdc. All three share one frontmatter shape
// (a hand-authored description from the port map's rule_descriptions,
// empty globs, alwaysApply: true) since Class A rules load into every
// session regardless of file type. Only 000-global-rules.mdc rewrites
// enforcer tags: session-types.md and the memory index carry none. Design
// ruling carried from the cursor-shapes-study (section 7): fidelity over
// hand-tuned phrasing; the old hand-port's per-rule Cursor rewordings are
// not reproduced here, only the port map's cursor_preamble and
// index_trailing_paragraph are templated prose.
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";
import { isHookPortedForCursor, SourceError } from "./parse-sources.mjs";

const BUILDER_NAME = "translate/cursor.mjs";
const PORT_MAP_PATH = "translate/cursor-port-map.json";

// renderClassAFrontmatter(mdcName, portMap): the frontmatter block shared by
// every Class A rule file: a hand-authored description keyed by the
// rendered .mdc filename, empty globs (Class A rules are never path-
// scoped), alwaysApply always true.
function renderClassAFrontmatter(mdcName, portMap) {
  const description = portMap.rule_descriptions[mdcName];
  return `---\ndescription: ${description}\nglobs:\nalwaysApply: true\n---\n`;
}

// rewriteEnforcerTags(line, settingsHooks, portMap): rewrites every
// hook:<name> token on the line independently, so a bracket holding several
// comma-separated tokens ([hook:alpha-guard, hook:beta-check]) rewrites
// only the unported ones. Ported hooks, and any other token shape
// (eslint:*, judge, manual, ...), pass through untouched. Cursor analog of
// render-codex-rules.mjs's rewriteEnforcerTags, keyed off
// isHookPortedForCursor's per-matcher fan-out instead of codex's flat
// per-event isHookPorted.
export function rewriteEnforcerTags(line, settingsHooks, portMap) {
  return line.replace(/hook:([a-z0-9-]+)/g, (whole, hookName) =>
    isHookPortedForCursor(hookName, settingsHooks, portMap) ? whole : `hook:${hookName} in Claude Code; manual in Cursor`);
}

// renderGlobalRules(claudeMdText, settingsHooks, portMap) -> {
// path: "rules/000-global-rules.mdc", content }: the Class A frontmatter,
// the GENERATED header, the port map's cursor_preamble paragraph, then
// CLAUDE.md's body with every unported hook:<name> tag rewritten to name
// the Cursor gap explicitly.
export function renderGlobalRules(claudeMdText, settingsHooks, portMap) {
  const frontmatter = renderClassAFrontmatter("000-global-rules.mdc", portMap);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "CLAUDE.md");
  const rewritten = claudeMdText
    .split("\n")
    .map((line) => rewriteEnforcerTags(line, settingsHooks, portMap))
    .join("\n");
  const content = `${frontmatter}${header}\n\n${portMap.cursor_preamble}\n\n${rewritten}`;
  return { path: "rules/000-global-rules.mdc", content };
}

// renderSessionTypes(text, portMap) -> {
// path: "rules/001-session-types.mdc", content }: the Class A frontmatter,
// the GENERATED header, then session-types.md's body verbatim. No enforcer
// tags to rewrite: the session-type classification table carries none.
export function renderSessionTypes(text, portMap) {
  const frontmatter = renderClassAFrontmatter("001-session-types.mdc", portMap);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "rules/session-types.md");
  const content = `${frontmatter}${header}\n\n${text}`;
  return { path: "rules/001-session-types.mdc", content };
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

// --- Class C: rulebook fan-out and the reference.md section splitter ---
//
// rulebook-agents.mdc, rulebook-audits.mdc, rulebook-cost.mdc are whole-file
// copies of the matching claude/rulebook/*.md source; rulebook-reference-
// <slug>.mdc is one file per top-level `## ` heading of
// claude/rulebook/reference.md, `### ` subheadings staying nested inside
// their parent section rather than splitting out on their own. Every
// produced file shares one frontmatter shape with Class A/B/D (a
// hand-authored description from the port map's rule_descriptions, empty
// globs, alwaysApply: false) and additionally carries a templated `Source:`
// line naming the claude/ source path and the section it holds, so a rule
// read in isolation under Cursor still says where its full text is
// canonical and that the enforcement lines describe the Claude Code harness
// (the cursor-shapes-study's exact wording, section name interpolated).

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

// renderClassCFrontmatter(description): the frontmatter block shared by
// every Class C rule file: a hand-authored description, empty globs (Class
// C rules are fetched on demand, never path-scoped), alwaysApply always
// false.
function renderClassCFrontmatter(description) {
  return `---\ndescription: ${description}\nglobs:\nalwaysApply: false\n---\n`;
}

// renderSourceLine(sourcePath, sectionName): the templated boilerplate line
// every Class C file carries, naming the claude/ source and the section
// this file holds (the whole file's own title for a whole-file copy, one
// `## ` heading's text for a reference-splitter file).
function renderSourceLine(sourcePath, sectionName) {
  return `Source: \`~/.claude/${sourcePath}\`, section "${sectionName}". Enforcement lines describe the Claude Code harness; the Cursor port status of each hook is in \`~/.cursor/PORT-STATUS.md\`.`;
}

// wholeFileTitle(text, fallback): the section name a whole-file Class C
// copy interpolates into its Source line: the source's own top-level `# `
// heading text, or fallback (the rulebook basename) when the source
// carries no such heading.
function wholeFileTitle(text, fallback) {
  const match = /^# (.+)$/m.exec(text);
  return match ? match[1].trim() : fallback;
}

// rulebookMdcName(sourcePath): claude/rulebook/agents.md -> rulebook-
// agents.mdc, matching cursor-shapes-study Class C's naming for the three
// whole-file copies.
function rulebookMdcName(sourcePath) {
  const base = sourcePath.split("/").pop().replace(/\.md$/, "");
  return `rulebook-${base}.mdc`;
}

// renderRulebookWholeFile(sourcePath, text, portMap) -> { path:
// "rules/rulebook-<name>.mdc", content }: one whole-file copy of a
// claude/rulebook/*.md source (agents.md, audits.md, cost.md), Class C
// frontmatter and Source line, then the source body verbatim.
function renderRulebookWholeFile(sourcePath, text, portMap) {
  const mdcName = rulebookMdcName(sourcePath);
  const description = requireRuleDescription(mdcName, portMap);
  const frontmatter = renderClassCFrontmatter(description);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, sourcePath);
  const sectionName = wholeFileTitle(text, rulebookMdcName(sourcePath).replace(/^rulebook-|\.mdc$/g, ""));
  const sourceLine = renderSourceLine(sourcePath, sectionName);
  const content = `${frontmatter}${header}\n\n${sourceLine}\n\n${text.trimStart()}`;
  return { path: `rules/${mdcName}`, content };
}

// kebabCase(text): lowercases, collapses every run of non-alphanumeric
// characters to one hyphen, trims leading/trailing hyphens. Shared by every
// slug the reference splitter derives from heading text.
function kebabCase(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

// referenceSectionSlug(heading): kebab of a reference.md `## ` heading with
// its rule-range parenthetical, when present, pulled to the front as a
// prefix instead of kebabbed in place: "Session init (R-0xx)" ->
// "r0xx-session-init" (the range moves from a trailing parenthetical to a
// leading token, hyphen dropped, digits kept); "Convention files" (no
// range) -> "convention-files", the plain kebab of the whole heading.
function referenceSectionSlug(heading) {
  const rangeMatch = /\(R-(\d+)xx\)/i.exec(heading);
  const nameOnly = heading.replace(/\s*\(R-\d+xx\)\s*/i, " ").trim();
  const nameSlug = kebabCase(nameOnly);
  return rangeMatch ? `r${rangeMatch[1]}xx-${nameSlug}` : nameSlug;
}

// splitReferenceSections(referenceText) -> [{ heading, body }]: every
// top-level `## ` section of reference.md, `### ` (and deeper) subheadings
// staying folded into their parent section's body rather than starting a
// new one. A line starts a new section only when it is exactly an h2
// (`## `, not `### `): the third character of an h3 line is `#`, not the
// space `startsWith("## ")` requires, so the check tells the two apart
// without a full heading-depth parse. Any preamble text before the first
// `## ` heading (reference.md's own title and intro paragraph) has no
// section to attach to and is dropped, matching the study's "one file per
// top-level ## heading" contract: the preamble is not itself a heading.
function splitReferenceSections(referenceText) {
  const sections = [];
  let current = null;
  for (const line of referenceText.split("\n")) {
    if (line.startsWith("## ")) {
      if (current) sections.push(current);
      current = { heading: line.slice(3).trim(), lines: [line] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  if (current) sections.push(current);
  return sections.map((section) => ({ heading: section.heading, body: section.lines.join("\n") }));
}

// renderReferenceSection(section, portMap) -> { path:
// "rules/rulebook-reference-<slug>.mdc", content }: one reference.md
// top-level section, Class C frontmatter and Source line (section name is
// this section's own heading text, range parenthetical included), then the
// section body verbatim, `## ` heading line through its nested `### `
// subheadings and all, trimmed of trailing blank lines from the split.
function renderReferenceSection(section, portMap) {
  const slug = referenceSectionSlug(section.heading);
  const mdcName = `rulebook-reference-${slug}.mdc`;
  const description = requireRuleDescription(mdcName, portMap);
  const frontmatter = renderClassCFrontmatter(description);
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "rulebook/reference.md");
  const sourceLine = renderSourceLine("rulebook/reference.md", section.heading);
  const content = `${frontmatter}${header}\n\n${sourceLine}\n\n${section.body.trimEnd()}\n`;
  return { path: `rules/${mdcName}`, content };
}

// renderRulebookFiles(rulebookTexts, referenceText, portMap) -> [{ path,
// content }]: the full Class C fan-out. rulebookTexts is [{ file, text }]
// for the three whole-file sources (claude/rulebook/agents.md, audits.md,
// cost.md, in that order); referenceText is claude/rulebook/reference.md's
// full text, split into its top-level sections here.
export function renderRulebookFiles(rulebookTexts, referenceText, portMap) {
  const wholeFiles = rulebookTexts.map(({ file, text }) => renderRulebookWholeFile(file, text, portMap));
  const referenceSections = splitReferenceSections(referenceText).map((section) => renderReferenceSection(section, portMap));
  return [...wholeFiles, ...referenceSections];
}
