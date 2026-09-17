// render-codex-agents.mjs: renders claude/agents/*.md to codex/agents/*.toml,
// and the agents the port map's agents_to_skills list names to
// codex/skills/<name>/SKILL.md as well.
import { renderGeneratedHeader } from "./parse-sources.mjs";

// escapeTomlBasicString(value): escapes backslashes and double quotes for a
// TOML basic string. Serves both the single-line basic strings (name,
// description) and the multiline basic string ("""..."""; body: below) the
// same way, since TOML's escaping rule is identical for both; newlines and
// tabs stay literal, which TOML allows inside either. Multiline literal
// strings (''') were considered for the body instead, but they never process
// backslash escapes, so they cannot losslessly carry an arbitrary agent
// body: a run of 3+ apostrophes still collides with the closing delimiter,
// and there is no escape sequence to break the collision.
function escapeTomlBasicString(value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export function renderAgentToml(agent) {
  const { name, description } = agent.frontmatter;
  const content = [
    `# ${renderGeneratedHeader(`agents/${name}.md`)}`,
    `name = "${escapeTomlBasicString(name)}"`,
    `description = "${escapeTomlBasicString(description)}"`,
    `developer_instructions = """`,
    escapeTomlBasicString(agent.body.trim()),
    `"""`,
    ``,
  ].join("\n");
  return { path: `agents/${name}.toml`, content };
}

export function matchesAgentSkillList(name, patterns) {
  return patterns.some((p) => (p.endsWith("*") ? name.startsWith(p.slice(0, -1)) : name === p));
}

export function renderAgentSkill(agent) {
  const { name, description } = agent.frontmatter;
  const content = `---\nname: ${name}\ndescription: ${description}\n---\n${renderGeneratedHeader(`agents/${name}.md`)}\n\n${agent.body.trimStart()}`;
  return { path: `skills/${name}/SKILL.md`, content };
}
