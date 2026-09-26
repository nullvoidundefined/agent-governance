#!/usr/bin/env bash
# Covers: hook:push-semgrep-gate
# Asserts the IAN-381 security-first rule, R-109, and the R-406 extension that
# comes with it (spec 2026-09-25-security-first-gate-design.md, B-17).
#
# R-109 makes security the first-order concern: a security finding outranks
# every other finding, is never deferred, softened, or re-graded to pass a
# merge, and only the owner waives one; a PR range that touches a security
# control merges only with a clean security rule pack, a current
# `## Security review` on the strongest model (`securityReviewModel`), and a
# test that feeds each touched control its insecure value. The fixture checks
# that the rule is present in all four places that carry it: the norm line in
# CLAUDE.md, the Spec and Enforcement entry in rulebook/reference.md, the
# manifest registration (R-516), and the general reviewer prompt's SECURITY
# item, which must hand a security-touching PR to the separate R-109 review.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
CLAUDE_FILE="$ROOT/CLAUDE.md"
REFERENCE_FILE="$ROOT/rulebook/reference.md"
MANIFEST_FILE="$ROOT/enforce/manifest.json"
PROMPT_FILE="$ROOT/prompts/codex-pr-review-prompt.md"
ENFORCER='hook:push-semgrep-gate'

fail() {
    echo "FAIL: $1"
    exit 1
}

# requirePhrase <haystack text> <literal> <failure message>
# Fails unless the text contains the literal, compared case-insensitively.
requirePhrase() {
    grep -qiF -- "$2" <<< "$1" || fail "$3"
}

# requireEitherPhrase <haystack text> <literal> <alternative literal> <failure message>
# Fails unless the text contains either literal, compared case-insensitively.
requireEitherPhrase() {
    grep -qiF -- "$2" <<< "$1" || grep -qiF -- "$3" <<< "$1" || fail "$4"
}

# lineNumberOf <file> <extended regex>: prints the first matching line number, or nothing.
lineNumberOf() {
    { grep -nE -- "$2" "$1" || true; } | head -1 | cut -d: -f1
}

# ---------------------------------------------------------------------------
# Item 1: the R-109 norm line in CLAUDE.md.
# ---------------------------------------------------------------------------
R108_LINE=$(lineNumberOf "$CLAUDE_FILE" '^R-108: ')
R109_LINE=$(lineNumberOf "$CLAUDE_FILE" '^R-109: ')
SECRETS_HEADING=$(lineNumberOf "$CLAUDE_FILE" '^## Secrets and trust \(R-1xx\)')
CONDUCT_HEADING=$(lineNumberOf "$CLAUDE_FILE" '^## Conduct and output \(R-2xx\)')
[ -n "$R108_LINE" ] || fail "CLAUDE.md has no R-108 norm line to anchor R-109 after"
[ -n "$R109_LINE" ] || fail "CLAUDE.md has no R-109 norm line"
[ -n "$SECRETS_HEADING" ] && [ -n "$CONDUCT_HEADING" ] || fail "CLAUDE.md lost its R-1xx or R-2xx section heading"
[ "$R109_LINE" -eq $((R108_LINE + 1)) ] || fail "CLAUDE.md R-109 must be the line right after R-108 (R-108 at $R108_LINE, R-109 at $R109_LINE)"
[ "$R109_LINE" -gt "$SECRETS_HEADING" ] && [ "$R109_LINE" -lt "$CONDUCT_HEADING" ] \
    || fail "CLAUDE.md R-109 must sit in the Secrets and trust (R-1xx) section"

R109_NORM=$(sed -n "${R109_LINE}p" "$CLAUDE_FILE")
requireEitherPhrase "$R109_NORM" 'security is the first-order concern' 'treat security as the first-order concern' \
    "CLAUDE.md R-109 does not make security the first-order concern"
requirePhrase "$R109_NORM" 'outranks every other finding' \
    "CLAUDE.md R-109 does not rank a security finding above every other finding"
requireEitherPhrase "$R109_NORM" 'never deferred, softened, or re-graded' 'never defer, soften, or re-grade' \
    "CLAUDE.md R-109 does not forbid deferring, softening, or re-grading a security finding"
requirePhrase "$R109_NORM" 'only the owner waives' \
    "CLAUDE.md R-109 does not reserve the waiver of a security finding to the owner"
requirePhrase "$R109_NORM" 'security control' \
    "CLAUDE.md R-109 does not scope the merge condition to a PR range touching a security control"
requirePhrase "$R109_NORM" 'clean security rule pack' \
    "CLAUDE.md R-109 does not require a clean security rule pack before merge"
requirePhrase "$R109_NORM" '`## Security review`' \
    "CLAUDE.md R-109 does not require a \`## Security review\` section"
requirePhrase "$R109_NORM" '`securityReviewModel`' \
    "CLAUDE.md R-109 does not name the securityReviewModel key for the review model"
requirePhrase "$R109_NORM" 'insecure value' \
    "CLAUDE.md R-109 does not require a test feeding each touched control its insecure value"
grep -qE -- "\[[^]]*${ENFORCER}[^]]*\]\$" <<< "$R109_NORM" \
    || fail "CLAUDE.md R-109 must end with an enforcer bracket naming $ENFORCER"

# ---------------------------------------------------------------------------
# Item 4: the R-406 norm line in CLAUDE.md covers every security control.
# ---------------------------------------------------------------------------
R406_NORM=$(grep -E '^R-406: ' "$CLAUDE_FILE" || true)
[ -n "$R406_NORM" ] || fail "CLAUDE.md has no R-406 norm line"
requirePhrase "$R406_NORM" 'negative-input test' \
    "CLAUDE.md R-406 lost its user-input negative-input test"
