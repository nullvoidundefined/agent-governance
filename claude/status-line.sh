#!/usr/bin/env bash
# status-line.sh: the session HUD (hardening spec B-5). Reads the statusLine
# stdin JSON and prints one line: model | branch(+* when dirty) | context %
# | session cost | elapsed | 5h rate limit. Every field degrades to "-" when
# its input is null or absent (a percentage also when it falls outside
# 0..100, which is how an overflowed value renders on Linux), and every
# failure path still prints a line
# and exits 0: a broken HUD must never break the session.
set -uo pipefail

emit_fallback() { echo "claude | - | ctx - | \$- | - | 5h -%"; exit 0; }
trap emit_fallback ERR

INPUT=$(cat 2>/dev/null || true)
jq -e . >/dev/null 2>&1 <<<"$INPUT" || emit_fallback

field() { jq -r "$1 // empty" <<<"$INPUT" 2>/dev/null; }

MODEL=$(field '.model.display_name'); [ -n "$MODEL" ] || MODEL="claude"
CWD=$(field '.cwd'); [ -n "$CWD" ] || CWD=$(field '.workspace.current_dir')
BRANCH="-"
if [ -n "$CWD" ] && git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] || BRANCH="detached"
  [ -z "$(git -C "$CWD" status --porcelain 2>/dev/null | head -1)" ] || BRANCH="${BRANCH}*"
fi
CTX=$(field '.context_window.used_percentage')
if [ -n "$CTX" ] && CTX_FMT=$(printf '%.0f' "$CTX" 2>/dev/null) && [[ "$CTX_FMT" =~ ^[0-9]+$ ]] && [ "$CTX_FMT" -le 100 ]; then
  CTX="${CTX_FMT}%"
else
  CTX="-"
fi
COST=$(field '.cost.total_cost_usd')
if [ -n "$COST" ] && COST_FMT=$(printf '%.2f' "$COST" 2>/dev/null) && [[ "$COST_FMT" =~ ^-?[0-9]+\.[0-9]{2}$ ]]; then
  COST="$COST_FMT"
else
  COST="-"
fi
MS=$(field '.cost.total_duration_ms')
if [ -n "$MS" ] && [ "$MS" -gt 0 ] 2>/dev/null; then
  ELAPSED="$((MS / 3600000))h$(((MS % 3600000) / 60000))m"
else
  ELAPSED="-"
fi
RATE=$(field '.rate_limits.five_hour.used_percentage')
if [ -n "$RATE" ] && RATE_FMT=$(printf '%.0f' "$RATE" 2>/dev/null) && [[ "$RATE_FMT" =~ ^[0-9]+$ ]] && [ "$RATE_FMT" -le 100 ]; then
  RATE="$RATE_FMT"
else
  RATE="-"
fi

echo "$MODEL | $BRANCH | ctx $CTX | \$$COST | $ELAPSED | 5h ${RATE}%"
exit 0
