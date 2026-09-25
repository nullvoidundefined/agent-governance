#!/usr/bin/env bash
# push-semgrep-gate.sh: on `git push`, run the security rule pack in
# enforce/semgrep/ over every code file (.py .ts .tsx .mts .cts .js .jsx .mjs
# .cjs .go .rb) the outgoing range adds or changes, and deny the push when the
# pack reports a finding, naming each one as `path:line rule` (R-109, IAN-381).
# Modeled on push-ruff-gate.sh, with deliberate differences. Each changed file
# is scanned whole rather than only its added lines, because an insecure
# setting already on the base is still shipped by a push that touches its file.
# The scan judges what the push ships: each changed file's HEAD blob is
# exported into a fresh temporary directory and Semgrep runs there, so an
# uncommitted fix or a file deleted only from the working tree cannot change
# the outcome, and reported paths stay repo-relative. Semgrep runs with
# --disable-nosem, so a `# nosemgrep` comment cannot silence a finding, and
# with --disable-version-check. This gate fails CLOSED: the push is denied when
# the outgoing base cannot be resolved (CLAUDE_ENFORCE_BASE overrides it), when
# no Semgrep resolves (CLAUDE_SEMGREP_CMD, then `semgrep`, then `uvx
# semgrep`), when Semgrep crashes or prints output that is not a readable JSON
# report, and when the report carries any error (PartialParsing included) or
# any skipped path, because a partial scan is indistinguishable from a clean
# one. Semgrep's error recovery can also drop a finding from a file with a
# syntax error while reporting no error at all, so every exported file first
# gets a local parse check: ast.parse for .py under the pushed repository's
# .venv/bin/python3 when it is executable, else python3 on PATH, and `node
# --check` for .js .mjs .cjs when node is on PATH; a file that does not parse
# is denied. `node --check` detects ESM syntax in a .js file only from Node
# 22.7 on, so an older node can reject a valid ES module .js file. Known
# limit: .ts .tsx .mts .cts .jsx .go .rb have no guaranteed local parser, so
# for those the gate relies on Semgrep's own errors alone.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"
RULES_DIR="$ENFORCE_DIR/semgrep"
CODE_FILE_PATTERN='\.(py|ts|tsx|mts|cts|js|jsx|mjs|cjs|go|rb)$'

# Prints the PreToolUse deny decision with the given reason and logs the fire.
emit_deny() {
  local reason="$1"
  local log_rule_fire_helper
  log_rule_fire_helper="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$log_rule_fire_helper" ] && source "$log_rule_fire_helper"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "R-109" "push-semgrep-gate" "deny"
  jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

# Prints the Semgrep command to run, or nothing when none resolves. An
# explicit CLAUDE_SEMGREP_CMD that does not resolve counts as none.
resolve_semgrep_command() {
  if [ -n "${CLAUDE_SEMGREP_CMD:-}" ]; then
    command -v "${CLAUDE_SEMGREP_CMD%% *}" >/dev/null 2>&1 && printf '%s' "$CLAUDE_SEMGREP_CMD"
  elif command -v semgrep >/dev/null 2>&1; then
    printf 'semgrep'
  elif command -v uvx >/dev/null 2>&1; then
    printf 'uvx semgrep'
  fi
}

# Writes the HEAD blob of every newline-separated repo-relative path in $1
# under the directory $2, keeping the relative layout. Returns non-zero when
# any blob cannot be read.
export_head_files() {
  local file_list="$1" scan_dir="$2" file_path
  while IFS= read -r file_path; do
    [ -z "$file_path" ] && continue
    mkdir -p "$(dirname "$scan_dir/$file_path")" || return 1
    run_git_on_target show "HEAD:$file_path" > "$scan_dir/$file_path" 2>/dev/null || return 1
  done <<< "$file_list"
}

# Prints the Python interpreter for the parse check: the pushed repository's
# own <top level>/.venv/bin/python3 when it is executable, else python3 on
# PATH, so a project on a newer Python than the host is parsed by its own.
resolve_python_interpreter() {
  local repo_top_level
  repo_top_level=$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$repo_top_level" ] && [ -x "$repo_top_level/.venv/bin/python3" ]; then
    printf '%s' "$repo_top_level/.venv/bin/python3"
  else
    printf 'python3'
  fi
}

# Prints the version of the interpreter $1 for the deny message, or
# `unknown version` when it cannot report one.
describe_interpreter_version() {
  local interpreter="$1" interpreter_version
  interpreter_version=$("$interpreter" -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || true)
  printf '%s' "${interpreter_version:-unknown version}"
}

# Returns non-zero when the exported file $1 does not parse with its local
# parser: the interpreter in $PYTHON_INTERPRETER running ast.parse for .py, and
# `node --check` for .js .mjs .cjs when node resolves. A .py file with no
# interpreter fails, so the gate stays closed. Other extensions have no
# guaranteed local parser and pass here.
check_file_parses() {
  local file_path="$1"
  case "$file_path" in
    *.py)
      "$PYTHON_INTERPRETER" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$file_path" >/dev/null 2>&1 ;;
    *.js|*.mjs|*.cjs)
      if command -v node >/dev/null 2>&1; then node --check "$file_path" >/dev/null 2>&1; fi ;;
  esac
}

# Prints each newline-separated repo-relative path in $1 whose exported copy
# under the directory $2 does not parse, one per line.
list_unparsable_files() {
  local file_list="$1" scan_dir="$2" file_path
  while IFS= read -r file_path; do
    [ -z "$file_path" ] && continue
    check_file_parses "$scan_dir/$file_path" || printf '%s\n' "$file_path"
  done <<< "$file_list"
}

