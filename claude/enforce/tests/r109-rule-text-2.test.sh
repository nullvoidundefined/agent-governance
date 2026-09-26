#!/usr/bin/env bash
# Covers: hook:push-semgrep-gate
# Asserts the R-517 review findings on the IAN-381 R-109 rule text (spec
# 2026-09-25-security-first-gate-design.md, B-12, B-17, Invariants, State
# transitions), slice B-17b.
#
# The first R-109 fixture checks that the rule exists in every place that
# carries it. This one checks that the wording is right: R-517 no longer claims
# to be the only pre-merge review on a security-touching range; the R-406 Spec
# entry covers security controls; the waiver wording matches B-12 (the owner's
# `approved` in the current turn, confirmed at the merge gate's permission
# prompt, never the marker alone); the R-109 norm line is imperative and
# unconditional; the incident history is true; the narrowing claim is precise;
# and the model key the rule cites exists.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
CLAUDE_FILE="$ROOT/CLAUDE.md"
REFERENCE_FILE="$ROOT/rulebook/reference.md"
MODEL_FILE="$ROOT/enforce/security-review-model.json"

fail() {
    echo "FAIL: $1"
    exit 1
}

# requirePhrase <haystack text> <literal> <failure message>
# Fails unless the text contains the literal, compared case-insensitively.
requirePhrase() {
    grep -qiF -- "$2" <<< "$1" || fail "$3"
}

# forbidPhrase <haystack text> <literal> <failure message>
# Fails when the text contains the literal, compared case-insensitively.
forbidPhrase() {
    if grep -qiF -- "$2" <<< "$1"; then fail "$3"; fi
}

# readNormLine <rule id>: prints the rule's norm line from CLAUDE.md, or nothing.
readNormLine() {
    { grep -E -- "^$1: " "$CLAUDE_FILE" || true; } | head -1
}

# readReferenceEntry <rule id>: prints the rule's reference.md entry, from its
# first line to the first blank line, or nothing.
readReferenceEntry() {
    awk -v prefix="$1: " 'index($0, prefix) == 1 { inside = 1 } inside && $0 == "" { exit } inside' "$REFERENCE_FILE"
}

# ---------------------------------------------------------------------------
# Item 1: R-517 names the R-109 security review as the exception to "only review".
# ---------------------------------------------------------------------------
R517_NORM=$(readNormLine 'R-517')
[ -n "$R517_NORM" ] || fail "CLAUDE.md has no R-517 norm line"
requirePhrase "$R517_NORM" 'R-109 security review' \
    "CLAUDE.md R-517 does not name the R-109 security review as an additional required review"
requirePhrase "$R517_NORM" 'security-touching' \
    "CLAUDE.md R-517 does not scope the R-109 security review to a security-touching range"
# Every clause that calls R-517 the only review must carry the R-109 exception.
while IFS= read -r ONLY_CLAUSE; do
    requirePhrase "$ONLY_CLAUSE" 'R-109 security review' \
        "CLAUDE.md R-517 still calls itself the only review without the R-109 exception: '$ONLY_CLAUSE'"
done < <(tr ';' '\n' <<< "$R517_NORM" | grep -iF 'only review' || true)

# ---------------------------------------------------------------------------
# Item 2: the R-406 reference entry covers security controls.
# ---------------------------------------------------------------------------
REF_R406=$(readReferenceEntry 'R-406')
[ -n "$REF_R406" ] || fail "rulebook/reference.md has no R-406 entry"
requirePhrase "$REF_R406" 'negative-input test' \
    "rulebook/reference.md R-406 lost its user-input negative-input test"
requirePhrase "$REF_R406" 'security control' \
    "rulebook/reference.md R-406 does not extend the negative test to security controls"
requirePhrase "$REF_R406" 'insecure value' \
    "rulebook/reference.md R-406 does not require feeding a security control its insecure value"
requirePhrase "$REF_R406" 'configuration' \
    "rulebook/reference.md R-406 does not say configuration-sourced values are included"
requirePhrase "$REF_R406" 'security-surface' \
    "rulebook/reference.md R-406 does not point to the security-surface detector's definition of a security control"

# ---------------------------------------------------------------------------
# The R-109 reference entry, shared by items 3, 6, and 7.
# ---------------------------------------------------------------------------
REF_R109=$(readReferenceEntry 'R-109')
[ -n "$REF_R109" ] || fail "rulebook/reference.md has no R-109 entry"

