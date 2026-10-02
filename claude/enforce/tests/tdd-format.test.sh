#!/usr/bin/env bash
# Shard: slow
# Verifies `.enforce.json`'s testFormatCommand in enforce/tdd.sh (I2, IAN-568).
# red formats the named test before hashing it, so a later reformat by the
# same formatter (a pre-commit hook) before green is not read as a change,
# while a real edit to the locked test still is. A value holding a shell
# operator is refused (R-109 r1 #4). Drives the bash *.test.sh
# runner through the real run-fixture-shards.sh in a throwaway repository.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"

P=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd /; rm -rf "$P"' EXIT
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
mkdir -p "$P/tests" "$P/scripts"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
# The formatter strips trailing whitespace in place.
printf '#!/usr/bin/env bash\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$P/scripts/fmt.sh"
jq -n '{testFormatCommand: "bash scripts/fmt.sh"}' > "$P/.enforce.json"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

# lock_field <jq filter>: reads one field of the slice lock.
lock_field() { jq -r "$1" .claude/tdd-lock.json; }
# file_sha <path>: the sha256 of a file.
file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
# expect_fail <label> <command...>: runs the command, fails the fixture when it
# exits zero, and prints its output.
expect_fail() {
  local label="$1" out; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}

# --- red formats before hashing; the same formatter later changes nothing ----
bash "$TDD" open "F-1 trim.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/trim.sh")  \n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "trim.test.sh PASS"\n' > tests/trim.test.sh
bash "$TDD" red tests/trim.test.sh >/dev/null || { echo "FAIL: red with a testFormatCommand must succeed"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/trim.test.sh)" ] || { echo "FAIL: red must record the hash of the file as it left red"; exit 1; }
# The pre-commit hook runs the same formatter before green.
bash scripts/fmt.sh tests/trim.test.sh
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/trim.test.sh)" ] || { echo "FAIL: red must record the formatted hash, so the same formatter changes nothing afterwards"; exit 1; }
printf '#!/usr/bin/env bash\necho ok\n' > scripts/trim.sh
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept a test the same formatter reformatted after red; output: $out"; exit 1; }
echo "PASS: a reformat by the same formatter before green does not trip the hash check"

# --- a real edit to the locked test still trips it ---------------------------
printf 'echo changed\n' >> tests/trim.test.sh
expect_fail "green after a semantic edit" bash "$TDD" green | grep -q 'changed since RED' || { echo "FAIL: green must refuse a locked test changed beyond formatting"; exit 1; }
echo "PASS: a semantic edit to the locked test still trips the hash check"

# --- a value holding a shell operator is refused (R-109 r1 #4) ---------------
# The key runs under bash -c, so it may name one formatter and its flags only;
# a refused value warns, formats nothing, and leaves the hash byte-exact.
rm -f .claude/tdd-lock.json
jq -n '{testFormatCommand: "bash scripts/fmt.sh; touch injected"}' > .enforce.json
bash "$TDD" open "F-2 pad.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/pad.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "pad.test.sh PASS"\n' > tests/pad.test.sh
out=$(bash "$TDD" red tests/pad.test.sh 2>&1) || { echo "FAIL: red with a refused testFormatCommand must still succeed; output: $out"; exit 1; }
grep -q 'testFormatCommand is refused' <<< "$out" || { echo "FAIL: red must warn that the testFormatCommand is refused; output: $out"; exit 1; }
[ ! -e injected ] || { echo "FAIL: a refused testFormatCommand must not run"; exit 1; }
grep -q '[[:space:]]$' tests/pad.test.sh || { echo "FAIL: a refused testFormatCommand must leave the test unformatted"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: a refused testFormatCommand must leave the hash byte-exact"; exit 1; }
echo "PASS: a testFormatCommand holding a shell operator is refused and hashing stays byte-exact"

echo "tdd-format.test.sh PASS"
