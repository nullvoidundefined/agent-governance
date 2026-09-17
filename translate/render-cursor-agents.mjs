// render-cursor-agents.mjs: renders claude/agents/*.md to
// cursor/agents/<name>.md and cursor/commands/<name>.md, for agents matching
// the port map's agents_to_subagents list (cursor-shapes-study section 2).
// Agent frontmatter carries name and description verbatim, model pinned to
// "inherit" always (the source's own opus/sonnet routing is dropped: Cursor
// selects the model in its own UI, not per-agent frontmatter), readonly true
// iff the source's tools list has neither Write nor Edit, and no tools
// field at all (Cursor carries no tools-allowlist frontmatter key).
// Commands carry no frontmatter at all: the source's description becomes
// the opening paragraph, followed by the delegate boilerplate naming this
// agent's own subagent. commands/session-start.md and
// commands/session-handoff.md have no claude/agents/ source and so are
// never touched here; they stay hand-authored (port map).
import { renderGeneratedHeaderFor, matchesAgentSkillList } from "./exporter-core.mjs";

const BUILDER_NAME = "translate/cursor.mjs";

// matchesAgentSubagentList(name, patterns): re-exported under the cursor
// vocabulary (subagents, not skills) from exporter-core.mjs's
// matchesAgentSkillList, which already implements the exact glob-suffix
// pattern matching codex's agents_to_skills list uses; cursor's
// agents_to_subagents list needs the identical semantics, so this reuses
// that shared implementation rather than re-deriving it (R-308) and rather
// than importing sideways from a codex-specific module (review I-2).
export function matchesAgentSubagentList(name, patterns) {
  return matchesAgentSkillList(name, patterns);
}

// hasWriteOrEditTool(toolsField): true when the source agent's raw
// frontmatter tools: string (comma-separated, e.g. "Read, Grep, Glob, Bash,
// Write") names Write or Edit as a whole tool token, never a substring
// match against another token.
function hasWriteOrEditTool(toolsField) {
  const tools = (toolsField ?? "").split(",").map((tool) => tool.trim());
  return tools.includes("Write") || tools.includes("Edit");
}

// renderCursorAgent(agent) -> { path: "agents/<name>.md", content }: see
// module header for the frontmatter contract. The GENERATED header follows
// the frontmatter directly, then the source body verbatim (unstripped, so
// the source's own leading blank line before its first heading survives
// into the rendered file, matching render-cursor-skills.mjs's body
// handling).
export function renderCursorAgent(agent) {
  const { name, description, tools } = agent.frontmatter;
  const readonly = !hasWriteOrEditTool(tools);
  const frontmatter = `---\nname: ${name}\ndescription: ${description}\nmodel: inherit\nreadonly: ${readonly}\n---\n`;
  const header = renderGeneratedHeaderFor(BUILDER_NAME, `agents/${name}.md`);
  const content = `${frontmatter}${header}\n${agent.body}`;
  return { path: `agents/${name}.md`, content };
}

// renderCursorCommand(agent) -> { path: "commands/<name>.md", content }: no
// frontmatter (Cursor commands are plain markdown), the GENERATED header as
// line 1, the source's description as the opening paragraph, then the
// delegate boilerplate.
export function renderCursorCommand(agent) {
  const { name, description } = agent.frontmatter;
  const header = renderGeneratedHeaderFor(BUILDER_NAME, `agents/${name}.md`);
  const boilerplate = `Delegate this to the \`${name}\` subagent. If subagents are unavailable in this build, read \`~/.claude/agents/${name}.md\` and carry out that role definition in this conversation, honoring its model-routing and output-discipline sections.`;
  const content = `${header}\n\n${description}\n\n${boilerplate}\n`;
  return { path: `commands/${name}.md`, content };
}
