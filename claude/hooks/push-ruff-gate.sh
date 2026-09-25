#!/usr/bin/env bash
# push-ruff-gate.sh: on `git push`, run the bundled enforcement ruff config over
# the Python files added/changed in the outgoing diff. Deny the push on any
# violation of the AST-tier rule analogs (R-324/R-326/R-329/R-342/R-344; code mapping in
# enforce/ruff-enforce.toml). It also runs the standard-library data-access
# checker (enforce/data-access/python_data_access.py) over the same files,
# which decides the Python halves of R-361 (a query per loop iteration, the
# N+1) and R-362 (network I/O, or a statement off the transaction's
# connection, inside an explicit begin()/begin_nested() block), because ruff
# cannot load custom rules. The Python counterpart of push-eslint-gate.sh:
# heavy work runs once per push, not per edit; only lines the outgoing diff
# adds can deny (--added-only parity, 2026-07-10, Ian-approved). Each tool
# fails OPEN on its own with a stderr note when it is unavailable (no ruff or
# uvx, or no python3), because a missing tool must not block legitimate work,
# and one tool missing must not switch the other off.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`
# (2026-09-16 audit P2-1; the normalizer lives once in git-invocation.sh),
# then recover which repository the push names so that every query below
# runs against THAT repository (2026-09-18 audit, defect 4).
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), which is a silent
# fail-open for a guard.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  # The target is read from the UNSTRIPPED command, because stripping is
  # exactly what throws it away (2026-09-18 audit, defect 4).
  parse_git_target_options "$RAW_CMD" push
fi
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

# Repo exemption: same allowlist as push-eslint-gate (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.py$' || true)
[ -z "$FILES" ] && exit 0

# Resolve both tools before any heavy work. A missing tool no longer exits
# the gate early: ruff absent still lets the data-access checker run, and
# python3 absent still lets ruff run; only when both are absent is there
# nothing to do.
RUFF=""
if [ -n "${CLAUDE_RUFF_CMD:-}" ]; then
  RUFF="$CLAUDE_RUFF_CMD"
elif command -v ruff >/dev/null 2>&1; then
  RUFF="ruff"
elif command -v uvx >/dev/null 2>&1; then
  RUFF="uvx ruff"
else
  echo "push-ruff-gate: no ruff or uvx on PATH, skipping the ruff AST checks (install ruff or uv)" >&2
fi

# CLAUDE_PYTHON_CMD mirrors CLAUDE_RUFF_CMD so a fixture can drive the
# missing-interpreter path without rebuilding PATH.
DATA_ACCESS_CHECKER="$ENFORCE_DIR/data-access/python_data_access.py"
PYTHON_CMD="${CLAUDE_PYTHON_CMD:-python3}"
RUN_CHECKER=1
if ! command -v "$PYTHON_CMD" >/dev/null 2>&1; then
  echo "push-ruff-gate: no python3 on PATH, skipping the R-361/R-362 data-access checker" >&2
  RUN_CHECKER=0
elif [ ! -f "$DATA_ACCESS_CHECKER" ]; then
  echo "push-ruff-gate: data-access checker missing at $DATA_ACCESS_CHECKER, skipping it (fails open)" >&2
  RUN_CHECKER=0
fi
[ -z "$RUFF" ] && [ "$RUN_CHECKER" = 0 ] && exit 0

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0
CONFIG="$ENFORCE_DIR/ruff-enforce.toml"

# R-320's Python analog (D100 module docstring, D103 public-function docstring)
# shares the ESLint header rule's opt-in switch, .enforce.json fileHeaders, so a
# repo turns file headers on for both languages at once and minimal fixtures
# elsewhere never need a docstring.
EXTRA_SELECT=""
if [ -f "$TOP/.enforce.json" ] && jq -e '.fileHeaders == true' "$TOP/.enforce.json" >/dev/null 2>&1; then
  EXTRA_SELECT="--extend-select D100,D103"
fi

# The set of file:line pairs the outgoing diff adds; only these can deny.
ADDED=$(run_git_on_target diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.py' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

# Ruff and the checker each yield "path:line CODE message" lines filtered to
# the added set; the jq filter is shared so both tools are scoped the same way.
# ruff reports absolute filenames, and the checker echoes the relative paths
# it was given, so stripping the top-level prefix normalizes both.
ADDED_FILTER='($added | split("\n") | map(select(length > 0))) as $lines
  | [ .[]
      | (.file | ltrimstr($top)) as $rel
      | ($rel + ":" + (.line | tostring)) as $key
      | select($lines | index($key))
      | "\($rel):\(.line) \(.code) \(.message)" ]
  | .[]'

RUFF_REPORT=""
if [ -n "$RUFF" ]; then
  RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUFF check --config "$CONFIG" $EXTRA_SELECT --output-format json --no-cache 2>/dev/null || true)
  if printf '%s' "$RESULTS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    RUFF_REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" --arg top "$TOP/" \
      "map({file: .filename, line: .location.row, code: .code, message: .message}) | $ADDED_FILTER" 2>/dev/null || true)
  else
    # An unparseable ruff run used to end the gate here; it now skips only
    # ruff, so the data-access checker still judges the push.
    echo "push-ruff-gate: ruff produced no parseable output, skipping the ruff checks (fails open)" >&2
  fi
fi

DATA_ACCESS_REPORT=""
if [ "$RUN_CHECKER" = 1 ]; then
  # xargs may split a long file list into several runs, each printing its own
  # JSON array, so jq -s concatenates them before filtering.
  CHECKER_RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs "$PYTHON_CMD" "$DATA_ACCESS_CHECKER" 2>/dev/null || true)
  if printf '%s' "$CHECKER_RESULTS" | jq -s -e 'length > 0 and all(type == "array")' >/dev/null 2>&1; then
    DATA_ACCESS_REPORT=$(printf '%s' "$CHECKER_RESULTS" | jq -r -s --arg added "$ADDED" --arg top "$TOP/" \
      "add | map({file: .file, line: .line, code: .rule, message: .message}) | $ADDED_FILTER" 2>/dev/null || true)
  else
    echo "push-ruff-gate: the data-access checker produced no parseable output, skipping it (fails open)" >&2
  fi
fi

REPORT=$(printf '%s\n%s\n' "$RUFF_REPORT" "$DATA_ACCESS_REPORT" | grep -v '^$' || true)

if [ -n "$REPORT" ]; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  [ -n "$RUFF_REPORT" ] && log_rule_fire "ruff-ast" "push-ruff-gate" "deny"
  [ -n "$DATA_ACCESS_REPORT" ] && log_rule_fire "python-data-access" "push-ruff-gate" "deny"
  jq -n --arg r "Python enforcement failed on the outgoing diff (ruff: R-324/R-326/R-329/R-342/R-344 analogs, mapping in enforce/ruff-enforce.toml; data-access checker: R-361/R-362, silenced only by a \`# data-access-allow: <reason>\` comment). Fix the violations:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
