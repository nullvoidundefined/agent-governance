// render-cursor-skills.mjs: renders claude/skills/<name>/SKILL.md sources to
// cursor/skills/<name>/SKILL.md, verbatim except for the GENERATED header
// inserted immediately after the frontmatter's closing "---" line
// (cursor-shapes-study section 3: a one-to-one copy of every claude/skills/*
// entry, structure-conventions included alongside its separate Class D
// rules/structure-conventions.mdc rendering). Thin cursor-specific wrapper
// over exporter-core's target-agnostic renderSkillCopyFor, which
// render-codex-skills.mjs also wraps with its own builder name (R-308: one
// insertion implementation, not two).
import { renderSkillCopyFor } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/cursor.mjs";

export function renderCursorSkillCopy(skill) {
  return renderSkillCopyFor(BUILDER_NAME, skill);
}
