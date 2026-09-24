#!/usr/bin/env bash
# Shard: slow
# Verifies `tdd.sh abandon` (R-412): a lock left by a dead session is closed
# without the user, and logged, but only when it is truly stale and nothing is
# lost by closing it. Refused with no lock, for a lock that never locked a test
# (`close` handles that), for a lock touched within the stale window, while
# another live process holds the working tree, while a locked test differs
# from HEAD, and while the locked tests or the rest of the suite fail. Drives
# the bash *.test.sh runner through the real run-fixture-shards.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"
LOG_DIR=$(cd "$(mktemp -d)" && pwd -P)
export CLAUDE_TDD_ABANDON_LOG="$LOG_DIR/tdd-abandon.jsonl"

P=$(cd "$(mktemp -d)" && pwd -P)
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
mkdir -p "$P/tests" "$P/scripts"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

lock_field() { jq -r "$1" .claude/tdd-lock.json; }
expect_fail() {
  local label="$1" out; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}
# Ages the lock past the stale window: every recorded timestamp and the mtime.
age_lock() {
  jq '(.openedAt, .redAt, .greenAt) |= (if . == null then null else "2026-01-01T00:00:00Z" end)' .claude/tdd-lock.json > lock.tmp && mv lock.tmp .claude/tdd-lock.json
  touch -t 202601010000 .claude/tdd-lock.json
}

expect_fail "abandon with no lock" bash "$TDD" abandon | grep -q 'no slice is open' || { echo "FAIL: abandon without a lock must say no slice is open"; exit 1; }

bash "$TDD" open "D-1 score.sh prints 2" >/dev/null
age_lock
expect_fail "abandon of a lock with no test" bash "$TDD" abandon | grep -q 'tdd.sh close' || { echo "FAIL: a lock with no test must be pointed at close"; exit 1; }

# The dead session got as far as RED, committed its test, and wrote no code.
printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > tests/score.test.sh
bash "$TDD" red tests/score.test.sh >/dev/null
git add tests/score.test.sh && git commit -qm "test: RED for score"

expect_fail "abandon of a fresh lock" bash "$TDD" abandon | grep -q 'hours' || { echo "FAIL: a lock touched inside the stale window must be refused, naming the window"; exit 1; }
age_lock
expect_fail "abandon while the locked test fails" bash "$TDD" abandon | grep -q 'not passing' || { echo "FAIL: a locked test that still fails must be refused"; exit 1; }

# The implementation landed and was committed, but green never ran.
printf '#!/usr/bin/env bash\necho 2\n' > scripts/score.sh
git add scripts/score.sh && git commit -qm "feat: score prints 2"
age_lock

printf '# drift\n' >> tests/score.test.sh
age_lock
expect_fail "abandon with an uncommitted test change" bash "$TDD" abandon | grep -q 'committed' || { echo "FAIL: a locked test that differs from HEAD must be refused"; exit 1; }
git checkout -q -- tests/score.test.sh
age_lock

printf '#!/usr/bin/env bash\necho "FAIL: sibling broke"\n' > tests/baseline.test.sh
expect_fail "abandon with the rest of the suite red" bash "$TDD" abandon | grep -q 'tests/baseline.test.sh' || { echo "FAIL: a failing test outside the lock must be named"; exit 1; }
git checkout -q -- tests/baseline.test.sh
age_lock

# Another live process working in the tree means the session may not be dead.
# The holder is orphaned by a double fork: a child of this script belongs to
# the caller's own session, which abandon rightly ignores.
( cd "$P" && { sleep 60 >/dev/null 2>&1 & echo $! > "$LOG_DIR/holder.pid"; } )
holder=$(cat "$LOG_DIR/holder.pid")
sleep 0.3
if command -v lsof >/dev/null 2>&1; then
  expect_fail "abandon while a live process holds the tree" bash "$TDD" abandon | grep -q 'live process' || { kill "$holder"; echo "FAIL: a live process in the working tree must be refused"; exit 1; }
fi
kill "$holder" 2>/dev/null || true
sleep 0.2

# Stale, committed, passing, unheld: the lock is closed and the close logged.
bash "$TDD" abandon | grep -q 'abandoned' || { echo "FAIL: a stale, committed, passing lock must be abandoned"; exit 1; }
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: abandon must remove the lock"; exit 1; }
[ "$(jq -r '.slice' "$CLAUDE_TDD_ABANDON_LOG")" = "D-1 score.sh prints 2" ] || { echo "FAIL: abandon must log the slice it closed"; exit 1; }
[ "$(jq -r '.phase' "$CLAUDE_TDD_ABANDON_LOG")" = "red" ] || { echo "FAIL: abandon must log the phase it found"; exit 1; }

cd /; rm -rf "$P" "$LOG_DIR"
echo "tdd-abandon.test.sh PASS"
