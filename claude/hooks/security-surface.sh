#!/usr/bin/env bash
# security-surface.sh: the security-surface detector, a sourced helper and not
# a hook (IAN-381, B-7, B-8, B-8c, and B-8d). It decides whether the range
# <base-oid>..<head-oid> of a repository touches a security surface, so the
# security merge gate can demand a security review only for the PRs that need
# one.
#
#   is_security_surface <repo-top> <base-oid> [<head-oid>]
#     returns 0 when the range touches a security surface, 1 when it does not.
#   list_security_surface_hits <repo-top> <base-oid> [<head-oid>]
#     prints one `path:line trigger` line per hit, trigger being `path`,
#     `content`, or `semgrep`; a path hit reports line 0. Returns 2 after
#     printing what it found when the detector itself failed.
#
# <head-oid> defaults to HEAD and names the commit whose file list, diffs, and
# blobs are read. A range is marked by any of three triggers: a changed path
# matching a `paths` regex in enforce/security-surface.json, an added or
# removed line matching a `content` regex there (both case-insensitive
# extended regexes; a removed line reports its pre-image line number), or a
# finding from the rule pack in enforce/semgrep/ on a changed code file. Every
# diff runs with --no-renames, so a rename lists its old path as a deletion,
# and the content diff runs with --text, so neither a NUL byte nor a `-diff`
# attribute can collapse a file into a `Binary files` line; any such line that
# still appears counts as a detector failure. Files matching a glob in the
# repository's `.enforce.json` `securitySurfaceExclude` list are skipped; that
# list is read from the base commit, so a range cannot exclude itself by
# adding the key. The Semgrep resolution and report checks are copied from
# push-semgrep-gate.sh rather than extracted, so that gate stays untouched.
#
# The detector fails CLOSED: when the patterns, the diff, or the Semgrep scan
# cannot be read (no Semgrep resolves, it crashes, its JSON is unreadable, it
# reports errors or skipped paths, or its `.paths.scanned` list leaves out any
# exported code target, compared exactly as the relative path passed from the
# export directory; the scan runs with --max-target-bytes=0 so no size limit
# drops a target), when scope-match.sh did not load, or
# when an exported code file does not parse (`.py` through the PATH python3 in
# isolated mode, `.js .mjs .cjs` through `node --check` when node is on PATH),
# is_security_surface returns 0, because a detector error must never excuse a
# PR from review. No interpreter the repository supplies is ever run.
#
# Sourced, never executed: nothing here sets shell options or traps, and every
# function prints or returns without exiting. bash 3.2 compatible.

SECURITY_SURFACE_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SURFACE_PATTERNS_FILE="$SECURITY_SURFACE_HOOK_DIR/../enforce/security-surface.json"
SECURITY_SURFACE_RULES_DIR="$SECURITY_SURFACE_HOOK_DIR/../enforce/semgrep"
SECURITY_SURFACE_CODE_FILE_PATTERN='\.(py|ts|tsx|mts|cts|js|jsx|mjs|cjs|go|rb)$'
# A missing scope-match.sh leaves is_in_scope undefined, which
# list_included_changed_files reports as a detector failure.
# shellcheck source=scope-match.sh
[ -f "$SECURITY_SURFACE_HOOK_DIR/scope-match.sh" ] && . "$SECURITY_SURFACE_HOOK_DIR/scope-match.sh"

# resolve_security_surface_semgrep_command: prints the Semgrep command to run
# (CLAUDE_SEMGREP_CMD, then `semgrep`, then `uvx semgrep`), or nothing when
# none resolves. An explicit CLAUDE_SEMGREP_CMD that does not resolve counts as
# none. Copied from push-semgrep-gate.sh.
resolve_security_surface_semgrep_command() {
  if [ -n "${CLAUDE_SEMGREP_CMD:-}" ]; then
    command -v "${CLAUDE_SEMGREP_CMD%% *}" >/dev/null 2>&1 && printf '%s' "$CLAUDE_SEMGREP_CMD"
  elif command -v semgrep >/dev/null 2>&1; then
    printf 'semgrep'
  elif command -v uvx >/dev/null 2>&1; then
    printf 'uvx semgrep'
  fi
}

