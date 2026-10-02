#!/usr/bin/env bash
# Shard: slow
# Verifies `.enforce.json`'s testFormatCommand in enforce/tdd.sh (I2, IAN-568).
# red formats the named test before hashing it, so a later reformat by the
# same formatter (a pre-commit hook) before green is not read as a change,
# while a real edit to the locked test still is. A value holding a shell
# operator or metacharacter, a program outside the formatter allowlist by its
# exact on-disk name, a wrong subcommand, a positional word, or a path outside
# node_modules/.bin/ and .venv/bin/ is refused with nothing executed (R-109
# r1 #4, r2 #1, r4 #1 #2), as is an entry that
# resolves through a link into the repository outside node_modules/ and
# .venv/ or onto a launcher (R-109 r3 #2), and the formatted copy
# green hashes matches no test glob (R-109 r1 #5), lives in a fresh scratch
# directory made with mkdir, and never writes through a symlink planted at
# its old or a predictable path, a FIFO or /dev/null target included (R-109
# r2 #2, r3 #1). Drives the bash *.test.sh runner through the real
# run-fixture-shards.sh in a throwaway repository.
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
printf '#!/usr/bin/env bash\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$P/node_modules/.bin/shfmt"
chmod +x "$P/node_modules/.bin/shfmt"
jq -n '{testFormatCommand: "node_modules/.bin/shfmt"}' > "$P/.enforce.json"
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
node_modules/.bin/shfmt tests/trim.test.sh
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
jq -n '{testFormatCommand: "node_modules/.bin/shfmt; touch injected"}' > .enforce.json
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
# The formatter here logs the root-relative path of every file it formats.
rm -f .claude/tdd-lock.json tests/pad.test.sh
printf '#!/usr/bin/env bash\nfor f in "$@"; do printf "%%s\\n" "$f" >> fmt.log; done\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/isort
chmod +x node_modules/.bin/isort
jq -n '{testFormatCommand: "node_modules/.bin/isort"}' > .enforce.json
bash "$TDD" open "F-3 copy.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/copy.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "copy.test.sh PASS"\n' > tests/copy.test.sh
bash "$TDD" red tests/copy.test.sh >/dev/null || { echo "FAIL: red with the logging formatter must succeed"; exit 1; }
perl -pi -e 's/$/ /' tests/copy.test.sh
printf '#!/usr/bin/env bash\necho ok\n' > scripts/copy.sh
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept the reformatted test; output: $out"; exit 1; }
copyNames=$(grep -v '^tests/copy\.test\.sh$' fmt.log || true)
[ -n "$copyNames" ] || { echo "FAIL: green must format a copy of the reformatted test; log: $(cat fmt.log)"; exit 1; }
while IFS= read -r copyName; do
  grep -qE '^tests/\.tddfmt_[0-9]+_[0-9]+/tddfmt\.sh$' <<< "$copyName" || { echo "FAIL: the formatted copy is tests/.tddfmt_<pid>_<random>/tddfmt.<ext>, got $copyName"; exit 1; }
  case "$(basename "$copyName")" in
    test_*.py | *_test.py | *.test.* | *.spec.*) echo "FAIL: the formatted copy $copyName matches a test glob"; exit 1 ;;
  esac
done <<< "$copyNames"
[ -z "$(find tests -name '.tddfmt_*')" ] || { echo "FAIL: green must remove the scratch directory"; exit 1; }
echo "PASS: the formatted copy matches no test glob and is removed"

# --- an interrupted green removes the copy (R-109 r1 #5) ----------------------
# The formatter stalls on the copy; terminating green's process group mid-format
# must still remove it through the trap.
rm -f .claude/tdd-lock.json fmt.log
printf '#!/usr/bin/env bash\ncase "$(basename "$1")" in tddfmt.*) sleep 20 ;; esac\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/yapf
chmod +x node_modules/.bin/yapf
jq -n '{testFormatCommand: "node_modules/.bin/yapf"}' > .enforce.json
bash "$TDD" open "F-4 stall.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \n[ "$(bash "$(dirname "$0")/../scripts/stall.sh")" = ok ] || { echo "FAIL: expected ok"; exit 1; }\n' > tests/stall.test.sh
bash "$TDD" red tests/stall.test.sh >/dev/null || { echo "FAIL: red with the stalling formatter must succeed"; exit 1; }
perl -pi -e 's/$/ /' tests/stall.test.sh
printf '#!/usr/bin/env bash\necho ok\n' > scripts/stall.sh
set -m; bash "$TDD" green >/dev/null 2>&1 & greenPid=$!; set +m
for _ in $(seq 1 100); do [ -n "$(find tests -name '.tddfmt_*')" ] && break; sleep 0.1; done
[ -n "$(find tests -name '.tddfmt_*')" ] || { echo "FAIL: green never made the scratch directory"; exit 1; }
kill -TERM -- "-$greenPid" 2>/dev/null || true
wait "$greenPid" 2>/dev/null || true
for _ in $(seq 1 30); do [ -z "$(find tests -name '.tddfmt_*')" ] && break; sleep 0.1; done
[ -z "$(find tests -name '.tddfmt_*')" ] || { echo "FAIL: a terminated green must remove the scratch directory"; exit 1; }
echo "PASS: a terminated green removes the formatted copy"

