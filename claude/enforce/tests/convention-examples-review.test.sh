#!/usr/bin/env bash
# Verifies the fixes that PR #139's review asked of the CORS and session cookie
# examples in the four stack convention files (IAN-381, spec
# 2026-09-25-security-first-gate-design, B-1 and B-2, slice B-1d). The review
# found examples that could not run, tests that checked their own literals
# instead of the code, and examples that broke their own file's injection rule,
# so each file must now show:
#   (1) an origin pattern that anchors the whole string: executed with each
#       stack's engine, every pattern refuses a value with an embedded newline,
#       and the Ruby pattern is written with \A and \z, not ^ and $;
#   (2) TypeScript: a createCorsConfig factory that takes the raw value, with no
#       cors() call at import time; a parser test that imports only the parser;
#       a createSessionMiddleware factory that takes the environment, and a
#       session cookie test that calls it with "staging" instead of building
#       its own `secure:` literal;
#   (3) Python: a cookie example that reads Secure from injected settings, and
#       a staging test that overrides settings through dependency_overrides and
#       asserts on the Set-Cookie header text;
#   (4) Ruby: a session cookie test that posts to the login route;
#   (5) Go: parseCORSOrigin called inside config.Load, a CORS middleware and a
#       setSessionCookie that take the Config, no os.Getenv outside Load, and a
#       cookie test that passes a staging Config;
#   (6) one unset policy: the TypeScript, Go, and Ruby parsers return the empty
#       string, with no error, for a blank or whitespace-only value, and each
#       example test has a case for it;
#   (7) SETUP.md names CLAUDE-OBSERVABILITY.md on the Go and Ruby lines.
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
SETUP_DOC="$CLAUDE_HARNESS_ROOT/SETUP.md"
for doc in "$PYTHON_DOC" "$BACKEND_DOC" "$GO_DOC" "$RUBY_DOC" "$SETUP_DOC"; do
  [ -f "$doc" ] || { echo "FAIL: $doc does not exist, so nothing could be checked"; exit 1; }
done
for engine in python3 node ruby; do
  command -v "$engine" >/dev/null || { echo "FAIL: $engine is not installed, so the examples cannot be executed"; exit 1; }
done

scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

