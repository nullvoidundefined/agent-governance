#!/usr/bin/env bash
# task-provenance-gate.sh: PreToolUse(TaskCreate) gate for R-213, the rule
# that every task records who asked for it (IAN-199).
#
# The failure this exists for is not scope greed, which R-212 gates at the
# write. It is that hours into a session the task list is a flat pile in
# which the work the user asked for is indistinguishable from the work the
# session decided was needed and the work it merely thought would be nice.
# The user is then left unable to answer two questions: is the original
# request finished, and was everything since required for it or optional.
#
# Nothing in the rulebook recorded this before. R-502 governs which tasks are
# created, R-503 governs percentage reporting, and R-605 governs the tracker
# ticket's fields. None of them carries provenance, so the information the
# user needs was never captured and therefore could never be reported back.
#
# The tag leads the subject, so a task list skimmed down its left edge is
# readable without opening anything:
#   [requested]  the user asked for this in their own words
#   [required]   not asked for, but the requested work cannot be delivered
#                without it
#   [self]       the session decided this was worth doing
#
# Only TaskCreate is gated. Provenance is a fact about a task's origin, so it
# is set once, at creation, and a later TaskUpdate never revisits it; gating
# updates too would turn every status change into a second prompt for a
# decision already made. A subject that is missing or empty is left alone,
# because the tool refuses it anyway and a second refusal would only bury the
# real reason.
#
# Matching ignores case and tolerates leading whitespace, since neither
# changes what a reader sees, and a denial over capitalisation would teach
# the session to fight the gate rather than use it. Anything else is denied
# rather than guessed at: an unrecognised tag, and a tag that appears
# anywhere but the start, both leave the list unreadable in exactly the way
# the rule exists to prevent.
#
# `deny` rather than `ask` here, unlike the R-212 gate next to it. Complying
# costs the session eleven characters and no judgement, so there is nothing
# for the user to decide and no reason to spend one of their interruptions on
# it; the denial carries the three tags, which is the whole fix.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it emits a decision, and a PreToolUse hook that emits nothing is an allow,
# so the failure mode is an ungated task rather than a blocked session.
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "TaskCreate" ] || exit 0

SUBJECT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subject // ""')
[ -n "$SUBJECT" ] || exit 0
HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"

# normalized_subject: the subject lowercased with leading whitespace removed,
# which is the form the tag is matched against.
normalized_subject() {
  printf '%s' "$SUBJECT" | sed 's/^[[:space:]]*//' | tr 'A-Z' 'a-z'
}

case "$(normalized_subject)" in
  '[requested]'* | '[required]'* | '[self]'*) exit 0 ;;
esac

[ -f "$HOOK_DIR/log-rule-fire.sh" ] && source "$HOOK_DIR/log-rule-fire.sh"
type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-213" "task-provenance-gate" "deny"

jq -n --arg reason "R-213 (every task records who asked for it): the subject '$SUBJECT' carries no provenance tag, so this task would be indistinguishable from the rest of the list and the user could not tell whether it is theirs or yours. Start the subject with exactly one of: \`[requested]\` when the user asked for this in their own words, \`[required]\` when they did not ask but the requested work cannot be delivered without it, or \`[self]\` when you decided it was worth doing. A \`[self]\` task is not forbidden, but it is the one the user is most entitled to decline, so name it honestly rather than relabelling it \`[required]\`. Work that is genuinely separate from this request belongs in a tracker ticket (R-605), not in this list." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
exit 0