# write_security_surface_patterns <kind> <output file>: writes the non-empty
# regexes of the pattern file's <kind> array, one per line. Returns non-zero
# when the file cannot be read or the array is missing or empty, so a broken
# pattern file never reads as "no pattern matches".
write_security_surface_patterns() {
  local pattern_kind="$1" output_file="$2"
  jq -r --arg k "$pattern_kind" '.[$k] | if type == "array" and length > 0 then .[] | strings | select(length > 0) else error("no patterns") end' \
    "$SECURITY_SURFACE_PATTERNS_FILE" > "$output_file" 2>/dev/null || return 1
  [ -s "$output_file" ]
}

# read_security_surface_excludes <repo-top> <base-oid>: prints one
# securitySurfaceExclude glob per line from the base commit's .enforce.json,
# or nothing when the file or the key is absent or unreadable. Nothing means
# no file is skipped, which marks more, never less.
read_security_surface_excludes() {
  local repo_top="$1" base_oid="$2"
  git -C "$repo_top" show "$base_oid:.enforce.json" 2>/dev/null \
    | jq -r '(.securitySurfaceExclude // []) | if type == "array" then .[] | strings else empty end' 2>/dev/null
}

# list_included_changed_files <repo-top> <base-oid> <head-oid>: prints every
# path the range changes that no exclude glob covers, one per line; a renamed
# file appears under both its old and its new path. Returns non-zero when
# is_in_scope is not defined or git cannot list the range.
list_included_changed_files() {
  local repo_top="$1" base_oid="$2" head_oid="$3" changed_files file_path
  local exclude_globs=()
  declare -F is_in_scope >/dev/null || return 1
  changed_files=$(git -c core.quotePath=false -C "$repo_top" diff --name-only --no-renames --no-ext-diff "$base_oid" "$head_oid" 2>/dev/null) || return 1
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && exclude_globs+=("$file_path")
  done < <(read_security_surface_excludes "$repo_top" "$base_oid")
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    if [ "${#exclude_globs[@]}" -gt 0 ] && is_in_scope "$file_path" "${exclude_globs[@]}"; then
      continue
    fi
    printf '%s\n' "$file_path"
  done <<< "$changed_files"
}

# list_path_hits <file list> <path patterns file>: prints `path:0 path` for
# each newline-separated path matching a path pattern. Returns non-zero when
# grep fails on the patterns.
list_path_hits() {
  local file_list="$1" patterns_file="$2" matched_paths grep_status
  matched_paths=$(printf '%s\n' "$file_list" | grep -Ei -f "$patterns_file")
  grep_status=$?
  [ "$grep_status" -le 1 ] || return 1
  [ -n "$matched_paths" ] && printf '%s\n' "$matched_paths" | sed 's/$/:0 path/'
  return 0
}

