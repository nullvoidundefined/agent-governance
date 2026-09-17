#!/usr/bin/env bash
# dangling-refs.test.sh: verifies skills/bug-hunt/scripts/dangling-refs.sh
# (2026-09-17 skills audit, S-6): the range resolves from the merge base on a
# feature branch and from the last commits on the default branch; a deleted
# module still imported is reported with the importing file and line; a
# rename is reported the same way; a clean range reports nothing dangling.
set -uo pipefail
DR="$HOME/.claude/skills/bug-hunt/scripts/dangling-refs.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }
not_reports() { ! printf '%s' "$OUT" | grep -qF "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/src/services" "$REPO/src/handlers" "$REPO/app"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf 'export function score() { return 1; }\n' > "$REPO/src/services/score.ts"
printf 'import { score } from "../services/score";\nexport const h = score;\n' > "$REPO/src/handlers/getScore.ts"
printf 'export function rank() {}\n' > "$REPO/src/services/rank.ts"
printf 'import { rank } from "../services/rank";\n' > "$REPO/src/handlers/getRank.ts"
printf 'def helper():\n    pass\n' > "$REPO/app/helper.py"
printf 'from app.helper import helper\n' > "$REPO/app/main.py"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "init"

# Feature branch: delete score.ts (still imported), rename rank.ts (still
# imported by the old name), delete helper.py (still imported).
git -C "$REPO" checkout -q -b feat/cleanup
git -C "$REPO" rm -q src/services/score.ts app/helper.py
git -C "$REPO" mv src/services/rank.ts src/services/rankJobs.ts
git -C "$REPO" commit -qm "refactor: drop score, rename rank"
OUT=$(cd "$REPO" && bash "$DR" 2>&1); ST=$?
check "exits 0" test "$ST" -eq 0
check "range from merge base" bash -c "printf '%s' \"\$0\" | grep -qE '^dangling-refs: range [0-9a-f]{40}\.\.HEAD'" "$OUT"
check "deleted ts module reported with importer" reports 'DANGLING: src/services/score.ts <- src/handlers/getScore.ts:1:'
check "renamed module reported by old name" reports 'DANGLING: src/services/rank.ts <- src/handlers/getRank.ts:1:'
check "deleted python module reported" reports 'DANGLING: app/helper.py <- app/main.py:1:'
check "count line names three paths" reports 'checked 3 deleted or renamed path(s)'

# Fix the importers: nothing dangling.
printf 'export const h = 1;\n' > "$REPO/src/handlers/getScore.ts"
printf 'import { rank } from "../services/rankJobs";\n' > "$REPO/src/handlers/getRank.ts"
printf 'x = 1\n' > "$REPO/app/main.py"
git -C "$REPO" commit -qam "fix: importers follow"
OUT=$(cd "$REPO" && bash "$DR" 2>&1)
check "clean range has no DANGLING line" not_reports 'DANGLING:'

# Default branch with few commits: capped range, no error.
git -C "$REPO" checkout -q main
OUT=$(cd "$REPO" && bash "$DR" 2>&1); ST=$?
check "young default branch exits 0" test "$ST" -eq 0
check "young default branch range capped" reports 'range HEAD~0..HEAD'
OUT=$(cd "$REPO" && bash "$DR" main..feat/cleanup 2>&1)
check "explicit range honoured" reports 'range main..feat/cleanup'

[ "$fail" -eq 0 ] && echo "dangling-refs.test.sh PASS"
exit "$fail"
