#!/usr/bin/env bash
# Covers: hook:spec-glossary-check
# Test harness for spec-glossary-check.sh (PostToolUse Write backstop, R-330).
#
# A superpowers spec design doc (*-design.md under docs/superpowers/specs/) must
# carry "## Domain vocabulary" with a "chosen over:" entry, "## Acceptance
# criteria", and "## Non-goals". Any missing -> one reminder naming each
# missing section; all present -> silent; any other path -> silent.
#
# A slice plan under docs/slices/ must carry the seven bold labels in every
# "### PR" block and, since IAN-352 (2026-09-24), a plan-level
# "**Merge mode:**" line recording the merge mode the owner chose at Gate 1.
# The two are reported together in one reminder, so a plan missing both hears
# about both.
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
names_but_omits() { # present, absent, path, content
    local present="$1" absent="$2"; shift 2
    local out; out=$(run_hook "$@" | jq -r '.hookSpecificOutput.additionalContext // ""')
    grep -q "$present" <<< "$out" && ! grep -q "$absent" <<< "$out"
}

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

# Slice plans (2026-09-17 skills audit, S-10): every "### PR" block carries
# the seven bold labels of build-by-slice-require-review's PR format, and
# (IAN-352) the plan carries a "**Merge mode:**" line.
SLICE="docs/slices/slice-01-auth.md"
SLICE_COMPLETE="# Slice 01: auth

**Merge mode:** owner merges, because the owner is reading the auth work PR by PR.

### PR 1: session table

**Context:** nothing exists yet.

**Problem:** no sessions.

**Approach:** a table and a repository.

**Contents:** migration, repository.

**Tests:** repository round-trip.

**Review focus:** the migration.

**Size:** 3 files, 120 lines.

### PR 2: login handler

**Context:** PR 1 merged.

**Problem:** no way in.

**Approach:** a handler over the repository.

**Contents:** handler, route.

**Tests:** handler happy and negative paths.

**Review focus:** the negative-input test.

**Size:** 4 files, 200 lines.
"
SLICE_PARTIAL="# Slice 01: auth

### PR 1: session table

**Context:** nothing exists yet.

**Problem:** no sessions.

**Approach:** a table.

**Contents:** migration.

### PR 2: login handler

**Context:** PR 1 merged.

**Problem:** no way in.

**Approach:** a handler.

**Contents:** handler.

**Tests:** handler tests.

**Review focus:** the negative-input test.

**Size:** 4 files.
"
SLICE_EMPTY="# Slice 01: auth

Some prose and no PR blocks.
"
# Derived plans. The mode line is stripped with grep rather than with a
# parameter substitution because `**` opens a glob in a substitution pattern,
# which silently replaces the wrong span: the first draft of these fixtures
# mangled the whole document and still passed (second review of PR #132). The
# two plans that place the phrase inside a PR block are written out in full for
# the same reason.
SLICE_NO_MODE="$(printf '%s\n' "$SLICE_COMPLETE" | grep -v '^\*\*Merge mode:\*\*')"
SLICE_OPT_IN="${SLICE_COMPLETE/owner merges, because the owner is reading the auth work PR by PR./merge on green, because every PR here is a mechanical rename.}"
SLICE_OPT_IN_NO_MODE="$(printf '%s\n' "$SLICE_OPT_IN" | grep -v '^\*\*Merge mode:\*\*')"
# The phrase quoted in a PR block's prose is not a declaration.
SLICE_MODE_IN_PROSE="# Slice 01: auth

### PR 1: session table

**Context:** nothing exists yet.

**Problem:** no sessions.

**Approach:** a table and a repository, and the **Merge mode:** question is answered on the ticket.

**Contents:** migration, repository.

**Tests:** repository round-trip.

**Review focus:** the migration.

**Size:** 3 files, 120 lines.
"
# A line of its own, but inside a PR block rather than above the blocks.
SLICE_MODE_IN_BLOCK="# Slice 01: auth

### PR 1: session table

**Context:** nothing exists yet.

**Problem:** no sessions.

**Approach:** a table and a repository.

**Merge mode:** merge on green.

**Contents:** migration, repository.

**Tests:** repository round-trip.

**Review focus:** the migration.

**Size:** 3 files, 120 lines.
"

check "complete slice plan silent"                    silent "$SLICE" "$SLICE_COMPLETE"
check "opt-in mode line also silent"                  silent "$SLICE" "$SLICE_OPT_IN"
check "slice plan missing labels nudges"              nudges "$SLICE" "$SLICE_PARTIAL"
check "missing labels named per PR"                   names 'PR 1: session table lacks Tests, Review focus, Size' "$SLICE" "$SLICE_PARTIAL"
check "complete PR not named"                         omits 'PR 2: login handler lacks' "$SLICE" "$SLICE_PARTIAL"
check "slice plan with no PR block nudges"            names 'no "### PR' "$SLICE" "$SLICE_EMPTY"
check "other file under docs/slices silent"           silent "docs/slices/README.md" "$SLICE_EMPTY"

# The merge mode (IAN-352): its absence is reported on its own when the PR
# blocks are complete, reported alongside the label problems when they are not,
# and folded into the no-PR-block reminder rather than lost behind it.
check "plan without a merge mode nudges"              nudges "$SLICE" "$SLICE_NO_MODE"
check "missing merge mode is named"                   names 'no "\*\*Merge mode:\*\*" line' "$SLICE" "$SLICE_NO_MODE"
check "mode named without inventing label problems"   names_but_omits 'Merge mode' 'lacks' "$SLICE" "$SLICE_NO_MODE"
check "stripping the mode from an opt-in plan nudges" names 'Merge mode' "$SLICE" "$SLICE_OPT_IN_NO_MODE"
check "the phrase inside a PR block is not the line"  names_but_omits 'Merge mode' 'lacks' "$SLICE" "$SLICE_MODE_IN_PROSE"
check "a mode line inside a PR block is not plan-level" names_but_omits 'Merge mode' 'lacks' "$SLICE" "$SLICE_MODE_IN_BLOCK"
check "mode and labels reported together"             names 'Merge mode.*PR 1: session table lacks' "$SLICE" "$SLICE_PARTIAL"
check "no-PR-block reminder names the mode too"       names 'Merge mode' "$SLICE" "$SLICE_EMPTY"

exit $fail
