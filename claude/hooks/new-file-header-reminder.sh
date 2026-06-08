#!/usr/bin/env bash
# PostToolUse(Write) hook: nudge to add a what+why header on new code files.
#
# Per the what+why convention, a new code source file should open with a
# file-level header stating what the file does and why (a /** ... */ block in
# TypeScript, a module docstring in Python). A hook cannot author a good header,
# so this emits a reminder (additionalContext) when a freshly written code file
# has no leading comment or docstring. Stays silent for non-code files, tests,
# type decls, stories, configs, and migrations, and for files that already start
# with a comment or docstring. Never blocks.
jq -rc '
  .tool_input as $i
  | ($i.file_path // "") as $p
  | ($i.content // "") as $c
  | if ($p | test("\\.(ts|tsx|js|jsx|mjs|cjs|py)$"))
       and ($p | test("(\\.test\\.|\\.spec\\.|__tests__|\\.d\\.ts$|\\.stories\\.|\\.config\\.|/migrations/|/tests/|(^|/)test_|_test\\.py$|conftest\\.py$)") | not)
       and (($c | sub("^\\s+";"")) | test("^(//|/\\*|#|\"|\\x27)") | not)
    then {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("New file "+$p+" has no file-level header. Per the what+why convention, add a header at the very top stating what the file does and why (a /** ... */ block in TypeScript, a module docstring in Python), unless it is genuinely self-explanatory (barrel, single-constant, or pure type re-export). No em dashes.")}}
    else empty end
' 2>/dev/null || true
