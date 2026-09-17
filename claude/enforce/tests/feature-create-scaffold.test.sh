#!/usr/bin/env bash
# feature-create-scaffold.test.sh: verifies skills/feature-create/scripts/scaffold.sh
# (2026-09-17 skills audit, S-1) against a sandboxed repo: the happy path
# creates the worktree, the branch, the docs scaffold, and its commit; each
# refusal stops with its own exit code; a red baseline preserves the worktree
# and scaffolds nothing; the default branch is detected when it is master.
set -uo pipefail
SCAFFOLD="$HOME/.claude/skills/feature-create/scripts/scaffold.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
export FEATURE_CREATE_INSTALL_CMD=skip
export FEATURE_CREATE_TEST_CMD=true

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }

# make_repo <dir> <default-branch>: a project with docs/ trees and one plan.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  mkdir -p "$dir/docs/superpowers/plans" "$dir/docs/feature-list" "$dir/docs/user-stories"
  printf '# Features\n\n| Feature | Status | Stories |\n|---|---|---|\n' > "$dir/docs/feature-list/features.md"
  : > "$dir/docs/user-stories/.gitkeep"
  printf '# Voice presets plan\n\nTask 1: add a preset picker with a ?preset= query param.\n' > "$dir/docs/superpowers/plans/2026-09-17-voice-presets.md"
  printf '{"name":"sandbox","scripts":{"test":"true"}}\n' > "$dir/package.json"
  git -C "$dir" add -A && git -C "$dir" commit -qm "init"
}

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/my-app"; WT="$SB/worktrees"
make_repo "$REPO" main

# Happy path.
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "happy path exits 0" test "$ST" -eq 0
check "worktree created" test -d "$WT/voice-presets"
check "branch is feat/<slug>" test "$(git -C "$WT/voice-presets" branch --show-current)" = "feat/voice-presets"
check "feature-list row appended" grep -q '| Voice Presets | \*\*Planned\*\* | US-VOICE-PRESETS |' "$WT/voice-presets/docs/feature-list/features.md"
check "user story written" test -f "$WT/voice-presets/docs/user-stories/voice-presets.md"
check "user story carries the story id" grep -q 'US-VOICE-PRESETS-001' "$WT/voice-presets/docs/user-stories/voice-presets.md"
check "user story records the e2e path" grep -q 'e2e/voice-presets.spec.ts' "$WT/voice-presets/docs/user-stories/voice-presets.md"
check "scaffold committed with a scope" test "$(git -C "$WT/voice-presets" log -1 --format=%s)" = "chore(docs): scaffold docs for feat/voice-presets"
check "worktree clean after commit" test -z "$(git -C "$WT/voice-presets" status --porcelain)"
check "plan auto-discovered" reports "plan:          docs/superpowers/plans/2026-09-17-voice-presets.md"
check "query params detected" reports "query params:  yes"
check "main untouched" test "$(git -C "$REPO" branch --show-current)" = "main"

# Refusals.
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "existing branch refused with 5" test "$ST" -eq 5
check "existing branch named" reports "branch feat/voice-presets already exists"
git -C "$REPO" worktree remove --force "$WT/voice-presets"; git -C "$REPO" branch -D feat/voice-presets -q
mkdir -p "$WT/voice-presets"
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "existing directory refused with 6" test "$ST" -eq 6
rmdir "$WT/voice-presets"
OUT=$(cd "$REPO" && "$SCAFFOLD" no-such-plan --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "no plan refused with 3" test "$ST" -eq 3
cp "$REPO/docs/superpowers/plans/2026-09-17-voice-presets.md" "$REPO/docs/superpowers/plans/2026-09-18-voice-presets-v2.md"
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "several plans refused with 4" test "$ST" -eq 4
check "several plans listed" reports "2026-09-18-voice-presets-v2.md"
rm "$REPO/docs/superpowers/plans/2026-09-18-voice-presets-v2.md"
OUT=$(cd "$REPO" && "$SCAFFOLD" "Bad Slug" --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "bad slug refused with 2" test "$ST" -eq 2
check "explicit plan path honoured" bash -c "cd '$REPO' && '$SCAFFOLD' explicit docs/superpowers/plans/2026-09-17-voice-presets.md --worktree-parent '$WT' --no-fetch >/dev/null 2>&1 && test -d '$WT/explicit'"

# Red baseline: worktree kept, nothing scaffolded, exit 7.
OUT=$(cd "$REPO" && FEATURE_CREATE_TEST_CMD=false "$SCAFFOLD" red-base docs/superpowers/plans/2026-09-17-voice-presets.md --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "red baseline exits 7" test "$ST" -eq 7
check "red baseline preserves worktree" test -d "$WT/red-base"
check "red baseline scaffolds nothing" test ! -e "$WT/red-base/docs/user-stories/red-base.md"
check "red baseline makes no commit" test "$(git -C "$WT/red-base" log -1 --format=%s)" = "init"

# Default branch detection when it is master, and a missing docs tree skipped.
REPO2="$SB/legacy"; make_repo "$REPO2" master
rm -r "$REPO2/docs/user-stories"; git -C "$REPO2" commit -qam "drop stories" 2>/dev/null || true
OUT=$(cd "$REPO2" && "$SCAFFOLD" voice-presets --worktree-parent "$SB/worktrees2" --no-fetch 2>&1); ST=$?
check "master detected as base" reports "from master"
check "missing user-stories tree skipped" reports "no docs/user-stories/; user story skipped"
check "still exits 0 with a partial scaffold" test "$ST" -eq 0

[ "$fail" -eq 0 ] && echo "feature-create-scaffold.test.sh PASS"
exit "$fail"
