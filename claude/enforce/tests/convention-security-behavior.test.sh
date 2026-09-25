#!/usr/bin/env bash
# Verifies that the CORS validator examples in the four stack convention files
# behave correctly, not merely exist (IAN-381, spec
# 2026-09-25-security-first-gate-design, B-1 and B-2, slice B-1b). The sibling
# fixture convention-security-examples.test.sh checks that the markers are
# present; this one executes each stack's origin pattern with a real regex
# engine and checks the example tests and wiring for the shapes that make
# them fail when the validator is wrong:
#   (1) each origin pattern, run as the example runs it, accepts two real
#       browser origins and refuses every value a browser never sends as an
#       Origin header (wildcard, null, lists, paths, a trailing slash,
#       userinfo, uppercase hosts, default ports, out-of-range ports, and
#       hosts that do not start with a letter or digit);
#   (2) the Python negative test sets every other required setting and
#       asserts the refusal is located at `cors_origin`, so it cannot pass
#       for an unrelated missing field;
#   (3) each stack's example test asserts a real origin comes back unchanged;
#   (4) the TypeScript, Go, and Ruby examples feed the CORS middleware the
#       parser's output, never the raw environment value (TypeScript through
#       parseCorsOrigin or a createCorsConfig factory taking the raw value, Go
#       through a block that holds both parseCORSOrigin and AllowedOrigins).
# No `# Covers:` line: no manifest enforcer exists for these documents yet, and
# manifest-fixture-closure refuses a declaration the manifest does not name.
# Every failing check names the file and the behavior; all failures are
# printed before the fixture exits nonzero.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

fail=0
report_failure() { echo "FAIL: $1: $2"; fail=1; }

PYTHON_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-PYTHON.md"
BACKEND_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-BACKEND.md"
GO_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-GO.md"
RUBY_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-RUBY.md"
for doc in "$PYTHON_DOC" "$BACKEND_DOC" "$GO_DOC" "$RUBY_DOC"; do
  [ -f "$doc" ] || { echo "FAIL: $doc does not exist, so nothing could be checked"; exit 1; }
done
for engine in python3 node ruby; do
  command -v "$engine" >/dev/null || { echo "FAIL: $engine is not installed, so the patterns cannot be executed"; exit 1; }
done

# Origins a browser really sends; every pattern must accept them.
ACCEPTED_ORIGINS=("https://app.example.com" "http://localhost:3000")
# Values the example refuses either through the pattern or through the
# unsafe-origin constant, which the examples check trimmed and lowercased.
REFUSED_BY_CONSTANT_OR_PATTERN=("*" "null" " NULL ")
# Values the pattern itself must refuse.
REFUSED_BY_PATTERN=(
  "https://a.example,https://b.example"
  "https://app.example.com/path"
  "https://app.example.com/"
  "https://name@app.example.com"
  "https://App.Example.com"
  "https://app.example.com:443"
  "http://app.example.com:80"
  "http://app.example.com:99999"
  "https://."
  "https://-"
)
ALL_VALUES=("${ACCEPTED_ORIGINS[@]}" "${REFUSED_BY_CONSTANT_OR_PATTERN[@]}" "${REFUSED_BY_PATTERN[@]}")

# Each probe extracts one stack's pattern and unsafe-origin constant from its
# document, trims every value the way the example does, and prints one line per
# value: "<pattern matched 0|1> <in unsafe constant 0|1>". It prints
# "EXTRACT_FAIL: <reason>" and exits 2 when the document no longer has the shape.

# Python runs its own pattern with re.fullmatch, as the example's validator does.
# Go is not installed on this machine, so the Go pattern runs under python3's re;
# it uses only the RE2-compatible subset, and re.search mirrors Go's unanchored
# MatchString, so a pattern that drops its anchors fails here as it would in Go.
# A Go pattern using lookaround or a backreference is reported, since RE2 would
# panic at MustCompile where python3 would quietly accept it.
probe_with_python() {
  python3 - "$@" <<'PY'
import re
import sys

stack, doc_path, *values = sys.argv[1:]
text = open(doc_path, encoding="utf-8").read()
if stack == "python":
    pattern_match = re.search(r'^BROWSER_ORIGIN_PATTERN = re\.compile\(r"(.*)"\)\s*$', text, re.M)
    constant_match = re.search(r'^UNSAFE_CORS_ORIGINS\s*=(.*)$', text, re.M)
else:
    pattern_match = re.search(r'^var browserOriginPattern = regexp\.MustCompile\(`([^`]*)`\)\s*$', text, re.M)
    constant_match = re.search(r'^var unsafeCORSOrigins\s*=(.*)$', text, re.M)
if not pattern_match or not constant_match:
    print("EXTRACT_FAIL: origin pattern or unsafe-origin constant definition not found")
    sys.exit(2)
if stack == "go" and re.search(r'\(\?(=|!|<=|<!)|\\[1-9]', pattern_match.group(1)):
    print("EXTRACT_FAIL: the Go pattern uses lookaround or a backreference, which RE2 rejects at MustCompile")
    sys.exit(2)
constant_source = re.sub(r'\s+(#|//)[^"\']*$', "", constant_match.group(1))
unsafe_origins = {single or double for double, single in re.findall(r'"([^"]*)"|\'([^\']*)\'', constant_source)}
pattern = re.compile(pattern_match.group(1))
for value in values:
    origin = value.strip()
    if stack == "python":
        matched = pattern.fullmatch(origin) is not None
    else:
        matched = pattern.search(origin) is not None
    print(int(matched), int(origin.lower() in unsafe_origins))
PY
}

