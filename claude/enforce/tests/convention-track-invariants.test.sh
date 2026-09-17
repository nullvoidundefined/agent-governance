#!/usr/bin/env bash
# Proves every convention file under claude/ is wired end to end: a `paths:`
# frontmatter block, a rules/ symlink that resolves to it, and a mention in
# rules/session-types.md or the frontend core's Framework Files table. Runs
# the check on the real tree, then on sandbox copies with one wire removed
# each, and requires each copy to be rejected naming the unwired file
# (spec 2026-09-17-python-vue-convention-tracks-design.md, AC-8).
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
TMPDIRS=""
cleanup() { for d in $TMPDIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

resolve_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

has_paths_frontmatter() {
  awk 'BEGIN { code = 1 }
       NR == 1 && $0 != "---" { exit }
       NR > 1 && $0 == "---" { code = (found ? 0 : 1); exit }
       /^paths:/ { in_paths = 1 }
       in_paths && /^  - "/ { found = 1 }
       END { exit code }' "$1"
}

has_resolving_symlink() {
  local target="$1" root="$2" link
  local wanted
  wanted="$(resolve_path "$target")"
  for link in "$root"/rules/*.md; do
    [ -L "$link" ] || continue
    [ -e "$link" ] || continue
    if [ "$(resolve_path "$link")" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

is_mentioned() {
  local base="$1" root="$2"
  grep -qF "$base" "$root/rules/session-types.md" "$root/CLAUDE-FRONTEND.md" 2>/dev/null
}

check_tree() {
  local root="$1" rc=0 file base
  for file in "$root"/CLAUDE-*.md; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    if ! has_paths_frontmatter "$file"; then
      echo "unwired: $base has no paths: frontmatter block"; rc=1
    fi
    if ! has_resolving_symlink "$file" "$root"; then
      echo "unwired: $base has no resolving rules/ symlink"; rc=1
    fi
    if ! is_mentioned "$base" "$root"; then
      echo "unwired: $base is not named in rules/session-types.md or CLAUDE-FRONTEND.md"; rc=1
    fi
  done
  return $rc
}

make_sandbox() {
  local sandbox
  sandbox="$(mktemp -d)"
  TMPDIRS="$TMPDIRS $sandbox"
  cp "$DIR"/CLAUDE-*.md "$sandbox"/
  cp -R "$DIR/rules" "$sandbox/rules"
  echo "$sandbox"
}

expect_rejected() {
  local case_id="$1" sandbox="$2" base="$3" out
  out="$(check_tree "$sandbox" 2>&1)"
  if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF "$base"; then
    echo "PASS: $case_id rejected naming $base"
  else
    echo "FAIL: $case_id not rejected or $base not named"; fail=1
  fi
}

# A. The real tree is wired.
if out="$(check_tree "$DIR" 2>&1)"; then
  echo "PASS: real tree wired"
else
  printf '%s\n' "$out" | sed 's/^unwired:/FAIL:/'; fail=1
fi

# B. An untouched sandbox copy is wired.
BASE="$(make_sandbox)"
if check_tree "$BASE" >/dev/null 2>&1; then
  echo "PASS: sandbox baseline wired"
else
  echo "FAIL: sandbox baseline not wired"; fail=1
fi

# C1. A removed symlink is caught.
S1="$(make_sandbox)"
rm "$S1/rules/python.md"
expect_rejected "C1 missing symlink" "$S1" "CLAUDE-PYTHON.md"

# C2. A stripped frontmatter block is caught.
S2="$(make_sandbox)"
sed '1,/^---$/d' "$S2/CLAUDE-GO.md" > "$S2/CLAUDE-GO.md.tmp" && mv "$S2/CLAUDE-GO.md.tmp" "$S2/CLAUDE-GO.md"
expect_rejected "C2 missing frontmatter" "$S2" "CLAUDE-GO.md"

# C3. A file no detection table names is caught.
S3="$(make_sandbox)"
for doc in "$S3/rules/session-types.md" "$S3/CLAUDE-FRONTEND.md"; do
  grep -vF "CLAUDE-RUBY.md" "$doc" > "$doc.tmp" && mv "$doc.tmp" "$doc"
done
expect_rejected "C3 missing mention" "$S3" "CLAUDE-RUBY.md"

exit $fail