# write_changed_lines <repo-top> <base-oid> <head-oid> <file list>
# <locations file> <texts file>: writes each line the range adds to or removes
# from the listed files as a `path:line` entry in the locations file and its
# text, on the same line number, in the texts file. An added line carries its
# post-image path and line number, a removed line its pre-image ones. Returns
# non-zero when git cannot diff the range or the diff still holds a
# `Binary files` line despite --text.
write_changed_lines() {
  local repo_top="$1" base_oid="$2" head_oid="$3" file_list="$4" locations_file="$5" texts_file="$6" file_path
  local pathspecs=()
  : > "$locations_file"
  : > "$texts_file"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && pathspecs+=("$file_path")
  done <<< "$file_list"
  [ "${#pathspecs[@]}" -gt 0 ] || return 0
  git -c core.quotePath=false --literal-pathspecs -C "$repo_top" diff -U0 --text --no-renames --no-color \
    --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$base_oid" "$head_oid" -- "${pathspecs[@]}" 2>/dev/null \
    | LC_ALL=C awk -v locations="$locations_file" -v texts="$texts_file" '
        function strip_diff_path(header, prefix,   stripped) {
          stripped = substr(header, 5); sub(/\t$/, "", stripped); sub(prefix, "", stripped); return stripped
        }
        /^diff --git / { in_hunk = 0; next }
        /^Binary files / { has_binary = 1; next }
        !in_hunk && /^--- / { old_path = strip_diff_path($0, "^a/"); next }
        !in_hunk && /^\+\+\+ / { new_path = strip_diff_path($0, "^b/"); next }
        /^@@ / {
          in_hunk = 1
          match($0, / -[0-9]+/); old_line = substr($0, RSTART + 2, RLENGTH - 2) + 0
          match($0, / \+[0-9]+/); new_line = substr($0, RSTART + 2, RLENGTH - 2) + 0
          next
        }
        in_hunk && /^\+/ { print new_path ":" new_line > locations; print substr($0, 2) > texts; new_line++; next }
        in_hunk && /^-/ { print old_path ":" old_line > locations; print substr($0, 2) > texts; old_line++; next }
        END { if (has_binary) exit 3 }
      '
  # Copy both statuses at once: the first test would overwrite PIPESTATUS.
  local pipe_statuses="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  [ "$pipe_statuses" = "0 0" ]
}

# list_content_hits <repo-top> <base-oid> <head-oid> <file list> <content
# patterns file> <work dir>: prints `path:line content` for each added or
# removed line matching a content pattern. Returns non-zero when the diff or
# grep fails.
list_content_hits() {
  local repo_top="$1" base_oid="$2" head_oid="$3" file_list="$4" patterns_file="$5" work_dir="$6"
  local locations_file="$work_dir/changed-locations" texts_file="$work_dir/changed-texts" matched_lines grep_status
  write_changed_lines "$repo_top" "$base_oid" "$head_oid" "$file_list" "$locations_file" "$texts_file" || return 1
  matched_lines=$(LC_ALL=C grep -a -Ein -f "$patterns_file" "$texts_file")
  grep_status=$?
  [ "$grep_status" -le 1 ] || return 1
  [ -n "$matched_lines" ] || return 0
  printf '%s\n' "$matched_lines" | cut -d: -f1 \
    | awk 'NR == FNR { wanted[$1] = 1; next } FNR in wanted { print $0 " content" }' - "$locations_file"
}

# export_security_surface_code_files <repo-top> <head-oid> <file list> <scan
# dir>: writes the <head-oid> blob of every listed code file that exists there
# under the scan dir, keeping the relative layout, and prints each exported
# path. Returns non-zero when a blob cannot be written.
export_security_surface_code_files() {
  local repo_top="$1" head_oid="$2" file_list="$3" scan_dir="$4" file_path
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    printf '%s\n' "$file_path" | grep -Eq "$SECURITY_SURFACE_CODE_FILE_PATTERN" || continue
    git -C "$repo_top" cat-file -e "$head_oid:$file_path" 2>/dev/null || continue
    mkdir -p "$(dirname "$scan_dir/$file_path")" || return 1
    git -C "$repo_top" show "$head_oid:$file_path" > "$scan_dir/$file_path" 2>/dev/null || return 1
    printf '%s\n' "$file_path"
  done <<< "$file_list"
}

# check_python_files_parse <file>...: returns 0 when the PATH python3, in
# isolated mode so nothing beside the files can shadow the standard library,
# parses every file, and non-zero when any fails or python3 cannot run.
check_python_files_parse() {
  python3 -I -c 'import ast, sys
for source_path in sys.argv[1:]:
    with open(source_path, "rb") as source_file:
        ast.parse(source_file.read(), source_path)' "$@" >/dev/null 2>&1
}

