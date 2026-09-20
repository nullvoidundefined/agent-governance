#!/usr/bin/env bash
# Covers: ci:llm-rule-judge
# Asserts the IAN-175 amendment to R-334 in CLAUDE.md, in rulebook/reference.md,
# and in the generated Cursor port of both. The word order stays fixed, base
# noun first with the aggregate root repeated by every entity inside the
# aggregate, while the separator follows the case convention of the engine or
# language the name lives in. `trip_legs` in Postgres and `tripLegs` in MongoDB
# are therefore the same name under the rule, and only a name that reorders the
# words is a defect. The judge has to be told which case convention a name lives
# under, otherwise it reads every camelCase name as a missing underscore.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

SEPARATOR_CLAUSE='the separator follows the case convention of the engine or language the name lives in'
POSTGRES_FORM='`trip_legs` in Postgres'
MONGO_FORM='`tripLegs` in MongoDB'
WORD_ORDER_SENTENCE="Word order is the rule; the separator is the engine's."
SAME_NAME_SENTENCE='`trip_legs` and `tripLegs` are the same name under this rule'
SNAKE_KEY_FORM='`{referenced_table_singular}_id`'
CAMEL_KEY_FORM='`{referencedEntitySingular}Id`'
JUDGE_TOLD_CLAUSE="the name's engine case convention"
JUDGE_NOT_UNDERSCORE_CLAUSE='a camelCase name is not judged against the underscore form'
STALE_NORM_EXAMPLES='(`trip_leg`, `conversation_message`)'
STALE_SINGLE_KEY_FORM='A foreign key is `{referenced_table_singular}_id`, exactly as'

