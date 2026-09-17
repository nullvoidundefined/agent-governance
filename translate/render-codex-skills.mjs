// render-codex-skills.mjs: renders claude/skills/<name>/SKILL.md sources to
// codex/skills/<name>/SKILL.md, verbatim except for the GENERATED header
// inserted immediately after the frontmatter's closing "---" line.
import { renderGeneratedHeader } from "./parse-sources.mjs";

export function renderSkillCopy(skill) {
  const { name } = skill.frontmatter;
  const content =
    `---\n${skill.rawFrontmatter}\n---\n${renderGeneratedHeader(`skills/${name}/SKILL.md`)}\n${skill.body}`;
  return { path: `skills/${name}/SKILL.md`, content };
}
