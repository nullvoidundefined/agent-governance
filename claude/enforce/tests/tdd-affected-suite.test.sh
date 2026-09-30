#!/usr/bin/env bash
# Shard: slow
# Verifies that enforce/tdd.sh runs bash fixtures in the runner's affected mode
# (IAN-510), not every fixture in the directory: red and green run the fast
# tier, each slow fixture a changed file names, the locked tests even when git
# no longer lists them as changed, and every fixture the RED run passed, so the
# baseline count compares like with like. CI still runs every fixture.
# Separate from tdd-red-green.test.sh because fixture-implementation-root runs
# that file and needs it to pass, which a RED case there can never satisfy.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

expect_fail() {
  local label="$1"; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}
# The RED fixture calls scripts/score.sh, which does not exist yet.
shell_red_test() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > "$1"
}
shell_impl() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > scripts/score.sh; }

MARKS=$(cd "$(mktemp -d)" && pwd -P)
P=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd / && rm -rf "$P" "$MARKS"' EXIT
cd "$P"
git init -q && git config user.email t@t && git config user.name t
mkdir -p tests scripts
printf '.claude/\n' > .gitignore
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > tests/baseline.test.sh
# slow-unrelated names nothing the slice changes; slow-notes names notes.txt.
printf '#!/usr/bin/env bash\n# Shard: slow\ntouch "%s/unrelated"\necho "slow-unrelated PASS"\n' "$MARKS" > tests/slow-unrelated.test.sh
printf '#!/usr/bin/env bash\n# Shard: slow\n# reads notes.txt\ntouch "%s/notes"\necho "slow-notes PASS"\n' "$MARKS" > tests/slow-notes.test.sh
printf 'seed\n' > notes.txt
git init -q --bare "$MARKS/remote.git"
git remote add origin "$MARKS/remote.git"
git add -A && git commit -qm "chore: init" && git push -q -u origin HEAD:main

bash "$TDD" open "A-1 score.sh prints 2" >/dev/null
shell_red_test tests/score.test.sh
printf 'edited\n' > notes.txt
bash "$TDD" red tests/score.test.sh >/dev/null || { echo "FAIL: affected red must succeed"; exit 1; }
[ ! -e "$MARKS/unrelated" ] || { echo "FAIL: red must skip a slow fixture no changed file names"; exit 1; }
[ -e "$MARKS/notes" ] || { echo "FAIL: red must run a slow fixture a changed file names"; exit 1; }

# The RED test is committed and pushed and notes.txt is reverted, so git lists
# neither as changed; green must still run both.
git add tests/score.test.sh && git commit -qm "test(score): A-1" && git push -q origin HEAD:main
git checkout -q -- notes.txt
rm -f "$MARKS/notes"
shell_impl 1
expect_fail "green while failing" bash "$TDD" green | grep -q 'expected 2, got 1' || { echo "FAIL: green must run the pushed, unchanged locked test"; exit 1; }
shell_impl 2
bash "$TDD" green >/dev/null || { echo "FAIL: green must pass when a RED-passing fixture is no longer changed"; exit 1; }
[ -e "$MARKS/notes" ] || { echo "FAIL: green must re-run every fixture the RED run passed"; exit 1; }
[ ! -e "$MARKS/unrelated" ] || { echo "FAIL: green must skip a slow fixture neither changed nor passed at RED"; exit 1; }

# Deleting a fixture the RED run passed still drops below the baseline.
rm tests/slow-notes.test.sh
expect_fail "green with a deleted RED-passing fixture" bash "$TDD" green | grep -q 'baseline' || { echo "FAIL: deleting a fixture the RED run passed must drop below the baseline"; exit 1; }
git checkout -q -- tests/slow-notes.test.sh

echo "tdd-affected-suite.test.sh PASS"