# Prints one line per Semgrep error and per skipped path in the JSON report
# on stdin, as `path: message`, or nothing when the scan was complete. Each
# branch is parenthesized because jq's comma binds tighter than its pipe:
# unparenthesized, every error line was piped into the skipped-path template,
# jq failed on it, and the report came out empty, which allowed the push.
list_incomplete_scan_entries() {
  jq -r '
    ((.errors // [])[]
      | "\(.path // (.spans[0].file // "<no path>")): \(.type | if type == "array" then .[0] else . end | tostring): \(.message // "" | tostring | .[0:300])"),
    ((.paths.skipped // [])[]
      | "\(.path // "<no path>"): skipped: \(.reason // "" | tostring)")
  ' 2>/dev/null
}

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`,
# then recover which repository the push names so that every query below runs
# against THAT repository (same normalization as push-ruff-gate.sh).
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  parse_git_target_options "$RAW_CMD" push
fi
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

# Repo exemption: same allowlist as the other push gates (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

# The shared resolver returns empty when nothing resolves; the linters treat
# that as a skip, while this security gate treats it as a denial.
BASE=$(resolve_outgoing_base)
if [ -z "$BASE" ]; then
  emit_deny "R-109: push-semgrep-gate could not resolve the outgoing base for this push (no upstream, no origin branch, no main or master), and this security gate fails closed. Set CLAUDE_ENFORCE_BASE to the ref the push starts from, then push again."
  exit 0
fi

if ! CHANGED_FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null); then
  emit_deny "R-109: push-semgrep-gate could not list the files changed in $BASE..HEAD, and this security gate fails closed. Set CLAUDE_ENFORCE_BASE to a ref that exists, then push again."
  exit 0
fi
FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -E "$CODE_FILE_PATTERN" || true)
[ -z "$FILES" ] && exit 0

SEMGREP=$(resolve_semgrep_command)
if [ -z "$SEMGREP" ]; then
  emit_deny "R-109: push-semgrep-gate could not find Semgrep (tried CLAUDE_SEMGREP_CMD, semgrep, uvx semgrep), and this security gate fails closed. Install it (brew install semgrep, or pipx install semgrep, or install uv so uvx semgrep resolves), then push again."
  exit 0
fi

ERR_FILE=$(mktemp)
SCAN_DIR=$(mktemp -d)
trap 'rm -f "$ERR_FILE"; rm -rf "$SCAN_DIR"' EXIT
if ! export_head_files "$FILES" "$SCAN_DIR"; then
  emit_deny "R-109: push-semgrep-gate could not export the pushed HEAD content of the changed files for scanning, and this security gate fails closed."
  exit 0
fi
# An empty ignore file stops Semgrep's default ignore list from silently
# skipping a pushed file (a tests/ directory, for example).
: > "$SCAN_DIR/.semgrepignore"

# Semgrep's error recovery can drop a finding from a file that does not parse
# without reporting any error, so a file that fails its local parse check is
# denied before Semgrep's result is trusted.
PYTHON_INTERPRETER=$(resolve_python_interpreter)
UNPARSABLE=$(list_unparsable_files "$FILES" "$SCAN_DIR")
if [ -n "$UNPARSABLE" ]; then
  unparsable_path=$(printf '%s\n' "$UNPARSABLE" | head -n 1)
  case "$unparsable_path" in
    *.py)
      parse_failure="$unparsable_path does not parse under $PYTHON_INTERPRETER ($(describe_interpreter_version "$PYTHON_INTERPRETER")), so the security scan cannot vouch for it; fix the syntax, or point .venv at the project's interpreter, and push again" ;;
    *)
      parse_failure="$unparsable_path does not parse under node ($(node --version 2>/dev/null || printf 'unknown version')), so the security scan cannot vouch for it; fix the syntax and push again" ;;
  esac
  emit_deny "R-109: $parse_failure. Files that do not parse:
$UNPARSABLE"
  exit 0
fi

TARGETS=()
while IFS= read -r file_path; do
  [ -n "$file_path" ] && TARGETS+=("$file_path")
done <<< "$FILES"

# shellcheck disable=SC2086  # SEMGREP may be the two-word `uvx semgrep`
RESULTS=$(cd "$SCAN_DIR" && $SEMGREP --config "$RULES_DIR" --metrics=off --disable-version-check --disable-nosem --json --quiet "${TARGETS[@]}" 2>"$ERR_FILE")
SEMGREP_STATUS=$?
if ! printf '%s' "$RESULTS" | jq -e '.results | type == "array"' >/dev/null 2>&1; then
  emit_deny "R-109: Semgrep crashed or printed no readable JSON report (exit $SEMGREP_STATUS), and this security gate fails closed. Semgrep said: $(head -c 400 "$ERR_FILE")"
  exit 0
fi

INCOMPLETE=$(printf '%s' "$RESULTS" | list_incomplete_scan_entries)
if [ -n "$INCOMPLETE" ]; then
  emit_deny "R-109: Semgrep could not fully scan files this push changes, and this security gate fails closed on a partial scan. Fix each file so it parses and is scanned whole, then push again:
$INCOMPLETE"
  exit 0
fi
if [ "$SEMGREP_STATUS" -ge 2 ]; then
  emit_deny "R-109: Semgrep crashed (exit $SEMGREP_STATUS), and this security gate fails closed. Semgrep said: $(head -c 400 "$ERR_FILE")"
  exit 0
fi

# check_id carries the config directory as a dotted prefix; the rule id is the
# last dotted component.
REPORT=$(printf '%s' "$RESULTS" | jq -r '.results[] | "\(.path):\(.start.line) \(.check_id | split(".") | last)"' 2>/dev/null)
if [ -n "$REPORT" ]; then
  emit_deny "R-109: the security rule pack (enforce/semgrep/) reported findings in files this push changes. Fix each one before pushing:
$REPORT"
fi
exit 0
