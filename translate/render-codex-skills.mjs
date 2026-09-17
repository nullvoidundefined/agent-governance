// render-codex-skills.mjs: renders claude/skills/<name>/SKILL.md sources to
// codex/skills/<name>/SKILL.md, verbatim except for the GENERATED header
// inserted immediately after the frontmatter's closing "---" line, and every
// other file under the skill directory (scripts/, reference.md) byte for
// byte with its mode, since a script cannot carry an HTML-comment header
// and the skill text references it by the same relative path in every port.
import { renderGeneratedHeader } from "./parse-sources.mjs";

export function renderSkillCopy(skill) {
  const { name } = skill.frontmatter;
  const content =
    `---\n${skill.rawFrontmatter}\n---\n${renderGeneratedHeader(`skills/${name}/SKILL.md`)}\n${skill.body}`;
  return { path: `skills/${name}/SKILL.md`, content };
}

// renderSkillSupportFile(skill, file) -> { path, content, mode }: one file
// bundled beside SKILL.md (file.rel is its path relative to the skill
// directory, forward-slash separated), copied without alteration.
export function renderSkillSupportFile(skill, file) {
  const { name } = skill.frontmatter;
  return { path: `skills/${name}/${file.rel}`, content: file.content, mode: file.mode };
}