requirePhrase "$R406_NORM" 'every security control' \
    "CLAUDE.md R-406 does not extend the negative test to every security control"
requirePhrase "$R406_NORM" 'insecure value' \
    "CLAUDE.md R-406 does not require feeding a security control its insecure value"
requirePhrase "$R406_NORM" '`*`, `null`, empty' \
    "CLAUDE.md R-406 does not list the insecure values (\`*\`, \`null\`, empty)"
requirePhrase "$R406_NORM" 'weakened flag' \
    "CLAUDE.md R-406 does not list a weakened flag among the insecure values"
requirePhrase "$R406_NORM" 'configuration included' \
    "CLAUDE.md R-406 does not say configuration-sourced values are included"

# ---------------------------------------------------------------------------
# Item 2: the R-109 entry in rulebook/reference.md.
# ---------------------------------------------------------------------------
REF_R108=$(lineNumberOf "$REFERENCE_FILE" '^R-108: ')
REF_R109=$(lineNumberOf "$REFERENCE_FILE" '^R-109: ')
REF_CONDUCT=$(lineNumberOf "$REFERENCE_FILE" '^## Conduct and output')
[ -n "$REF_R109" ] || fail "rulebook/reference.md has no R-109 entry"
[ -n "$REF_R108" ] && [ -n "$REF_CONDUCT" ] || fail "rulebook/reference.md lost its R-108 entry or its R-2xx heading"
[ "$REF_R109" -gt "$REF_R108" ] && [ "$REF_R109" -lt "$REF_CONDUCT" ] \
    || fail "rulebook/reference.md R-109 must follow R-108 inside the Secrets and trust section"
# The entry runs from its R-109 line to the first blank line, as every neighbour does.
REF_ENTRY=$(awk -v start="$REF_R109" 'NR >= start { if (NR > start && $0 == "") exit; print }' "$REFERENCE_FILE")
grep -qE '^  Spec:' <<< "$REF_ENTRY" || fail "rulebook/reference.md R-109 has no indented Spec line"
REF_ENFORCEMENT=$(grep -E '^  Enforcement: ' <<< "$REF_ENTRY" || true)
[ -n "$REF_ENFORCEMENT" ] || fail "rulebook/reference.md R-109 has no indented Enforcement line"
requirePhrase "$REF_ENFORCEMENT" "$ENFORCER" \
    "rulebook/reference.md R-109 Enforcement line does not name $ENFORCER"
requirePhrase "$REF_ENTRY" '`securityReviewModel`' \
    "rulebook/reference.md R-109 Spec does not name the securityReviewModel key"
requirePhrase "$REF_ENTRY" '`## Security review`' \
    "rulebook/reference.md R-109 Spec does not name the \`## Security review\` section"
requirePhrase "$REF_ENTRY" 'insecure value' \
    "rulebook/reference.md R-109 Spec does not require the insecure-value test"

# ---------------------------------------------------------------------------
# Item 3: the manifest registers R-109 under the Semgrep pre-push gate (R-516).
# ---------------------------------------------------------------------------
R109_ENTRY=$(jq -c --arg e "$ENFORCER" '[.rules[] | select(.id == "R-109" and .enforcer == $e)] | first // empty' "$MANIFEST_FILE")
[ -n "$R109_ENTRY" ] || fail "enforce/manifest.json has no R-109 entry with enforcer $ENFORCER"
[ "$(jq -r '.tier' <<< "$R109_ENTRY")" = ast ] \
    || fail "enforce/manifest.json R-109 tier must be ast, as the neighbouring push-*-gate linter entries are"
[ "$(jq -r '.severity' <<< "$R109_ENTRY")" = error ] \
    || fail "enforce/manifest.json R-109 severity must be error"
R109_NOTE=$(jq -r '.note // ""' <<< "$R109_ENTRY")
requirePhrase "$R109_NOTE" 'push-semgrep-gate.test.sh' \
    "enforce/manifest.json R-109 note does not name the push-semgrep-gate fixture"
requirePhrase "$R109_NOTE" 'r109-rule-text.test.sh' \
    "enforce/manifest.json R-109 note does not name the r109-rule-text fixture"

# ---------------------------------------------------------------------------
# Item 5: the general reviewer prompt's SECURITY item defers to the R-109 review.
# ---------------------------------------------------------------------------
ITEM_FOUR=$(awk '/^4\. SECURITY/ { inside = 1 } /^5\. / { inside = 0 } inside' "$PROMPT_FILE")
[ -n "$ITEM_FOUR" ] || fail "prompts/codex-pr-review-prompt.md has no item 4 SECURITY"
requirePhrase "$ITEM_FOUR" 'weakened protections' \
    "prompts/codex-pr-review-prompt.md item 4 lost its existing weakened-protections check"
requirePhrase "$ITEM_FOUR" 'security-touching' \
    "prompts/codex-pr-review-prompt.md item 4 does not name a security-touching PR"
requirePhrase "$ITEM_FOUR" 'separate R-109 review' \
    "prompts/codex-pr-review-prompt.md item 4 does not say a security-touching PR also gets a separate R-109 review"
requirePhrase "$ITEM_FOUR" 'below HIGH' \
    "prompts/codex-pr-review-prompt.md item 4 does not forbid grading a security finding below HIGH"
requirePhrase "$ITEM_FOUR" 'configuration is trusted' \
    "prompts/codex-pr-review-prompt.md item 4 does not reject trusted configuration as a reason to downgrade"

echo "r109-rule-text.test.sh PASS"
