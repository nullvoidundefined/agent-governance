// render-codex-rules.mjs: renders rules/GLOBAL.md (filtered for codex) as
// codex/AGENTS.md: the generated header, a short preamble, then the body unchanged.
import { renderGeneratedHeader } from "./parse-sources.mjs";

const PREAMBLE =
  "This is the Claude Code `CLAUDE.md` rendered for Codex. `~/.claude/` is the canonical home of everything it references; every path below resolves there. Under Codex the hooks fire through `~/.codex/hooks.json` (generated from `settings.json`; `~/.codex/hooks/codex-hook-adapter.sh` replays each `apply_patch` as the file edits the guards read and translates the ask decision).";

// renderRulesDoc(claudeMdText) -> { path, content }
export function renderRulesDoc(claudeMdText) {
  const content = `${renderGeneratedHeader("CLAUDE.md")}\n\n${PREAMBLE}\n\n${claudeMdText}`;
  return { path: "AGENTS.md", content };
}
