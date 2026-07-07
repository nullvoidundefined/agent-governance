#!/usr/bin/env bash
# Test harness for spec-glossary-check.sh (PostToolUse Write backstop, R-330).
#
# A superpowers spec design doc (*-design.md under docs/superpowers/specs/) must
# carry a "## Domain vocabulary" section with at least one "chosen over:" entry.
# Written without it -> reminder; with it -> silent; any other path -> silent.
#
# Run: ~/.claude/hooks/tests/spec-glossary-check.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../spec-glossary-check.sh"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

run_hook() { # path, content
    jq -n --arg p "$1" --arg c "$2" '{tool_input:{file_path:$p, content:$c}}' | bash "$HOOK"
}
nudges() { run_hook "$@" | grep -q 'additionalContext'; }
silent() { [ -z "$(run_hook "$@")" ]; }

SPEC="docs/superpowers/specs/2026-07-07-thing-design.md"

WITH_GLOSSARY="# Thing

## Domain vocabulary

- world - the simulated system state - chosen over: system because it is an ECS standard.
"
HEADING_ONLY="# Thing

## Domain vocabulary

Some prose but no committed entries.
"
NO_GLOSSARY="# Thing

Just a design with no glossary section at all.
"

# Spec doc missing the glossary -> reminder
check "spec without glossary nudges"        nudges "$SPEC" "$NO_GLOSSARY"
# Spec doc with heading but no 'chosen over:' entry -> reminder
check "spec heading without entry nudges"   nudges "$SPEC" "$HEADING_ONLY"
# Spec doc with a complete glossary -> silent
check "spec with glossary silent"           silent "$SPEC" "$WITH_GLOSSARY"
# A non-design markdown under specs/ is not gated -> silent
check "non-design md under specs silent"    silent "docs/superpowers/specs/notes.md" "$NO_GLOSSARY"
# A design doc outside the specs tree is not gated -> silent
check "design md outside specs silent"      silent "docs/other/x-design.md" "$NO_GLOSSARY"
# An ordinary source file -> silent
check "source file silent"                  silent "apps/server/src/services/foo.ts" "export const x = 1;"

exit $fail
