#!/usr/bin/env bash
# Shard: slow
# Verifies `.enforce.json`'s testFormatCommand in enforce/tdd.sh (I2, IAN-568).
# red formats the named test before hashing it, so a later reformat by the
# same formatter (a pre-commit hook) before green is not read as a change,
# while a real edit to the locked test still is. A value holding a shell
# operator or metacharacter, or naming a shell, interpreter, launcher,
# package runner, or a path outside node_modules/.bin/ and .venv/bin/, is
# refused with nothing executed (R-109 r1 #4, r2 #1), and the formatted copy
# green hashes matches no test glob (R-109 r1 #5) and never writes through a
# symlink planted at its path (R-109 r2 #2). Drives the bash *.test.sh
# runner through the real run-fixture-shards.sh in a throwaway repository.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"

P=$(cd "$(mktemp -d)" && pwd -P)
# B holds bare formatter stubs on PATH, outside the repository.
B=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd /; rm -rf "$P" "$B"' EXIT
export PATH="$B:$PATH"
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
mkdir -p "$P/tests" "$P/scripts" "$P/node_modules/.bin"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
# The formatter strips trailing whitespace in place.
printf '#!/usr/bin/env bash\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$P/node_modules/.bin/fmt"
chmod +x "$P/node_modules/.bin/fmt"
jq -n '{testFormatCommand: "node_modules/.bin/fmt"}' > "$P/.enforce.json"
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
node_modules/.bin/fmt tests/trim.test.sh
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/trim.test.sh)" ] || { echo "FAIL: red must record the formatted hash, so the same formatter changes nothing afterwards"; exit 1; }
printf '#!/usr/bin/env bash\necho ok\n' > scripts/trim.sh
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept a test the same formatter reformatted after red; output: $out"; exit 1; }
echo "PASS: a reformat by the same formatter before green does not trip the hash check"

# --- a real edit to the locked test still trips it ---------------------------
printf 'echo changed\n' >> tests/trim.test.sh
expect_fail "green after a semantic edit" bash "$TDD" green | grep -q 'changed since RED' || { echo "FAIL: green must refuse a locked test changed beyond formatting"; exit 1; }
echo "PASS: a semantic edit to the locked test still trips the hash check"

# --- a value holding a shell operator is refused (R-109 r1 #4) ---------------
# The key names one formatter binary and its flags only; a refused value
# warns, formats nothing, and leaves the hash byte-exact.
rm -f .claude/tdd-lock.json
jq -n '{testFormatCommand: "node_modules/.bin/fmt; touch injected"}' > .enforce.json
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
printf '#!/usr/bin/env bash\nfor f in "$@"; do basename "$f" >> fmt.log; done\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/fmtlog
chmod +x node_modules/.bin/fmtlog
jq -n '{testFormatCommand: "node_modules/.bin/fmtlog"}' > .enforce.json
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
printf '#!/usr/bin/env bash\ncase "$(basename "$1")" in tddfmt_*) sleep 20 ;; esac\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/slowfmt
chmod +x node_modules/.bin/slowfmt
jq -n '{testFormatCommand: "node_modules/.bin/slowfmt"}' > .enforce.json
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

