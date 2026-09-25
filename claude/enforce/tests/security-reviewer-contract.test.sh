#!/usr/bin/env bash
# Verifies the security reviewer's contract (IAN-381, spec
# 2026-09-25-security-first-gate-design, B-15 and B-16, and the invariant that
# the security review model is read from one key):
#   (1) enforce/security-review-model.json exists and its securityReviewModel
#       key is a non-empty string;
#   (2) agents/security-reviewer.md is read-only: its frontmatter tools line is
#       exactly `tools: Read, Grep, Glob, Bash` (its model line is pinned by
#       security-reviewer-contract-2.test.sh);
#   (3) prompts/security-review-prompt.md requires the control inventory, the
#       input sources per control, the worst value per source and the control's
#       behavior with it, the insecure-value test with MEDIUM for a missing one,
#       the findings table, the "Nothing found" line that names the values it
#       tried, and the rule that trusted configuration never downgrades a
#       finding; it carries the three placeholders and the `## Security review`
#       section format the merge gate parses;
#   (4) no file under hooks/ or prompts/ contains the literal model id, so the
#       key is the only place the model is named.
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

# --- (1) the model key -------------------------------------------------------
MODEL_ID=""
if [ ! -f "$MODEL_FILE" ]; then
  report_failure "$MODEL_FILE" "does not exist, so no hook or agent has a single source for the security review model"
elif ! MODEL_ID=$(jq -er '.securityReviewModel | select(type == "string" and length > 0)' "$MODEL_FILE" 2>/dev/null); then
  MODEL_ID=""
  report_failure "$MODEL_FILE" "has no non-empty string at the key 'securityReviewModel'"
fi

# --- (2) the read-only agent -------------------------------------------------
# Prints the YAML frontmatter of a Markdown file: the lines between the first
# `---` line and the next one.
print_frontmatter() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$1"; }

if [ ! -f "$AGENT_FILE" ]; then
  report_failure "$AGENT_FILE" "does not exist, so there is no security-reviewer agent to dispatch"
else
  FRONTMATTER=$(print_frontmatter "$AGENT_FILE")
  printf '%s\n' "$FRONTMATTER" | grep -qx 'name: security-reviewer' \
    || report_failure "$AGENT_FILE" "frontmatter has no 'name: security-reviewer' line"
  TOOLS_LINE=$(printf '%s\n' "$FRONTMATTER" | grep -E '^tools:' || true)
  [ "$TOOLS_LINE" = "tools: Read, Grep, Glob, Bash" ] \
    || report_failure "$AGENT_FILE" "frontmatter tools line is '${TOOLS_LINE:-<missing>}', expected exactly 'tools: Read, Grep, Glob, Bash' (read-only, no Write, Edit, or NotebookEdit)"
  # The model line is pinned by security-reviewer-contract-2.test.sh (6): the
  # dispatcher passes the model from the key, so no frontmatter check here.
fi

# --- (3) the review prompt ---------------------------------------------------
# require_phrase <requirement> <fixed string>: the prompt holds the string,
# compared case-insensitively.
require_phrase() { grep -qiF -- "$2" "$PROMPT_FILE" || report_failure "$PROMPT_FILE" "$1: no line contains '$2'"; }
# require_exact <requirement> <fixed string>: the prompt holds the string with
# its case unchanged.
require_exact() { grep -qF -- "$2" "$PROMPT_FILE" || report_failure "$PROMPT_FILE" "$1: no line contains '$2' (case-sensitive)"; }
# require_line_with_all <requirement> <regex>...: one line of the prompt
# matches every extended regex given, case-insensitively.
require_line_with_all() {
  local requirement="$1" matching_lines
  shift
  matching_lines=$(cat "$PROMPT_FILE")
  for pattern in "$@"; do
    matching_lines=$(printf '%s\n' "$matching_lines" | grep -iE -- "$pattern" || true)
  done
  [ -n "$matching_lines" ] || report_failure "$PROMPT_FILE" "$requirement: no single line matches all of: $*"
}

if [ ! -f "$PROMPT_FILE" ]; then
  report_failure "$PROMPT_FILE" "does not exist, so the security reviewer has no prompt"
