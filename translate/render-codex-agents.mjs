// render-codex-agents.mjs: renders claude/agents/*.md to codex/agents/*.toml,
// and the agents the port map's agents_to_skills list names to
// codex/skills/<name>/SKILL.md as well.
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/codex.mjs";

// matchesAgentSkillList now lives in exporter-core.mjs (review I-2: both
// exporters need the identical glob-suffix matching, and cursor's renderer
// used to import it sideways from this codex-specific module). Re-exported
// here, rather than moving codex.mjs's own import, so
// `import { matchesAgentSkillList } from "./render-codex-agents.mjs"` stays
// valid at its existing call site.
export { matchesAgentSkillList } from "./exporter-core.mjs";

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
    `# ${renderGeneratedHeaderFor(BUILDER_NAME, `agents/${name}.md`)}`,
    `name = "${escapeTomlBasicString(name)}"`,
    `description = "${escapeTomlBasicString(description)}"`,
    `developer_instructions = """`,
    escapeTomlBasicString(agent.body.trim()),
    `"""`,
    ``,
  ].join("\n");
  return { path: `agents/${name}.toml`, content };
}

export function renderAgentSkill(agent) {
  const { name, description } = agent.frontmatter;
  const content = `---\nname: ${name}\ndescription: ${description}\n---\n${renderGeneratedHeaderFor(BUILDER_NAME, `agents/${name}.md`)}\n\n${agent.body.trimStart()}`;
  return { path: `skills/${name}/SKILL.md`, content };
}