# TypeScript runs its pattern with RegExp.prototype.test, as parseCorsOrigin does.
probe_with_node() {
  node - "$@" <<'JS'
const fs = require("fs");
const [docPath, ...values] = process.argv.slice(2);
const text = fs.readFileSync(docPath, "utf8");
const patternMatch = text.match(/^(?:export\s+)?const BROWSER_ORIGIN_PATTERN\s*=\s*\/(.*)\/([dgimsuyv]*);?\s*$/m);
const constantMatch = text.match(/^(?:export\s+)?const UNSAFE_CORS_ORIGINS\b[^=]*=(.*)$/m);
if (!patternMatch || !constantMatch) {
    console.log("EXTRACT_FAIL: origin pattern or unsafe-origin constant definition not found");
    process.exit(2);
}
const constantSource = constantMatch[1].replace(/\s+\/\/[^"']*$/, "");
const unsafeOrigins = new Set([...constantSource.matchAll(/"([^"]*)"|'([^']*)'/g)].map((m) => m[1] ?? m[2]));
const pattern = new RegExp(patternMatch[1], patternMatch[2]);
for (const value of values) {
    const origin = value.trim();
    console.log(`${pattern.test(origin) ? 1 : 0} ${unsafeOrigins.has(origin.toLowerCase()) ? 1 : 0}`);
}
JS
}

# Ruby runs its pattern with Regexp#match?, as parse_cors_origin does.
probe_with_ruby() {
  ruby - "$@" <<'RB'
doc_path, *values = ARGV
text = File.read(doc_path, encoding: "UTF-8")
pattern_match = text.match(%r{^BROWSER_ORIGIN_PATTERN\s*=\s*/(.*)/([mix]*)\s*$})
constant_match = text.match(/^UNSAFE_CORS_ORIGINS\s*=(.*)$/)
unless pattern_match && constant_match
  puts "EXTRACT_FAIL: origin pattern or unsafe-origin constant definition not found"
  exit 2
end
options = 0
options |= Regexp::EXTENDED if pattern_match[2].include?("x")
options |= Regexp::IGNORECASE if pattern_match[2].include?("i")
options |= Regexp::MULTILINE if pattern_match[2].include?("m")
pattern = Regexp.new(pattern_match[1], options)
constant_source = constant_match[1].sub(/\s+#[^"']*\z/, "")
unsafe_origins = constant_source.scan(/"([^"]*)"|'([^']*)'/).map { |double, single| double || single }
values.each do |value|
  origin = value.strip
  puts "#{pattern.match?(origin) ? 1 : 0} #{unsafe_origins.include?(origin.downcase) ? 1 : 0}"
end
RB
}

# (1) Runs one stack's probe and checks every value against the expected verdict.
check_origin_verdicts() {
  local doc="$1" label="$2" probe_output
  shift 2
  if ! probe_output=$("$@" "${ALL_VALUES[@]}" 2>&1); then
    report_failure "$doc" "$label origin probe did not run: $probe_output"
    return
  fi
  local verdicts=()
  while IFS= read -r line; do verdicts+=("$line"); done <<<"$probe_output"
  local index=0 value matched in_constant
  for value in "${ALL_VALUES[@]}"; do
    read -r matched in_constant <<<"${verdicts[$index]:-missing missing}"
    if [ "$index" -lt "${#ACCEPTED_ORIGINS[@]}" ]; then
      { [ "$matched" = 1 ] && [ "$in_constant" = 0 ]; } \
        || report_failure "$doc" "$label validator refuses the real browser origin '$value'"
    elif [ "$index" -lt $(( ${#ACCEPTED_ORIGINS[@]} + ${#REFUSED_BY_CONSTANT_OR_PATTERN[@]} )) ]; then
      { [ "$matched" = 0 ] || [ "$in_constant" = 1 ]; } \
        || report_failure "$doc" "$label validator accepts the unsafe value '$value' (neither the pattern nor the unsafe-origin constant refuses it)"
    else
      [ "$matched" = 0 ] \
        || report_failure "$doc" "$label origin pattern accepts '$value', which a browser never sends as an Origin"
    fi
    index=$((index + 1))
  done
}

check_origin_verdicts "$PYTHON_DOC"  "Python"     probe_with_python python "$PYTHON_DOC"
check_origin_verdicts "$BACKEND_DOC" "TypeScript" probe_with_node "$BACKEND_DOC"
check_origin_verdicts "$GO_DOC"      "Go"         probe_with_python go "$GO_DOC"
check_origin_verdicts "$RUBY_DOC"    "Ruby"       probe_with_ruby "$RUBY_DOC"

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

# has_match reports whether any input line matches, reading ALL of its input
# first. `grep -q` exits at the first match, and print_blocks_containing writes
# one block at a time, so under pipefail a block written after grep has gone
# dies of SIGPIPE and turns a match into a failure; it depends on scheduling
# and failed 18 of 30 runs under CPU load (2026-09-25). Output to /dev/null is
# not enough, because GNU grep treats that like -q; counting reads everything.
has_match() {
  local match_count
  match_count=$(grep -c "$@" || true)
  [ "${match_count:-0}" -gt 0 ]
}

# A quoted real origin literal, as the positive cases must write it.
REAL_ORIGIN_LITERAL="[\"']https?://[a-z0-9][a-z0-9.-]*(:[0-9]+)?[\"']"

# (2) The Python negative test isolates the refusal to cors_origin.
python_negative_test=$(print_blocks_containing "$PYTHON_DOC" 'def test_settings_refuses_unsafe_cors_origin(')
if [ -z "$python_negative_test" ]; then
  report_failure "$PYTHON_DOC" "no fenced block holds 'def test_settings_refuses_unsafe_cors_origin('"
else
  printf '%s' "$python_negative_test" | grep -qE "setenv\([\"']DATABASE_URL[\"']" \
    || report_failure "$PYTHON_DOC" "negative test does not set DATABASE_URL (monkeypatch.setenv(\"DATABASE_URL\", ...)), so it passes on the missing required field even with the validator deleted"
  printf '%s' "$python_negative_test" | grep -E "[\"']loc[\"']" | grep -qF 'cors_origin' \
    || report_failure "$PYTHON_DOC" "negative test does not assert the ValidationError's \"loc\" is cors_origin"
fi

# (3) Each stack's example test asserts a real origin is accepted and returned unchanged.
print_blocks_containing "$PYTHON_DOC" 'def test_' | has_match -E "\.cors_origin == ${REAL_ORIGIN_LITERAL}" \
  || report_failure "$PYTHON_DOC" "no example test asserts '.cors_origin == \"<real origin>\"' for an accepted origin"
print_blocks_containing "$BACKEND_DOC" 'parseCorsOrigin(' | has_match -E "\.to(Be|Equal|StrictEqual)\(${REAL_ORIGIN_LITERAL}\)" \
  || report_failure "$BACKEND_DOC" "no example test asserts parseCorsOrigin returns a real origin unchanged ('.toBe(\"<real origin>\")')"
print_blocks_containing "$GO_DOC" 'parseCORSOrigin(' | has_match -E "(!=|==)[[:space:]]*${REAL_ORIGIN_LITERAL}" \
  || report_failure "$GO_DOC" "no example test compares parseCORSOrigin's result with a real origin ('got != \"<real origin>\"')"
print_blocks_containing "$RUBY_DOC" 'parse_cors_origin(' | has_match -E "eq\(${REAL_ORIGIN_LITERAL}\)" \
  || report_failure "$RUBY_DOC" "no example test asserts parse_cors_origin returns a real origin unchanged ('eq(\"<real origin>\")')"

# (4) The CORS middleware receives the parser's output, never the raw env value.
print_blocks_containing "$BACKEND_DOC" 'process.env.CORS_ORIGIN' | has_match -E '(parseCorsOrigin|createCorsConfig)\(process\.env\.CORS_ORIGIN' \
  || report_failure "$BACKEND_DOC" "no example wires the CORS middleware with 'parseCorsOrigin(process.env.CORS_ORIGIN' or the factory 'createCorsConfig(process.env.CORS_ORIGIN'"
if print_blocks_containing "$BACKEND_DOC" 'process.env.CORS_ORIGIN' | grep -E 'origin:[[:space:]]*process\.env\.CORS_ORIGIN' | has_match .; then
  report_failure "$BACKEND_DOC" "an example passes the raw 'origin: process.env.CORS_ORIGIN' to the CORS middleware"
fi
print_blocks_containing "$GO_DOC" 'parseCORSOrigin(' | has_match -F 'AllowedOrigins' \
  || report_failure "$GO_DOC" "no fenced block holds both 'parseCORSOrigin(' and 'AllowedOrigins', so the parsed origin is never shown reaching the CORS middleware"
print_blocks_containing "$RUBY_DOC" 'parse_cors_origin(ENV' | has_match . \
  || report_failure "$RUBY_DOC" "no example feeds 'parse_cors_origin(ENV' to the rack-cors configuration"
if print_blocks_containing "$RUBY_DOC" 'origins' | grep -E "origins[[:space:]]+ENV" | has_match .; then
  report_failure "$RUBY_DOC" "an example passes the raw 'origins ENV' value to rack-cors"
fi

[ "$fail" -eq 0 ] && echo "convention-security-behavior.test.sh PASS"
exit "$fail"
