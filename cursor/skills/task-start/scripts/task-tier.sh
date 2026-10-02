#!/usr/bin/env bash
# task-tier.sh: the task-start skill's ledger (2026-09-17 skills audit, S-8).
# The tier task-start announces, the reason, the session start timestamp, and
# the branch lived only in the transcript, so after a compaction the tier
# task-cleanup scales its work by was whatever the model recalled. This
# writes them to .claude/task-tier.json at the repo root, where task-cleanup's
# scan reads them and post-compact-rules.sh re-injects them.
#
# Usage:
#   task-tier.sh set <trivial|standard|complex|saga|investigation> "<reason>" [--ticket <KEY>] [--share <percent>] [--scope <glob>[,<glob>...]]
#                             --ticket is optional at every tier: the ticket opens
#                             by the time the draft PR opens (R-605, owner decision
#                             2026-10-02, IAN-568, which retired the IAN-149 rule
#                             that refused a tier above trivial without one); a
#                             reclassification on the same branch keeps it
#                             --scope records the files the request implies, as
#                             repository-relative globs, repeatable and comma
#                             separated; build-lane.sh reads it to predict a lane
#                             (R-212 itself is recall since IAN-568), and a
#                             reclassification on the same branch keeps it
#                             --lane <fast|guarded>, --lane-override <fast|guarded>, and
#                             --merge-mode <owner|green> record build-fast's lane, the
#                             owner's lane override, and the merge mode chosen in the
#                             opening batch (IAN-401); a later set keeps each one it does
#                             not restate only for the same branch and the same ticket
#   task-tier.sh get          prints the ledger as JSON (exit 1 when none)
#   task-tier.sh summary      one line: tier, reason, elapsed, branch; a second
#                             line names the build-fast lane, override, and merge
#                             mode when the ledger carries any
#   task-tier.sh clear        removes the ledger (task-cleanup's last step)
# The ledger is session state like .claude/tdd-lock.json: keep it out of
# commits (the script warns once when the project does not ignore it).
set -uo pipefail

