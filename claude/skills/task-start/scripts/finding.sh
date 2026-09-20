#!/usr/bin/env bash
# finding.sh: the R-214 ledger of work discovered while doing something else
# (IAN-201).
#
# Before this existed, something noticed mid-task had two possible fates and
# both were bad. Fixing it immediately put unrelated work in the current
# diff under the current task's ticket, which is the scope greed R-212 gates
# at the write. Mentioning it once in chat lost it the moment the
# conversation moved on, which is why the same defects kept being rediscovered
# session after session. This records it instead, at the moment it is noticed
# and before any decision about whether to act on it, so the choice of what to
# do about it belongs to the user later rather than to the session now.
#
# Usage:
#   finding.sh add "<what was found>" --kind bug|task|optimization
#                                     [--where <path or area>] [--ticket <KEY>]
#       records one finding. --ticket attaches the tracker key when the ticket
#       already exists; leaving it off records the finding as open, and
#       `finding.sh open` is then the list of things still owed a ticket.
#   finding.sh ticket <id> <KEY>   attaches a key to an already-recorded finding
#   finding.sh list                prints every finding
#   finding.sh open                prints only the findings carrying no ticket
#   finding.sh clear               removes the ledger (task-cleanup's last step)
#
# The ledger is session state like .claude/task-tier.json and the slice lock:
# it is per-checkout, it is never committed, and the script warns once when
# the project does not ignore it. The tracker ticket is the durable record;
# this file is only what carries a finding from the moment of noticing to the
# moment a ticket exists for it.
set -uo pipefail

LEDGER_RELATIVE=".claude/findings.json"
die() { printf 'finding: %s\n' "$*" >&2; exit 1; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
LEDGER="$ROOT/$LEDGER_RELATIVE"

# read_ledger: prints the ledger as a JSON array, an empty one when no ledger
# exists yet or the file on disk is not readable as an array.
read_ledger() {
  [ -f "$LEDGER" ] || { printf '[]'; return 0; }
  jq -c 'if type == "array" then . else [] end' "$LEDGER" 2>/dev/null || printf '[]'
}

# write_ledger <jq-program> <jq-arg>...: applies the program to the current
# ledger and replaces it atomically. A unique temp file in the ledger's own
# directory rather than a fixed `$LEDGER.tmp` (finding 7 of the PR #96
# review): two runs in one checkout, which the multi-agent session type makes
# plausible, would otherwise interleave into that single file before either
# rename. Every failure dies rather than reporting success over an unchanged
# ledger, because R-214's whole promise is that nothing noticed is lost.
write_ledger() {
  local program="$1" scratch
  shift
  scratch=$(mktemp "$ROOT/.claude/findings.XXXXXX") || die "could not create a temporary file beside $LEDGER_RELATIVE"
  if read_ledger | jq "$@" "$program" > "$scratch" 2>/dev/null && [ -s "$scratch" ]; then
    mv "$scratch" "$LEDGER" || { rm -f "$scratch"; die "could not replace $LEDGER_RELATIVE"; }
  else
    rm -f "$scratch"
    die "could not write $LEDGER_RELATIVE"
  fi
}

# warn_when_tracked: one warning when the project does not ignore the ledger,
# matching task-tier.sh, since session state committed to a branch is how a
# stale ledger reaches another checkout.
warn_when_tracked() {
  git -C "$ROOT" check-ignore -q "$LEDGER_RELATIVE" 2>/dev/null && return 0
  printf 'finding: note: %s is not gitignored in this project; add it, it is session state, not source\n' \
    "$LEDGER_RELATIVE" >&2
}

cmd_add() {
  local description="${1:-}" kind="" where="" ticket="" next_id
  shift 1 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 2>/dev/null || shift ;;
      --where) where="${2:-}"; shift 2 2>/dev/null || shift ;;
      --ticket) ticket="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) die "unknown option '$1' (expected --kind, --where, or --ticket)" ;;
    esac
  done
  [ -n "$description" ] || die "say what was found as the first argument, in one sentence"
  case "$kind" in
    bug | task | optimization) ;;
    *) die "--kind must be bug, task, or optimization (got '${kind}'); a bug is broken behavior, a task is work that needs doing, an optimization is something that works but could be better" ;;
  esac
  if [ -n "$ticket" ] && ! printf '%s' "$ticket" | grep -qE '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    die "--ticket takes a tracker key such as IAN-201 (got '${ticket}')"
  fi
  mkdir -p "$ROOT/.claude"
  next_id=$(read_ledger | jq '(map(.id) | max // 0) + 1')
  write_ledger '
    . + [ {id: $id, kind: $kind, description: $description, foundAt: $iso, branch: $branch}
          + (if $where != "" then {where: $where} else {} end)
          + (if $ticket != "" then {ticket: $ticket} else {} end) ]
  ' --argjson id "$next_id" --arg description "$description" --arg kind "$kind" \
    --arg where "$where" --arg ticket "$ticket" \
    --arg branch "$(git -C "$ROOT" branch --show-current 2>/dev/null)" \
    --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  warn_when_tracked
  if [ -n "$ticket" ]; then
    printf 'finding %d recorded (%s, %s): %s\n' "$next_id" "$kind" "$ticket" "$description"
  else
    printf 'finding %d recorded (%s, no ticket yet): %s\n' "$next_id" "$kind" "$description"
    printf 'Open its ticket with /ticket-lifecycle, then: finding.sh ticket %d <KEY>\n' "$next_id"
  fi
}

cmd_ticket() {
  local id="${1:-}" key="${2:-}"
  printf '%s' "$id" | grep -qE '^[0-9]+$' || die "give the finding's id, as \`finding.sh ticket <id> <KEY>\`"
  printf '%s' "$key" | grep -qE '^[A-Z][A-Z0-9]+-[0-9]+$' || die "give a tracker key such as IAN-201"
  read_ledger | jq -e --argjson id "$id" 'any(.id == $id)' >/dev/null 2>&1 || die "no finding with id $id"
  write_ledger 'map(if .id == $id then . + {ticket: $key} else . end)' \
    --argjson id "$id" --arg key "$key"
  printf 'finding %s now carries %s\n' "$id" "$key"
}

# print_findings <jq-filter>: the shared renderer, so list and open cannot
# drift into showing different columns for the same row.
print_findings() {
  local rows
  rows=$(read_ledger | jq -r "$1"' | .[] | "  [\(.id)] \(.kind): \(.description)" + (if .where then " (\(.where))" else "" end) + " -> " + (.ticket // "NO TICKET")')
  [ -n "$rows" ] || { printf 'finding: none recorded\n'; return 0; }
  printf '%s\n' "$rows"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  ticket) shift; cmd_ticket "$@" ;;
  list) print_findings '.' ;;
  open) print_findings 'map(select(.ticket == null or .ticket == ""))' ;;
  clear) rm -f "$LEDGER" && printf 'finding: cleared\n' ;;
  *) die "usage: finding.sh add \"<what>\" --kind bug|task|optimization [--where <path>] [--ticket <KEY>] | ticket <id> <KEY> | list | open | clear" ;;
esac
