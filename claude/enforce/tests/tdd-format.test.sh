#!/usr/bin/env bash
# Shard: slow
# Verifies `.enforce.json`'s testFormatCommand in enforce/tdd.sh (I2, IAN-568).
# red formats the named test before hashing it, so the recorded hash is of the
# formatted content and a later run of the same formatter changes nothing.
# green is byte-exact and runs no formatter (R-109 r5): a test reformatted
# after red is refused as changed, and no formatter stub, session-written or
# earlier on PATH, can run during green. A value holding a shell operator or
# metacharacter, a program outside the formatter allowlist by its exact
# on-disk name, a wrong subcommand, a positional word, an option whose `=`
# value is a path, a configuration or plugin option, or a path outside
# node_modules/.bin/ and .venv/bin/ is refused at red with nothing executed
# (R-109 r1 #4, r2 #1, r4 #1 #2, r5 #3), as is an entry that resolves
# through a link into the repository outside node_modules/ and .venv/ or onto
# a launcher (R-109 r3 #2). Drives the bash *.test.sh runner through the real
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
formattedSha=$(perl -pe 's/[ \t]+$//' tests/trim.test.sh | shasum -a 256 | awk '{print $1}')
bash "$TDD" red tests/trim.test.sh >/dev/null || { echo "FAIL: red with a testFormatCommand must succeed"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$formattedSha" ] || { echo "FAIL: red must record the hash of the formatted content"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/trim.test.sh)" ] || { echo "FAIL: red must leave the test formatted on disk"; exit 1; }
# The pre-commit hook runs the same formatter before green.
node_modules/.bin/shfmt tests/trim.test.sh
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/trim.test.sh)" ] || { echo "FAIL: red must record the formatted hash, so the same formatter changes nothing afterwards"; exit 1; }
printf '#!/usr/bin/env bash\necho ok\n' > scripts/trim.sh
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: green must accept a test the same formatter left unchanged; output: $out"; exit 1; }
echo "PASS: red hashes the formatted content, and the same formatter afterwards changes nothing"

# --- green is byte-exact: a whitespace-only reformat after red is refused -----
# R-109 r5: no formatting tolerance at green, so a reformat by any formatter is
# a change; the session re-hashes with `tdd.sh amend`.
perl -pi -e 's/$/ /' tests/trim.test.sh
out=$(expect_fail "green after a whitespace-only reformat" bash "$TDD" green) || { echo "$out"; exit 1; }
grep -q 'changed since RED' <<< "$out" || { echo "FAIL: green must refuse a test reformatted after red as changed since RED; output: $out"; exit 1; }
perl -pi -e 's/[ \t]+$//' tests/trim.test.sh
echo "PASS: green refuses a whitespace-only reformat after red"

# --- a real edit to the locked test still trips it ---------------------------
printf 'echo changed\n' >> tests/trim.test.sh
expect_fail "green after a semantic edit" bash "$TDD" green | grep -q 'changed since RED' || { echo "FAIL: green must refuse a locked test changed beyond formatting"; exit 1; }
echo "PASS: a semantic edit to the locked test still trips the hash check"

