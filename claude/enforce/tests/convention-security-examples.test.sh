#!/usr/bin/env bash
# Verifies that the CORS examples in the four stack convention files teach a
# validated origin (IAN-381, spec 2026-09-25-security-first-gate-design, B-1
# and B-2). template-fastapi-nuxt #27 copied an unvalidated `cors_origin` from
# CLAUDE-PYTHON.md into CORSMiddleware(allow_credentials=True), so each file
# must now show, in its own stack's idiom:
#   (a) a named constant of unsafe origins whose one-line definition holds
#       both `*` and `null`, and a validator for the origin setting;
#   (b) a negative test, inside a fenced code block, that feeds the validator
#       `*`, `null`, a comma-separated list, an origin with a path, and an
#       origin with userinfo, and asserts refusal;
#   (c) for Python, the CORSMiddleware wiring with its `allow_origins=` line;
#       the validator in (a) is what keeps the value it receives safe.
# No `# Covers:` line: no manifest enforcer exists for these documents yet, and
# manifest-fixture-closure refuses a declaration the manifest does not name.
# Every failing check names the file and the missing marker; all failures are
# printed before the fixture exits nonzero.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

fail=0
report_missing() { echo "FAIL: $1: $2"; fail=1; }

# Prints every fenced code block in a markdown file that contains the marker
# string, blocks separated by a blank line.
print_blocks_containing() {
  awk -v marker="$2" '
    /^[[:space:]]*```/ {
      if (inside) { if (found) printf "%s\n", buffer; inside = 0; buffer = ""; found = 0 }
      else { inside = 1; buffer = ""; found = 0 }
      next
    }
    inside { buffer = buffer $0 "\n"; if (index($0, marker)) found = 1 }
  ' "$1"
}

# (a) The unsafe-origin constant is defined on one line that names both `*` and `null`.
check_unsafe_constant() {
  local doc="$1" constant="$2" definition
  definition=$(grep -E "^[[:space:]]*(export[[:space:]]+)?(const[[:space:]]+|var[[:space:]]+)?${constant}[[:space:]]*(:[^=]*)?=" "$doc" | head -1 || true)
  if [ -z "$definition" ]; then
    report_missing "$doc" "no definition line for the unsafe-origin constant '$constant'"
    return
  fi
  printf '%s' "$definition" | grep -qF '*' \
    || report_missing "$doc" "'$constant' definition does not contain '*'"
  printf '%s' "$definition" | grep -qw 'null' \
    || report_missing "$doc" "'$constant' definition does not contain 'null'"
}

# (a) The validator for the origin setting is shown.
check_validator() {
  grep -qF "$2" "$1" || report_missing "$1" "no CORS origin validator marker '$2'"
}

# (b) A fenced block holding the named negative test asserts refusal and feeds every worst value.
check_negative_test() {
  local doc="$1" test_marker="$2" refusal_marker="$3" test_block
  test_block=$(print_blocks_containing "$doc" "$test_marker")
  if [ -z "$test_block" ]; then
    report_missing "$doc" "no fenced code block containing the negative test marker '$test_marker'"
    return
  fi
  printf '%s' "$test_block" | grep -qF "$refusal_marker" \
    || report_missing "$doc" "negative test '$test_marker' has no refusal assertion '$refusal_marker'"
  printf '%s' "$test_block" | grep -qE "[\"']\\*[\"']" \
    || report_missing "$doc" "negative test '$test_marker' does not feed the quoted value '*'"
  printf '%s' "$test_block" | grep -qE "[\"']null[\"']" \
    || report_missing "$doc" "negative test '$test_marker' does not feed the quoted value 'null'"
  printf '%s' "$test_block" | grep -qE "[\"']https?://[^\"' ]*,[^\"']*[\"']" \
    || report_missing "$doc" "negative test '$test_marker' does not feed a comma-separated origin list (quoted, starting https://)"
  printf '%s' "$test_block" | grep -qE "[\"']https?://[^\"'/@ ]+/[^\"' ]+[\"']" \
    || report_missing "$doc" "negative test '$test_marker' does not feed an origin with a path (quoted, e.g. https://host/path)"
  printf '%s' "$test_block" | grep -qE "[\"']https?://[^\"'/@: ]+@[^\"' ]+[\"']" \
    || report_missing "$doc" "negative test '$test_marker' does not feed an origin with userinfo (quoted, e.g. https://name@host)"
}

PYTHON_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-PYTHON.md"
BACKEND_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-BACKEND.md"
GO_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-GO.md"
RUBY_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-RUBY.md"
for doc in "$PYTHON_DOC" "$BACKEND_DOC" "$GO_DOC" "$RUBY_DOC"; do
  [ -f "$doc" ] || { echo "FAIL: $doc does not exist, so nothing could be checked"; exit 1; }
done

# B-1: Python (pydantic-settings field validator, pytest).
check_unsafe_constant "$PYTHON_DOC" 'UNSAFE_CORS_ORIGINS'
check_validator       "$PYTHON_DOC" '@field_validator("cors_origin")'
check_negative_test   "$PYTHON_DOC" 'def test_settings_refuses_unsafe_cors_origin(' 'pytest.raises(ValidationError)'
# (c) The CORSMiddleware wiring is still shown; the validator check above guards the value it receives.
grep -qF 'CORSMiddleware,' "$PYTHON_DOC" \
  || report_missing "$PYTHON_DOC" "no CORSMiddleware wiring example ('CORSMiddleware,')"
grep -qE 'allow_origins=' "$PYTHON_DOC" \
  || report_missing "$PYTHON_DOC" "no 'allow_origins=' line in the CORSMiddleware example"

# B-2: TypeScript backend (Express, Vitest).
check_unsafe_constant "$BACKEND_DOC" 'UNSAFE_CORS_ORIGINS'
check_validator       "$BACKEND_DOC" 'function parseCorsOrigin('
check_negative_test   "$BACKEND_DOC" 'describe("parseCorsOrigin"' '.toThrow('

# B-2: Go (config.Load, table-driven go test).
check_unsafe_constant "$GO_DOC" 'unsafeCORSOrigins'
check_validator       "$GO_DOC" 'func parseCORSOrigin('
check_negative_test   "$GO_DOC" 'func TestParseCORSOriginRefusesUnsafeValues(' 'err == nil'

# B-2: Ruby (initializer, RSpec).
check_unsafe_constant "$RUBY_DOC" 'UNSAFE_CORS_ORIGINS'
check_validator       "$RUBY_DOC" 'def parse_cors_origin('
check_negative_test   "$RUBY_DOC" 'RSpec.describe "parse_cors_origin"' 'raise_error('

[ "$fail" -eq 0 ] && echo "convention-security-examples.test.sh PASS"
exit "$fail"
