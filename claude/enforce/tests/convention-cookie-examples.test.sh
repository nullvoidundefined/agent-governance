#!/usr/bin/env bash
# Verifies that the session-cookie examples in the four stack convention files
# teach a safe cookie (IAN-381, spec 2026-09-25-security-first-gate-design, B-2,
# the cookie half). CLAUDE-BACKEND.md used to set `secure: isProduction()`, so a
# staging deploy sent the session cookie over plain HTTP, and the other stacks
# showed the settings in prose or not at all. Each file must now show, in its
# own stack's idiom:
#   (a) a fenced code block that sets the session cookie with HttpOnly on,
#       SameSite lax or strict, and Secure tied to a condition that negates
#       development (never one that names production), and that never shows
#       SameSite none;
#   (b) a fenced test block that runs with the environment set to staging and
#       asserts the cookie is Secure and HttpOnly.
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

# Reports a missing pattern when the text does not match the extended regex.
require_pattern() {
  local doc="$1" text="$2" pattern="$3" description="$4"
  printf '%s' "$text" | grep -qE "$pattern" || report_missing "$doc" "$description"
}

# Reports a forbidden pattern when the text matches the extended regex.
forbid_pattern() {
  local doc="$1" text="$2" pattern="$3" description="$4"
  if printf '%s' "$text" | grep -qiE "$pattern"; then report_missing "$doc" "$description"; fi
}

# (a) The cookie-settings block sets HttpOnly, SameSite lax or strict, and a
# development-negating Secure, and shows neither a production-only Secure nor
# SameSite none.
check_cookie_settings() {
  local doc="$1" marker="$2" httponly="$3" samesite="$4" secure_dev="$5" secure_prod="$6" samesite_none="$7" block
  block=$(print_blocks_containing "$doc" "$marker")
  if [ -z "$block" ]; then
    report_missing "$doc" "no fenced code block containing the session-cookie settings marker '$marker'"
    return
  fi
  require_pattern "$doc" "$block" "$httponly"   "cookie settings block '$marker' does not turn HttpOnly on (/$httponly/)"
  require_pattern "$doc" "$block" "$samesite"   "cookie settings block '$marker' does not set SameSite lax or strict (/$samesite/)"
  require_pattern "$doc" "$block" "$secure_dev" "cookie settings block '$marker' does not tie Secure to a condition negating development (/$secure_dev/)"
  forbid_pattern  "$doc" "$block" "$secure_prod"   "cookie settings block '$marker' ties Secure to production (/$secure_prod/); staging would send the cookie over HTTP"
  forbid_pattern  "$doc" "$block" "$samesite_none" "cookie settings block '$marker' shows SameSite none (/$samesite_none/)"
}

# (b) A fenced test block sets the environment to staging and asserts both
# Secure and HttpOnly on the cookie.
check_cookie_test() {
  local doc="$1" marker="$2" secure_assert="$3" httponly_assert="$4" block
  block=$(print_blocks_containing "$doc" "$marker")
  if [ -z "$block" ]; then
    report_missing "$doc" "no fenced code block containing the cookie test marker '$marker'"
    return
  fi
  require_pattern "$doc" "$block" "[\"']staging[\"']" "cookie test '$marker' does not set the environment to the quoted value 'staging'"
  printf '%s' "$block" | grep -qiE "$secure_assert" \
    || report_missing "$doc" "cookie test '$marker' does not assert the cookie is Secure (/$secure_assert/, case-insensitive)"
  printf '%s' "$block" | grep -qiE "$httponly_assert" \
    || report_missing "$doc" "cookie test '$marker' does not assert the cookie is HttpOnly (/$httponly_assert/, case-insensitive)"
}

PYTHON_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-PYTHON.md"
BACKEND_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-BACKEND.md"
GO_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-GO.md"
RUBY_DOC="$CLAUDE_HARNESS_ROOT/CLAUDE-RUBY.md"
for doc in "$PYTHON_DOC" "$BACKEND_DOC" "$GO_DOC" "$RUBY_DOC"; do
  [ -f "$doc" ] || { echo "FAIL: $doc does not exist, so nothing could be checked"; exit 1; }
done

# Python (FastAPI response.set_cookie, pytest).
check_cookie_settings "$PYTHON_DOC" 'response.set_cookie(' \
  'httponly=True' \
  "samesite=[\"'](lax|strict)[\"']" \
  "secure=[^,)]*(!|not )[^,)]*[\"']?development" \
  'secure=[^,)]*production' \
  "samesite=[\"']none[\"']"
check_cookie_test "$PYTHON_DOC" 'def test_session_cookie_is_secure_in_staging(' \
  'assert .*secure' \
  'assert .*httponly'

# TypeScript backend (express-session cookie options, Vitest).
check_cookie_settings "$BACKEND_DOC" 'cookie: {' \
  'httpOnly:[[:space:]]*true' \
  "sameSite:[[:space:]]*[\"'](lax|strict)[\"']" \
  "secure:[^,]*(!isDevelopment\(\)|!==?[[:space:]]*[\"']development[\"'])" \
  'secure:[^,]*(isProduction|production)' \
  "sameSite:[[:space:]]*[\"']none[\"']"
check_cookie_test "$BACKEND_DOC" 'describe("session cookie"' \
  'expect\(.*secure' \
  'expect\(.*httponly'
if grep -qF 'secure: isProduction()' "$BACKEND_DOC"; then
  report_missing "$BACKEND_DOC" "still shows 'secure: isProduction()'; staging must get a Secure cookie too"
fi

# Go (net/http http.Cookie, go test).
check_cookie_settings "$GO_DOC" 'http.Cookie{' \
  'HttpOnly:[[:space:]]*true' \
  'SameSite:[[:space:]]*http\.SameSite(Lax|Strict)Mode' \
  'Secure:[^,]*!=[[:space:]]*"development"' \
  'Secure:[^,]*production' \
  'SameSiteNoneMode'
check_cookie_test "$GO_DOC" 'func TestSessionCookieIsSecureInStaging(' \
  '\.Secure([^a-z0-9_]|$)' \
  '\.HttpOnly([^a-z0-9_]|$)'
go_test_block=$(print_blocks_containing "$GO_DOC" 'func TestSessionCookieIsSecureInStaging(')
if [ -n "$go_test_block" ]; then
  require_pattern "$GO_DOC" "$go_test_block" 't\.(Error|Errorf|Fatal|Fatalf)\(' \
    "cookie test 'func TestSessionCookieIsSecureInStaging(' never fails the test (no t.Error/t.Errorf/t.Fatal/t.Fatalf call)"
fi

# Ruby (Rails signed cookie, RSpec request spec).
check_cookie_settings "$RUBY_DOC" 'cookies.signed[:session_token]' \
  'httponly:[[:space:]]*true' \
  'same_site:[[:space:]]*:(lax|strict)' \
  'secure:[^,]*(!|not )[^,]*development' \
  'secure:[^,]*production' \
  'same_site:[[:space:]]*:none'
check_cookie_test "$RUBY_DOC" 'RSpec.describe "session cookie"' \
  'expect\(.*secure' \
  'expect\(.*httponly'

[ "$fail" -eq 0 ] && echo "convention-cookie-examples.test.sh PASS"
exit "$fail"