# Prints every fenced code block in the markdown on stdin that contains the
# marker string, blocks separated by a blank line.
print_blocks_containing() {
  awk -v marker="$1" '
    /^[[:space:]]*```/ {
      if (inside) { if (found) printf "%s\n", buffer; inside = 0; buffer = ""; found = 0 }
      else { inside = 1; buffer = ""; found = 0 }
      next
    }
    inside { buffer = buffer $0 "\n"; if (index($0, marker)) found = 1 }
  '
}

# Prints a fenced block's text for the marker, reading the document named in $1.
blocks_in() { print_blocks_containing "$2" <"$1"; }

# Prints the definition that starts at the first line holding the marker, through
# the first line that closes it at column zero ("}" for Go and TypeScript, "end"
# for Ruby), reading the text on stdin.
print_definition() {
  awk -v marker="$1" -v closer="$2" '
    !on && index($0, marker) { on = 1; print; next }
    on { print; if (index($0, closer) == 1) exit }
  '
}

# Prints stdin with the body of `func Load(` removed, so what is left can be
# searched for environment reads outside config.Load.
drop_go_load_function() {
  awk '
    !skipping && index($0, "func Load(") { skipping = 1; next }
    skipping { if (index($0, "}") == 1) skipping = 0; next }
    { print }
  '
}

# ---------------------------------------------------------------------------
# (1) Every origin pattern anchors the whole string.

NEWLINE_VALUES=($'*\nhttps://app.example.com' $'https://app.example.com\n/path')

# Python runs its pattern with re.fullmatch; the Go pattern runs under python3's
# re.search, which mirrors Go's unanchored MatchString, so it must anchor itself.
probe_newlines_with_python() {
  python3 - "$@" <<'PY'
import re
import sys

stack, doc_path, *values = sys.argv[1:]
text = open(doc_path, encoding="utf-8").read()
if stack == "python":
    pattern_match = re.search(r'^BROWSER_ORIGIN_PATTERN = re\.compile\(r"(.*)"\)\s*$', text, re.M)
else:
    pattern_match = re.search(r'^var browserOriginPattern = regexp\.MustCompile\(`([^`]*)`\)\s*$', text, re.M)
if not pattern_match:
    print("EXTRACT_FAIL: origin pattern definition not found")
    sys.exit(2)
pattern = re.compile(pattern_match.group(1))
for value in values:
    origin = value.strip()
    matched = pattern.fullmatch(origin) if stack == "python" else pattern.search(origin)
    print(int(matched is not None))
PY
}

# TypeScript runs its pattern with RegExp.prototype.test, as parseCorsOrigin does.
probe_newlines_with_node() {
  node - "$@" <<'JS'
const fs = require("fs");
const [docPath, ...values] = process.argv.slice(2);
const text = fs.readFileSync(docPath, "utf8");
const patternMatch = text.match(/^(?:export\s+)?const BROWSER_ORIGIN_PATTERN\s*=\s*\/(.*)\/([dgimsuyv]*);?\s*$/m);
if (!patternMatch) {
    console.log("EXTRACT_FAIL: origin pattern definition not found");
    process.exit(2);
}
const pattern = new RegExp(patternMatch[1], patternMatch[2]);
for (const value of values) {
    console.log(pattern.test(value.trim()) ? 1 : 0);
}
JS
}

# Ruby runs its pattern with Regexp#match?, as parse_cors_origin does.
probe_newlines_with_ruby() {
  ruby - "$@" <<'RB'
doc_path, *values = ARGV
text = File.read(doc_path, encoding: "UTF-8")
pattern_match = text.match(%r{^BROWSER_ORIGIN_PATTERN\s*=\s*/(.*)/([mix]*)\s*$})
unless pattern_match
  puts "EXTRACT_FAIL: origin pattern definition not found"
  exit 2
end
options = 0
options |= Regexp::EXTENDED if pattern_match[2].include?("x")
options |= Regexp::IGNORECASE if pattern_match[2].include?("i")
options |= Regexp::MULTILINE if pattern_match[2].include?("m")
pattern = Regexp.new(pattern_match[1], options)
values.each { |value| puts(pattern.match?(value.strip) ? 1 : 0) }
RB
}

# Runs one stack's probe over the newline values and requires a refusal for each.
check_newline_refusals() {
  local doc="$1" label="$2" probe_output
  shift 2
  if ! probe_output=$("$@" "${NEWLINE_VALUES[@]}" 2>&1); then
    report_failure "$doc" "$label newline probe did not run: $probe_output"
    return
  fi
  local verdicts=() index=0 value
  while IFS= read -r line; do verdicts+=("$line"); done <<<"$probe_output"
  for value in "${NEWLINE_VALUES[@]}"; do
    [ "${verdicts[$index]:-missing}" = 0 ] \
      || report_failure "$doc" "$label origin pattern accepts $(printf '%q' "$value"), which smuggles a second line past a line-anchored pattern"
    index=$((index + 1))
  done
}

check_newline_refusals "$PYTHON_DOC"  "Python"     probe_newlines_with_python python "$PYTHON_DOC"
check_newline_refusals "$BACKEND_DOC" "TypeScript" probe_newlines_with_node "$BACKEND_DOC"
check_newline_refusals "$GO_DOC"      "Go"         probe_newlines_with_python go "$GO_DOC"
check_newline_refusals "$RUBY_DOC"    "Ruby"       probe_newlines_with_ruby "$RUBY_DOC"

ruby_pattern_line=$(grep -E '^BROWSER_ORIGIN_PATTERN[[:space:]]*=' "$RUBY_DOC" | head -1 || true)
printf '%s' "$ruby_pattern_line" | grep -qE '=[[:space:]]*/\\A' \
  || report_failure "$RUBY_DOC" "BROWSER_ORIGIN_PATTERN does not open with \\A (Ruby's ^ matches at every line start)"
printf '%s' "$ruby_pattern_line" | grep -qE '\\z/[mix]*[[:space:]]*$' \
  || report_failure "$RUBY_DOC" "BROWSER_ORIGIN_PATTERN does not close with \\z (Ruby's \$ matches at every line end)"

# ---------------------------------------------------------------------------
# (2) TypeScript: CORS factory, parser-only test import, session factory and test.

ts_cors_block=$(blocks_in "$BACKEND_DOC" 'function parseCorsOrigin(')
if [ -z "$ts_cors_block" ]; then
  report_failure "$BACKEND_DOC" "no fenced block defines 'function parseCorsOrigin('"
else
  ts_factory=$(printf '%s' "$ts_cors_block" | print_definition 'export function createCorsConfig(' '}')
  if [ -z "$ts_factory" ]; then
    report_failure "$BACKEND_DOC" "the corsConfig block does not export a factory 'export function createCorsConfig(<raw value>)'"
  else
    printf '%s' "$ts_factory" | head -1 | grep -qE 'createCorsConfig\([[:space:]]*[A-Za-z_]+' \
      || report_failure "$BACKEND_DOC" "createCorsConfig takes no parameter; it must take the raw CORS_ORIGIN value"
    printf '%s' "$ts_factory" | grep -qF 'parseCorsOrigin(' \
      || report_failure "$BACKEND_DOC" "createCorsConfig does not pass its raw value through parseCorsOrigin("
    printf '%s' "$ts_factory" | grep -qF 'cors(' \
      || report_failure "$BACKEND_DOC" "createCorsConfig does not build the middleware with cors("
    if printf '%s' "$ts_cors_block" | grep -qE '^(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_]+[[:space:]]*=[[:space:]]*cors\('; then
      report_failure "$BACKEND_DOC" "the corsConfig block still calls cors({ ... }) at module level, which runs parseCorsOrigin at import time"
    fi
  fi
fi
blocks_in "$BACKEND_DOC" 'createCorsConfig(process.env.CORS_ORIGIN' | grep -q . \
  || report_failure "$BACKEND_DOC" "no example wires the app with 'createCorsConfig(process.env.CORS_ORIGIN'"

ts_parser_test=$(blocks_in "$BACKEND_DOC" 'describe("parseCorsOrigin"')
if [ -z "$ts_parser_test" ]; then
  report_failure "$BACKEND_DOC" "no fenced block holds 'describe(\"parseCorsOrigin\"'"
else
  printf '%s' "$ts_parser_test" | grep -qE '^import[[:space:]]*\{[[:space:]]*parseCorsOrigin[[:space:]]*\}[[:space:]]*from' \
    || report_failure "$BACKEND_DOC" "the parseCorsOrigin test does not import exactly '{ parseCorsOrigin }'"
  if printf '%s' "$ts_parser_test" | grep -E '^import' | grep -qE 'createCorsConfig|\bcorsConfig[[:space:]]*[,}]'; then
    report_failure "$BACKEND_DOC" "the parseCorsOrigin test imports the CORS middleware, not only the parser"
  fi
  printf '%s' "$ts_parser_test" | grep -qF '.toBe("")' \
    || report_failure "$BACKEND_DOC" "the parseCorsOrigin test has no case asserting a blank value returns '' ('.toBe(\"\")')"
  printf '%s' "$ts_parser_test" | grep -qE "[\"'][[:space:]]+[\"']" \
    || report_failure "$BACKEND_DOC" "the parseCorsOrigin test feeds no whitespace-only value (e.g. \"   \")"
fi

ts_session_block=$(blocks_in "$BACKEND_DOC" 'export function createSessionMiddleware(')
if [ -z "$ts_session_block" ]; then
  report_failure "$BACKEND_DOC" "no fenced block exports 'function createSessionMiddleware(environment...)' for the session middleware"
else
  printf '%s' "$ts_session_block" | grep -qE 'export function createSessionMiddleware\([^)]*environment' \
    || report_failure "$BACKEND_DOC" "createSessionMiddleware does not take an 'environment' parameter"
  printf '%s' "$ts_session_block" | grep -qE 'secure:[[:space:]]*environment[[:space:]]*!==[[:space:]]*"development"' \
    || report_failure "$BACKEND_DOC" "createSessionMiddleware does not set 'secure: environment !== \"development\"'"
  if printf '%s' "$ts_session_block" | grep -qF 'process.env.NODE_ENV'; then
    report_failure "$BACKEND_DOC" "the session middleware block still reads process.env.NODE_ENV instead of its environment argument"
  fi
fi

ts_session_test=$(blocks_in "$BACKEND_DOC" 'describe("session cookie"')
if [ -z "$ts_session_test" ]; then
  report_failure "$BACKEND_DOC" "no fenced block holds 'describe(\"session cookie\"'"
else
  printf '%s' "$ts_session_test" | grep -qE '^import[[:space:]]*\{[^}]*createSessionMiddleware' \
    || report_failure "$BACKEND_DOC" "the session cookie test does not import createSessionMiddleware"
  printf '%s' "$ts_session_test" | grep -qE "createSessionMiddleware\([^)]*[\"']staging[\"']" \
    || report_failure "$BACKEND_DOC" "the session cookie test does not call createSessionMiddleware(\"staging\")"
  printf '%s' "$ts_session_test" | grep -F 'expect(' | grep -qi 'secure' \
    || report_failure "$BACKEND_DOC" "the session cookie test asserts nothing about Secure"
  printf '%s' "$ts_session_test" | grep -F 'expect(' | grep -qi 'httponly' \
    || report_failure "$BACKEND_DOC" "the session cookie test asserts nothing about HttpOnly"
  if printf '%s' "$ts_session_test" | grep -qF 'secure:'; then
    report_failure "$BACKEND_DOC" "the session cookie test builds its own 'secure:' literal, so it tests itself instead of the middleware"
  fi
fi

# ---------------------------------------------------------------------------
# (3) Python: Secure from injected settings; test overrides settings, reads Set-Cookie.

python_cookie_block=$(blocks_in "$PYTHON_DOC" 'response.set_cookie(')
if [ -z "$python_cookie_block" ]; then
  report_failure "$PYTHON_DOC" "no fenced block holds 'response.set_cookie('"
else
  printf '%s' "$python_cookie_block" | grep -qE 'secure=settings\.environment[[:space:]]*!=[[:space:]]*"development"' \
    || report_failure "$PYTHON_DOC" "the session cookie example does not set 'secure=settings.environment != \"development\"'"
  if printf '%s' "$python_cookie_block" | grep -qF 'os.environ'; then
    report_failure "$PYTHON_DOC" "the session cookie example reads os.environ, which the file's own injection rule forbids"
  fi
fi

python_cookie_test=$(blocks_in "$PYTHON_DOC" 'def test_session_cookie_is_secure_in_staging(')
if [ -z "$python_cookie_test" ]; then
  report_failure "$PYTHON_DOC" "no fenced block holds 'def test_session_cookie_is_secure_in_staging('"
else
  printf '%s' "$python_cookie_test" | grep -qF 'dependency_overrides' \
    || report_failure "$PYTHON_DOC" "the staging cookie test does not override settings through app.dependency_overrides"
  printf '%s' "$python_cookie_test" | grep -qi 'set-cookie' \
    || report_failure "$PYTHON_DOC" "the staging cookie test does not read the set-cookie header"
  printf '%s' "$python_cookie_test" | grep -qE '"Secure" in ' \
    || report_failure "$PYTHON_DOC" "the staging cookie test does not assert '\"Secure\" in' the set-cookie header"
  printf '%s' "$python_cookie_test" | grep -qE '"HttpOnly" in ' \
    || report_failure "$PYTHON_DOC" "the staging cookie test does not assert '\"HttpOnly\" in' the set-cookie header"
  if printf '%s' "$python_cookie_test" | grep -qiE '\[[\"'"'"'](secure|httponly)[\"'"'"']\]'; then
    report_failure "$PYTHON_DOC" "the staging cookie test still reads response.cookies[...][\"secure\"], which a TestClient cookie jar does not expose"
  fi
fi

# ---------------------------------------------------------------------------
# (4) Ruby: the session cookie test posts to the login route.

ruby_cookie_test=$(blocks_in "$RUBY_DOC" 'RSpec.describe "session cookie"')
if [ -z "$ruby_cookie_test" ]; then
  report_failure "$RUBY_DOC" "no fenced block holds 'RSpec.describe \"session cookie\"'"
else
  printf '%s' "$ruby_cookie_test" | grep -qF 'post "/v1/auth/login"' \
    || report_failure "$RUBY_DOC" "the session cookie test does not issue 'post \"/v1/auth/login\"'"
  if printf '%s' "$ruby_cookie_test" | grep -qF 'get "/v1/auth/login"'; then
    report_failure "$RUBY_DOC" "the session cookie test issues 'get \"/v1/auth/login\"', which no login route answers with a cookie"
  fi
fi

# ---------------------------------------------------------------------------
# (5) Go: parse inside config.Load, middleware and cookie take the Config.

go_load_function=$(blocks_in "$GO_DOC" 'func Load(' | print_definition 'func Load(' '}')
if [ -z "$go_load_function" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func Load('"
else
  printf '%s' "$go_load_function" | grep -qF 'parseCORSOrigin(' \
    || report_failure "$GO_DOC" "func Load does not call parseCORSOrigin("
fi

go_cors_constructor=$(blocks_in "$GO_DOC" 'func newCORSMiddleware(' | print_definition 'func newCORSMiddleware(' '}')
if [ -z "$go_cors_constructor" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func newCORSMiddleware('"
else
  printf '%s' "$go_cors_constructor" | head -1 | grep -qE 'func newCORSMiddleware\([^)]*\bcfg[[:space:]]+([a-z]+\.)?Config\b' \
    || report_failure "$GO_DOC" "newCORSMiddleware does not take the config ('newCORSMiddleware(cfg Config)')"
  printf '%s' "$go_cors_constructor" | grep -E 'AllowedOrigins' | grep -qF 'cfg.' \
    || report_failure "$GO_DOC" "newCORSMiddleware does not pass the parsed origin from cfg to AllowedOrigins"
fi

go_cookie_block=$(blocks_in "$GO_DOC" 'http.SetCookie(')
if [ -z "$go_cookie_block" ]; then
  report_failure "$GO_DOC" "no fenced block holds 'http.SetCookie('"
else
  printf '%s' "$go_cookie_block" | grep -qE 'func setSessionCookie\([^)]*\bcfg\b' \
    || report_failure "$GO_DOC" "the cookie example does not define 'func setSessionCookie(' taking cfg, which its test calls"
  printf '%s' "$go_cookie_block" | grep -qE 'cfg\.Environment[[:space:]]*!=[[:space:]]*"development"' \
    || report_failure "$GO_DOC" "the cookie example does not set Secure from 'cfg.Environment != \"development\"'"
fi

for go_marker in 'func parseCORSOrigin(' 'func newCORSMiddleware(' 'http.SetCookie('; do
  if blocks_in "$GO_DOC" "$go_marker" | drop_go_load_function | grep -qF 'os.Getenv('; then
    report_failure "$GO_DOC" "the block holding '$go_marker' reads os.Getenv( outside func Load, which the file's own injection rule forbids"
  fi
done

go_cookie_test=$(blocks_in "$GO_DOC" 'func TestSessionCookieIsSecureInStaging(')
if [ -z "$go_cookie_test" ]; then
  report_failure "$GO_DOC" "no fenced block holds 'func TestSessionCookieIsSecureInStaging('"
else
  printf '%s' "$go_cookie_test" | grep -qE 'Environment:[[:space:]]*"staging"' \
    || report_failure "$GO_DOC" "the staging cookie test does not build a Config with 'Environment: \"staging\"'"
  printf '%s' "$go_cookie_test" | grep -qF 'setSessionCookie(' \
    || report_failure "$GO_DOC" "the staging cookie test does not call setSessionCookie("
  if printf '%s' "$go_cookie_test" | grep -qF 't.Setenv('; then
    report_failure "$GO_DOC" "the staging cookie test sets the environment with t.Setenv, which an injected Config never reads"
  fi
fi

# ---------------------------------------------------------------------------
# (6) One unset policy: a blank value parses to "" with no error.

BLANK_VALUES=("" $'   \t ')

# Runs the TypeScript parser, extracted from its block, over a real origin and
# the blank values; prints one JSON result or "THROW: <message>" per value.
run_typescript_parser() {
  local probe_file="$scratch_dir/parseCorsOrigin.mts"
  blocks_in "$BACKEND_DOC" 'function parseCorsOrigin(' | awk '
    /^(export[[:space:]]+)?const (UNSAFE_CORS_ORIGINS|BROWSER_ORIGIN_PATTERN)[[:space:]:=]/ { print; next }
    !on && /^export function parseCorsOrigin\(/ { on = 1 }
    on { print; if ($0 ~ /^}/) on = 0 }
  ' >"$probe_file"
  cat >>"$probe_file" <<'TS'
for (const value of process.argv.slice(2)) {
    try {
        console.log(JSON.stringify(parseCorsOrigin(value)));
    } catch (error) {
        console.log(`THROW: ${error instanceof Error ? error.message : String(error)}`);
    }
}
TS
  node --experimental-strip-types --no-warnings "$probe_file" "$@"
}

# Runs the Ruby parser, extracted from its block, the same way.
run_ruby_parser() {
  local probe_file="$scratch_dir/parse_cors_origin.rb"
  { echo 'require "set"'
    blocks_in "$RUBY_DOC" 'def parse_cors_origin(' | awk '
      /^(UNSAFE_CORS_ORIGINS|BROWSER_ORIGIN_PATTERN)[[:space:]]*=/ { print; next }
      !on && /^def parse_cors_origin\(/ { on = 1 }
      on { print; if ($0 ~ /^end/) on = 0 }
    '
    cat <<'RB'
ARGV.each do |value|
  begin
    puts parse_cors_origin(value).inspect
  rescue StandardError => error
    puts "THROW: #{error.message}"
  end
end
RB
  } >"$probe_file"
  ruby "$probe_file" "$@"
}

# Checks one parser: the real origin comes back unchanged, each blank value as "".
check_blank_policy() {
  local doc="$1" label="$2" parser_output
  shift 2
  if ! parser_output=$("$@" "https://app.example.com" "${BLANK_VALUES[@]}" 2>&1); then
    report_failure "$doc" "$label parser could not be run from its example: $parser_output"
    return
  fi
  local results=()
  while IFS= read -r line; do results+=("$line"); done <<<"$parser_output"
  [ "${results[0]:-missing}" = '"https://app.example.com"' ] \
    || report_failure "$doc" "$label parser, run from its example, did not return a real origin unchanged (got '${results[0]:-missing}')"
  [ "${results[1]:-missing}" = '""' ] \
    || report_failure "$doc" "$label parser returns '${results[1]:-missing}' for an empty CORS_ORIGIN; a blank value means no cross-origin access and must return \"\""
  [ "${results[2]:-missing}" = '""' ] \
    || report_failure "$doc" "$label parser returns '${results[2]:-missing}' for a whitespace-only CORS_ORIGIN; it must return \"\""
}

check_blank_policy "$BACKEND_DOC" "TypeScript" run_typescript_parser
check_blank_policy "$RUBY_DOC"    "Ruby"       run_ruby_parser

go_parser=$(blocks_in "$GO_DOC" 'func parseCORSOrigin(' | print_definition 'func parseCORSOrigin(' '}')
if [ -z "$go_parser" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func parseCORSOrigin('"
else
  printf '%s' "$go_parser" | grep -qE 'if origin == "" \{' \
    || report_failure "$GO_DOC" "parseCORSOrigin has no 'if origin == \"\" {' branch for a blank value"
  printf '%s' "$go_parser" | grep -qE 'return "", nil' \
    || report_failure "$GO_DOC" "parseCORSOrigin never returns '\"\", nil', so a blank CORS_ORIGIN is refused instead of meaning no cross-origin access"
fi

go_blank_test=$(blocks_in "$GO_DOC" 'func TestParseCORSOriginReturnsEmptyForBlankValue(' | print_definition 'func TestParseCORSOriginReturnsEmptyForBlankValue(' '}')
if [ -z "$go_blank_test" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func TestParseCORSOriginReturnsEmptyForBlankValue('"
else
  printf '%s' "$go_blank_test" | grep -qE '"[[:space:]]+"' \
    || report_failure "$GO_DOC" "TestParseCORSOriginReturnsEmptyForBlankValue feeds no whitespace-only value (e.g. \"   \")"
  printf '%s' "$go_blank_test" | grep -qF 'err != nil' \
    || report_failure "$GO_DOC" "TestParseCORSOriginReturnsEmptyForBlankValue does not fail on a non-nil error ('err != nil')"
  printf '%s' "$go_blank_test" | grep -qF '!= ""' \
    || report_failure "$GO_DOC" "TestParseCORSOriginReturnsEmptyForBlankValue does not fail on a non-empty result ('!= \"\"')"
fi

ruby_parser_test=$(blocks_in "$RUBY_DOC" 'RSpec.describe "parse_cors_origin"')
if [ -z "$ruby_parser_test" ]; then
  report_failure "$RUBY_DOC" "no fenced block holds 'RSpec.describe \"parse_cors_origin\"'"
else
  printf '%s' "$ruby_parser_test" | grep -qF 'eq("")' \
    || report_failure "$RUBY_DOC" "the parse_cors_origin spec has no case asserting a blank value returns \"\" ('eq(\"\")')"
  printf '%s' "$ruby_parser_test" | grep -qE '"[[:space:]]+"' \
    || report_failure "$RUBY_DOC" "the parse_cors_origin spec feeds no whitespace-only value (e.g. \"   \")"
fi

# ---------------------------------------------------------------------------
# (7) SETUP.md points the Go and Ruby tracks at the shared observability file.

grep -E '^- \*\*Go\*\*' "$SETUP_DOC" | grep -qF 'CLAUDE-OBSERVABILITY.md' \
  || report_failure "$SETUP_DOC" "the Go track line does not name CLAUDE-OBSERVABILITY.md"
grep -E '^- \*\*Ruby on Rails\*\*' "$SETUP_DOC" | grep -qF 'CLAUDE-OBSERVABILITY.md' \
  || report_failure "$SETUP_DOC" "the Ruby on Rails track line does not name CLAUDE-OBSERVABILITY.md"

[ "$fail" -eq 0 ] && echo "convention-examples-review.test.sh PASS"
exit "$fail"
