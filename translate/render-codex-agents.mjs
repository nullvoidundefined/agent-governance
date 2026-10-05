// render-codex-agents.mjs: renders rules/agents/*.md to codex/agents/*.toml.
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/codex.mjs";

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
