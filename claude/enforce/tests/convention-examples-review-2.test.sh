#!/usr/bin/env bash
# Verifies the two LOW findings from the R-517 re-review of PR #139 against the
# CORS and session cookie examples in the stack convention files (IAN-381, spec
# 2026-09-25-security-first-gate-design, B-2, slice B-1e). A blank CORS origin
# means no cross-origin access, which is right in development and wrong in
# production, and a test that clears every dependency override can erase
# overrides it never set, so each file must now show:
#   (1) Go: func Load returns an error when the environment is "production" and
#       the parsed CORS origin is empty, and a fenced test
#       TestLoadRequiresCORSOriginInProduction sets ENVIRONMENT to production and
#       CORS_ORIGIN to blank with t.Setenv, calls Load, and fails on err == nil;
#   (2) Ruby: the CORS initializer, executed against a stubbed Rails, raises for
#       a blank origin in production and stays quiet for a blank origin outside
#       production and for a real origin in production, and it tests the
#       environment with Rails.env.production?;
#   (3) Python: the staging cookie test restores only its own override, inside a
#       finally, with app.dependency_overrides.pop(get_settings, and never calls
#       dependency_overrides.clear().
# No `# Covers:` line: no manifest enforcer exists for these documents yet, and
# manifest-fixture-closure refuses a declaration the manifest does not name.
# Every failing check names the file and the behavior; all failures are
# printed before the fixture exits nonzero.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

fail=0
report_failure() { echo "FAIL: $1: $2"; fail=1; }

PYTHON_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-PYTHON.md"
GO_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-GO.md"
RUBY_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-RUBY.md"
for doc in "$PYTHON_DOC" "$GO_DOC" "$RUBY_DOC"; do
  [ -f "$doc" ] || { echo "FAIL: $doc does not exist, so nothing could be checked"; exit 1; }
done
for engine in python3 ruby; do
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
# the first line that closes it at column zero, reading the text on stdin.
print_definition() {
  awk -v marker="$1" -v closer="$2" '
    !on && index($0, marker) { on = 1; print; next }
    on { print; if (index($0, closer) == 1) exit }
  '
}

# ---------------------------------------------------------------------------
# (1) Go: Load refuses a blank CORS origin in production, with a test.

