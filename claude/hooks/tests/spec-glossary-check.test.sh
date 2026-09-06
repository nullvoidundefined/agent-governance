#!/usr/bin/env bash
# Test harness for spec-glossary-check.sh (PostToolUse Write backstop, R-330).
#
# A superpowers spec design doc (*-design.md under docs/superpowers/specs/) must
# carry "## Domain vocabulary" with a "chosen over:" entry, "## Acceptance
# criteria", and "## Non-goals". Any missing -> one reminder naming each
# missing section; all present -> silent; any other path -> silent.
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
names() { local pattern="$1"; shift; run_hook "$@" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "$pattern"; }
omits() { local pattern="$1"; shift; ! run_hook "$@" | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -q "$pattern"; }
silent() { [ -z "$(run_hook "$@")" ]; }

SPEC="docs/superpowers/specs/2026-07-07-thing-design.md"

COMPLETE="# Thing

## Acceptance criteria

- B-1: the thing scores a job at 2 when the job has two requirements.

## Non-goals

Ranking across users.

## Domain vocabulary

- world - the simulated system state - chosen over: system because it is an ECS standard.
"
GLOSSARY_ONLY="# Thing

## Domain vocabulary

- world - the simulated system state - chosen over: system because it is an ECS standard.
"
HEADING_ONLY="# Thing

## Acceptance criteria

- B-1: something.

## Non-goals

None.

## Domain vocabulary

Some prose but no committed entries.
"
NO_GLOSSARY="# Thing

## Acceptance criteria

- B-1: something.

## Non-goals

None.
"
NOTHING="# Thing

Just a design with no sections at all.
"

check "complete spec silent"                          silent "$SPEC" "$COMPLETE"
check "spec without glossary nudges"                  nudges "$SPEC" "$NO_GLOSSARY"
check "missing glossary is named"                     names 'Domain vocabulary' "$SPEC" "$NO_GLOSSARY"
check "present sections are not named"                omits 'Acceptance criteria' "$SPEC" "$NO_GLOSSARY"
check "glossary heading without entry nudges"         nudges "$SPEC" "$HEADING_ONLY"
check "glossary-only spec names acceptance criteria"  names 'Acceptance criteria' "$SPEC" "$GLOSSARY_ONLY"
check "glossary-only spec names non-goals"            names 'Non-goals' "$SPEC" "$GLOSSARY_ONLY"
check "glossary-only spec does not name the glossary" omits 'Domain vocabulary' "$SPEC" "$GLOSSARY_ONLY"
all_three() { run_hook "$@" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'Domain vocabulary.*Acceptance criteria.*Non-goals'; }
check "empty spec names all three"                    all_three "$SPEC" "$NOTHING"
check "non-design md under specs silent"              silent "docs/superpowers/specs/notes.md" "$NOTHING"
check "design md outside specs silent"                silent "docs/other/x-design.md" "$NOTHING"
check "source file silent"                            silent "apps/server/src/services/foo.ts" "export const x = 1;"

exit $fail