# check_script_files_parse <file>...: returns 0 when node is not on PATH or
# `node --check` accepts every file, non-zero when node rejects one.
check_script_files_parse() {
  local script_path
  command -v node >/dev/null 2>&1 || return 0
  for script_path in "$@"; do
    node --check "$script_path" >/dev/null 2>&1 || return 1
  done
}

# check_security_surface_code_parses <scan dir> <target>...: parse-checks the
# exported `.py` and `.js .mjs .cjs` targets, so a file Semgrep could not
# parse is never read as clean. Returns non-zero when any target fails.
check_security_surface_code_parses() {
  local scan_dir="$1" target_path
  local python_files=() script_files=()
  shift
  for target_path in "$@"; do
    case "$target_path" in
      *.py) python_files+=("$scan_dir/$target_path") ;;
      *.js|*.mjs|*.cjs) script_files+=("$scan_dir/$target_path") ;;
    esac
  done
  if [ "${#python_files[@]}" -gt 0 ]; then
    check_python_files_parse "${python_files[@]}" || return 1
  fi
  if [ "${#script_files[@]}" -gt 0 ]; then
    check_script_files_parse "${script_files[@]}" || return 1
  fi
  return 0
}

# run_security_surface_semgrep <scan dir> <target>...: runs the rule pack over
# the targets inside the scan dir and prints Semgrep's JSON report. Returns
# non-zero when no Semgrep resolves or it exits 2 or above.
run_security_surface_semgrep() {
  local scan_dir="$1" semgrep_command
  shift
  semgrep_command=$(resolve_security_surface_semgrep_command)
  [ -n "$semgrep_command" ] || return 1
  # An empty ignore file stops Semgrep's default ignore list from skipping a
  # target (a tests/ directory, for example).
  : > "$scan_dir/.semgrepignore"
  # shellcheck disable=SC2086  # the command may be the two-word `uvx semgrep`
  # --max-target-bytes=0 lifts the default 1 MB limit, over which Semgrep
  # silently leaves a target out of the scan.
  (cd "$scan_dir" && $semgrep_command --config "$SECURITY_SURFACE_RULES_DIR" --metrics=off \
    --disable-version-check --disable-nosem --max-target-bytes=0 --json --quiet "$@" 2>/dev/null)
  [ "$?" -lt 2 ]
}