# --- a value holding a shell operator is refused (R-109 r1 #4) ---------------
# The key names one formatter binary and its flags only; a refused value
# warns, formats nothing, and red hashes the file as it stands.
rm -f .claude/tdd-lock.json
jq -n '{testFormatCommand: "node_modules/.bin/shfmt; touch injected"}' > .enforce.json
bash "$TDD" open "F-2 pad.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/pad.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "pad.test.sh PASS"\n' > tests/pad.test.sh
out=$(bash "$TDD" red tests/pad.test.sh 2>&1) || { echo "FAIL: red with a refused testFormatCommand must still succeed; output: $out"; exit 1; }
grep -q 'testFormatCommand is refused' <<< "$out" || { echo "FAIL: red must warn that the testFormatCommand is refused; output: $out"; exit 1; }
[ ! -e injected ] || { echo "FAIL: a refused testFormatCommand must not run"; exit 1; }
grep -q '[[:space:]]$' tests/pad.test.sh || { echo "FAIL: a refused testFormatCommand must leave the test unformatted"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: a refused testFormatCommand must leave the hash of the file as it stands"; exit 1; }
echo "PASS: a testFormatCommand holding a shell operator is refused and red hashes the file as it stands"

# --- only an allowlisted formatter runs (R-109 r2 #1, r4 #1 #2) ---------------
# The value is split into words and run as an argument vector, never through a
# shell. Its program must be one of the allowlisted formatters by the exact
# name of its on-disk directory entry (a case-insensitive filesystem resolves
# `Node` to node and `BASH` to bash), ruff and biome take `format` and dprint
# `fmt` as their first argument, and every other word is an option naming no
# path. Anything else is refused: nothing runs, the test stays unformatted,
# and red hashes the test as it stands. Each refused program would create the
# marker file `injected` if it ran. An option word is checked whole and on its
# value after the first `=`, and a configuration or plugin option is refused
# outright (R-109 r5 #3).
rm -f .claude/tdd-lock.json tests/pad.test.sh
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
write_trim_stub "$B/prettier"
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
  "prettier --write --config=.prettierrc.js"
  "black --config=x.toml"
  "prettier --plugin=evil"
  "prettier --write --style=x"
  "black --settings-path=x"
  "black --config-path=x"
  "prettier --config"
  "prettier --ignore-path=x"
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
  [ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: the refused testFormatCommand [$refusedValue] must leave the hash of the file as it stands"; exit 1; }
done
echo "PASS: a program outside the formatter allowlist (by exact on-disk name), a wrong subcommand, a positional word, a configuration or plugin option, an option value naming a repository path, an assignment, a repository script, or a link into the repository as testFormatCommand is refused with nothing executed"

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

# --- a symlink cycle is refused promptly (R-109 r4 #3) -----------------------
# node_modules/.bin/black -> black2 -> black never resolves; red must warn and
# hash the file as it stands instead of looping. A watchdog kills red after 20 seconds so
# a loop fails the fixture instead of hanging it.
ln -s black2 node_modules/.bin/black
ln -s black node_modules/.bin/black2
jq -n '{testFormatCommand: "node_modules/.bin/black -q"}' > .enforce.json
bash "$TDD" open "F-6b pad.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/pad.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "pad.test.sh PASS"\n' > tests/pad.test.sh
set -m; bash "$TDD" red tests/pad.test.sh > cycle.out 2>&1 & redPid=$!; set +m
for _ in $(seq 1 200); do kill -0 "$redPid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$redPid" 2>/dev/null; then
  kill -TERM -- "-$redPid" 2>/dev/null || true; wait "$redPid" 2>/dev/null || true
  echo "FAIL: red must refuse a symlink-cycle testFormatCommand promptly, not loop"; exit 1
fi
wait "$redPid" || { echo "FAIL: red with a symlink-cycle testFormatCommand must still succeed; output: $(cat cycle.out)"; exit 1; }
grep -q 'testFormatCommand is refused' cycle.out || { echo "FAIL: red must warn that the symlink cycle is refused; output: $(cat cycle.out)"; exit 1; }
grep -q '[[:space:]]$' tests/pad.test.sh || { echo "FAIL: a symlink-cycle testFormatCommand must leave the test unformatted"; exit 1; }
[ "$(lock_field '.tests[0].sha256')" = "$(file_sha tests/pad.test.sh)" ] || { echo "FAIL: a symlink-cycle testFormatCommand must leave the hash of the file as it stands"; exit 1; }
rm -f .claude/tdd-lock.json tests/pad.test.sh cycle.out node_modules/.bin/black node_modules/.bin/black2
echo "PASS: a symlink cycle as testFormatCommand is refused promptly with nothing executed"

# --- green runs no formatter (R-109 r5) -------------------------------------
# red runs the bare `black` on PATH; afterwards the session replaces it with a
# stub that writes a marker, writes a node_modules/.bin/black that does the
# same, and puts an earlier PATH entry holding another. green must run none of
# them, whether the locked test is unchanged (accepted) or reformatted
# (refused as changed since RED).
E=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd /; rm -rf "$P" "$B" "$E"' EXIT
jq -n '{testFormatCommand: "black -q"}' > .enforce.json
bash "$TDD" open "F-8 nofmt.sh prints ok" >/dev/null
printf '#!/usr/bin/env bash   \nout=$(bash "$(dirname "$0")/../scripts/nofmt.sh")\n[ "$out" = ok ] || { echo "FAIL: expected ok, got $out"; exit 1; }\necho "nofmt.test.sh PASS"\n' > tests/nofmt.test.sh
bash "$TDD" red tests/nofmt.test.sh >/dev/null || { echo "FAIL: red with black -q must succeed"; exit 1; }
if grep -q '[[:space:]]$' tests/nofmt.test.sh; then echo "FAIL: red must run black and format the test"; exit 1; fi
for stub in "$B/black" "$P/node_modules/.bin/black" "$E/black"; do
  printf '#!/usr/bin/env bash\ntouch "%s/formatter-ran"\nperl -pi -e '"'"'s/[ \\t]+$//'"'"' "$@"\n' "$P" > "$stub"
  chmod +x "$stub"
done
printf '#!/usr/bin/env bash\necho ok\n' > scripts/nofmt.sh
out=$(PATH="$E:$PATH" bash "$TDD" green 2>&1) || { echo "FAIL: green must accept the unchanged test; output: $out"; exit 1; }
[ ! -e formatter-ran ] || { echo "FAIL: green must run no formatter on an unchanged test"; exit 1; }
perl -pi -e 's/$/ /' tests/nofmt.test.sh
out=$(PATH="$E:$PATH" expect_fail "green after a reformat with formatter stubs present" bash "$TDD" green) || { echo "$out"; exit 1; }
grep -q 'changed since RED' <<< "$out" || { echo "FAIL: green must refuse the reformatted test; output: $out"; exit 1; }
[ ! -e formatter-ran ] || { echo "FAIL: green must run no formatter, so no stub can make a reformatted test match"; exit 1; }
rm -f .claude/tdd-lock.json tests/nofmt.test.sh node_modules/.bin/black
echo "PASS: green runs no formatter, so neither a session-written node_modules/.bin/black nor an earlier PATH stub influences it"

echo "tdd-format.test.sh PASS"