go_load_function=$(blocks_in "$GO_DOC" 'func Load(' | print_definition 'func Load(' '}')
if [ -z "$go_load_function" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func Load('"
else
  # The condition line names "production" compared with ==, and the origin
  # field compared with == "" (the local corsOrigin or the CORSOrigin field).
  production_condition=$(printf '%s\n' "$go_load_function" \
    | grep -nE '^[[:space:]]*if[[:space:]].*"production"' \
    | grep -E '([Ee]nvironment[[:space:]]*==[[:space:]]*"production"|"production"[[:space:]]*==[[:space:]]*[A-Za-z_.]*[Ee]nvironment)' \
    | grep -E '(corsOrigin|CORSOrigin)[[:space:]]*==[[:space:]]*""' \
    | head -1 || true)
  if [ -z "$production_condition" ]; then
    report_failure "$GO_DOC" "func Load has no 'if <environment> == \"production\" && <corsOrigin> == \"\" {' condition, so a blank CORS origin starts a production server with no cross-origin access"
  else
    condition_line_number=${production_condition%%:*}
    refusal_branch=$(printf '%s\n' "$go_load_function" | sed -n "$((condition_line_number + 1)),$((condition_line_number + 3))p")
    printf '%s' "$refusal_branch" | grep -qE 'return[[:space:]]+Config\{\},[[:space:]]*(fmt\.Errorf|errors\.New)\(' \
      || report_failure "$GO_DOC" "the production blank-origin branch in func Load does not 'return Config{}, fmt.Errorf(...)' (or errors.New), so Load does not refuse"
  fi
fi

go_load_test=$(blocks_in "$GO_DOC" 'func TestLoadRequiresCORSOriginInProduction(' | print_definition 'func TestLoadRequiresCORSOriginInProduction(' '}')
if [ -z "$go_load_test" ]; then
  report_failure "$GO_DOC" "no fenced block defines 'func TestLoadRequiresCORSOriginInProduction('"
else
  printf '%s' "$go_load_test" | grep -qE 't\.Setenv\("ENVIRONMENT",[[:space:]]*"production"\)' \
    || report_failure "$GO_DOC" "TestLoadRequiresCORSOriginInProduction does not set 't.Setenv(\"ENVIRONMENT\", \"production\")'"
  printf '%s' "$go_load_test" | grep -qE 't\.Setenv\("CORS_ORIGIN",[[:space:]]*""\)' \
    || report_failure "$GO_DOC" "TestLoadRequiresCORSOriginInProduction does not set 't.Setenv(\"CORS_ORIGIN\", \"\")'"
  printf '%s' "$go_load_test" | grep -qE '(:=|=)[[:space:]]*(config\.)?Load\(\)' \
    || report_failure "$GO_DOC" "TestLoadRequiresCORSOriginInProduction does not call Load() and keep its error"
  printf '%s' "$go_load_test" | grep -qE 'if[[:space:]]+err[[:space:]]*==[[:space:]]*nil[[:space:]]*\{' \
    || report_failure "$GO_DOC" "TestLoadRequiresCORSOriginInProduction does not fail on 'if err == nil {'"
  printf '%s' "$go_load_test" | grep -qE 't\.(Fatal|Fatalf|Error|Errorf)\(' \
    || report_failure "$GO_DOC" "TestLoadRequiresCORSOriginInProduction never reports a failure with t.Fatal or t.Error"
fi

# ---------------------------------------------------------------------------
# (2) Ruby: the CORS initializer raises for a blank origin in production.

ruby_initializer=$(blocks_in "$RUBY_DOC" 'parse_cors_origin(ENV')
if [ -z "$ruby_initializer" ]; then
  report_failure "$RUBY_DOC" "no fenced block holds 'parse_cors_origin(ENV'"
else
  printf '%s' "$ruby_initializer" | grep -qF 'Rails.env.production?' \
    || report_failure "$RUBY_DOC" "the CORS initializer does not test 'Rails.env.production?'"
  printf '%s' "$ruby_initializer" | grep -E 'Rails\.env\.production\?' | grep -qE '(^|[[:space:]])raise([[:space:]]|\()' \
    || printf '%s' "$ruby_initializer" | grep -A2 -E '^[[:space:]]*(if|unless)[[:space:]].*Rails\.env\.production\?' | grep -qE '^[[:space:]]*raise([[:space:]]|\()' \
    || report_failure "$RUBY_DOC" "the CORS initializer does not pin a 'raise' to 'Rails.env.production?'"

  initializer_probe="$scratch_dir/cors_initializer_probe.rb"
  { cat <<'RB'
require "set"
# Stubs only what the initializer touches: Rails.env and the middleware stack.
class ProbeEnvironment < String
  def production?
    self == "production"
  end

  def development?
    self == "development"
  end
end

class ProbeMiddlewareStack
  attr_reader :inserted
  def insert_before(*_arguments, &_block)
    @inserted = true
  end
end

module Rails
  def self.env
    ProbeEnvironment.new(ENV.fetch("PROBE_RAILS_ENV"))
  end

  def self.middleware_stack
    @middleware_stack ||= ProbeMiddlewareStack.new
  end

  def self.application
    stack = middleware_stack
    config = Object.new
    config.define_singleton_method(:middleware) { stack }
    application = Object.new
    application.define_singleton_method(:config) { config }
    application
  end
end

module Rack
  class Cors; end
end

begin
RB
    printf '%s\n' "$ruby_initializer"
    cat <<'RB'
  puts "LOADED"
rescue StandardError => error
  puts "RAISED: #{error.message}"
end
RB
  } >"$initializer_probe"

  # Runs the initializer under one Rails environment and one CORS_ORIGIN value;
  # prints LOADED or RAISED, or the interpreter's own error text.
  run_ruby_initializer() {
    PROBE_RAILS_ENV="$1" CORS_ORIGIN="$2" ruby "$initializer_probe" 2>&1 || true
  }

  production_blank=$(run_ruby_initializer production "")
  case "$production_blank" in
    RAISED:*) ;;
    *) report_failure "$RUBY_DOC" "the CORS initializer, run with Rails.env production and a blank CORS_ORIGIN, did not raise (got '$production_blank')" ;;
  esac
  production_whitespace=$(run_ruby_initializer production $'   \t ')
  case "$production_whitespace" in
    RAISED:*) ;;
    *) report_failure "$RUBY_DOC" "the CORS initializer, run with Rails.env production and a whitespace-only CORS_ORIGIN, did not raise (got '$production_whitespace')" ;;
  esac
  development_blank=$(run_ruby_initializer development "")
  [ "$development_blank" = "LOADED" ] \
    || report_failure "$RUBY_DOC" "the CORS initializer, run with Rails.env development and a blank CORS_ORIGIN, did not load quietly (got '$development_blank'); a blank origin outside production means no cross-origin access"
  production_real=$(run_ruby_initializer production "https://app.example.com")
  [ "$production_real" = "LOADED" ] \
    || report_failure "$RUBY_DOC" "the CORS initializer, run with Rails.env production and a real CORS_ORIGIN, did not load (got '$production_real')"
