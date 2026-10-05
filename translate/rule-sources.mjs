// rule-sources.mjs: loads the tool-neutral prose rules under rules/ for one
// target (claude, codex, or cursor), with every only: block not naming that
// target already removed (only-blocks.mjs). The one loader every generator
// reads, so the three trees cannot drift in what they consider the source.
//
// Layout read (every file listed is required; the directories may be empty):
//   rules/GLOBAL.md, rules/CLOUD-DEPLOYMENT.md, rules/PROTOCOL.md
//   rules/stacks/<NAME>.md        (claude/CLAUDE-<NAME>.md in the Claude tree)
//   rules/agents/*.md             (frontmatter, then body)
//   rules/skills/<dir>/SKILL.md   (frontmatter, then body) plus support files
//   rules/prompts/*.md
import path from "node:path";
import { loadTextFile, splitFrontmatter } from "./parse-sources.mjs";
import {
  listFilesWithExtension,
  listSkillDirs,
  makeMarkdownSourceLoader,
  makeSkillSourceLoader,
} from "./exporter-core.mjs";
import { selectForTarget } from "./only-blocks.mjs";

const loadMarkdownSource = makeMarkdownSourceLoader(loadTextFile, splitFrontmatter);
const loadSkillSource = makeSkillSourceLoader(loadTextFile, splitFrontmatter);

// relativeTo(rootDir, file): the repo-relative, forward-slash form of file,
// used in error messages and generated headers.
function relativeTo(rootDir, file) {
  return path.relative(rootDir, file).split(path.sep).join("/");
}

// loadRuleSources(rootDir, target) -> { globalText, cloudDeploymentText,
// protocolText, stacks, agents, skills, prompts }. Every text has been
// filtered for target; an agent or skill keeps its rawFrontmatter and has its
// body filtered. Each entry carries `source`, its repo-relative path.
export function loadRuleSources(rootDir, target) {
  const rulesDir = path.join(rootDir, "rules");
  const loadFiltered = (file) => {
    const source = relativeTo(rootDir, file);
    return { file, source, text: selectForTarget(loadTextFile(file), target, source) };
  };
  const filterBody = (entry) => {
    const source = relativeTo(rootDir, entry.file);
    return { ...entry, source, body: selectForTarget(entry.body, target, source) };
  };
  return {
    global: loadFiltered(path.join(rulesDir, "GLOBAL.md")),
    cloudDeployment: loadFiltered(path.join(rulesDir, "CLOUD-DEPLOYMENT.md")),
    protocol: loadFiltered(path.join(rulesDir, "PROTOCOL.md")),
    stacks: listFilesWithExtension(path.join(rulesDir, "stacks"), ".md").map((file) => {
      const name = path.basename(file, ".md");
      return { ...loadFiltered(file), name, legacyName: `CLAUDE-${name}.md` };
    }),
    agents: listFilesWithExtension(path.join(rulesDir, "agents"), ".md").map(loadMarkdownSource).map(filterBody),
    skills: listSkillDirs(path.join(rulesDir, "skills"))
      .map((dir) => ({ ...loadSkillSource(dir), dirName: path.basename(dir) }))
      .map(filterBody),
    prompts: listFilesWithExtension(path.join(rulesDir, "prompts"), ".md").map((file) => ({
      ...loadFiltered(file),
      name: path.basename(file),
    })),
  };
}
