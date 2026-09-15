#!/usr/bin/env bash
# Verifies the foreign-rule no-op stubs (2026-07-17, user-approved): a live
# eslint-disable comment referencing a repo-side plugin rule the gate does not
# carry (security/react/react-hooks) must not error as "Definition for rule
# not found", while the gate's own rules still fire on the same file.
set -euo pipefail
LINT="$HOME/.claude/enforce/lint.mjs"

DIR=$(mktemp -d); cd "$DIR"; git init -q

# Each stubbed rule name in a disable comment above clean code -> passes.
cat > cleanWithDisables.ts <<'EOF'
// eslint-disable-next-line security/detect-non-literal-fs-filename
const fileContents = 'placeholder';
// eslint-disable-next-line react/forbid-dom-props
const styledProp = 'placeholder';
// eslint-disable-next-line react-hooks/exhaustive-deps
const dependencyNote = 'placeholder';
export { dependencyNote, fileContents, styledProp };
EOF
node "$LINT" cleanWithDisables.ts

# The stubs must not mask the gate's own rules: a nested ternary next to a
# stubbed-rule disable comment still fails.
cat > stillCaught.ts <<'EOF'
// eslint-disable-next-line security/detect-non-literal-fs-filename
const label = 'x';
const nested = label === 'a' ? 1 : label === 'b' ? 2 : 3;
export { nested };
EOF
if node "$LINT" stillCaught.ts; then
  echo "FAIL: gate rules were masked alongside a stubbed disable comment" >&2; exit 1
fi

echo "foreign-rule-stubs.test.sh PASS"
