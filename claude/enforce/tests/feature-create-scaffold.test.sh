#!/usr/bin/env bash
# feature-create-scaffold.test.sh: verifies skills/feature-create/scripts/scaffold.sh
# (2026-09-17 skills audit, S-1) against a sandboxed repo: the happy path
# creates the worktree, the branch, the docs scaffold, and its commit; each
# refusal stops with its own exit code; a red baseline preserves the worktree
# and scaffolds nothing; the default branch is detected when it is master.
# R-607 (spec docs/superpowers/specs/2026-09-18-product-docs-design.md, B-19 to
# B-22): --area is required; the story is appended to the area's file with the
# next free US-<AREA>-NNN; the feature row lands inside the area's section of
# features.md; absent product docs are seeded from the harness templates
# instead of being skipped.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCAFFOLD="$CLAUDE_HARNESS_ROOT/skills/feature-create/scripts/scaffold.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
export FEATURE_CREATE_INSTALL_CMD=skip
export FEATURE_CREATE_TEST_CMD=true
TODAY=$(date +%Y-%m-%d)

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { printf '%s' "$OUT" | grep -qF "$1"; }

# section_has <file> <heading> <text>: true when the text appears between
# "## <heading>" and the next "## " heading.
section_has() { awk -v h="## $2" '$0 == h { on = 1; next } on && /^## / { exit } on' "$1" | grep -qF -- "$3"; }

# make_repo <dir> <default-branch>: a project with product docs (a Voice and
# an Account area, voice stories 001 and 007 already used) and one plan.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  mkdir -p "$dir/docs/superpowers/plans" "$dir/docs/feature-list" "$dir/docs/user-stories"
  printf '# Features\n\nLast updated: 2020-01-01 (seed)\n\n## Voice\n\n| Feature | Status | Notes |\n| --- | --- | --- |\n| Voice upload | **Complete** | US-VOICE-001 |\n\n## Account\n\n| Feature | Status | Notes |\n| --- | --- | --- |\n| Login | **Complete** | US-ACCOUNT-001 |\n' > "$dir/docs/feature-list/features.md"
  printf '# User Stories\n\n## Files\n\n| File | Covers |\n| ---- | ------ |\n| `voice.md` | Voice |\n' > "$dir/docs/user-stories/README.md"
  printf '# Voice User Stories\n\n## US-VOICE-001: Upload a voice\n\n## US-VOICE-007: Rename a voice\n' > "$dir/docs/user-stories/voice.md"
  printf '# Voice presets plan\n\nTask 1: add a preset picker with a ?preset= query param.\n' > "$dir/docs/superpowers/plans/2026-09-17-voice-presets.md"
  printf '{"name":"sandbox","scripts":{"test":"true"}}\n' > "$dir/package.json"
  git -C "$dir" add -A && git -C "$dir" commit -qm "init"
}

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/my-app"; WT="$SB/worktrees"
make_repo "$REPO" main
PLAN=docs/superpowers/plans/2026-09-17-voice-presets.md

# Happy path, with a ticket key, into an existing area.
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --area voice --ticket IAN-7 --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
W="$WT/voice-presets"
check "happy path exits 0" test "$ST" -eq 0
check "worktree created" test -d "$W"
check "branch is feat/<slug>" test "$(git -C "$W" branch --show-current)" = "feat/voice-presets"
check "B-20 story appended with the next free number" grep -q '^## US-VOICE-008: ' "$W/docs/user-stories/voice.md"
check "B-20 existing stories intact" bash -c "grep -q '^## US-VOICE-001: Upload a voice' '$W/docs/user-stories/voice.md' && grep -q '^## US-VOICE-007: Rename a voice' '$W/docs/user-stories/voice.md'"
check "B-20 no per-feature story file" test ! -e "$W/docs/user-stories/voice-presets.md"
check "user story records the e2e path" grep -q 'e2e/voice-presets.spec.ts' "$W/docs/user-stories/voice.md"
check "user story carries the ticket key" grep -q '^\*\*Ticket:\*\* IAN-7$' "$W/docs/user-stories/voice.md"
check "user story has a criteria checklist" grep -q '^- \[ \] ' "$W/docs/user-stories/voice.md"
check "B-20 existing area adds no index row" test "$(grep -c 'voice.md' "$W/docs/user-stories/README.md")" -eq 1
check "B-21 row inside the Voice section" section_has "$W/docs/feature-list/features.md" Voice '| Voice Presets | **Planned** | US-VOICE-008 |'
check "B-21 row not in the Account section" bash -c "! awk '/^## Account/{on=1} on' '$W/docs/feature-list/features.md' | grep -q 'Voice Presets'"
check "B-21 Last updated rewritten with today" grep -q "^Last updated: $TODAY (voice-presets planned)$" "$W/docs/feature-list/features.md"
check "scaffold committed with a scope" test "$(git -C "$W" log -1 --format=%s)" = "chore(docs): scaffold docs for feat/voice-presets"
check "scaffold commit carries the Refs trailer" test "$(git -C "$W" log -1 --format=%b | tr -d '\n')" = "Refs: IAN-7"
check "worktree clean after commit" test -z "$(git -C "$W" status --porcelain)"
check "plan auto-discovered" reports "plan:          $PLAN"
check "query params detected" reports "query params:  yes"
check "main untouched" test "$(git -C "$REPO" branch --show-current)" = "main"

