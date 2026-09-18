#!/usr/bin/env bash
# spec-grounding-check.test.sh: verifies skills/spec-grounding/scripts/check.sh
# (2026-09-17 skills audit, S-2) against a sandboxed repo: a fully grounded
# spec passes, and each of the six definition-of-done conditions fails with a
# line naming what is unmet.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECK="$CLAUDE_HARNESS_ROOT/skills/spec-grounding/scripts/check.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
# omits <text>: true when the check output does not contain the text.
omits() { ! grep -qF "$1" <<< "$OUT"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
git -C "$SB" init -q -b main
git -C "$SB" config user.email t@example.invalid; git -C "$SB" config user.name t
mkdir -p "$SB/src/services" "$SB/docs/superpowers/specs"
printf 'export function sendUserNotification() {}\nline two\nline three\n' > "$SB/src/services/sendUserNotification.ts"
git -C "$SB" add -A && git -C "$SB" commit -qm "init"

SPEC="$SB/docs/superpowers/specs/2026-09-17-notify-design.md"
# good_spec: a fully grounded spec on stdout; cases pipe it through sed
# (no sed -i, which differs between GNU and BSD) into $SPEC.
good_spec() {
cat <<'EOF'
# Notifications

## Codebase grounding

| Concept in this spec | Real path | Exported name |
|---|---|---|
| notification service | `src/services/sendUserNotification.ts` | `sendUserNotification` |

Concepts with no match in the repo, which this spec therefore creates: digest scheduler.

## Already exists

- send a notification: implemented at `src/services/sendUserNotification.ts:1`.

## Conflicts with current patterns

- Spec says a `utils/` helper; the repo keeps services under `src/services/sendUserNotification.ts:1` (R-306).

## Acceptance criteria

- B-1: the digest scheduler sends one notification per user per day.

## Non-goals

- Push notifications.

## Domain vocabulary

- notification - a message sent to one user - chosen over: alert because alert implies urgency.
EOF
}

# Grounded spec, only the spec dirty: passes.
good_spec > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "grounded spec passes" test "$ST" -eq 0
check "pass line printed" reports "meets the definition of done"

# Regression pin for the macOS /var-vs-/private/var mismatch: the spec path
# is handed over in whichever symlink form the sandbox came in, while git
# reports the physical toplevel; condition 6 must still recognize the spec
# as itself. Passing the PHYSICAL form here exercises the opposite pairing
# on every platform, so a revert of the canonicalization fails somewhere
# regardless of what mktemp returned.
SPEC_PHYSICAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SPEC")
OUT=$("$CHECK" "$SPEC_PHYSICAL" 2>&1); ST=$?
check "grounded spec passes via its physical path" test "$ST" -eq 0

# Regression (IAN-120): each section check piped the awk section extract into
# `grep -q`. On a section larger than the pipe buffer, grep exits at an early
# match while awk is still writing, awk dies of SIGPIPE, and under pipefail
# the match read as a miss: a present B-1 line or chosen-over entry was
# reported missing, and an uncited conflict bullet went unreported.
# spec_with_large_sections: the grounded spec with 4096 extra lines after the
# B-1 line and after the chosen-over entry, pushing both sections past 64KB.
spec_with_large_sections() {
  good_spec | awk '
    { print }
    /^- B-1: / { for (i = 2; i < 4098; i++) print "- B-" i ": an ordinary acceptance criterion kept for size" }
    /chosen over:/ { for (i = 0; i < 4096; i++) print "- term" i " - an ordinary glossary entry kept for size - chosen over: other" i "." }
  '
}
spec_with_large_sections > "$SPEC"
# spec_exceeds_pipe_buffer: true when the spec is over 128KB, so the cases
# below cannot pass merely because a section fit in the pipe buffer.
spec_exceeds_pipe_buffer() { [ "$(wc -c < "$SPEC" | tr -d ' ')" -gt 131072 ]; }
check "large-section spec exceeds two pipe buffers" spec_exceeds_pipe_buffer
OUT=$("$CHECK" "$SPEC" --no-git 2>&1); ST=$?
check "grounded spec with sections over 64KB passes" test "$ST" -eq 0
check "B-1 found in an Acceptance criteria section over 64KB" omits "has no B-1 line"
check "chosen-over found in a Domain vocabulary section over 64KB" omits "has no \"chosen over:\" entry"

# spec_with_large_uncited_conflicts: the first conflict bullet loses its rule
# citation and 4096 cited bullets follow it, pushing the section past 64KB.
spec_with_large_uncited_conflicts() {
  good_spec | sed 's| (R-306)\.|.|' | awk '
    { print }
    /^- Spec says a `utils\/` helper/ { for (i = 0; i < 4096; i++) print "- an ordinary conflict bullet kept for size " i " (R-306)." }
  '
}
spec_with_large_uncited_conflicts > "$SPEC"
OUT=$("$CHECK" "$SPEC" --no-git 2>&1); ST=$?
check "uncited conflict in a section over 64KB fails" test "$ST" -eq 1
check "uncited conflict in a section over 64KB named" reports "names no governing R-NNN rule"

# A path that does not exist in the grounding table.
good_spec | sed 's|src/services/sendUserNotification.ts` \| `sendUserNotification`|src/services/missing.ts` \| `sendUserNotification`|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "missing grounding path fails" test "$ST" -eq 1
check "missing grounding path named" reports "src/services/missing.ts, which does not exist"

# A file:line beyond the end of the file.
good_spec | sed 's|implemented at `src/services/sendUserNotification.ts:1`|implemented at `src/services/sendUserNotification.ts:40`|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "line beyond EOF fails" test "$ST" -eq 1
check "line beyond EOF named" reports "has only 3 lines"

# A conflict bullet with no governing rule.
good_spec | sed 's| (R-306)\.|.|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "conflict without rule fails" test "$ST" -eq 1
check "conflict without rule named" reports "names no governing R-NNN rule"

# No glossary entry.
good_spec | sed 's|chosen over: alert because alert implies urgency|nothing chosen|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "glossary without chosen-over fails" test "$ST" -eq 1
check "glossary failure cites R-330" reports "R-330"

# No B-1 and no Non-goals.
good_spec | sed 's|^- B-1: |- |; s|^## Non-goals|## Later|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "missing B-1 and Non-goals fails" test "$ST" -eq 1
check "missing B-1 named" reports "has no B-1 line"
check "missing Non-goals named" reports 'missing "## Non-goals"'

# A second modified file: the skill implements nothing.
good_spec > "$SPEC"; printf 'stray\n' > "$SB/src/services/stray.ts"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "other modified file fails" test "$ST" -eq 1
check "other modified file named" reports "src/services/stray.ts"
OUT=$("$CHECK" "$SPEC" --no-git 2>&1); ST=$?
check "--no-git skips the tree check" test "$ST" -eq 0
rm "$SB/src/services/stray.ts"

# Missing section named.
good_spec | sed 's|^## Already exists|## Present|' > "$SPEC"
OUT=$("$CHECK" "$SPEC" 2>&1); ST=$?
check "missing section fails" test "$ST" -eq 1
check "missing section named" reports 'missing "## Already exists"'

[ "$fail" -eq 0 ] && echo "spec-grounding-check.test.sh PASS"
exit "$fail"