# ---------------------------------------------------------------------------
# Item 3: the waiver wording matches B-12 and the State transitions.
# ---------------------------------------------------------------------------
requirePhrase "$REF_R109" '`waived by owner <date>`' \
    "rulebook/reference.md R-109 does not name the \`waived by owner <date>\` finding status"
requirePhrase "$REF_R109" 'findings table' \
    "rulebook/reference.md R-109 does not say the waiver is recorded in the findings table"
requirePhrase "$REF_R109" "owner's \`approved\` in the current turn" \
    "rulebook/reference.md R-109 does not make the waiver take effect only on the owner's \`approved\` in the current turn"
requirePhrase "$REF_R109" "merge gate's permission prompt" \
    "rulebook/reference.md R-109 does not say the waiver is confirmed at the merge gate's permission prompt"
requirePhrase "$REF_R109" 'the marker alone never clears a finding' \
    "rulebook/reference.md R-109 does not say the waiver marker alone never clears a finding"
forbidPhrase "$REF_R109" 'never an agent message or a marker in the PR body' \
    "rulebook/reference.md R-109 still says the waiver is never a marker in the PR body, which contradicts B-12's findings-table marker"

# ---------------------------------------------------------------------------
# Items 4 and 5: the R-109 norm line is imperative and unconditional.
# ---------------------------------------------------------------------------
R109_NORM=$(readNormLine 'R-109')
[ -n "$R109_NORM" ] || fail "CLAUDE.md has no R-109 norm line"
case "$R109_NORM" in
    'R-109: Treat security as the first-order concern'*) ;;
    *) fail "CLAUDE.md R-109 must open with the imperative 'R-109: Treat security as the first-order concern', as reference.md does" ;;
esac
requirePhrase "$R109_NORM" 'never defer, soften, or re-grade' \
    "CLAUDE.md R-109 does not forbid deferring, softening, and re-grading a security finding in the imperative"
forbidPhrase "$R109_NORM" 'to pass a merge' \
    "CLAUDE.md R-109 still conditions the ban on 'to pass a merge'; the ban on deferring, softening, and re-grading is unconditional"

# ---------------------------------------------------------------------------
# Item 6: the incident history is true.
# ---------------------------------------------------------------------------
INCIDENT_LINE=$({ grep -iF 'Incident:' <<< "$REF_R109" || true; } | head -1)
[ -n "$INCIDENT_LINE" ] || fail "rulebook/reference.md R-109 has no Incident bullet"
forbidPhrase "$INCIDENT_LINE" 'rule pack' \
    "rulebook/reference.md R-109 incident says a rule pack passed #27; the rule pack did not exist then"
requirePhrase "$INCIDENT_LINE" 'the authoring agent and every Claude reviewer passed it' \
    "rulebook/reference.md R-109 incident does not say the authoring agent and every Claude reviewer passed #27"
requirePhrase "$INCIDENT_LINE" 'only a Copilot review comment caught it' \
    "rulebook/reference.md R-109 incident does not say only a Copilot review comment caught #27"

# ---------------------------------------------------------------------------
# Item 7: the narrowing claim is precise.
# ---------------------------------------------------------------------------
requirePhrase "$REF_R109" '`securitySurfaceExclude` narrows only the security-surface detector' \
    "rulebook/reference.md R-109 does not say \`securitySurfaceExclude\` narrows only the security-surface detector"
requirePhrase "$REF_R109" 'the rule-pack gate has no exclude list' \
    "rulebook/reference.md R-109 does not say the rule-pack gate has no exclude list"
forbidPhrase "$REF_R109" 'nothing else scopes the rule down' \
    "rulebook/reference.md R-109 still claims nothing else scopes the rule down"

# ---------------------------------------------------------------------------
# Item 8: the model key R-109 cites exists.
# ---------------------------------------------------------------------------
[ -f "$MODEL_FILE" ] || fail "enforce/security-review-model.json is missing"
jq -e '(.securityReviewModel | type) == "string" and (.securityReviewModel | length) > 0' "$MODEL_FILE" >/dev/null \
    || fail "enforce/security-review-model.json has no non-empty string securityReviewModel"

echo "r109-rule-text-2.test.sh PASS"
