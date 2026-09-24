#!/usr/bin/env bash
# Shard: slow
# Verifies that `tdd.sh amend` judges "the RED is pushed" by this slice's RED
# alone (R-410). A repository that once committed .claude/tdd-lock.json, and
# pushed it, before ignoring it (this harness's own history does) must not
# have every later amendment refused: only a pushed commit whose lock records
# this test at the hash RED recorded counts. Found 2026-09-24 when the first
# real `tdd.sh amend` in this repository was refused as pushed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"

P=$(cd "$(mktemp -d)" && pwd -P)
REMOTE=$(cd "$(mktemp -d)" && pwd -P)
git init -q --bare "$REMOTE"
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
git -C "$P" remote add origin "$REMOTE"
mkdir -p "$P/tests" "$P/.claude"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
cd "$P"

# An old, unrelated lock was committed and pushed, then the lock was ignored.
printf '{"slice":"old","phase":"green","tests":[]}\n' > .claude/tdd-lock.json
git add -A && git commit -qm "chore: an old slice lock" && git push -q origin HEAD:refs/heads/main 2>/dev/null
git rm -q --cached .claude/tdd-lock.json && rm .claude/tdd-lock.json
printf '.claude/tdd-lock.json\n' > .gitignore
git add -A && git commit -qm "chore: ignore the slice lock" && git push -q origin HEAD:refs/heads/main 2>/dev/null

# A new slice proves a RED that was never pushed; its author may amend it.
bash "$TDD" open "O-1 score.sh prints 2" >/dev/null
printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > tests/score.test.sh
bash "$TDD" red tests/score.test.sh >/dev/null
if ! out=$(bash "$TDD" amend tests/score.test.sh 2>&1); then
  echo "FAIL: an unpushed RED must be amendable despite an old pushed lock commit; got: $out"; exit 1
fi
[ "$(jq -r .phase .claude/tdd-lock.json)" = "amending" ] || { echo "FAIL: the amendment window must open"; exit 1; }

cd /; rm -rf "$P" "$REMOTE"
echo "tdd-amend-old-lock-commit.test.sh PASS"
