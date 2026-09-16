#!/usr/bin/env bash
# Test harness for build-cheatsheets.sh (PreToolUse Bash, advisory tooling).
#
# The hook regenerates cheatsheet docs on `git push`, but only when the
# repo's origin URL is listed in enforce/gate-trusted-repos.txt and the
# repo ships an executable docs/features/build-all-cheatsheets.sh; the
# 2026-07-31 audit P1 it replaced auto-executed whatever script the cwd
# happened to contain. Fixtures prove the trust gate: the builder runs for
# a trusted origin (including through git global options, 2026-09-16 audit
# P2-1), and never for an untrusted origin or a non-push command. HOME is
# sandboxed so the trust list is fixture data, never the live config.
#
# Run: hooks/tests/build-cheatsheets.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../build-cheatsheets.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

TRUSTED_URL="https://example.invalid/trusted/cheatsheet-repo.git"
mkdir -p "$HOME/.claude/enforce"
printf '%s\n' "$TRUSTED_URL" >"$HOME/.claude/enforce/gate-trusted-repos.txt"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

setup_repo() { # dir, origin-url
  local dir="$1" origin="$2"
  mkdir -p "$dir/docs/features"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
  cat >"$dir/docs/features/build-all-cheatsheets.sh" <<'BUILDER'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/.cheatsheet-built"
BUILDER
  chmod +x "$dir/docs/features/build-all-cheatsheets.sh"
}

run_hook() { # repo-dir, command
  local dir="$1" cmd="$2"
  (cd "$dir" && jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
}

TRUSTED="$SANDBOX/trusted-repo"
UNTRUSTED="$SANDBOX/untrusted-repo"
setup_repo "$TRUSTED" "$TRUSTED_URL"
setup_repo "$UNTRUSTED" "https://example.invalid/other/repo.git"

OUT=$(run_hook "$TRUSTED" "git push origin main"); STATUS=$?
check "trusted push exits 0 and stays silent" test "$STATUS" -eq 0 -a -z "$OUT"
check "trusted push runs the builder" test -f "$TRUSTED/.cheatsheet-built"

rm -f "$TRUSTED/.cheatsheet-built"
run_hook "$TRUSTED" "git --no-pager push" >/dev/null
check "git global options do not bypass the trigger" test -f "$TRUSTED/.cheatsheet-built"

rm -f "$TRUSTED/.cheatsheet-built"
run_hook "$TRUSTED" "git status" >/dev/null
check "a non-push command never runs the builder" test ! -f "$TRUSTED/.cheatsheet-built"

run_hook "$UNTRUSTED" "git push origin main" >/dev/null
check "an untrusted origin never runs the builder" test ! -f "$UNTRUSTED/.cheatsheet-built"

[ "$fail" -eq 0 ] && echo "PASS: build-cheatsheets" || exit 1
