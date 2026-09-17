#!/usr/bin/env bash
# spec-inventory.test.sh: verifies skills/cleanup-specs-plans/scripts/inventory.sh
# (2026-09-17 skills audit, S-3): one row per spec or plan with its pair, its
# last commit, the count of commits mentioning its slug, and the named
# artifacts present versus absent, plus the absent-artifact list.
set -uo pipefail
INV="$HOME/.claude/skills/cleanup-specs-plans/scripts/inventory.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
row() { printf '%s' "$OUT" | grep -F "$1 |" | grep -qF "$2"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"; mkdir -p "$REPO/docs/superpowers/specs" "$REPO/docs/superpowers/plans" "$REPO/src/services"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf '# Voice presets design\n\nAdds `src/services/applyPreset.ts` and `src/services/missingThing.ts`.\n' > "$REPO/docs/superpowers/specs/2026-09-01-voice-presets-design.md"
printf '# Voice presets plan\n\n- [ ] task\n' > "$REPO/docs/superpowers/plans/2026-09-01-voice-presets.md"
printf '# Orphan plan\n' > "$REPO/docs/superpowers/plans/2026-09-02-orphan.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "docs(specs): voice presets design and plan"
printf 'export function applyPreset() {}\n' > "$REPO/src/services/applyPreset.ts"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(voice): apply voice presets"
printf 'unrelated\n' > "$REPO/u.txt"; git -C "$REPO" add -A && git -C "$REPO" commit -qm "chore: unrelated"

OUT=$(cd "$REPO" && bash "$INV" 2>&1); ST=$?
check "inventory exits 0" test "$ST" -eq 0
check "spec row pairs with its plan" row "docs/superpowers/specs/2026-09-01-voice-presets-design.md" "| docs/superpowers/plans/2026-09-01-voice-presets.md |"
check "plan row pairs with its spec" row "docs/superpowers/plans/2026-09-01-voice-presets.md" "| docs/superpowers/specs/2026-09-01-voice-presets-design.md |"
check "orphan plan has no pair" row "docs/superpowers/plans/2026-09-02-orphan.md" "| - |"
check "last commit subject shown" row "2026-09-01-voice-presets-design.md" "docs(specs): voice presets design and plan"
check "slug mentions counted (design commit and feat commit)" row "2026-09-01-voice-presets-design.md" "| 2 |"
check "artifacts present over named" row "2026-09-01-voice-presets-design.md" "| 1/2 |"
check "absent artifact listed" bash -c "printf '%s' \"\$0\" | grep -q 'src/services/missingThing.ts'" "$OUT"

OUT=$(cd "$REPO" && bash "$INV" docs/nowhere docs/nowhere-either 2>&1); ST=$?
check "empty directories exit 0" test "$ST" -eq 0
check "empty directories say so" bash -c "printf '%s' \"\$0\" | grep -q 'no files under'" "$OUT"

[ "$fail" -eq 0 ] && echo "spec-inventory.test.sh PASS"
exit "$fail"
