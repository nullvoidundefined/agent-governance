#!/usr/bin/env bash
# PostToolUse(Write|Edit) hook: nudge toward composed, short functions (R-322).
#
# Reads the written or edited file from disk (PostToolUse runs after the change
# lands, so disk reflects the final content for both Write and Edit) and runs a
# best-effort detector for function bodies over the ~25-line ceiling. When any
# are found it emits a non-blocking reminder (additionalContext) naming them and
# restating the R-322 composition checklist. Silent for clean files and for
# tests, stories, configs, migrations, and type declarations. Never blocks; the
# rule is a smell, not a hard fail, so a heuristic false positive must not gate.
file_path=$(jq -rc '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
    *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.py) : ;;
    *) exit 0 ;;
esac
case "$file_path" in
    *.d.ts | *.test.* | *.spec.* | *__tests__* | *.stories.* | *.config.* | */migrations/* | */tests/* | */test_* | *_test.py | *conftest.py) exit 0 ;;
esac

summary=$(node "$(dirname "$0")/clean-code-scan.mjs" "$file_path" 2>/dev/null) || exit 0
[ -z "$summary" ] && exit 0

jq -nc --arg s "$summary" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Clean-code check (R-322): function bodies over the ~25-line ceiling in "+$s+". The ceiling binds atomic functions (one indivisible piece of work); an orchestrator (a sequence of calls plus control flow, no inline business logic) may be as long as the flow needs. For each: if atomic, extract its steps, branches, or business rules into named verb-noun helpers ordered caller-above-callee; if an orchestrator, no change needed. No em dashes.")}}' 2>/dev/null || true
