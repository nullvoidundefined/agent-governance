#!/usr/bin/env bash
# Shard: slow
# Verifies `.enforce.json`'s testFormatCommand in enforce/tdd.sh (I2, IAN-568).
# red formats the named test before hashing it, so a later reformat by the
# same formatter (a pre-commit hook) before green is not read as a change,
# while a real edit to the locked test still is. A value holding a shell
# operator is refused (R-109 r1 #4), and the formatted copy green hashes
# matches no test glob (R-109 r1 #5). Drives the bash *.test.sh
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

# --- the formatted copy matches no test glob (R-109 r1 #5) -------------------
# green formats a copy of a reformatted test beside it; an interrupted run that
# left a copy named after the test would be collected as a passing duplicate.
# The formatter here logs the basename of every file it formats.
rm -f .claude/tdd-lock.json tests/pad.test.sh
printf '#!/usr/bin/env bash\nfor f in "$@"; do basename "$f" >> "$(dirname "$0")/../fmt.log"; done\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > scripts/fmtlog.sh
jq -n '{testFormatCommand: "bash scripts/fmtlog.sh"}' > .enforce.json
bash "$TDD" open "F-3 copy.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/copy.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "copy.test.sh PASS"\n' > tests/copy.test.sh
bash "$TDD" red tests/copy.test.sh >/dev/null || { echo "FAIL: red with the logging formatter must succeed"; exit 1; }
perl -pi -e 's/$/ /' tests/copy.test.sh
printf '#!/usr/bin/env bash\necho ok\n' > scripts/copy.sh
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept the reformatted test; output: $out"; exit 1; }
copyNames=$(grep -v '^copy\.test\.sh$' fmt.log || true)
[ -n "$copyNames" ] || { echo "FAIL: green must format a copy of the reformatted test; log: $(cat fmt.log)"; exit 1; }
while IFS= read -r copyName; do
  grep -qE '^tddfmt_[0-9]+\.sh$' <<< "$copyName" || { echo "FAIL: the formatted copy is named tddfmt_<pid>.<ext>, got $copyName"; exit 1; }
  case "$copyName" in
    test_*.py | *_test.py | *.test.* | *.spec.*) echo "FAIL: the formatted copy $copyName matches a test glob"; exit 1 ;;
  esac
done <<< "$copyNames"
[ -z "$(find tests -name 'tddfmt_*')" ] || { echo "FAIL: green must remove the formatted copy"; exit 1; }
echo "PASS: the formatted copy matches no test glob and is removed"

# --- an interrupted green removes the copy (R-109 r1 #5) ----------------------
# The formatter stalls on the copy; terminating green's process group mid-format
# must still remove it through the trap.
rm -f .claude/tdd-lock.json fmt.log
printf '#!/usr/bin/env bash\ncase "$(basename "$1")" in tddfmt_*) sleep 20 ;; esac\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > scripts/slowfmt.sh
jq -n '{testFormatCommand: "bash scripts/slowfmt.sh"}' > .enforce.json
bash "$TDD" open "F-4 stall.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \n[ "$(bash "$(dirname "$0")/../scripts/stall.sh")" = ok ] || { echo "FAIL: expected ok"; exit 1; }\n' > tests/stall.test.sh
bash "$TDD" red tests/stall.test.sh >/dev/null || { echo "FAIL: red with the stalling formatter must succeed"; exit 1; }
perl -pi -e 's/$/ /' tests/stall.test.sh
printf '#!/usr/bin/env bash\necho ok\n' > scripts/stall.sh
set -m; bash "$TDD" green >/dev/null 2>&1 & greenPid=$!; set +m
for _ in $(seq 1 100); do [ -n "$(find tests -name 'tddfmt_*')" ] && break; sleep 0.1; done
[ -n "$(find tests -name 'tddfmt_*')" ] || { echo "FAIL: green never wrote the formatted copy"; exit 1; }
kill -TERM -- "-$greenPid" 2>/dev/null || true
wait "$greenPid" 2>/dev/null || true
for _ in $(seq 1 30); do [ -z "$(find tests -name 'tddfmt_*')" ] && break; sleep 0.1; done
[ -z "$(find tests -name 'tddfmt_*')" ] || { echo "FAIL: a terminated green must remove the formatted copy"; exit 1; }
echo "PASS: a terminated green removes the formatted copy"

echo "tdd-format.test.sh PASS"