LEDGER_RELATIVE=".claude/task-tier.json"
die() { printf 'task-tier: %s\n' "$*" >&2; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
LEDGER="$ROOT/$LEDGER_RELATIVE"

# read_previous_ticket <branch>: prints the ticket an existing ledger holds for
# the same branch, so a reclassification keeps the key without restating it.
read_previous_ticket() {
  [ -f "$LEDGER" ] || return 0
  jq -r --arg b "$1" 'select(.branch == $b) | .ticket // "" | strings' "$LEDGER" 2>/dev/null
}

# read_scope_entries <comma-separated globs>: appends each entry to the
# caller's scope_entries array, refusing an absolute path or one climbing out
# of the repository, since the gate matches repository-relative paths only.
read_scope_entries() {
  local raw="$1" entry
  while IFS= read -r entry; do
    entry="${entry#./}"
    [ -n "$entry" ] || continue
    case "$entry" in
      /*) die "--scope takes repository-relative globs, and '$entry' is absolute" ;;
      ..* | */../*) die "--scope entries stay inside the repository, and '$entry' climbs out of it" ;;
    esac
    scope_entries+=("$entry")
  done < <(printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# read_previous_scope <branch>: prints the scope an existing ledger holds for
# the same branch as a JSON array, so a reclassification keeps the declared
# scope without restating it.
read_previous_scope() {
  [ -f "$LEDGER" ] || return 0
  jq -c --arg b "$1" 'select(.branch == $b) | .scope // empty | arrays' "$LEDGER" 2>/dev/null
}

# read_previous_lane_field <branch> <ticket> <key>: prints a build-fast field
# (lane, laneOverride, mergeMode) from an existing ledger only when it names the
# same branch and the same ticket, so a new task never inherits one (IAN-401).
read_previous_lane_field() {
  [ -f "$LEDGER" ] || return 0
  jq -r --arg b "$1" --arg t "$2" --arg k "$3" \
    'select(.branch == $b and (.ticket // "") == $t) | .[$k] // "" | strings' "$LEDGER" 2>/dev/null
}

# require_lane_value <flag> <value> <allowed...>: dies unless the value is one
# of the allowed words, compared exactly.
require_lane_value() {
  local flag="$1" value="$2" allowed
  shift 2
  for allowed in "$@"; do [ "$value" = "$allowed" ] && return 0; done
  die "$flag takes one of: $* (got '${value}')"
}

cmd_set() {
  local tier="${1:-}" reason="${2:-}" share="" ticket="" has_ticket_flag=0 branch
  local lane="" lane_override="" merge_mode=""
  local -a scope_entries=()
  local has_scope_flag=0 scope_json=""
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --share) share="${2:-}"; shift 2 2>/dev/null || shift ;;
      --ticket) ticket="${2:-}"; has_ticket_flag=1; shift 2 2>/dev/null || shift ;;
      --scope) read_scope_entries "${2:-}"; has_scope_flag=1; shift 2 2>/dev/null || shift ;;
      --lane) lane="${2:-}"; require_lane_value --lane "$lane" fast guarded; shift 2 2>/dev/null || shift ;;
      --lane-override) lane_override="${2:-}"; require_lane_value --lane-override "$lane_override" fast guarded; shift 2 2>/dev/null || shift ;;
      --merge-mode) merge_mode="${2:-}"; require_lane_value --merge-mode "$merge_mode" owner green; shift 2 2>/dev/null || shift ;;
      *) die "unknown option '$1' (expected --ticket <KEY>, --share <percent>, --scope <glob>[,<glob>...], --lane, --lane-override, or --merge-mode)" ;;
    esac
  done
  case "$tier" in trivial|standard|complex|saga|investigation) ;; *) die "tier must be trivial, standard, complex, saga, or investigation (got '${tier}')" ;; esac
  [ -n "$reason" ] || die "give the one-sentence reason for the tier as the second argument"
  if [ "$has_ticket_flag" -eq 1 ] && ! printf '%s' "$ticket" | grep -qE '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    die "--ticket takes a tracker key such as IAN-149 (got '${ticket}')"
  fi
  branch=$(git -C "$ROOT" branch --show-current 2>/dev/null)
  [ "$has_ticket_flag" -eq 1 ] || ticket=$(read_previous_ticket "$branch")
  [ -n "$lane" ] || lane=$(read_previous_lane_field "$branch" "$ticket" lane)
  [ -n "$lane_override" ] || lane_override=$(read_previous_lane_field "$branch" "$ticket" laneOverride)
  [ -n "$merge_mode" ] || merge_mode=$(read_previous_lane_field "$branch" "$ticket" mergeMode)
  if [ "$has_scope_flag" -eq 1 ]; then
    [ "${#scope_entries[@]}" -gt 0 ] || die "--scope takes at least one repository-relative glob, such as --scope 'src/services/**,src/api/**'"
    scope_json=$(printf '%s\n' "${scope_entries[@]}" | jq -R . | jq -sc .)
  else
    scope_json=$(read_previous_scope "$branch")
  fi
  local previous=""
  [ -f "$LEDGER" ] && previous=$(jq -r '.tier // ""' "$LEDGER" 2>/dev/null)
  mkdir -p "$ROOT/.claude"
  jq -n --arg tier "$tier" --arg reason "$reason" --arg share "$share" --arg ticket "$ticket" \
        --arg lane "$lane" --arg laneOverride "$lane_override" --arg mergeMode "$merge_mode" \
        --arg branch "$branch" --argjson scope "${scope_json:-null}" \
        --arg previous "$previous" --argjson started "$(date +%s)" \
        --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {tier: $tier, reason: $reason, branch: $branch, startedAt: $started, startedAtIso: $iso}
    + (if $ticket != "" then {ticket: $ticket} else {} end)
    + (if $scope == null then {} else {scope: $scope} end)
    + (if $share != "" then {sharePercent: ($share | tonumber)} else {} end)
    + (if $lane != "" then {lane: $lane} else {} end)
    + (if $laneOverride != "" then {laneOverride: $laneOverride} else {} end)
    + (if $mergeMode != "" then {mergeMode: $mergeMode} else {} end)
    + (if $previous != "" and $previous != $tier then {reclassifiedFrom: $previous} else {} end)
  ' > "$LEDGER" || die "could not write $LEDGER_RELATIVE"
  if ! git -C "$ROOT" check-ignore -q "$LEDGER_RELATIVE" 2>/dev/null; then
    printf 'task-tier: note: %s is not gitignored in this project; add it, it is session state (the task-tier ledger), not source\n' "$LEDGER_RELATIVE" >&2
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
  printf 'task-tier: %s | %s | started %s, %dh%02dm elapsed | branch %s | ticket %s\n' \
    "$(jq -r .tier "$LEDGER")" "$(jq -r .reason "$LEDGER")" "$(jq -r .startedAtIso "$LEDGER")" \
    $((elapsed / 3600)) $(((elapsed % 3600) / 60)) "$(jq -r '.branch // "?"' "$LEDGER")" \
    "$(jq -r '.ticket // "none"' "$LEDGER")"
  jq -r '[(if .lane then "lane \(.lane)" else empty end), (if .laneOverride then "override \(.laneOverride)" else empty end), (if .mergeMode then "merge \(.mergeMode)" else empty end)] | select(length > 0) | "task-tier: build-fast " + join(" | ")' "$LEDGER"
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
  *) die "usage: task-tier.sh set <tier> \"<reason>\" [--ticket <KEY>] [--share <percent>] | get | summary | clear" ;;
esac
