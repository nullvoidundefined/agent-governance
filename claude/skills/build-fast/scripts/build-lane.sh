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
BUILD_LANE_HARNESS_ROOT="${CLAUDE_HARNESS_ROOT:-$(cd "$BUILD_LANE_DIR/../../.." && pwd)}"
BUILD_LANE_SECURITY_FILE="$BUILD_LANE_HARNESS_ROOT/enforce/security-surface.json"
BUILD_LANE_DETECTOR="$BUILD_LANE_HARNESS_ROOT/hooks/security-surface.sh"

# printRawLane <lane> <reason>: prints the one output line and exits 0.
printRawLane() {
  printf '%s %s\n' "$1" "$2"
  exit 0
}

# readLaneOverride: prints laneOverride from the checkout's task-tier ledger
# when the ledger parses and names the checked-out branch; nothing otherwise,
# so an empty, truncated, or foreign ledger never changes the lane.
readLaneOverride() {
  local top branch ledger
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  ledger="$top/.claude/task-tier.json"
  [ -s "$ledger" ] || return 0
  jq -r --arg b "$branch" 'select(.branch == $b) | .laneOverride // "" | strings' "$ledger" 2>/dev/null || true
}

# printLane <lane> <reason>: applies the owner's lane override, then prints.
# A raise always applies; a lower applies only to a security-surface or path
# reason, and a lowered security-surface reason carries r109-required; a
# failure reason is never lowered.
printLane() {
  local detectedLane="$1" reason="$2" override
  override=$(readLaneOverride)
  if [ -z "$override" ] || [ "$override" = "$detectedLane" ]; then printRawLane "$detectedLane" "$reason"; fi
  if [ "$override" = guarded ]; then printRawLane guarded "$reason; override from $detectedLane"; fi
  case "$reason" in
    security-surface:*) printRawLane fast "$reason; override from $detectedLane; r109-required" ;;
    path:*) printRawLane fast "$reason; override from $detectedLane" ;;
    *) printRawLane "$detectedLane" "$reason" ;;
  esac
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

# findGuardedPattern <path>: prints the first guardedPaths pattern the path
# matches, case-insensitively, and returns 0; returns 1 when none matches.
findGuardedPattern() {
  local candidatePath="$1" pattern
  for pattern in "${GUARDED_PATTERNS[@]}"; do
    if printf '%s\n' "$candidatePath" | grep -Eiq -- "$pattern"; then
      printf '%s' "$pattern"
      return 0
    fi
  done
  return 1
}

# readPrBaseRef: prints the base branch of the current branch's PR, or nothing
# when gh is absent, fails, or finds no PR.
readPrBaseRef() {
  command -v gh >/dev/null 2>&1 || return 0
  gh pr view --json baseRefName -q .baseRefName 2>/dev/null </dev/null || true
}

# readDefaultBaseRef: prints origin's default branch name from origin/HEAD, or
# returns 1 when origin/HEAD is not set.
readDefaultBaseRef() {
  local symbolic
  symbolic=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
  printf '%s' "${symbolic#origin/}"
}

# resolveRange <base-arg> <head-arg>: sets RANGE_TOP, RANGE_BASE, and RANGE_HEAD
# as commit IDs, or sets RANGE_ERROR and returns 1. The default base is the
# merge base with origin/<PR base or default branch>, fetched first; local main
# is never read.
resolveRange() {
  local baseArg="$1" headArg="${2:-HEAD}" baseRef
  RANGE_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { RANGE_ERROR="not inside a git repository"; return 1; }
  RANGE_HEAD=$(git rev-parse --verify --quiet "$headArg^{commit}") || { RANGE_ERROR="head '$headArg' is not a commit"; return 1; }
  if [ -n "$baseArg" ]; then
    RANGE_BASE=$(git rev-parse --verify --quiet "$baseArg^{commit}") || { RANGE_ERROR="base '$baseArg' is not a commit"; return 1; }
    return 0
  fi
  baseRef=$(readPrBaseRef)
  if [ -z "$baseRef" ]; then
    baseRef=$(readDefaultBaseRef) || { RANGE_ERROR="no PR base and no origin/HEAD"; return 1; }
  fi
  git fetch --quiet origin "$baseRef" 2>/dev/null </dev/null || true
  git rev-parse --verify --quiet "refs/remotes/origin/$baseRef^{commit}" >/dev/null || { RANGE_ERROR="origin/$baseRef does not resolve"; return 1; }
  RANGE_BASE=$(git merge-base "refs/remotes/origin/$baseRef" "$RANGE_HEAD" 2>/dev/null) || { RANGE_ERROR="no merge base with origin/$baseRef"; return 1; }
}

# readDetectorTimeout: CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS, or 30 when it
# is unset or not a whole number (the default git-workflow-guard.sh uses).
readDetectorTimeout() {
  local timeoutSeconds="${CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS:-}"
  case "$timeoutSeconds" in '' | *[!0-9]*) timeoutSeconds=30 ;; esac
  printf '%s' "$timeoutSeconds"
}

