#!/usr/bin/env bash
# Covers: hook:verification-gate
# Asserts the IAN-98 rule wording in CLAUDE.md, rulebook/reference.md, the
# task-start skill, and the generated Cursor rules: R-509's full suite runs in
# CI and not at pre-push; R-514 carries the trivial-tier fast path; [judge]
# names the CI rule judge rather than a push-time hook.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
R509_TAIL='the full suite runs as the required CI check before any merge to main; neither a turn nor a writing subagent ends on a red suite.'

# requireText <file> <literal> <failure message>
# Fails the fixture unless the file contains the literal text.
requireText() {
  grep -qF -- "$2" "$1" || { echo "FAIL: $3"; exit 1; }
}

# forbidText <file> <literal> <failure message>
# Fails the fixture when the file still contains the literal text.
forbidText() {
  if grep -qF -- "$2" "$1"; then echo "FAIL: $3"; exit 1; fi
}

requireText "$ROOT/CLAUDE.md" "$R509_TAIL" "CLAUDE.md R-509 must put the full suite in CI only"
forbidText "$ROOT/CLAUDE.md" 'the full suite runs at pre-push' "CLAUDE.md R-509 still runs the full suite at pre-push"
requireText "$ROOT/CLAUDE.md" '`[judge]` is the CI rule judge' "CLAUDE.md still calls [judge] a push-time judge"
requireText "$ROOT/rulebook/reference.md" 'run the full suite in CI before any merge to main.' "reference.md R-509 must put the full suite in CI only"
forbidText "$ROOT/rulebook/reference.md" 'Pre-push runs the whole suite' "reference.md R-509 still runs the whole suite at pre-push"
requireText "$ROOT/rulebook/reference.md" 'trivial-tier PR' "reference.md R-514 lacks the trivial fast path"
requireText "$ROOT/skills/task-start/SKILL.md" 'no ticket, no PR document, no Copilot review request' "task-start lacks the trivial fast path"
forbidText "$ROOT/rulebook/reference.md" 'push-time judge' "reference.md still calls the judge push-time"
requireText "$ROOT/enforce/README.md" 'R-315, R-316, R-317, R-325, R-334, R-362, R-363, R-364, R-365 |' "enforce/README.md judge row must list every llm-judge rule"
requireText "$ROOT/rulebook/reference.md" 'under the same merge authorization as any PR' "R-514's trivial path must keep the merge authorization"
PORT_MAP="$REPO_ROOT/translate/cursor-port-map.json"
if [ -f "$PORT_MAP" ]; then
  forbidText "$PORT_MAP" 'push-time LLM judge' "the Cursor preamble still calls [judge] a push-time judge"
  forbidText "$PORT_MAP" 'the push judge' "the Cursor rule descriptions still name the push judge"
fi
if [ -d "$REPO_ROOT/cursor/rules" ]; then
  grep -rqF -- "$R509_TAIL" "$REPO_ROOT/cursor/rules" || { echo "FAIL: cursor rules were not regenerated"; exit 1; }
fi
echo "wall-time-rule-text.test.sh PASS"
