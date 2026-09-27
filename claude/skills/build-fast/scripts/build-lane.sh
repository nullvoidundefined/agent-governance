#!/usr/bin/env bash
# build-lane.sh: build-fast's lane classifier (IAN-401, spec
# 2026-09-27-build-fast-design.md B-1 and B-2). Prints one line, "<lane>
# <reason>", and exits 0; the lane is fast or guarded. `predict <glob>...`
# decides from the declared scope before any code exists; `classify [--base
# <oid>] [--head <oid>]` decides from a committed range. Every failure prints a
# guarded line, because a classifier that cannot answer must never let a change
# run fast. Bash 3.2 compatible, like the hooks/security-surface.sh it sources.
set -uo pipefail

BUILD_LANE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_LANE_RULES_FILE="${BUILD_LANE_RULES:-$BUILD_LANE_DIR/../lane-rules.json}"

# printLane <lane> <reason>: prints the one output line and exits 0.
printLane() {
  printf '%s %s\n' "$1" "$2"
  exit 0
}

# loadLaneRules <file>: fills GUARDED_PATTERNS from guardedPaths, or sets
# LANE_RULES_ERROR and returns 1 when the file is missing, is not a JSON
# object, lacks a non-empty list of non-empty strings, or holds a pattern
# grep -E rejects (grep exits 2 on a bad pattern and 1 on no match).
loadLaneRules() {
  local rulesFile="$1" pattern grepStatus
  GUARDED_PATTERNS=()
  [ -f "$rulesFile" ] || { LANE_RULES_ERROR="lane rules file missing: $rulesFile"; return 1; }
  jq -e 'type == "object"' "$rulesFile" >/dev/null 2>&1 \
    || { LANE_RULES_ERROR="lane rules file is not a JSON object"; return 1; }
  jq -e '.guardedPaths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' "$rulesFile" >/dev/null 2>&1 \
    || { LANE_RULES_ERROR="guardedPaths must be a non-empty list of non-empty strings"; return 1; }
  while IFS= read -r pattern; do
    printf 'x\n' | grep -Eiq -- "$pattern" 2>/dev/null
    grepStatus=$?
    [ "$grepStatus" -le 1 ] || { LANE_RULES_ERROR="guardedPaths pattern rejected by grep -E: $pattern"; return 1; }
    GUARDED_PATTERNS+=("$pattern")
  done < <(jq -r '.guardedPaths[]' "$rulesFile")
}

# classifyRange: the classify command; the range and security checks arrive in
# later slices of IAN-401.
classifyRange() {
  printLane fast "clear: 0 files"
}

# predictScope: the predict command; the scope checks arrive in a later slice.
predictScope() {
  printLane fast "predicted"
}

# runBuildLane <command> <args...>: loads the rules, failing closed, then
# dispatches to the command.
runBuildLane() {
  local command="${1:-}"
  shift || true
  loadLaneRules "$BUILD_LANE_RULES_FILE" || printLane guarded "config-failure: $LANE_RULES_ERROR"
  case "$command" in
    classify) classifyRange "$@" ;;
    predict) predictScope "$@" ;;
    *) printLane guarded "config-failure: usage: build-lane.sh classify [--base <oid>] [--head <oid>] | predict <glob>..." ;;
  esac
}

runBuildLane "$@"