# read_semgrep_findings: reads a Semgrep JSON report on stdin and prints
# `path:line semgrep` per finding. Returns non-zero when the report is not
# readable JSON with a results array, or carries any error or skipped path,
# because a partial scan is indistinguishable from a clean one. The trailing
# empty output keeps `jq -e` at status 0 on a clean report with no results;
# sed drops it.
read_semgrep_findings() {
  jq -er '
    if (.results | type) == "array"
       and ((.errors // []) | length) == 0
       and ((.paths.skipped // []) | length) == 0
    then (.results[] | "\(.path):\(.start.line) semgrep"), ""
    else error("incomplete report") end
  ' 2>/dev/null | sed '/^$/d'
  # Copy both statuses at once: the first test would overwrite PIPESTATUS.
  local pipe_statuses="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  [ "$pipe_statuses" = "0 0" ]
}

# list_unscanned_semgrep_targets <report> <target>...: prints each target the
# Semgrep JSON report does not list under `.paths.scanned`, compared exactly as
# passed, one per line. Returns non-zero when the report has no scanned array.
list_unscanned_semgrep_targets() {
  local semgrep_report="$1"
  shift
  jq -r '
    (.paths.scanned | if type == "array" then . else error("no scanned list") end) as $scanned
    | $ARGS.positional - $scanned | .[]
  ' --args "$@" <<< "$semgrep_report" 2>/dev/null
}

# check_semgrep_targets_scanned <report> <target>...: returns 0 when the report
# lists every target as scanned, and non-zero after naming each unscanned
# target on stderr, or when the scanned list cannot be read, because a target
# Semgrep silently left out is indistinguishable from a clean one.
check_semgrep_targets_scanned() {
  local unscanned_targets target_path
  unscanned_targets=$(list_unscanned_semgrep_targets "$@") || {
    echo "security-surface: the Semgrep report has no readable scanned-path list" >&2
    return 1
  }
  [ -n "$unscanned_targets" ] || return 0
  while IFS= read -r target_path; do
    echo "security-surface: Semgrep did not scan $target_path" >&2
  done <<< "$unscanned_targets"
  return 1
}

# list_semgrep_hits <repo-top> <head-oid> <file list> <work dir>: prints
# `path:line semgrep` for each rule-pack finding in the listed code files, or
# nothing when none of them is a code file. Returns non-zero when a code file
# does not parse, the scan fails, or the report leaves a target unscanned.
list_semgrep_hits() {
  local repo_top="$1" head_oid="$2" file_list="$3" scan_dir="$4/scan" exported_files semgrep_report file_path
  local scan_targets=()
  mkdir -p "$scan_dir" || return 1
  exported_files=$(export_security_surface_code_files "$repo_top" "$head_oid" "$file_list" "$scan_dir") || return 1
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && scan_targets+=("$file_path")
  done <<< "$exported_files"
  [ "${#scan_targets[@]}" -gt 0 ] || return 0
  check_security_surface_code_parses "$scan_dir" "${scan_targets[@]}" || return 1
  semgrep_report=$(run_security_surface_semgrep "$scan_dir" "${scan_targets[@]}") || return 1
  printf '%s' "$semgrep_report" | read_semgrep_findings || return 1
  check_semgrep_targets_scanned "$semgrep_report" "${scan_targets[@]}"
}

# collect_security_surface_hits <repo-top> <base-oid> <head-oid> <work dir>:
# prints every path, content, and Semgrep hit in the range. Returns non-zero
# when any trigger could not be evaluated.
collect_security_surface_hits() {
  local repo_top="$1" base_oid="$2" head_oid="$3" work_dir="$4" included_files
  local path_patterns_file="$work_dir/path-patterns" content_patterns_file="$work_dir/content-patterns"
  write_security_surface_patterns paths "$path_patterns_file" || return 1
  write_security_surface_patterns content "$content_patterns_file" || return 1
  included_files=$(list_included_changed_files "$repo_top" "$base_oid" "$head_oid") || return 1
  [ -n "$included_files" ] || return 0
  list_path_hits "$included_files" "$path_patterns_file" || return 1
  list_content_hits "$repo_top" "$base_oid" "$head_oid" "$included_files" "$content_patterns_file" "$work_dir" || return 1
  list_semgrep_hits "$repo_top" "$head_oid" "$included_files" "$work_dir" || return 1
}

# list_security_surface_hits <repo-top> <base-oid> [<head-oid>]: prints each
# hit once as `path:line trigger`. Returns 2 when the detector failed, after
# printing the hits it did find and naming the failure on stderr.
list_security_surface_hits() {
  local repo_top="$1" base_oid="$2" head_oid="${3:-HEAD}" work_dir hits collect_status
  work_dir=$(mktemp -d) || return 2
  hits=$(collect_security_surface_hits "$repo_top" "$base_oid" "$head_oid" "$work_dir")
  collect_status=$?
  rm -rf "$work_dir"
  [ -n "$hits" ] && printf '%s\n' "$hits" | awk '!seen[$0]++'
  if [ "$collect_status" -ne 0 ]; then
    echo "security-surface: the detector could not evaluate $base_oid..$head_oid in $repo_top; treat the range as security-touching" >&2
    return 2
  fi
  return 0
}

# is_security_surface <repo-top> <base-oid> [<head-oid>]: returns 0 when the
# range touches a security surface or the detector failed (fail closed), 1
# otherwise.
is_security_surface() {
  local hits
  hits=$(list_security_surface_hits "$1" "$2" "${3:-HEAD}") || return 0
  [ -n "$hits" ] && return 0
  return 1
}