# A new area: story file from the template, README index row, section at the end.
OUT=$(cd "$REPO" && "$SCAFFOLD" preset-billing "$PLAN" --area payments --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
W="$WT/preset-billing"
check "new area exits 0" test "$ST" -eq 0
check "B-20 new area file from the template" grep -q '^# Payments User Stories$' "$W/docs/user-stories/payments.md"
check "B-20 new area starts at 001" grep -q '^## US-PAYMENTS-001: ' "$W/docs/user-stories/payments.md"
check "B-20 template placeholders filled" bash -c "! grep -q '{{' '$W/docs/user-stories/payments.md'"
check "B-20 new area indexed in the README" grep -qF '| `payments.md` | Payments |' "$W/docs/user-stories/README.md"
check "B-21 new section created" section_has "$W/docs/feature-list/features.md" Payments '| Preset Billing | **Planned** | US-PAYMENTS-001 |'
check "B-21 new section after the existing ones" bash -c "awk '/^## /{print}' '$W/docs/feature-list/features.md' | tail -1 | grep -qx '## Payments'"
check "no ticket leaves the placeholder" grep -q '^\*\*Ticket:\*\* <ticket-key>$' "$W/docs/user-stories/payments.md"

# B-19: --area is required; the refusal lists the existing areas and creates nothing.
OUT=$(cd "$REPO" && "$SCAFFOLD" no-area "$PLAN" --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "B-19 missing --area exits 2" test "$ST" -eq 2
check "B-19 lists existing areas" reports "voice"
check "B-19 does not list the README" bash -c "! printf '%s' \"\$0\" | grep -q 'README'" "$OUT"
check "B-19 creates no worktree" test ! -e "$WT/no-area"
OUT=$(cd "$REPO" && "$SCAFFOLD" bad-area "$PLAN" --area "Bad Area" --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "B-19 malformed area exits 2" test "$ST" -eq 2

# Refusals.
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "existing branch refused with 5" test "$ST" -eq 5
check "existing branch named" reports "branch feat/voice-presets already exists"
git -C "$REPO" worktree remove --force "$WT/voice-presets"; git -C "$REPO" branch -D feat/voice-presets -q
mkdir -p "$WT/voice-presets"
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "existing directory refused with 6" test "$ST" -eq 6
rmdir "$WT/voice-presets"
OUT=$(cd "$REPO" && "$SCAFFOLD" no-such-plan --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "no plan refused with 3" test "$ST" -eq 3
cp "$REPO/$PLAN" "$REPO/docs/superpowers/plans/2026-09-18-voice-presets-v2.md"
OUT=$(cd "$REPO" && "$SCAFFOLD" voice-presets --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "several plans refused with 4" test "$ST" -eq 4
check "several plans listed" reports "2026-09-18-voice-presets-v2.md"
rm "$REPO/docs/superpowers/plans/2026-09-18-voice-presets-v2.md"
OUT=$(cd "$REPO" && "$SCAFFOLD" "Bad Slug" --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "bad slug refused with 2" test "$ST" -eq 2

# Red baseline: worktree kept, nothing scaffolded, exit 7.
OUT=$(cd "$REPO" && FEATURE_CREATE_TEST_CMD=false "$SCAFFOLD" red-base "$PLAN" --area voice --worktree-parent "$WT" --no-fetch 2>&1); ST=$?
check "red baseline exits 7" test "$ST" -eq 7
check "red baseline preserves worktree" test -d "$WT/red-base"
check "red baseline scaffolds nothing" bash -c "! grep -q 'US-VOICE-008' '$WT/red-base/docs/user-stories/voice.md'"
check "red baseline makes no commit" test "$(git -C "$WT/red-base" log -1 --format=%s)" = "init"

# B-22: a repository with no product docs, default branch master: the docs
# are seeded from the harness templates rather than skipped.
REPO2="$SB/legacy"; make_repo "$REPO2" master
git -C "$REPO2" rm -rq docs/feature-list docs/user-stories; git -C "$REPO2" commit -qm "drop product docs"
OUT=$(cd "$REPO2" && "$SCAFFOLD" voice-presets --area voice --worktree-parent "$SB/worktrees2" --no-fetch 2>&1); ST=$?
W="$SB/worktrees2/voice-presets"
check "master detected as base" reports "from master"
check "B-22 exits 0" test "$ST" -eq 0
check "B-22 features list seeded from the template" grep -q '^Status key: \*\*Complete\*\* | \*\*Partial\*\* | \*\*Planned\*\*$' "$W/docs/feature-list/features.md"
check "B-22 features list names the project" grep -q '^# legacy Feature List$' "$W/docs/feature-list/features.md"
check "B-22 seeded list gains the Voice section and row" section_has "$W/docs/feature-list/features.md" Voice '| Voice Presets | **Planned** | US-VOICE-001 |'
check "B-22 README seeded and indexes the area" grep -qF '| `voice.md` | Voice |' "$W/docs/user-stories/README.md"
check "B-22 story file written" grep -q '^## US-VOICE-001: ' "$W/docs/user-stories/voice.md"
check "B-22 seeded docs committed" test -z "$(git -C "$W" status --porcelain)"

[ "$fail" -eq 0 ] && echo "feature-create-scaffold.test.sh PASS"
exit "$fail"
