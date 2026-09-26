#!/usr/bin/env bash
# Verifies the R-517 review findings on the security reviewer's contract
# (IAN-381, spec 2026-09-25-security-first-gate-design, B-15b):
#   (1) enforce/role-policy.json gives the security-reviewer role a deny list
#       of ["any"], and hooks/protected-path-guard.sh denies that role a Write
#       to an ordinary source file;
#   (2) the clean-control line names the input sources as well as the values
#       tried, and the prompt says every enumerated source must appear on it;
#   (3) a hunk that changes an input source brings the control consuming it
#       into scope even outside the hunks, and a range with no control yields a
#       required "No security control in range" line;
#   (4) the model and artefact output lines copy the dispatcher-filled
#       {{MODEL}} and {{ARTEFACT_PATH}} placeholders verbatim rather than the
#       reviewer's self-description or its input path;
#   (5) finding rows are numbered from 1 in output order, only the Status cell
#       is edited afterwards, and no row is removed or renumbered;
#   (6) the model is named once: the agent frontmatter carries no model line,
#       the agent or prompt says the dispatcher passes the model from
#       enforce/security-review-model.json, and the literal model id appears
#       in no file under agents/, skills/, hooks/, or prompts/.
# No `# Covers:` line: no manifest enforcer exists for these files yet, and
# manifest-fixture-closure refuses a declaration the manifest does not name.
# Every failing check names the file and the requirement; all failures are
# printed before the fixture exits nonzero.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

fail=0
report_failure() { echo "FAIL: $1: $2"; fail=1; }

MODEL_FILE="$CLAUDE_HARNESS_ROOT/enforce/security-review-model.json"
AGENT_FILE="$CLAUDE_HARNESS_ROOT/agents/security-reviewer.md"
PROMPT_FILE="$CLAUDE_HARNESS_ROOT/prompts/security-review-prompt.md"
POLICY_FILE="$CLAUDE_HARNESS_ROOT/enforce/role-policy.json"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/protected-path-guard.sh"

# require_in <file> <requirement> <fixed string>: the file holds the string
# with its case unchanged.
require_in() { grep -qF -- "$3" "$1" || report_failure "$1" "$2: no line contains '$3' (case-sensitive)"; }
# require_line_in <file> <requirement> <regex>...: one line of the file
# matches every extended regex given, case-insensitively.
require_line_in() {
  local file="$1" requirement="$2" matching_lines
  shift 2
  matching_lines=$(cat "$file")
  for pattern in "$@"; do
    matching_lines=$(printf '%s\n' "$matching_lines" | grep -iE -- "$pattern" || true)
  done
  [ -n "$matching_lines" ] || report_failure "$file" "$requirement: no single line matches all of: $*"
}

# --- (1) the security-reviewer role is read-only (R-411) ---------------------
if [ ! -f "$POLICY_FILE" ]; then
  report_failure "$POLICY_FILE" "(1) does not exist"
elif ! jq -e '.roles["security-reviewer"] == {"deny": ["any"]}' "$POLICY_FILE" >/dev/null 2>&1; then
  report_failure "$POLICY_FILE" "(1) roles table has no \"security-reviewer\": {\"deny\": [\"any\"]} entry"
fi

export CLAUDE_ROLE_POLICY_FILE="$POLICY_FILE"
SCRATCH_REPO=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$SCRATCH_REPO"' EXIT
git -C "$SCRATCH_REPO" init -q
mkdir -p "$SCRATCH_REPO/src"
printf 'ALLOWED_ORIGINS = ["https://example.test"]\n' > "$SCRATCH_REPO/src/app.py"
GUARD_PAYLOAD=$(jq -nc --arg f "$SCRATCH_REPO/src/app.py" --arg d "$SCRATCH_REPO" \
  '{tool_name:"Write",cwd:$d,agent_type:"security-reviewer",tool_input:{file_path:$f,content:"ALLOWED_ORIGINS = [\"*\"]\n"}}')
GUARD_OUTPUT=$(printf '%s' "$GUARD_PAYLOAD" | "$HOOK" || true)
if [ -z "$GUARD_OUTPUT" ]; then
  GUARD_DECISION=allow