# extractRule <file> <rule id>
# Prints the rule's own block: the norm line and every line beneath it, stopping
# at the next rule line or the next markdown heading.
extractRule() {
  awk -v id="$2" '
    $0 ~ "^" id ":" { inside = 1; print; next }
    inside && (/^R-[0-9]/ || /^#/) { exit }
    inside { print }
  ' "$1"
}

# requireIn <text> <literal> <failure message>
# Fails the fixture unless the captured text contains the literal.
requireIn() {
  grep -qF -- "$2" <<< "$1" || { echo "FAIL: $3"; exit 1; }
}

# forbidIn <text> <literal> <failure message>
# Fails the fixture when the captured text still contains the literal.
forbidIn() {
  if grep -qF -- "$2" <<< "$1"; then echo "FAIL: $3"; exit 1; fi
}

# requireText <file> <literal> <failure message>
# Fails the fixture unless the file contains the literal text.
requireText() {
  grep -qF -- "$2" "$1" || { echo "FAIL: $3"; exit 1; }
}

# forbidText <file> <literal> <failure message>
# Fails the fixture when the file still contains the literal text.
forbidText() {
  if grep -qF -- "$2" "$1"; then echo "FAIL: $3"; exit 1; fi
}

NORM_LINE="$(grep -m1 -F 'R-334: Name every schema' "$ROOT/CLAUDE.md" || true)"
[ -n "$NORM_LINE" ] || { echo "FAIL: CLAUDE.md carries no R-334 norm line to check"; exit 1; }
requireIn "$NORM_LINE" "$SEPARATOR_CLAUSE" \
  "CLAUDE.md R-334 norm line does not say that $SEPARATOR_CLAUSE"
requireIn "$NORM_LINE" "$POSTGRES_FORM" \
  "CLAUDE.md R-334 norm line lacks the engine-cased example $POSTGRES_FORM"
requireIn "$NORM_LINE" "$MONGO_FORM" \
  "CLAUDE.md R-334 norm line lacks the engine-cased example $MONGO_FORM"
forbidIn "$NORM_LINE" "$STALE_NORM_EXAMPLES" \
  "CLAUDE.md R-334 norm line still gives only the underscore examples $STALE_NORM_EXAMPLES, which reads as a universal separator"

RULE_BLOCK="$(extractRule "$ROOT/rulebook/reference.md" R-334)"
[ -n "$RULE_BLOCK" ] || { echo "FAIL: rulebook/reference.md carries no R-334 block to check"; exit 1; }
ENFORCEMENT="$(grep -F '  Enforcement:' <<< "$RULE_BLOCK" || true)"
SPEC="$(grep -vF '  Enforcement:' <<< "$RULE_BLOCK" || true)"
[ -n "$ENFORCEMENT" ] || { echo "FAIL: rulebook/reference.md R-334 has no Enforcement paragraph"; exit 1; }

requireIn "$SPEC" "$WORD_ORDER_SENTENCE" \
  "rulebook/reference.md R-334 Spec does not state: $WORD_ORDER_SENTENCE"
requireIn "$SPEC" "$SAME_NAME_SENTENCE" \
  "rulebook/reference.md R-334 Spec does not state that $SAME_NAME_SENTENCE"

KEY_BULLET="$(grep -F "$SNAKE_KEY_FORM" <<< "$SPEC" || true)"
[ -n "$KEY_BULLET" ] || { echo "FAIL: rulebook/reference.md R-334 Spec has no foreign-key bullet naming $SNAKE_KEY_FORM"; exit 1; }
requireIn "$KEY_BULLET" "$CAMEL_KEY_FORM" \
  "rulebook/reference.md R-334 foreign-key bullet names $SNAKE_KEY_FORM but not the camelCase form $CAMEL_KEY_FORM"
forbidIn "$SPEC" "$STALE_SINGLE_KEY_FORM" \
  "rulebook/reference.md R-334 still declares one universal foreign-key form: $STALE_SINGLE_KEY_FORM"

requireIn "$ENFORCEMENT" "$JUDGE_TOLD_CLAUSE" \
  "rulebook/reference.md R-334 Enforcement does not say the judge is told $JUDGE_TOLD_CLAUSE"
requireIn "$ENFORCEMENT" "$JUDGE_NOT_UNDERSCORE_CLAUSE" \
  "rulebook/reference.md R-334 Enforcement does not say that $JUDGE_NOT_UNDERSCORE_CLAUSE"

CURSOR_REFERENCE="$REPO_ROOT/cursor/rules/rulebook-reference-r3xx-architecture-and-naming.mdc"
if [ -f "$CURSOR_REFERENCE" ]; then
  requireText "$CURSOR_REFERENCE" "$WORD_ORDER_SENTENCE" \
    "the Cursor port of the rulebook lacks the R-334 Spec sentence: $WORD_ORDER_SENTENCE"
  requireText "$CURSOR_REFERENCE" "$SAME_NAME_SENTENCE" \
    "the Cursor port of the rulebook does not say that $SAME_NAME_SENTENCE"
  requireText "$CURSOR_REFERENCE" "$CAMEL_KEY_FORM" \
    "the Cursor port of the rulebook lacks the camelCase foreign-key form $CAMEL_KEY_FORM"
  forbidText "$CURSOR_REFERENCE" "$STALE_SINGLE_KEY_FORM" \
    "the Cursor port of the rulebook still declares one universal foreign-key form: $STALE_SINGLE_KEY_FORM"
fi

CURSOR_GLOBAL="$REPO_ROOT/cursor/rules/000-global-rules.mdc"
if [ -f "$CURSOR_GLOBAL" ]; then
  requireText "$CURSOR_GLOBAL" "$SEPARATOR_CLAUSE" \
    "the Cursor port of CLAUDE.md lacks the R-334 clause: $SEPARATOR_CLAUSE"
  requireText "$CURSOR_GLOBAL" "$MONGO_FORM" \
    "the Cursor port of CLAUDE.md lacks the engine-cased example $MONGO_FORM"
fi

echo "r334-engine-case-rule-text.test.sh PASS"