fi

# ---------------------------------------------------------------------------
# (3) Python: the staging cookie test pops only its own override in a finally.

python_cookie_test=$(blocks_in "$PYTHON_DOC" 'def test_session_cookie_is_secure_in_staging(')
if [ -z "$python_cookie_test" ]; then
  report_failure "$PYTHON_DOC" "no fenced block holds 'def test_session_cookie_is_secure_in_staging('"
else
  if printf '%s' "$python_cookie_test" | grep -qF 'dependency_overrides.clear()'; then
    report_failure "$PYTHON_DOC" "the staging cookie test calls dependency_overrides.clear(), which also erases overrides other fixtures set"
  fi
  printf '%s' "$python_cookie_test" | grep -qF 'app.dependency_overrides.pop(get_settings' \
    || report_failure "$PYTHON_DOC" "the staging cookie test does not restore its override with 'app.dependency_overrides.pop(get_settings'"

  ast_verdict=$(printf '%s' "$python_cookie_test" | python3 -c '
import ast
import sys

source = sys.stdin.read()
try:
    tree = ast.parse(source)
except SyntaxError as error:
    print(f"SYNTAX: {error}")
    sys.exit(0)

test_function = next(
    (node for node in ast.walk(tree)
     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
     and node.name == "test_session_cookie_is_secure_in_staging"),
    None,
)
if test_function is None:
    print("NO_FUNCTION")
    sys.exit(0)

def is_override_pop(node):
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "pop"
        and ast.unparse(node.func.value) == "app.dependency_overrides"
        and node.args
        and ast.unparse(node.args[0]) == "get_settings"
    )

def is_login_post(node):
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "post"
    )

try_nodes = [node for node in ast.walk(test_function) if isinstance(node, ast.Try)]
for try_node in try_nodes:
    finally_pops = any(
        is_override_pop(inner)
        for statement in try_node.finalbody
        for inner in ast.walk(statement)
    )
    body_posts = any(
        is_login_post(inner)
        for statement in try_node.body
        for inner in ast.walk(statement)
    )
    if finally_pops and body_posts:
        print("OK")
        sys.exit(0)
if not try_nodes:
    print("NO_TRY")
elif not any(is_override_pop(inner) for try_node in try_nodes for statement in try_node.finalbody for inner in ast.walk(statement)):
    print("NO_FINALLY_POP")
else:
    print("POST_OUTSIDE_TRY")
' 2>&1)
  case "$ast_verdict" in
    OK) ;;
    SYNTAX:*) report_failure "$PYTHON_DOC" "the staging cookie test does not parse as Python: ${ast_verdict#SYNTAX: }" ;;
    NO_FUNCTION) report_failure "$PYTHON_DOC" "the staging cookie block does not define test_session_cookie_is_secure_in_staging as a function" ;;
    NO_TRY) report_failure "$PYTHON_DOC" "the staging cookie test has no try/finally, so a failing request leaves the settings override installed" ;;
    NO_FINALLY_POP) report_failure "$PYTHON_DOC" "the staging cookie test's finally does not call app.dependency_overrides.pop(get_settings, ...)" ;;
    POST_OUTSIDE_TRY) report_failure "$PYTHON_DOC" "the staging cookie test sends its login request outside the try whose finally pops the override" ;;
    *) report_failure "$PYTHON_DOC" "the staging cookie test could not be inspected: $ast_verdict" ;;
  esac
fi

[ "$fail" -eq 0 ] && echo "convention-examples-review-2.test.sh PASS"
exit "$fail"