else
  GUARD_DECISION=$(printf '%s' "$GUARD_OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // "unparsed"' 2>/dev/null || echo unparsed)
fi
[ "$GUARD_DECISION" = "deny" ] \
  || report_failure "$HOOK" "(1) a Write by agent_type security-reviewer to src/app.py was '$GUARD_DECISION', expected deny"

# --- (2) to (5) the review prompt --------------------------------------------
if [ ! -f "$PROMPT_FILE" ]; then
  report_failure "$PROMPT_FILE" "does not exist, so the security reviewer has no prompt"
else
  # (2) the clean-control line names the sources and the values tried.
  grep -qE 'Nothing found: <control>: sources <[^>]+>: tried <[^>]+>' "$PROMPT_FILE" \
    || report_failure "$PROMPT_FILE" "(2) no line carries the template 'Nothing found: <control>: sources <...>: tried <...>'"
  require_line_in "$PROMPT_FILE" "(2) every enumerated source must appear on the Nothing found line" \
    'nothing found' 'every' 'source' '(step 2|enumerat)'

  # (3) a changed input source brings its consuming control into scope.
  require_line_in "$PROMPT_FILE" "(3) a hunk changing an input source brings the control that consumes it into scope, even outside the hunks" \
    'chang' 'source' 'settings' 'environment' 'header' 'consum' 'scope' 'outside'
  require_in "$PROMPT_FILE" "(3) zero-control line format" 'No security control in range: <paths inspected>'
  require_line_in "$PROMPT_FILE" "(3) the zero-control line is required when the range has no control" \
    'No security control in range' '(must|required)'

  # (4) dispatcher-filled model and artefact lines.
  require_in "$PROMPT_FILE" "(4) placeholder" '{{MODEL}}'
  require_in "$PROMPT_FILE" "(4) placeholder" '{{ARTEFACT_PATH}}'
  require_line_in "$PROMPT_FILE" "(4) the model line copies {{MODEL}} verbatim" '\{\{MODEL\}\}' 'verbatim'
  require_line_in "$PROMPT_FILE" "(4) the artefact line copies {{ARTEFACT_PATH}} verbatim" '\{\{ARTEFACT_PATH\}\}' 'verbatim'
  if ! grep -qE '^## Security review[[:space:]]*$' "$PROMPT_FILE"; then
    report_failure "$PROMPT_FILE" "(4) no '## Security review' heading line"
  else
    SECTION=$(awk '/^## Security review[[:space:]]*$/ { found = 1; next } found { print }' "$PROMPT_FILE")
    printf '%s\n' "$SECTION" | grep -qE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?model(\*\*|__)?[[:space:]]*:[[:space:]]*`?\{\{MODEL\}\}`?[[:space:]]*$' \
      || report_failure "$PROMPT_FILE" "(4) the 'model:' line below '## Security review' is not exactly '{{MODEL}}'"
    printf '%s\n' "$SECTION" | grep -qE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?artefact(\*\*|__)?[[:space:]]*:[[:space:]]*`?\{\{ARTEFACT_PATH\}\}`?[[:space:]]*$' \
      || report_failure "$PROMPT_FILE" "(4) the 'artefact:' line below '## Security review' is not exactly '{{ARTEFACT_PATH}}'"
    for self_description in 'the model you ran on' 'flagged-hunks file you were given'; do
      if printf '%s\n' "$SECTION" | grep -qiF -- "$self_description"; then
        report_failure "$PROMPT_FILE" "(4) the output section still asks for the reviewer's own '$self_description'"
      fi
    done
  fi

  # (5) stable rows.
  require_line_in "$PROMPT_FILE" "(5) rows are numbered from 1 in output order" 'number' 'from 1' 'output order'
  require_line_in "$PROMPT_FILE" "(5) only the Status cell may be edited afterwards" 'only the status' 'edit'
  require_line_in "$PROMPT_FILE" "(5) no row is removed or renumbered" '(no row|never)' 'remov' 'renumber'
fi

# --- (6) the model is named once ---------------------------------------------
print_frontmatter() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$1"; }

if [ ! -f "$AGENT_FILE" ]; then
  report_failure "$AGENT_FILE" "(6) does not exist"
else
  if print_frontmatter "$AGENT_FILE" | grep -qE '^model:'; then
    report_failure "$AGENT_FILE" "(6) frontmatter carries a 'model:' line; the dispatcher passes the model from the key instead"
  fi
  DISPATCH_NOTE_FOUND=0
  for described_file in "$AGENT_FILE" "$PROMPT_FILE"; do
    [ -f "$described_file" ] || continue
    if grep -iE 'dispatch' "$described_file" | grep -iF 'security-review-model.json' | grep -qiE '\bpass(es|ed)?\b'; then
      DISPATCH_NOTE_FOUND=1
    fi
  done
  [ "$DISPATCH_NOTE_FOUND" -eq 1 ] \
    || report_failure "$AGENT_FILE" "(6) neither the agent nor the prompt has a line saying the dispatcher passes the model from security-review-model.json"
fi

MODEL_ID=""
if [ -f "$MODEL_FILE" ]; then
  MODEL_ID=$(jq -er '.securityReviewModel | select(type == "string" and length > 0)' "$MODEL_FILE" 2>/dev/null || true)
fi
if [ -z "$MODEL_ID" ]; then
  report_failure "$MODEL_FILE" "(6) has no non-empty securityReviewModel key, so the single-naming check cannot run"
else
  HARDCODED=$(grep -rlF -- "$MODEL_ID" "$CLAUDE_HARNESS_ROOT/agents" "$CLAUDE_HARNESS_ROOT/skills" "$CLAUDE_HARNESS_ROOT/hooks" "$CLAUDE_HARNESS_ROOT/prompts" 2>/dev/null | grep -vxF "$MODEL_FILE" || true)
  [ -z "$HARDCODED" ] \
    || report_failure "agents/, skills/, hooks/, prompts/" "(6) the model id '$MODEL_ID' is hardcoded in: $(printf '%s' "$HARDCODED" | tr '\n' ' ')"
fi

[ "$fail" -eq 0 ] && echo "security-reviewer-contract-2.test.sh PASS"
exit "$fail"