# --- only an allowlisted formatter runs (R-109 r2 #1, r4 #1 #2) ---------------
# The value is split into words and run as an argument vector, never through a
# shell. Its program must be one of the allowlisted formatters by the exact
# name of its on-disk directory entry (a case-insensitive filesystem resolves
# `Node` to node and `BASH` to bash), ruff and biome take `format` and dprint
# `fmt` as their first argument, and every other word is an option naming no
# path. Anything else is refused: nothing runs, the test stays unformatted,
# and the hash stays byte-exact. Each refused program would create the marker
# file `injected` if it ran. The stalled test above prints no PASS line, so it
# leaves the suite.
rm -f .claude/tdd-lock.json fmt.log tests/stall.test.sh
# write_trim_stub <path>: writes an executable formatter stub that strips
# trailing whitespace from every argument naming an existing file, skipping
# options and subcommands the way a real formatter consumes them.
write_trim_stub() {
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ -f "$a" ] && perl -pi -e '"'"'s/[ \\t]+$//'"'"' "$a"; done\nexit 0\n' > "$1"
  chmod +x "$1"
}
printf '#!/usr/bin/env bash\ntouch injected\n' > scripts/fmt.sh
chmod +x scripts/fmt.sh
printf 'open("injected", "w")\n' > scripts/inject.py
printf 'open("injected", "w")\n' > x.py
printf 'open(my $f, ">", "injected");\n' > x
printf 'require("fs").writeFileSync("injected", "");\n' > scripts/fmt.js
for runner in npx go bundle pipenv; do
  printf '#!/usr/bin/env bash\ntouch injected\n' > "$B/$runner"
  chmod +x "$B/$runner"
