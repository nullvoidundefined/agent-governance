#!/usr/bin/env bash
# inventory.sh: the evidence half of cleanup-specs-plans Step 2 (2026-09-17
# skills audit, S-3). Classifying a spec as SHIPPED, PARTIAL, or STALE is
# judgement; the evidence it rests on is not, and it is the part a model skips
# under pressure. For every file under the specs and plans directories this
# prints: its pair by the naming rule (YYYY-MM-DD-<slug>-design.md pairs with
# plans/YYYY-MM-DD-<slug>.md), the date and subject of the last commit that
# touched it, how many commits anywhere mention its slug words, and which of
# the backticked paths it names exist on disk. Never writes anything.
#
# Usage: inventory.sh [<specs dir>] [<plans dir>]
# Defaults: docs/superpowers/specs docs/superpowers/plans. Output: one
# markdown table row per file, then a per-file list of absent artifacts.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "inventory: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2
SPECS="${1:-docs/superpowers/specs}"
PLANS="${2:-docs/superpowers/plans}"

files=$(ls "$SPECS"/*.md "$PLANS"/*.md 2>/dev/null | sort -u)
[ -n "$files" ] || { echo "inventory: no files under $SPECS or $PLANS"; exit 0; }

# slug_words <file>: the file's name without date prefix, -design/-spec
# suffix, and extension, hyphens to spaces, two-letter words dropped.
slug_words() {
  basename "$1" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/-(design|spec)$//' | tr '-' '\n' | awk 'length($0) > 2' | tr '\n' ' ' | sed 's/ $//'
}

# pair_of <file>: the paired plan for a spec (or spec for a plan), or "-".
pair_of() {
  local f="$1" base stem
  base=$(basename "$f" .md)
  case "$f" in
    "$SPECS"/*)
      stem=$(printf '%s' "$base" | sed -E 's/-(design|spec)$//')
      [ -f "$PLANS/$stem.md" ] && printf '%s' "$PLANS/$stem.md" || printf '%s' "-" ;;
    *)
      for suffix in design spec; do [ -f "$SPECS/$base-$suffix.md" ] && { printf '%s' "$SPECS/$base-$suffix.md"; return; }; done
      printf '%s' "-" ;;
  esac
}

echo "| File | Pair | Last touched | Commits mentioning slug | Artifacts present/named |"
echo "|---|---|---|---|---|"
absent_report=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  pair=$(pair_of "$f")
  last=$(git log -1 --date=short --format='%ad %s' -- "$f" 2>/dev/null | cut -c1-70)
  [ -n "$last" ] || last="(uncommitted)"
  words=$(slug_words "$f")
  mentions=0
  if [ -n "$words" ]; then
    # A commit counts when its subject or body carries every slug word.
    grep_args=()
    for w in $words; do grep_args+=(--grep="$w"); done
    mentions=$(git log --all --all-match -i "${grep_args[@]}" --format=%h -- 2>/dev/null | wc -l | tr -d ' ')
  fi
  named=$(grep -oE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+`' "$f" | tr -d '`' | grep -E '/' | sort -u || true)
  total=$(printf '%s\n' "$named" | grep -c . || true)
  present=0; absent=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then present=$((present + 1)); else absent="$absent $p"; fi
  done <<< "$named"
  printf '| %s | %s | %s | %s | %s/%s |\n' "$f" "$pair" "$last" "$mentions" "$present" "$total"
  [ -z "$absent" ] || absent_report="$absent_report$f:$absent"$'\n'
done <<< "$files"

if [ -n "$absent_report" ]; then
  printf '\nArtifacts named but absent from the tree (a SHIPPED classification must explain each):\n'
  printf '%s' "$absent_report" | sed 's/^/- /'
fi
