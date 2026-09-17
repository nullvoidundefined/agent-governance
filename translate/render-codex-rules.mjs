// render-codex-rules.mjs: renders claude/CLAUDE.md plus
// claude/rules/session-types.md as codex/AGENTS.md. Every [hook:X] enforcer
// tag whose hook has no Codex event (spec B-1) gains the
// "in Claude Code; manual in Codex" suffix, so the rule reads as
// recall-dependent there instead of implying mechanical enforcement.
import { renderGeneratedHeader, isHookPorted } from "./parse-sources.mjs";

// Verbatim from the production codex/AGENTS.md preamble (lines 1-3 and the
// line 7 paragraph): stable prose the port map does not vary.
const PREAMBLE_INTRO =
  "This is the Claude Code `CLAUDE.md` rendered for Codex. `~/.claude/` is the canonical home of everything it references; every path below resolves there.";
const HOOK_FIRING_SENTENCE =
  "Under Codex the hooks fire through `~/.codex/hooks.json` (generated from `settings.json`; `~/.codex/hooks/codex-hook-adapter.sh` replays each `apply_patch` as the file edits the gates read and translates the ask decision); a tag reading `hook:X in Claude Code; manual in Codex` names a hook with no Codex event, so that rule depends on recall here.";
const PREAMBLE = `${PREAMBLE_INTRO} ${HOOK_FIRING_SENTENCE}`;

// rewriteEnforcerTags(line, settingsHooks, portMap): rewrites every
// hook:<name> token on the line independently, so an enforcer tag holding
// several comma-separated tokens rewrites only the unported ones. Ported
// hooks, and any other token shape (eslint:*, judge, manual, ruff:*,
// golangci:*), pass through untouched.
export function rewriteEnforcerTags(line, settingsHooks, portMap) {
  return line.replace(/hook:([a-z0-9-]+)/g, (whole, hookName) =>
    isHookPorted(hookName, settingsHooks, portMap) ? whole : `hook:${hookName} in Claude Code; manual in Codex`);
}

// renderRulesDoc(claudeMdText, sessionTypesText, settingsHooks, portMap):
// the generated header, the preamble, the tag-rewritten CLAUDE.md body, and
// the session-types content appended verbatim (session-types.md carries no
// enforcer tags, so it never needs rewriting).
export function renderRulesDoc(claudeMdText, sessionTypesText, settingsHooks, portMap) {
  const rewritten = claudeMdText
    .split("\n")
    .map((line) => rewriteEnforcerTags(line, settingsHooks, portMap))
    .join("\n");
  const content = `${renderGeneratedHeader("CLAUDE.md and rules/session-types.md")}\n\n${PREAMBLE}\n\n${rewritten}\n\n${sessionTypesText}`;
  return { path: "AGENTS.md", content };
}
