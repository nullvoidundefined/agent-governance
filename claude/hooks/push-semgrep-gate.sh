#!/usr/bin/env bash
# push-semgrep-gate.sh: on `git push`, run the security rule pack in
# enforce/semgrep/ over every code file (.py .ts .tsx .js .mjs .go .rb) the
# outgoing range adds or changes, and deny the push when the pack reports a
# finding, naming each one as `path:line rule` (R-109, IAN-381). Modeled on
# push-ruff-gate.sh, with two deliberate differences. First, each changed file
# is scanned whole rather than only its added lines, because an insecure
# setting already on the base is still shipped by a push that touches its file.
# Second, this gate fails CLOSED: when no Semgrep resolves (CLAUDE_SEMGREP_CMD,
# then `semgrep`, then `uvx semgrep`), or when Semgrep crashes or prints output
# that is not a readable JSON report, the push is denied, because a security
# gate that silently skips is indistinguishable from a clean scan.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"
RULES_DIR="$ENFORCE_DIR/semgrep"

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

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null \
  | grep -E '\.(py|ts|tsx|js|mjs|go|rb)$' || true)
[ -z "$FILES" ] && exit 0

SEMGREP=$(resolve_semgrep_command)
if [ -z "$SEMGREP" ]; then
  emit_deny "R-109: push-semgrep-gate could not find Semgrep (tried CLAUDE_SEMGREP_CMD, semgrep, uvx semgrep), and this security gate fails closed. Install it (brew install semgrep, or pipx install semgrep, or install uv so uvx semgrep resolves), then push again."
  exit 0
fi

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$TOP" ]; then
  emit_deny "R-109: push-semgrep-gate could not resolve the repository root for the push, and this security gate fails closed."
  exit 0
fi

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT
# shellcheck disable=SC2086  # SEMGREP may be the two-word `uvx semgrep`
RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $SEMGREP --config "$RULES_DIR" --metrics=off --json --quiet 2>"$ERR_FILE")
SEMGREP_STATUS=$?
if [ "$SEMGREP_STATUS" -ge 2 ] || ! printf '%s' "$RESULTS" | jq -e '.results | type == "array"' >/dev/null 2>&1; then
  emit_deny "R-109: Semgrep crashed or printed no readable JSON report (exit $SEMGREP_STATUS), and this security gate fails closed. Semgrep said: $(head -c 400 "$ERR_FILE")"
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
