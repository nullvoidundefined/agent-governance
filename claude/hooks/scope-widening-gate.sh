#!/usr/bin/env bash
# scope-widening-gate.sh: PreToolUse(Write|Edit) gate for R-212, the rule that
# a turn delivers what it was asked for and puts any widening of the work to
# the user before making it rather than reporting it afterward (IAN-193).
#
# The failure this exists for is scope greed: the request is satisfied and the
# session keeps going, fixing an adjacent defect it noticed while reading,
# refactoring a file it only needed to read, or adding tests and documents
# nobody asked for, so the diff arrives several times the size of the request.
# Nothing in the rulebook constrained that before this rule. R-204 governs how
# a fix is made, R-202 governs what may be read, and R-211 governs which
# decisions are put to the user, but none of them bounded how far a turn's
# writes may travel from the thing that was asked for.
#
# The scope is declared, not inferred. `task-tier.sh set <tier> "<reason>"
# --scope <glob>[,<glob>...]` records it on the task-start ledger
# (.claude/task-tier.json) beside the tier, the branch, and the ticket, and
# this hook reads that field for the branch checked out. A Write or Edit whose
# target falls outside every declared entry becomes an `ask`: the user sees
# the file and the declared scope and decides whether the task really grew.
#
# `ask` rather than `deny` is the deliberate choice (owner decision,
# 2026-09-20). A deny is bypassable by the session simply re-running
# task-tier.sh with a wider scope, so what a deny would really enforce is
# "announce the widening", while an ask puts the widening in front of the one
# person whose request defines the scope in the first place.
#
# Silent, so that ordinary work is never interrupted, when:
#   - no ledger exists (the session never ran task-start),
#   - the ledger declares no scope, or declares the empty list, since
#     declaring no paths is declaring no constraint and never the reverse,
#   - the ledger records a different branch, so it belongs to another task,
#     which is how ticket-at-start-gate.sh reads the same field,
#   - the target sits under the repository's own .claude/, which holds the
#     ledger and the slice lock that every task writes,
#   - git ignores the target, so scratch files and build output are out,
#   - the target is not inside a git work tree at all.
#
# Matching is by path component, never by substring: an entry carrying no glob
# character is a prefix that must end on a separator, so `claude/hooks` covers
# `claude/hooks/a.sh` but not `claude/hooks-extra/a.sh`, and `docs/a` does not
# cover `docs/ab.md`. An entry carrying a glob character is matched as a shell
# pattern, in which `*` crosses separators, so `claude/hooks/**` and
# `claude/hooks/*` both cover the whole tree beneath that directory.
#
# This gate fails open rather than closed, which is the opposite of the
# convention the deny-tier guards follow (enforce/README.md). An unreadable or
# absent scope is the documented degraded path of R-212 rather than an attempt
# to evade it, and a gate that raised a prompt whenever it could not read its
# own input would teach every session to click through the prompt, which costs
# more than the widening it was built to catch.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it emits a decision, and this one decides by emitting nothing.
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write | Edit) ;; *) exit 0 ;; esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -n "$FILE_PATH" ] || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

# physical_path <file-path>: prints the target's physical path, resolving the
# nearest existing ancestor through symlinks and keeping the components that
# do not exist yet, so a file about to be created is judged by where it lands
# rather than skipped for not being there.
physical_path() {
  local absolute existing missing
  case "$1" in /*) absolute="$1" ;; *) absolute="$CWD/$1" ;; esac
  existing=$(dirname "$absolute")
  missing=$(basename "$absolute")
  while [ ! -d "$existing" ] && [ "$existing" != "/" ]; do
    missing="$(basename "$existing")/$missing"
    existing=$(dirname "$existing")
  done
  printf '%s/%s' "$(cd "$existing" 2>/dev/null && pwd -P)" "$missing"
}

# nearest_existing_directory <path>: prints the closest ancestor of the path
# that exists, physical, so a target under directories that do not exist yet
# is still resolved against the repository it would land in.
nearest_existing_directory() {
  local directory
  directory=$(dirname "$1")
  while [ ! -d "$directory" ] && [ "$directory" != "/" ]; do directory=$(dirname "$directory"); done
  (cd "$directory" 2>/dev/null && pwd -P)
}

# is_in_scope <relative-path> <entry>...: true when the path matches any
# declared entry, by shell pattern for an entry holding a glob character and
# by separator-terminated prefix for one that does not.
is_in_scope() {
  local rel="$1" entry
  shift
  for entry in "$@"; do
    entry="${entry#./}"
    entry="${entry%/}"
    [ -n "$entry" ] || continue
    case "$entry" in
      *[\*\?\[]*) case "$rel" in $entry) return 0 ;; esac ;;
      *) [ "$rel" = "$entry" ] && return 0
         case "$rel" in "$entry"/*) return 0 ;; esac ;;
    esac
  done
  return 1
}

TARGET=$(physical_path "$FILE_PATH")
TOP=$(git -C "$(nearest_existing_directory "$TARGET")" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$TOP" ] || exit 0
TOP=$(cd "$TOP" 2>/dev/null && pwd -P) || exit 0

LEDGER="$TOP/.claude/task-tier.json"
[ -f "$LEDGER" ] || exit 0
jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1 || exit 0

BRANCH=$(git -C "$TOP" branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] || exit 0
LEDGER_BRANCH=$(jq -r '.branch // "" | strings' "$LEDGER" 2>/dev/null)
[ "$LEDGER_BRANCH" = "$BRANCH" ] || exit 0

mapfile -t SCOPE < <(jq -r '(.scope // []) | if type == "array" then .[] | strings else empty end' "$LEDGER" 2>/dev/null)
[ "${#SCOPE[@]}" -gt 0 ] || exit 0

case "$TARGET" in "$TOP"/*) REL="${TARGET#"$TOP"/}" ;; *) exit 0 ;; esac
case "$REL" in .claude/*) exit 0 ;; esac
git -C "$TOP" check-ignore -q -- "$TARGET" 2>/dev/null && exit 0

is_in_scope "$REL" "${SCOPE[@]}" && exit 0

[ -f "$HOOK_DIR/log-rule-fire.sh" ] && source "$HOOK_DIR/log-rule-fire.sh"
type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-212" "scope-widening-gate" "ask"

DECLARED=$(printf '%s, ' "${SCOPE[@]}")
jq -n --arg reason "R-212 (deliver what was asked for): '$REL' is outside the file scope this task declared at task-start (${DECLARED%, }), so writing it widens the task beyond the request. Approve only if this file is genuinely part of what was asked for. If it is an adjacent defect, an unrequested refactor, or an extra test or document, decline: name it to the user and let them decide whether it joins this task or becomes a ticket of its own. If the request really did grow, re-record the scope with \`bash ~/.claude/skills/task-start/scripts/task-tier.sh set <tier> \"<reason>\" --scope <glob>[,<glob>...]\` so the ledger matches the work." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'
exit 0
