#!/usr/bin/env bash
# PostToolUse(Write) hook: nudge to add a what+why header on new code files.
#
# Per the user's convention (CLAUDE.md rule 13: comment what and why), a new code
# source file should open with a /** ... */ header stating what the file does and
# why. A hook cannot author a good header, so this emits a reminder
# (additionalContext) when a freshly written code file has no leading comment.
# Stays silent for non-code files, tests, type decls, stories, configs, and
# migrations, and for files that already start with a comment. Never blocks.
jq -rc '
  .tool_input as $i
  | ($i.file_path // "") as $p
  | ($i.content // "") as $c
  | if ($p | test("\\.(ts|tsx|js|jsx|mjs|cjs)$"))
       and ($p | test("(\\.test\\.|\\.spec\\.|__tests__|\\.d\\.ts$|\\.stories\\.|\\.config\\.|/migrations/)") | not)
       and (($c | sub("^\\s+";"")) | test("^(//|/\\*)") | not)
    then {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("New file "+$p+" has no file-level header. Per the what+why convention (CLAUDE.md rule 13), add a /** ... */ header at the very top stating what the file does and why, unless it is genuinely self-explanatory (barrel, single-constant, or pure type re-export). No em dashes.")}}
    else empty end
' 2>/dev/null || true
