#!/usr/bin/env bash
# check.sh: the spec-grounding skill's definition of done, decided rather than
# recalled (2026-09-17 skills audit, S-2). Given a spec the skill has grounded,
# every condition the skill lists is checked against the file and the tree:
#
#   1. "## Codebase grounding" exists and every path in its table exists.
#   2. "## Already exists" exists and every `path:line` it cites names a file
#      that exists and has at least that many lines.
#   3. "## Conflicts with current patterns" exists, every `path:line` it
#      cites resolves the same way, and every bullet names a governing R-NNN.
#   4. "## Domain vocabulary" exists with at least one "chosen over:" entry
#      (the same test hooks/spec-glossary-check.sh applies, which only fires
#      for docs/superpowers/specs/*-design.md; this runs on any path).
#   5. "## Acceptance criteria" exists with at least one "B-1" line, and
#      "## Non-goals" exists.
#   6. The spec is the only modified or untracked path in the working tree
#      (the skill implements nothing); --no-git skips this for a spec kept
#      outside a repository.
#
# Usage: check.sh <spec path> [--no-git]
# Exit 0 with one OK line when every condition holds; otherwise one line per
# failure on stderr and exit 1. Never edits anything.
set -uo pipefail

SPEC="${1:-}"
CHECK_GIT=1
[ "${2:-}" = "--no-git" ] && CHECK_GIT=0
[ -n "$SPEC" ] || { echo "usage: check.sh <spec path> [--no-git]" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "spec-grounding-check: no such file: $SPEC" >&2; exit 2; }

ROOT=$(git -C "$(dirname "$SPEC")" rev-parse --show-toplevel 2>/dev/null || pwd)
failures=0
fail() { printf 'spec-grounding-check: %s\n' "$*" >&2; failures=$((failures + 1)); }

# section <heading>: the lines under "## <heading>" up to the next "## ".
section() {
  awk -v h="## $1" '
    $0 == h { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' "$SPEC"
}
has_section() { grep -qx "## $1" "$SPEC"; }

# check_cites <section name>: every `path:line` in the section resolves.
check_cites() {
  local name="$1" cite path line count
  for cite in $(section "$name" | grep -oE '`[A-Za-z0-9_./-]+:[0-9]+`' | tr -d '`' | sort -u); do
    path="${cite%:*}"; line="${cite##*:}"
    if [ ! -f "$ROOT/$path" ]; then
      fail "$name cites $cite but $path does not exist"
    else
      count=$(wc -l < "$ROOT/$path" | tr -d ' ')
      [ "$line" -le "$count" ] || fail "$name cites $cite but $path has only $count lines"
    fi
  done
}

# 1. Codebase grounding table paths.
if has_section "Codebase grounding"; then
  for cell in $(section "Codebase grounding" | grep -E '^\|' | grep -oE '`[A-Za-z0-9_./-]+`' | tr -d '`' | sort -u); do
    case "$cell" in
      */*|*.*) [ -e "$ROOT/$cell" ] || fail "Codebase grounding names $cell, which does not exist" ;;
    esac
  done
else
  fail 'missing "## Codebase grounding" section'
fi

# 2. Already exists cites.
if has_section "Already exists"; then check_cites "Already exists"; else fail 'missing "## Already exists" section'; fi

# 3. Conflicts cites and governing rules.
if has_section "Conflicts with current patterns"; then
  check_cites "Conflicts with current patterns"
  section "Conflicts with current patterns" | grep -E '^- ' | grep -vqE 'R-[0-9]{3}' \
    && fail 'a bullet under "## Conflicts with current patterns" names no governing R-NNN rule'
else
  fail 'missing "## Conflicts with current patterns" section'
fi

# 4. Glossary.
if has_section "Domain vocabulary"; then
  section "Domain vocabulary" | grep -q 'chosen over:' || fail '"## Domain vocabulary" has no "chosen over:" entry (R-330)'
else
  fail 'missing "## Domain vocabulary" section (R-330)'
fi

# 5. Acceptance criteria and non-goals.
if has_section "Acceptance criteria"; then
  section "Acceptance criteria" | grep -qE '\bB-1\b' || fail '"## Acceptance criteria" has no B-1 line (R-412 slices)'
else
  fail 'missing "## Acceptance criteria" section'
fi
has_section "Non-goals" || fail 'missing "## Non-goals" section'

# 6. Only the spec changed.
if [ "$CHECK_GIT" -eq 1 ]; then
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # $ROOT is fully symlink-resolved (git rev-parse --show-toplevel does
    # that), so $SPEC must be too before the relative path is computed: on
    # macOS a spec under /tmp/... (-> /private/tmp/...) otherwise looks like
    # it sits outside $ROOT entirely, and the spec itself shows up in
    # "others" as if it were some other file, failing invariant 6 on every
    # grounded spec.
    spec_real=$(realpath "$SPEC" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SPEC")
    spec_rel=$(realpath --relative-to="$ROOT" "$spec_real" 2>/dev/null || python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$spec_real" "$ROOT")
    others=$(git -C "$ROOT" status --porcelain --untracked-files=all | awk '{print $NF}' | grep -vxF "$spec_rel" || true)
    [ -z "$others" ] || fail "files other than the spec are modified or untracked: $(printf '%s' "$others" | tr '\n' ' ')"
  else
    fail "$SPEC is not inside a git repository; pass --no-git to skip the only-the-spec check"
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "spec-grounding-check: $failures condition(s) unmet for $SPEC" >&2
  exit 1
fi
echo "spec-grounding-check: OK, $SPEC meets the definition of done"