# --- only a formatter binary named directly runs (R-109 r2 #1) ---------------
# The value is split into words and run as an argument vector, never through a
# shell. A shell, interpreter, launcher, or package runner as the program, an
# assignment before it, or a path outside node_modules/.bin/ and .venv/bin/
# (a repository script the session could edit) is refused: nothing runs, the
# test stays unformatted, and the hash stays byte-exact. Each refused program
# would create the marker file `injected` if it ran. The stalled test above
# prints no PASS line, so it leaves the suite.
rm -f .claude/tdd-lock.json fmt.log tests/stall.test.sh
printf '#!/usr/bin/env bash\ntouch injected\n' > scripts/fmt.sh
chmod +x scripts/fmt.sh
printf 'open("injected", "w")\n' > scripts/inject.py
printf '#!/usr/bin/env bash\ntouch injected\n' > "$B/npx"
printf '#!/usr/bin/env bash\ntouch injected\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$B/marker"
chmod +x "$B/npx" "$B/marker"
refusedValues=(
  "bash -c 'touch injected' --"
  "env touch injected"
  "X=1 marker"
  "python3 scripts/inject.py"
  "scripts/fmt.sh"
  "npx prettier --write"
  "node_modules/.bin/../../scripts/fmt.sh"
)
for refusedValue in "${refusedValues[@]}"; do
  rm -f .claude/tdd-lock.json injected tests/pad.test.sh
  jq -n --arg c "$refusedValue" '{testFormatCommand: $c}' > .enforce.json
  bash "$TDD" open "F-5 pad.sh prints ok" >/dev/null
  printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/pad.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "pad.test.sh PASS"\n' > tests/pad.test.sh
  out=$(bash "$TDD" red tests/pad.test.sh 2>&1) || { echo "FAIL: red with the refused testFormatCommand [$refusedValue] must still succeed; output: $out"; exit 1; }
  [ ! -e injected ] || { echo "FAIL: the refused testFormatCommand [$refusedValue] must not run"; exit 1; }
  grep -q 'testFormatCommand is refused' <<< "$out" || { echo "FAIL: red must warn that [$refusedValue] is refused; output: $out"; exit 1; }
  grep -q '[[:space:]]$' tests/pad.test.sh || { echo "FAIL: the refused testFormatCommand [$refusedValue] must leave the test unformatted"; exit 1; }
  [ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: the refused testFormatCommand [$refusedValue] must leave the hash byte-exact"; exit 1; }
done
echo "PASS: a shell, interpreter, launcher, package runner, assignment, or repository script as testFormatCommand is refused with nothing executed"

# A stub in node_modules/.bin/ and a bare stub on PATH are accepted and run.
printf '#!/usr/bin/env bash\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/fakefmt
printf '#!/usr/bin/env bash\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$B/barefmt"
chmod +x node_modules/.bin/fakefmt "$B/barefmt"
for acceptedValue in "node_modules/.bin/fakefmt" "barefmt"; do
  rm -f .claude/tdd-lock.json tests/pad.test.sh
  jq -n --arg c "$acceptedValue" '{testFormatCommand: $c}' > .enforce.json
  bash "$TDD" open "F-6 pad.sh prints ok" >/dev/null
  printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/pad.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "pad.test.sh PASS"\n' > tests/pad.test.sh
  out=$(bash "$TDD" red tests/pad.test.sh 2>&1) || { echo "FAIL: red with testFormatCommand [$acceptedValue] must succeed; output: $out"; exit 1; }
  if grep -q 'testFormatCommand is refused' <<< "$out"; then echo "FAIL: [$acceptedValue] must be accepted; output: $out"; exit 1; fi
  if grep -q '[[:space:]]$' tests/pad.test.sh; then echo "FAIL: [$acceptedValue] must run and format the test"; exit 1; fi
  [ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: red must hash the test [$acceptedValue] formatted"; exit 1; }
done
rm -f .claude/tdd-lock.json tests/pad.test.sh
echo "PASS: a formatter in node_modules/.bin/ and a bare formatter on PATH are accepted and run"

# --- the formatted copy never follows a planted symlink (R-109 r2 #2) --------
# green writes its copy at tests/tddfmt_<pid>.<ext>; a symlink planted at that
# path must not let the copy truncate or overwrite the link's target. Links
# are planted for the PID range the next processes take, pointing at a
# sentinel outside the test tree.
rm -f .claude/tdd-lock.json
printf 'sentinel\n' > sentinel.txt
jq -n '{testFormatCommand: "node_modules/.bin/fmt"}' > .enforce.json
bash "$TDD" open "F-7 link.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/link.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "link.test.sh PASS"\n' > tests/link.test.sh
bash "$TDD" red tests/link.test.sh >/dev/null || { echo "FAIL: red for the symlink case must succeed"; exit 1; }
perl -pi -e 's/$/ /' tests/link.test.sh
printf '#!/usr/bin/env bash\necho ok\n' > scripts/link.sh
# One perl process plants every link, so planting consumes no PIDs itself.
nextPid=$(bash -c 'echo $$')
perl -e 'symlink("../sentinel.txt", "tests/tddfmt_$_.sh") or die "symlink: $!" for $ARGV[0] .. $ARGV[0] + 2000' "$nextPid"
linksBefore=$(find tests -name 'tddfmt_*' -type l | wc -l)
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept the reformatted test with links planted; output: $out"; exit 1; }
linksAfter=$(find tests -name 'tddfmt_*' -type l | wc -l)
[ "$(cat sentinel.txt)" = sentinel ] || { echo "FAIL: the formatted copy must not write through a planted symlink; sentinel now: $(head -c 200 sentinel.txt)"; exit 1; }
[ "$linksAfter" -lt "$linksBefore" ] || { echo "FAIL: green's copy path was not among the planted links, so the case proved nothing"; exit 1; }
find tests -name 'tddfmt_*' -type l -delete
rm -f .claude/tdd-lock.json tests/link.test.sh
echo "PASS: the formatted copy never writes through a symlink planted at its path"

echo "tdd-format.test.sh PASS"