else
  # (a) the control inventory.
  require_phrase "(a) list every control" "every security control"
  require_phrase "(a) scope is the flagged hunks" "flagged hunks"

  # (b) every input source, each named.
  require_phrase "(b) sources per control" "every input source"
  for source_name in environment settings header body query database default; do
    require_phrase "(b) input source '$source_name'" "$source_name"
  done

  # (c) the worst value per source, and what the control does with it.
  require_phrase "(c) worst value per source" "worst value"
  require_exact "(c) worst value '*'" '`*`'
  require_exact "(c) worst value 'null'" '`null`'
  for worst_value in empty oversized "mixed case" injection; do
    require_phrase "(c) worst value '$worst_value'" "$worst_value"
  done
  require_phrase "(c) resulting behavior" "what the control does"

  # (d) the test that feeds the insecure value; a missing one is MEDIUM.
  require_phrase "(d) insecure-value test" "insecure value"
  require_line_with_all "(d) a missing insecure-value test is MEDIUM" 'MEDIUM' 'test'
  grep -qE 'MEDIUM' "$PROMPT_FILE" || report_failure "$PROMPT_FILE" "(d) the severity 'MEDIUM' is not written in capitals"

  # (e) the findings table and its evidence and status formats.
  require_line_with_all "(e) findings table header" '^[[:space:]]*\|' 'severity' 'evidence' 'fix' 'status'
  require_exact "(e) evidence cites file:line" '`file:line`'
  require_exact "(e) finding status 'open'" '`open`'
  require_exact "(e) finding status 'fixed <sha>'" '`fixed <sha>`'
  require_exact "(e) finding status 'waived by owner <date>'" '`waived by owner <date>`'

  # (f) the Nothing found line must name the values it tried.
  # The full template, sources included, is pinned by
  # security-reviewer-contract-2.test.sh (2); this check keeps the shape.
  require_line_with_all "(f) clean-control line format" 'Nothing found: <control>:' 'tried <'
  require_line_with_all "(f) a Nothing found line naming no values is refused" 'nothing found' 'no values' '(not acceptable|rejected|refused|invalid)'

  # (g) trusted configuration never lowers a severity.
  require_line_with_all "(g) never downgrade because configuration is trusted" '(never|do not)' '(grade|downgrade|lower)' 'trusted'

  # Placeholders the dispatcher fills.
  for placeholder in '{{FLAGGED_HUNKS}}' '{{SPEC_SECURITY_SECTION}}' '{{RANGE}}'; do
    require_exact "placeholder" "$placeholder"
  done

  # The section format the merge gate parses: the heading, then the four
  # labelled lines and the findings table below it. A label may carry a list
  # bullet or bold markers, as the Codex review parser in git-workflow-guard.sh
  # tolerates.
  if ! grep -qE '^## Security review[[:space:]]*$' "$PROMPT_FILE"; then
    report_failure "$PROMPT_FILE" "section format: no '## Security review' heading line"
  else
    SECTION=$(awk '/^## Security review[[:space:]]*$/ { found = 1; next } found { print }' "$PROMPT_FILE")
    for label in reviewer model range artefact; do
      printf '%s\n' "$SECTION" | grep -qiE "^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?${label}(\*\*|__)?[[:space:]]*:" \
        || report_failure "$PROMPT_FILE" "section format: no '$label:' line below the '## Security review' heading"
    done
    printf '%s\n' "$SECTION" | grep -iE '^[[:space:]]*\|' | grep -iE 'severity' | grep -iE 'evidence' | grep -iE 'status' | grep -qiE 'fix' \
      || report_failure "$PROMPT_FILE" "section format: no findings table header (severity, evidence, fix, status) below the '## Security review' heading"
  fi
fi

# --- (4) the model id is written only in the key file ------------------------
if [ -n "$MODEL_ID" ]; then
  HARDCODED=$(grep -rlF -- "$MODEL_ID" "$CLAUDE_HARNESS_ROOT/hooks" "$CLAUDE_HARNESS_ROOT/prompts" 2>/dev/null | grep -vxF "$MODEL_FILE" || true)
  [ -z "$HARDCODED" ] \
    || report_failure "hooks/ and prompts/" "the model id '$MODEL_ID' is hardcoded in: $(printf '%s' "$HARDCODED" | tr '\n' ' ')"
else
  report_failure "hooks/ and prompts/" "cannot prove the model id is not hardcoded because the securityReviewModel key is missing or empty"
fi

[ "$fail" -eq 0 ] && echo "security-reviewer-contract.test.sh PASS"
exit "$fail"
