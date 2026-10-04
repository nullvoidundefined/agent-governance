#!/usr/bin/env bash
# handoff-summary.sh: the block one provider hands the next when the router
# (route.sh) moves consecutive steps between Claude and Codex (IAN-603, slice
# 04 PR 4). It carries names and counts only, never raw log lines or diff
# hunks, so the receiving provider spends no quota on noise.
#
# Usage: handoff-summary.sh [--base <ref>] [--test-log <file>]
# Run inside a git repo. Prints one `key: value` per line:
#   status: green|red|unknown   (unknown without --test-log)
#   branch: <name>              (detached when HEAD is detached)
#   head: <short sha>
#   failing:                    then one "  - <test name>" per failing test
#   diff: <N> files changed, +<A> -<D>   (committed changes since --base, default main)
#
# Failing names come from vitest (`FAIL  file > suite > name`), jest
# (`● suite › name`), pytest (`FAILED path::id - reason`, reason dropped), and
# the bash runner (`FAIL name.test.sh`), after ANSI colour codes are stripped.
# Exit codes: 0 ok; 2 a usage error (unknown option, missing value, missing
# log file, unknown --base ref, not in a git repo).
set -uo pipefail

usage_error() {
  echo "handoff-summary: $1" >&2
  echo "usage: handoff-summary.sh [--base <ref>] [--test-log <file>]" >&2
  exit 2
}

base="main"
log=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || usage_error "--base needs a ref"
      base="$2"; shift 2 ;;
    --test-log)
      [ $# -ge 2 ] || usage_error "--test-log needs a file"
      log="$2"; shift 2 ;;
    *) usage_error "unknown option '$1'" ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage_error "not inside a git repository"
[ -z "$log" ] || [ -f "$log" ] || usage_error "test log '$log' does not exist"
git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || usage_error "base ref '$base' does not exist"

branch=$(git branch --show-current 2>/dev/null)
[ -n "$branch" ] || branch="detached"
head=$(git rev-parse --short HEAD)

status="unknown"
names=""
if [ -n "$log" ]; then
  # One pass: strip ANSI, print "NAME<TAB>name" for each failing test once, and
  # a final "MARK<TAB>n" with the count of failure marker lines.
  parsed=$(awk '
    { gsub(/\033\[[0-9;]*[A-Za-z]/, "") }
    /^[ \t]*FAIL[ \t]+.+ > .+$/ {
      n = $0; sub(/^[ \t]*FAIL[ \t]+/, "", n); sub(/[ \t]+$/, "", n); emit(n); marks++; next
    }
    /^[ \t]*●[ \t]+.+ › .+$/ {
      n = $0; sub(/^[ \t]*●[ \t]+/, "", n); sub(/[ \t]+$/, "", n); emit(n); marks++; next
    }
    /^FAILED [^ ]+::/ {
      n = $2; emit(n); marks++; next
    }
    /^[ \t]*FAIL[ \t]+[^ \t]+\.test\.sh[ \t]*$/ {
      n = $2; emit(n); marks++; next
    }
    /^[ \t]*(FAIL|FAILED)([: \t]|$)/ || /^[ \t]*×/ { marks++ }
    function emit(n) { if (!(n in seen)) { seen[n] = 1; print "NAME\t" n } }
    END { print "MARK\t" (marks + 0) }
  ' "$log")
  names=$(printf '%s\n' "$parsed" | sed -n 's/^NAME	//p')
  marks=$(printf '%s\n' "$parsed" | sed -n 's/^MARK	//p')
  if [ -n "$names" ] || [ "${marks:-0}" -gt 0 ]; then status="red"; else status="green"; fi
fi

files=0; added=0; deleted=0
while IFS=$'\t' read -r a d _; do
  [ -n "$a" ] || continue
  files=$((files + 1))
  [[ "$a" =~ ^[0-9]+$ ]] && added=$((added + a))
  [[ "$d" =~ ^[0-9]+$ ]] && deleted=$((deleted + d))
done < <(git diff --numstat "${base}...HEAD" 2>/dev/null)

echo "status: $status"
echo "branch: $branch"
echo "head: $head"
echo "failing:"
[ -z "$names" ] || printf '%s\n' "$names" | sed 's/^/  - /'
echo "diff: $files files changed, +$added -$deleted"
