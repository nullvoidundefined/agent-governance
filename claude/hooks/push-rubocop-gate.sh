#!/usr/bin/env bash
# push-rubocop-gate.sh: on `git push`, run the bundled enforcement RuboCop
# config over the Ruby files added/changed in the outgoing diff. Deny the push
# on any violation of the AST-tier rule analogs (R-327 plus R-316/R-317/R-324
# naming support; cop mapping in enforce/rubocop-enforce.yml). Also runs the
# stdlib-only data-access checker, enforce/data-access/ruby_data_access.rb,
# over the same files: R-361 (a query per element: an ActiveRecord finder,
# connection-level SQL, or a query object inside a loop) and R-362 (network
# I/O, mailer delivery, or a job enqueue inside a transaction block). Sibling
# of push-eslint-gate/push-ruff-gate: heavy work once per push, added lines
# only (--added-only parity, 2026-07-10, Ian-approved). Each half fails OPEN
# on its own with a stderr note: no RuboCop skips only the cops, no ruby skips
# only the data-access checker, so one missing tool never silences the other.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
# A session can start this hook with HOME unset; under set -u every $HOME
# expansion below would abort before a decision, which is an allow (IAN-436).
: "${HOME:=$(cd ~ 2>/dev/null && pwd)}"

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

# Repo exemption: same allowlist as the other push gates (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.rb$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0

# The set of file:line pairs the outgoing diff adds; only these can deny.
# Computed once and shared by both halves below.
ADDED=$(run_git_on_target diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.rb' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

# --- RuboCop half ------------------------------------------------------------
# SECURITY (2026-07-31 security audit P0): never resolve RuboCop through the
# target repo's bundle. `bundle exec` evaluates that repo's Gemfile (arbitrary
# Ruby) at push time, handing a cloned repo code execution. PATH-resolved
# RuboCop with our explicit --config only parses source; it executes nothing
# from the repo. Repos wanting their own RuboCop version run it in their own
# pre-commit, not here.
RUBOCOP=""
if [ -n "${CLAUDE_RUBOCOP_CMD:-}" ]; then
  RUBOCOP="$CLAUDE_RUBOCOP_CMD"
elif command -v rubocop >/dev/null 2>&1; then
  RUBOCOP="rubocop"
else
  echo "push-rubocop-gate: no rubocop on PATH, skipping the RuboCop half (the data-access checker still runs)" >&2
fi

CONFIG="$ENFORCE_DIR/rubocop-enforce.yml"
REPORT=""
if [ -n "$RUBOCOP" ]; then
  RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUBOCOP --format json --config "$CONFIG" -- 2>/dev/null || true)
  if printf '%s' "$RESULTS" | jq -e '.files | type == "array"' >/dev/null 2>&1; then
    REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" '
      ($added | split("\n") | map(select(length > 0))) as $lines
      | [ .files[]
          | .path as $rel
          | .offenses[]
          | ($rel + ":" + (.location.start_line // .location.line | tostring)) as $key
          | select($lines | index($key))
          | "\($key) \(.cop_name) \(.message)" ]
      | .[]' 2>/dev/null || true)
  else
    echo "push-rubocop-gate: rubocop produced no parseable output, skipping the RuboCop half (fails open)" >&2
  fi
fi

# --- Data-access half (R-361, R-362) -----------------------------------------
# The checker uses only Ruby's standard library (Ripper, JSON), so it runs from
# any ruby on PATH without a Gemfile and without executing anything from the
# target repo: it parses the files, it does not load them. CLAUDE_RUBY_CMD
# overrides the binary so fixtures can point at a specific or a missing ruby,
# mirroring CLAUDE_RUBOCOP_CMD.
DA_CHECKER="$ENFORCE_DIR/data-access/ruby_data_access.rb"
RUBY_BIN="${CLAUDE_RUBY_CMD:-ruby}"
DA_REPORT=""
if ! command -v "$RUBY_BIN" >/dev/null 2>&1; then
  echo "push-rubocop-gate: no ruby on PATH, skipping the R-361/R-362 data-access checker" >&2
elif [ ! -f "$DA_CHECKER" ]; then
  echo "push-rubocop-gate: $DA_CHECKER is missing, skipping the R-361/R-362 data-access checker" >&2
else
  # An array, not xargs: xargs may split a long file list across several
  # invocations, which would print several JSON arrays jq cannot read as one.
  DA_FILES=()
  while IFS= read -r da_file; do
    [ -n "$da_file" ] && DA_FILES+=("$da_file")
  done <<< "$FILES"
  DA_RESULTS=""
  if [ "${#DA_FILES[@]}" -gt 0 ]; then
    DA_RESULTS=$(cd "$TOP" && "$RUBY_BIN" "$DA_CHECKER" "${DA_FILES[@]}" 2>/dev/null || true)
  fi
  if printf '%s' "$DA_RESULTS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    DA_REPORT=$(printf '%s' "$DA_RESULTS" | jq -r --arg added "$ADDED" '
      ($added | split("\n") | map(select(length > 0))) as $lines
      | [ .[]
          | (.file + ":" + (.line | tostring)) as $key
          | select($lines | index($key))
          | "\($key) \(.rule) \(.message)" ]
      | .[]' 2>/dev/null || true)
  else
    echo "push-rubocop-gate: the data-access checker produced no parseable output, skipping it (fails open)" >&2
  fi
fi

if [ -n "$REPORT" ] || [ -n "$DA_REPORT" ]; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  REASON=""
  if [ -n "$REPORT" ]; then
    log_rule_fire "rubocop-ast" "push-rubocop-gate" "deny"
    REASON="RuboCop enforcement failed on the outgoing diff (R-327 plus naming support; mapping in enforce/rubocop-enforce.yml). Fix the violations:
$REPORT"
  fi
  if [ -n "$DA_REPORT" ]; then
    log_rule_fire "data-access-ruby" "push-rubocop-gate" "deny"
    [ -n "$REASON" ] && REASON="$REASON

"
    REASON="${REASON}Data-access checks failed on the outgoing diff (R-361 query per element, R-362 network or enqueue inside a transaction; enforce/data-access/ruby_data_access.rb). Fix the findings, or mark a deliberate, bounded case with \`# data-access-allow: <reason>\` on or above the line:
$DA_REPORT"
  fi
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