done
printf '#!/usr/bin/env bash\ntouch injected\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > "$B/marker"
chmod +x "$B/marker"
write_trim_stub "$B/black"
write_trim_stub "$B/ruff"
# R-109 r3 #2: an allowlisted entry in an allowed directory that links into
# the repository outside node_modules/ and .venv/, an allowlisted bare name on
# PATH that links into the repository, and a hook manager or TypeScript
# launcher are refused too.
mkdir -p .venv/bin
printf '#!/usr/bin/env bash\ntouch injected\n' > scripts/x.sh
chmod +x scripts/x.sh
ln -s ../../scripts/x.sh node_modules/.bin/rustfmt
ln -s "$P/scripts/x.sh" "$B/goimports"
printf '#!/usr/bin/env bash\ntouch injected\n' > .venv/bin/pre-commit
printf '#!/usr/bin/env bash\ntouch injected\n' > node_modules/.bin/tsx
chmod +x .venv/bin/pre-commit node_modules/.bin/tsx
refusedValues=(
  "bash -c 'touch injected' --"
  "env touch injected"
  "X=1 marker"
  "python3 scripts/inject.py"
  "scripts/fmt.sh"
  "npx prettier --write"
  "node_modules/.bin/../../scripts/fmt.sh"
  "node_modules/.bin/rustfmt"
  "goimports"
  ".venv/bin/pre-commit"
  "node_modules/.bin/tsx"
  "Node scripts/fmt.js"
  "BASH scripts/x.sh"
  "Perl x"
  "go run ./scripts/fmt"
  "bundle exec rubocop -A"
  "pipenv run python3 x.py"
  "ruff check --fix"
  "black scripts/x.py"
  "black x"
  "Black -q"
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
echo "PASS: a program outside the formatter allowlist (by exact on-disk name), a wrong subcommand, a positional word, an assignment, a repository script, or a link into the repository as testFormatCommand is refused with nothing executed"

# An allowlisted stub in node_modules/.bin/, a node_modules/.bin/ link into a
# package under node_modules/ (how npm installs a bin; the allowlist reads the
# .bin entry's own name), and bare allowlisted stubs on PATH with their
# required subcommand and options are accepted and run.
write_trim_stub node_modules/.bin/gofmt
mkdir -p node_modules/prettier/bin
write_trim_stub node_modules/prettier/bin/prettier.cjs
ln -s ../prettier/bin/prettier.cjs node_modules/.bin/prettier
for acceptedValue in "node_modules/.bin/gofmt" "node_modules/.bin/prettier --write" "black -q" "ruff format"; do
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
echo "PASS: an allowlisted formatter in node_modules/.bin/, a bin link into node_modules/, and bare allowlisted formatters on PATH are accepted and run"

# --- the formatted copy never follows a planted symlink (R-109 r2 #2, r3 #1) --
# Bash noclobber opens a link to an existing non-regular file (a FIFO,
# /dev/null) through, so the old copy path, removed and then recreated beside
# the test, could be written through by a link raced into that window. Stubs
# for rm and mkdir, on PATH for the green call only, delegate to the real
# tools and plant links deterministically: S/rm plants a link at any removed
# path named like the old copy (tests/tddfmt_<pid>.<ext>), the race window
# itself; S/mkdir plants per $PLANT_MODE. Links at the old path are also
# planted ahead for the PID range the next processes take.
S=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd /; rm -rf "$P" "$B" "$S"' EXIT
printf '#!/usr/bin/env bash\n/bin/rm "$@"; status=$?\nfor a in "$@"; do case "$a" in */tddfmt_*) [ -z "${PLANT_TARGET:-}" ] || ln -s "$PLANT_TARGET" "$a" 2>/dev/null ;; esac; done\nexit $status\n' > "$S/rm"
printf '#!/usr/bin/env bash\nlast="${!#}"\ncase "$last:${PLANT_MODE:-}" in\n  */.tddfmt_*:collide) [ -e "$PLANT_ONCE" ] || { : > "$PLANT_ONCE"; ln -s "$PLANT_TARGET" "$last"; } ;;\nesac\n/bin/mkdir "$@"; status=$?\ncase "$last:${PLANT_MODE:-}" in\n  */.tddfmt_*:inside) [ $status -ne 0 ] || ln -s "$PLANT_TARGET" "$last/tddfmt.sh" ;;\nesac\nexit $status\n' > "$S/mkdir"
chmod +x "$S/rm" "$S/mkdir"
printf 'sentinel\n' > sentinel.txt
mkfifo fifo
mkdir outside
printf '#!/usr/bin/env bash\nfor f in "$@"; do printf "%%s\\n" "$f" >> fmt.log; done\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' > node_modules/.bin/isort
chmod +x node_modules/.bin/isort
jq -n '{testFormatCommand: "node_modules/.bin/isort"}' > .enforce.json

# prepare_reformatted_slice <name>: opens a slice for tests/<name>.test.sh,
# records RED, then reformats the test the way a pre-commit hook would.
prepare_reformatted_slice() {
  rm -f .claude/tdd-lock.json fmt.log
  bash "$TDD" open "F-7 $1.sh prints ok" >/dev/null
  printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/%s.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "%s.test.sh PASS"\n' "$1" "$1" > "tests/$1.test.sh"
  bash "$TDD" red "tests/$1.test.sh" >/dev/null || { echo "FAIL: red for the $1 case must succeed"; exit 1; }
  perl -pi -e 's/$/ /' "tests/$1.test.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "scripts/$1.sh"
}
# run_green_watched <out file> [env assignments...]: runs green with the stubs
# on PATH in its own process group and kills the group after 20 seconds, so a
# write blocked on a FIFO fails the fixture instead of hanging it; prints
# green's exit status, or "timeout".
run_green_watched() {
  local outFile="$1" greenPid; shift
  set -m; env "$@" PATH="$S:$PATH" bash "$TDD" green > "$outFile" 2>&1 & greenPid=$!; set +m
  for _ in $(seq 1 200); do kill -0 "$greenPid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$greenPid" 2>/dev/null; then
    kill -TERM -- "-$greenPid" 2>/dev/null || true; wait "$greenPid" 2>/dev/null || true; echo timeout; return 0
  fi
  local status=0; wait "$greenPid" || status=$?; echo "$status"
}
# remove_planted_links: deletes every link left at the old copy path.
remove_planted_links() { find tests -name 'tddfmt_*' -type l -exec /bin/rm -f {} +; }

# A link to a FIFO raced in at the old path: a reader on the FIFO captures
# anything written through it.
prepare_reformatted_slice fifolink
perl -e 'alarm 25; open(my $f, "<", $ARGV[0]) or exit; print while <$f>' fifo > captured.txt & readerPid=$!
nextPid=$(bash -c 'echo $$')
perl -e 'symlink("../fifo", "tests/tddfmt_$_.sh") for $ARGV[0] .. $ARGV[0] + 50' "$nextPid"
status=$(run_green_watched green.out PLANT_TARGET="$P/fifo")
kill "$readerPid" 2>/dev/null || true; wait "$readerPid" 2>/dev/null || true
[ ! -s captured.txt ] || { echo "FAIL: the formatted copy was written through a link to a FIFO; the reader captured: $(head -c 200 captured.txt)"; exit 1; }
[ "$status" = 0 ] || { echo "FAIL: green must accept the reformatted test with FIFO links planted (status $status); output: $(cat green.out)"; exit 1; }
[ -p fifo ] || { echo "FAIL: the FIFO must be left in place"; exit 1; }
remove_planted_links; rm -f tests/fifolink.test.sh captured.txt
echo "PASS: the formatted copy never writes through a link to a FIFO planted at its old path"

# A link to /dev/null and one to a regular sentinel raced in at the old path.
for target in /dev/null "$P/sentinel.txt"; do
  case "$target" in /dev/null) slice=devnull ;; *) slice=sentinellink ;; esac
  prepare_reformatted_slice "$slice"
  nextPid=$(bash -c 'echo $$')
  perl -e 'symlink($ARGV[1], "tests/tddfmt_$_.sh") for $ARGV[0] .. $ARGV[0] + 50' "$nextPid" "$target"
  status=$(run_green_watched green.out PLANT_TARGET="$target")
  [ "$status" = 0 ] || { echo "FAIL: green must accept the reformatted test with links to $target planted (status $status); output: $(cat green.out)"; exit 1; }
  [ "$(cat sentinel.txt)" = sentinel ] || { echo "FAIL: the formatted copy wrote through a planted link; sentinel now: $(head -c 200 sentinel.txt)"; exit 1; }
  [ -c /dev/null ] || { echo "FAIL: /dev/null must stay a character device"; exit 1; }
  if grep -q '^tests/tddfmt_' fmt.log; then echo "FAIL: the formatter must never run on the old copy path; log: $(cat fmt.log)"; exit 1; fi
  remove_planted_links; rm -f "tests/$slice.test.sh"
