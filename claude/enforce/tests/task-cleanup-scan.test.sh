#!/usr/bin/env bash
# task-cleanup-scan.test.sh: verifies skills/task-cleanup/scripts/scan.sh
# (2026-09-17 skills audit, S-4): on a feature branch that adds a route, a
# component, a query-param read, and a spec, every answer is yes with the
# file named and the report rows are TODO; on a docs-only branch every answer
# is no and the rows are N/A; --range is honoured; the ledger line reads the
# task-start tier from disk.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCAN="$CLAUDE_HARNESS_ROOT/skills/task-cleanup/scripts/scan.sh"
TIER="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }
line() { printf '%s' "$OUT" | grep -E "$1" | grep -qF "$2"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
REPO="$SB/app"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
mkdir -p "$REPO/src" "$REPO/docs/superpowers/specs"
printf 'export const a = 1;\n' > "$REPO/src/a.ts"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"

# Feature branch with every surface.
git -C "$REPO" checkout -q -b feat/presets
mkdir -p "$REPO/src/routes" "$REPO/src/components/PresetPicker"
printf 'export function presets() {}\n' > "$REPO/src/routes/presets.ts"
printf 'export function PresetPicker() { const p = useSearchParams(); return null; }\n' > "$REPO/src/components/PresetPicker/PresetPicker.tsx"
printf '# presets design\n' > "$REPO/docs/superpowers/specs/2026-09-17-presets-design.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(presets): route and picker"
(cd "$REPO" && printf '.claude/\n' > .gitignore && bash "$TIER" set standard "preset picker with tests" >/dev/null 2>&1)

OUT=$(cd "$REPO" && bash "$SCAN" 2>&1); ST=$?
check "scan exits 0" test "$ST" -eq 0
check "range from merge base" reports "(1 commits, 3 files) on branch feat/presets, base main"
check "user-facing yes with the route" line '^1\.' "yes (src/routes/presets.ts)"
check "components yes with the file" line '^2\.' "yes (src/components/PresetPicker/PresetPicker.tsx)"
check "endpoints yes" line '^3\.' "yes (src/routes/presets.ts)"
check "query params yes with the line" line '^4\.' "yes (+export function PresetPicker() { const p = useSearchParams()"
check "spec yes with the file" line '^5\.' "yes (docs/superpowers/specs/2026-09-17-presets-design.md)"
check "feature branch yes with slug" line '^6\.' "yes (slug presets)"
check "ledger tier read from disk" line '^7\.' "standard | preset picker with tests"
check "feature list row TODO" line 'Feature list' "TODO"
check "storybook row TODO" line 'Storybook' "TODO"
check "squash merge row names the branch" line 'Squash merge' "squash feat/presets onto main"

# Docs-only branch: everything no, rows N/A.
git -C "$REPO" checkout -q main; git -C "$REPO" checkout -q -b docs/readme
rm -f "$REPO/.claude/task-tier.json"
printf '# readme\n' > "$REPO/README.md"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "docs: readme"
OUT=$(cd "$REPO" && bash "$SCAN" 2>&1)
check "docs branch: user-facing no" line '^1\.' "no"
check "docs branch: components no" line '^2\.' "no"
check "docs branch: query params no" line '^4\.' "no"
check "docs branch: no ledger reported" line '^7\.' "no ledger"
check "docs branch: storybook N/A" line 'Storybook' "N/A"
check "docs branch: query params doc N/A" line 'Query params doc' "N/A"

# On main with an explicit range.
git -C "$REPO" checkout -q main
OUT=$(cd "$REPO" && bash "$SCAN" --range "main..feat/presets" 2>&1)
check "explicit range honoured" reports "range main..feat/presets"
check "not on a feature branch" line '^6\.' "no"
check "squash row N/A on main" line 'Squash merge' "N/A"

# PR #44 review: the R-607 stacks count as user-facing surfaces too, so the
# feature-list and user-story rows are TODO for a Nuxt page or a FastAPI router.
for surface_path in app/pages/trips/index.vue server/api/trips.get.ts app/routers/trips.py; do
  name=$(printf '%s' "$surface_path" | tr '/.' '--')
  git -C "$REPO" checkout -q main; git -C "$REPO" checkout -q -b "feat/$name"
  mkdir -p "$REPO/$(dirname "$surface_path")"; printf 'x\n' > "$REPO/$surface_path"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: $surface_path"
  OUT=$(cd "$REPO" && bash "$SCAN" 2>&1)
  check "R-607 surface $surface_path is user-facing" line '^1\.' "yes ($surface_path)"
  check "R-607 surface $surface_path makes the story row TODO" line 'User story' "TODO"
done

[ "$fail" -eq 0 ] && echo "task-cleanup-scan.test.sh PASS"
exit "$fail"
