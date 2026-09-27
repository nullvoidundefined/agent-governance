#!/usr/bin/env bash
# build-lane.test.sh: verifies skills/build-fast/scripts/build-lane.sh, the
# build-fast lane classifier (spec 2026-09-27-build-fast-design.md, IAN-401).
#
# Fixture: every case runs inside a sandbox repository built by newOriginRepo.
# That helper creates a bare origin on main, a clone holding one commit on main
# that is pushed, origin/HEAD pointed at main with `git remote set-head`, and a
# feature branch feat/x carrying one commit that adds docs/a.md. commitFile
# writes and commits one file in a given repository. A stub `gh` that reports
# no pull request sits first on PATH so no case reaches the network. The rules
# file is supplied through BUILD_LANE_RULES.
#
# B-1 (criterion 1): an invalid lane-rules file (missing, not JSON, no
# guardedPaths key, an empty list, a non-string entry, a pattern grep -E
# rejects) makes both `classify` and `predict` print exactly one line starting
# `guarded config-failure:` and exit 0, so the lane fails closed.
#
# Later slices append their cases below, reusing newOriginRepo and commitFile.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
LANE="$CLAUDE_HARNESS_ROOT/skills/build-fast/scripts/build-lane.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home/.claude"; export HOME="$SB/home"
mkdir -p "$SB/bin"
printf '#!/usr/bin/env bash\necho "no pull requests found" >&2\nexit 1\n' > "$SB/bin/gh"
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH"

# commitFile <repo> <path> <content>: writes <content> to <path> inside <repo>
# (creating parent directories) and commits it on the current branch.
commitFile() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -qm "add $path"
}

# newOriginRepo <name>: builds $SB/<name>.git (bare origin on main) and
# $SB/<name> (a clone with main pushed, origin/HEAD set to main, and feat/x
# checked out holding one commit that adds docs/a.md).
newOriginRepo() {
  local name="$1"
  local origin="$SB/$name.git" repo="$SB/$name"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$repo" 2>/dev/null
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -B main
  commitFile "$repo" README.md "fixture"
  git -C "$repo" push -q origin main 2>/dev/null
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout -q -b feat/x
  commitFile "$repo" docs/a.md "a"
}

# ---- B-1: invalid lane rules fail closed ----------------------------------

newOriginRepo rules
REPO="$SB/rules"
RULES_DIR="$SB/rules-files"; mkdir -p "$RULES_DIR"
printf 'this is { not json\n' > "$RULES_DIR/not-json.json"
printf '{"otherKey": ["\\\\.sql$"]}\n' > "$RULES_DIR/missing-key.json"
printf '{"guardedPaths": []}\n' > "$RULES_DIR/empty-list.json"
printf '{"guardedPaths": ["\\\\.sql$", 1]}\n' > "$RULES_DIR/non-string.json"
printf '{"guardedPaths": ["\\\\.sql$", "(unclosed"]}\n' > "$RULES_DIR/bad-pattern.json"

# assertConfigFailure <case label> <rules path> <command args...>: runs the
# classifier with BUILD_LANE_RULES=<rules path> inside the fixture repo and
# checks exit 0, exactly one stdout line, and the config-failure prefix.
assertConfigFailure() {
  local label="$1" rules="$2"; shift 2
  local out st lineCount
  out=$(cd "$REPO" && BUILD_LANE_RULES="$rules" bash "$LANE" "$@" 2>/dev/null); st=$?
  lineCount=$(printf '%s' "$out" | awk 'END { print NR }')
  check "$label: $1 exits 0" test "$st" -eq 0
  check "$label: $1 prints exactly one line" test "$lineCount" -eq 1
  check "$label: $1 prints guarded config-failure" \
    bash -c 'case "$0" in "guarded config-failure:"*) exit 0 ;; *) exit 1 ;; esac' "$out"
}

for rulesCase in missing not-json missing-key empty-list non-string bad-pattern; do
  rulesPath="$RULES_DIR/$rulesCase.json"
  assertConfigFailure "rules $rulesCase" "$rulesPath" classify
  assertConfigFailure "rules $rulesCase" "$rulesPath" predict 'docs/*.md'
done

check "missing rules file really is absent" test ! -e "$RULES_DIR/missing.json"

[ "$fail" -eq 0 ] || exit 1
echo "build-lane.test.sh PASS"
