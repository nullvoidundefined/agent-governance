#!/usr/bin/env bash
# Shard: slow
# Verifies two properties of `tdd.sh amend` raised by the R-517 review of
# IAN-342 (R-410): each recorded amendment names git blobs for the test before
# and after, so `git diff <from> <to>` shows exactly what the author changed;
# and a RED pushed long ago is still found however many later commits on the
# remote touched the same file.
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
mkdir -p "$P/tests" "$P/scripts"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

score_test() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = %s ] || { echo "FAIL: expected %s, got $out"; exit 1; }\necho "score.test.sh PASS"\n' "$1" "$1" > tests/score.test.sh
}

# The amendment's before and after are blobs a reviewer can diff.
bash "$TDD" open "U-1 score.sh prints 3" >/dev/null
score_test 2
bash "$TDD" red tests/score.test.sh >/dev/null
bash "$TDD" amend tests/score.test.sh >/dev/null
score_test 3
bash "$TDD" amend tests/score.test.sh >/dev/null
from=$(jq -r '.amendments[0].fromBlob // ""' .claude/tdd-lock.json)
to=$(jq -r '.amendments[0].toBlob // ""' .claude/tdd-lock.json)
[ -n "$from" ] && [ -n "$to" ] || { echo "FAIL: the amendment must record fromBlob and toBlob"; exit 1; }
git diff "$from" "$to" | grep -q '^+.*expected 3' || { echo "FAIL: git diff of the recorded blobs must show the amended assertion"; exit 1; }
printf '#!/usr/bin/env bash\necho 3\n' > scripts/score.sh
bash "$TDD" green >/dev/null
bash "$TDD" close >/dev/null
git add -A && git commit -qm "feat: score prints 3"

# A RED pushed, then buried under more than fifty later remote commits.
bash "$TDD" open "U-2 score.sh prints 4" >/dev/null
score_test 4
bash "$TDD" red tests/score.test.sh >/dev/null
git add tests/score.test.sh && git commit -qm "test: RED for 4"
git push -q origin HEAD:refs/heads/feature 2>/dev/null
git checkout -q -b churn
for n in $(seq 1 55); do printf '# churn %s\n' "$n" >> tests/score.test.sh; git commit -qam "chore: churn $n"; done
git push -q origin churn 2>/dev/null
git checkout -q -
out=$(bash "$TDD" amend tests/score.test.sh 2>&1) && { echo "FAIL: a pushed RED under 55 later commits must still refuse amend; got: $out"; exit 1; }
grep -q 'pushed' <<< "$out" || { echo "FAIL: the refusal must say the RED was pushed; got: $out"; exit 1; }

cd /; rm -rf "$P" "$REMOTE"
echo "tdd-amend-audit.test.sh PASS"
