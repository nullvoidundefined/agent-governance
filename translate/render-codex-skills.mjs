// render-codex-skills.mjs: renders claude/skills/<name>/SKILL.md sources to
// codex/skills/<name>/SKILL.md, verbatim except for the GENERATED header
// inserted immediately after the frontmatter's closing "---" line, and every
// other file under the skill directory (scripts/, reference material) byte
// for byte with its mode. Thin codex-specific wrapper over exporter-core's
// target-agnostic renderSkillCopyFor and renderSkillSupportFileFor, which
// render-cursor-skills.mjs also wraps (R-308: one implementation, not two).
import { renderSkillCopyFor, renderSkillSupportFileFor } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/codex.mjs";

export function renderSkillCopy(skill) {
  return renderSkillCopyFor(BUILDER_NAME, skill);
}

// renderSkillSupportFile(skill, file) -> { path, content, mode }: one file
// bundled beside SKILL.md (file.rel is its path relative to the skill
// directory, forward-slash separated), copied without alteration.
export function renderSkillSupportFile(skill, file) {
  return renderSkillSupportFileFor(skill, file);
}