# runDetectorWithDeadline: runs list_security_surface_hits on the resolved range
# in its own process group, copied from git-workflow-guard.sh's
# run_security_detector_with_deadline rather than extracted, so the guard stays
# untouched. Sets DETECTOR_FIRST_HIT and returns the detector's status, or 3 on
# a timeout or when no work directory can be made. The work root is removed on
# every path, a killed detector included.
runDetectorWithDeadline() {
  local deadlineSteps waitedSteps=0 detectorRoot detectorPid detectorStatus
  DETECTOR_FIRST_HIT=""
  deadlineSteps=$(( $(readDetectorTimeout) * 5 ))
  detectorRoot=$(mktemp -d "${TMPDIR:-/tmp}/build-lane-detector.XXXXXX") || return 3
  # shellcheck disable=SC2034  # read by the sourced security-surface.sh in the detector subshell
  SECURITY_SURFACE_WORK_ROOT="$detectorRoot"
  set -m
  list_security_surface_hits "$RANGE_TOP" "$RANGE_BASE" "$RANGE_HEAD" >"$detectorRoot/hits" 2>"$detectorRoot/log" </dev/null &
  detectorPid=$!
  set +m
  while kill -0 "$detectorPid" 2>/dev/null; do
    if [ "$waitedSteps" -ge "$deadlineSteps" ]; then
      kill -KILL -- "-$detectorPid" 2>/dev/null
      wait "$detectorPid" 2>/dev/null
      rm -rf "$detectorRoot"
      return 3
    fi
    sleep 0.2
    waitedSteps=$((waitedSteps + 1))
  done
  wait "$detectorPid"
  detectorStatus=$?
  DETECTOR_FIRST_HIT=$(head -n 1 "$detectorRoot/hits")
  rm -rf "$detectorRoot"
  return "$detectorStatus"
}

# classifySecurity: prints guarded and exits when the detector is missing,
# fails, times out, or reports a hit; returns when the range is clear.
classifySecurity() {
  local detectorStatus
  [ -f "$BUILD_LANE_DETECTOR" ] || printLane guarded "detector-failure: $BUILD_LANE_DETECTOR missing"
  # shellcheck source=/dev/null
  . "$BUILD_LANE_DETECTOR"
  runDetectorWithDeadline
  detectorStatus=$?
  case "$detectorStatus" in
    0) [ -z "$DETECTOR_FIRST_HIT" ] || printLane guarded "security-surface: $DETECTOR_FIRST_HIT" ;;
    3) printLane guarded "detector-failure: no answer within $(readDetectorTimeout)s" ;;
    *) printLane guarded "detector-failure: security-surface.sh returned $detectorStatus" ;;
  esac
}

# classifyRange [--base <oid>] [--head <oid>]: the classify command: range,
# then the security detector, then the guarded path rules, else fast.
classifyRange() {
  local baseArg="" headArg="HEAD" changedPath changedCount=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) baseArg="${2:-}"; shift 2 2>/dev/null || shift ;;
      --head) headArg="${2:-HEAD}"; shift 2 2>/dev/null || shift ;;
      *) printLane guarded "config-failure: unknown option '$1'" ;;
    esac
  done
  resolveRange "$baseArg" "$headArg" || printLane guarded "range-failure: $RANGE_ERROR"
  classifySecurity
  while IFS= read -r -d '' changedPath; do
    changedCount=$((changedCount + 1))
    findGuardedPattern "$changedPath" >/dev/null && printLane guarded "path: $changedPath"
  done < <(git -C "$RANGE_TOP" diff --name-only --no-renames -z "$RANGE_BASE" "$RANGE_HEAD")
  printLane fast "clear: $changedCount files"
}

# listScopeCandidates <glob>...: prints each glob's text, then every tracked
# file the glob matches, its * crossing directory separators as
# scope-widening-gate.sh matches scope entries.
listScopeCandidates() {
  local scopeGlob trackedPath
  for scopeGlob in "$@"; do
    printf '%s\n' "$scopeGlob"
    while IFS= read -r trackedPath; do
      # shellcheck disable=SC2053  # the glob is intentionally unquoted to match
      [[ "$trackedPath" == $scopeGlob ]] && printf '%s\n' "$trackedPath"
    done < <(git ls-files 2>/dev/null)
  done
}

# findSecurityPathPattern <path>: prints the first enforce/security-surface.json
# `paths` regex the path matches, case-insensitively; returns 1 when none does.
findSecurityPathPattern() {
  local candidatePath="$1" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if printf '%s\n' "$candidatePath" | grep -Eiq -- "$pattern"; then
      printf '%s' "$pattern"
      return 0
    fi
  done < <(jq -r '.paths[]? // empty' "$BUILD_LANE_SECURITY_FILE" 2>/dev/null)
  return 1
}

# predictScope <glob>...: the predict command: a security path first, then a
# guarded path, else fast.
predictScope() {
  local candidatePath matchedPattern
  [ $# -gt 0 ] || printLane guarded "config-failure: predict needs at least one scope glob"
  jq -e '.paths | type == "array"' "$BUILD_LANE_SECURITY_FILE" >/dev/null 2>&1 \
    || printLane guarded "config-failure: $BUILD_LANE_SECURITY_FILE unreadable"
  while IFS= read -r candidatePath; do
    matchedPattern=$(findSecurityPathPattern "$candidatePath") && printLane guarded "security-surface: predicted $matchedPattern"
  done < <(listScopeCandidates "$@")
  while IFS= read -r candidatePath; do
    matchedPattern=$(findGuardedPattern "$candidatePath") && printLane guarded "path: predicted $matchedPattern"
  done < <(listScopeCandidates "$@")
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