done
echo "PASS: the formatted copy never writes through a link to /dev/null or a regular file planted at its old path"

# A link planted at the scratch directory's own name before mkdir runs: mkdir
# fails on it without following it, and green retries under a new name.
prepare_reformatted_slice collide
status=$(run_green_watched green.out PLANT_MODE=collide PLANT_TARGET="$P/outside" PLANT_ONCE="$P/plant.once")
[ "$status" = 0 ] || { echo "FAIL: green must retry past a taken scratch name (status $status); output: $(cat green.out)"; exit 1; }
[ -e plant.once ] || { echo "FAIL: the collision was never planted, so the case proved nothing"; exit 1; }
[ -z "$(ls -A outside)" ] || { echo "FAIL: mkdir followed the planted link into outside/: $(ls -A outside)"; exit 1; }
[ "$(find tests -name '.tddfmt_*' -type l | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: the planted link must be left alone, never reused or removed by the trap"; exit 1; }
[ -z "$(find tests -name '.tddfmt_*' -type d)" ] || { echo "FAIL: green must remove its own scratch directory"; exit 1; }
find tests -name '.tddfmt_*' -type l -exec /bin/rm -f {} +; rm -f tests/collide.test.sh plant.once
echo "PASS: a link at the scratch directory's name is never followed or reused"

# A link to /dev/null raced in inside the fresh scratch directory: the
# post-create check refuses the copy, nothing is formatted or hashed through
# it, and green fails closed on the byte-exact hash.
prepare_reformatted_slice inside
status=$(run_green_watched green.out PLANT_MODE=inside PLANT_TARGET=/dev/null)
[ "$status" != 0 ] && [ "$status" != timeout ] || { echo "FAIL: green must fail closed when the copy is not a regular file (status $status); output: $(cat green.out)"; exit 1; }
grep -q 'changed since RED' green.out || { echo "FAIL: green must fall back to the byte-exact hash; output: $(cat green.out)"; exit 1; }
if grep -q '/tddfmt\.sh$' fmt.log; then echo "FAIL: the formatter must never run on a copy that is a link; log: $(cat fmt.log)"; exit 1; fi
[ -c /dev/null ] || { echo "FAIL: /dev/null must stay a character device"; exit 1; }
[ -z "$(find tests -name '.tddfmt_*')" ] || { echo "FAIL: green must remove its scratch directory after refusing the copy"; exit 1; }
rm -f .claude/tdd-lock.json tests/inside.test.sh fmt.log green.out
echo "PASS: a copy that is not a regular file is never formatted or hashed, and green fails closed"

echo "tdd-format.test.sh PASS"
