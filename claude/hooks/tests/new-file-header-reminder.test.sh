#!/usr/bin/env bash
# Covers: hook:new-file-header-reminder
# Test harness for new-file-header-reminder.sh (PostToolUse Write nudge).
#
# Covers Python support: a new .py source file with no leading comment or
# docstring gets the what+why nudge; Python test files, conftest, files
# already starting with a comment/docstring, and migrations stay silent.
# Plus TypeScript regressions.
#
# Run: ~/.claude/hooks/tests/new-file-header-reminder.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../new-file-header-reminder.sh"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

run_hook() { # path, content
    jq -n --arg p "$1" --arg c "$2" '{tool_input:{file_path:$p, content:$c}}' | bash "$HOOK"
}
nudges()   { run_hook "$@" | grep -q 'additionalContext'; }
silent()   { [ -z "$(run_hook "$@")" ]; }

# Python: source with no header -> nudge
check "py source no header nudges" \
    nudges "app/services/foo.py" "def do_work():
    return 1
"
# Python: test files / conftest / tests dir -> silent
check "py test_ file silent"      silent "tests/test_foo.py" "def test_x():
    assert True
"
check "py _test.py file silent"   silent "app/foo_test.py" "def test_y():
    assert True
"
check "py conftest silent"        silent "tests/conftest.py" "import pytest
"
# Python: already has docstring or comment -> silent
check "py docstring silent"       silent "app/services/bar.py" '"""Builds the bar because baz."""

def f():
    return 2
'
check "py hash-comment silent"    silent "app/services/baz.py" "# builds baz because qux
def g():
    return 3
"
# Python: migration excluded
check "py migration silent"       silent "app/migrations/versions/abc_add.py" "def upgrade():
    pass
"

# TypeScript regressions
check "ts source no header nudges" nudges "src/services/foo.ts" "export const x = 1;
"
check "ts test file silent"        silent "src/__tests__/foo.test.ts" "import { it } from 'vitest';
"
check "ts commented file silent"   silent "src/services/y.ts" "/** does y because z */
export const y = 1;
"

# E4 (slice 01 PR 5): a new .vue file needs a header too; an HTML comment first,
# or a comment as the first line inside <script setup>, counts as one.
check "vue no header nudges"       nudges "app/components/TripCard/TripCard.vue" '<script setup lang="ts">
const isOpen = false;
</script>
'
check "vue html-comment silent"    silent "app/components/TripCard/TripCard.vue" '<!-- Shows one trip as a card because the list and map both need it. -->
<script setup lang="ts">
const isOpen = false;
</script>
'
check "vue script-comment silent"  silent "app/components/TripCard/TripCard.vue" '<script setup lang="ts">
/** Shows one trip as a card because the list and map both need it. */
const isOpen = false;
</script>
'
check "vue story silent"           silent "app/components/TripCard/TripCard.stories.vue" '<script setup lang="ts">
</script>
'

exit "$fail"
