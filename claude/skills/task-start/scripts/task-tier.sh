#!/usr/bin/env bash
# task-tier.sh: the task-start skill's ledger (2026-09-17 skills audit, S-8).
# The tier task-start announces, the reason, the R-503 start timestamp, and
# the branch lived only in the transcript, so after a compaction the tier
# task-cleanup scales its work by was whatever the model recalled. This
# writes them to .claude/task-tier.json at the repo root, where task-cleanup's
# scan reads them and post-compact-rules.sh re-injects them.
#
# Usage:
#   task-tier.sh set <trivial|standard|complex|saga> "<reason>" [--share <percent>]
#   task-tier.sh get          prints the ledger as JSON (exit 1 when none)
#   task-tier.sh summary      one line: tier, reason, elapsed, branch
#   task-tier.sh clear        removes the ledger (task-cleanup's last step)
# The ledger is session state like .claude/tdd-lock.json: keep it out of
# commits (the script warns once when the project does not ignore it).
set -uo pipefail

LEDGER_RELATIVE=".claude/task-tier.json"
die() { printf 'task-tier: %s\n' "$*" >&2; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
LEDGER="$ROOT/$LEDGER_RELATIVE"

cmd_set() {
  local tier="${1:-}" reason="${2:-}" share=""
  shift 2 2>/dev/null || true
  if [ "${1:-}" = "--share" ]; then share="${2:-}"; fi
  case "$tier" in trivial|standard|complex|saga) ;; *) die "tier must be trivial, standard, complex, or saga (got '${tier}')" ;; esac
  [ -n "$reason" ] || die "give the one-sentence reason for the tier as the second argument"
  local previous=""
  [ -f "$LEDGER" ] && previous=$(jq -r '.tier // ""' "$LEDGER" 2>/dev/null)
  mkdir -p "$ROOT/.claude"
  jq -n --arg tier "$tier" --arg reason "$reason" --arg share "$share" \
        --arg branch "$(git -C "$ROOT" branch --show-current 2>/dev/null)" \
        --arg previous "$previous" --argjson started "$(date +%s)" \
        --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {tier: $tier, reason: $reason, branch: $branch, startedAt: $started, startedAtIso: $iso}
    + (if $share != "" then {sharePercent: ($share | tonumber)} else {} end)
    + (if $previous != "" and $previous != $tier then {reclassifiedFrom: $previous} else {} end)
  ' > "$LEDGER" || die "could not write $LEDGER_RELATIVE"
  if ! git -C "$ROOT" check-ignore -q "$LEDGER_RELATIVE" 2>/dev/null; then
    printf 'task-tier: note: %s is not gitignored in this project; add it, it is session state (R-503 ledger), not source\n' "$LEDGER_RELATIVE" >&2
  fi
  if [ -n "$previous" ] && [ "$previous" != "$tier" ]; then
    printf 'task-tier: reclassified %s -> %s: %s\n' "$previous" "$tier" "$reason"
  else
    printf 'task-tier: %s: %s (started %s)\n' "$tier" "$reason" "$(jq -r .startedAtIso "$LEDGER")"
  fi
}

cmd_get() {
  [ -f "$LEDGER" ] || { printf 'task-tier: no tier recorded (run task-start)\n' >&2; exit 1; }
  jq . "$LEDGER"
}

cmd_summary() {
  [ -f "$LEDGER" ] || { printf 'task-tier: no tier recorded (run task-start)\n'; exit 1; }
  local started elapsed
  started=$(jq -r '.startedAt' "$LEDGER")
  elapsed=$(( $(date +%s) - started ))
  printf 'task-tier: %s | %s | started %s, %dh%02dm elapsed | branch %s\n' \
    "$(jq -r .tier "$LEDGER")" "$(jq -r .reason "$LEDGER")" "$(jq -r .startedAtIso "$LEDGER")" \
    $((elapsed / 3600)) $(((elapsed % 3600) / 60)) "$(jq -r '.branch // "?"' "$LEDGER")"
}

cmd_clear() {
  [ -f "$LEDGER" ] && rm -f "$LEDGER" && printf 'task-tier: cleared\n'
  exit 0
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  get) cmd_get ;;
  summary) cmd_summary ;;
  clear) cmd_clear ;;
  *) die "usage: task-tier.sh set <tier> \"<reason>\" [--share <percent>] | get | summary | clear" ;;
esac
