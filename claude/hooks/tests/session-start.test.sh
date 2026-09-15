#!/usr/bin/env bash
# Verifies session-start.sh loads the R-602 canonical handoff path
# (docs/session-handoff/session-handoff.md), SHA-verifies it against git log
# (R-001 step 5), labels an unverifiable handoff, and never injects dated
# audit reports as handoffs (2026-07-31 audits: the hook read docs/audits/).
set -euo pipefail
HOOK="$HOME/.claude/hooks/session-start.sh"

REPO=$(mktemp -d); cd "$REPO"; git init -q
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m "chore: init"
GOOD_SHA=$(git rev-parse --short HEAD)

# Decoy: a dated audit report must NOT be injected as a handoff.
mkdir -p docs/audits docs/session-handoff
printf '# Audit report decoy\n' > docs/audits/2026-01-01-engineering.md

# Canonical handoff with a real SHA -> injected, verified.
printf '# Handoff\n\n- Last commit: `%s` chore: init\n- next: continue\n' "$GOOD_SHA" > docs/session-handoff/session-handoff.md
OUT=$(echo '{}' | "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'session-handoff/session-handoff.md' || { echo "FAIL: canonical handoff not injected"; exit 1; }
printf '%s' "$CTX" | grep -q 'SHA-verified' || { echo "FAIL: expected SHA-verified verdict"; exit 1; }
printf '%s' "$CTX" | grep -q 'Audit report decoy' && { echo "FAIL: audit report injected as handoff"; exit 1; } || true

# Handoff with an unknown SHA -> injected but labeled UNVERIFIED.
printf '# Handoff\n\n- Last commit: `deadbeefcafe` mystery\n' > docs/session-handoff/session-handoff.md
OUT2=$(echo '{}' | "$HOOK")
CTX2=$(printf '%s' "$OUT2" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX2" | grep -q 'UNVERIFIED' || { echo "FAIL: expected UNVERIFIED label for unknown SHA"; exit 1; }

# No handoff file -> no handoff section.
rm docs/session-handoff/session-handoff.md
OUT3=$(echo '{}' | "$HOOK" || true)
printf '%s' "$OUT3" | grep -q 'Most recent handoff doc' && { echo "FAIL: handoff section without a handoff file"; exit 1; } || true

# SHA stamp is keyed by repo toplevel (2026-09-16 audit P3-4): two sessions
# in different repos write different files instead of clobbering one shared
# baseline, and the file carries HEAD of its own repo.
STAMP_TMP=$(mktemp -d)
TMPDIR="$STAMP_TMP" bash "$HOOK" <<< '{}' >/dev/null 2>&1 || true
REPO_KEY=$(printf '%s' "$(git rev-parse --show-toplevel)" | shasum | awk '{print $1}')
STAMP_FILE="$STAMP_TMP/claude-session-start-sha-$REPO_KEY"
[ -f "$STAMP_FILE" ] || { echo "FAIL: expected repo-keyed SHA stamp at claude-session-start-sha-<key>"; exit 1; }
[ "$(cat "$STAMP_FILE")" = "$(git rev-parse HEAD)" ] || { echo "FAIL: keyed stamp must hold this repo's HEAD"; exit 1; }
rm -rf "$STAMP_TMP"

cd / && rm -rf "$REPO"
echo "session-start.test.sh PASS"
