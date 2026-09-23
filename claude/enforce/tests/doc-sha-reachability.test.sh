#!/usr/bin/env bash
# Covers: ci:doc-sha-reachability
#
# Verifies enforce/doc-sha-reachability.sh (R-215, IAN-308 phase 1): a commit
# SHA cited in a document is a promise that the commit can still be fetched,
# and this is the check that reads the promise back.
#
# The motivating case is the IAN-260 spec. It cited four migration sources and
# three of them (`c6af9dd`, `23cdfca`, `ef2d24b`) sat on no ref at all, because
# the PR branches carrying them were deleted after merge. Each still resolved
# in the author's clone, so nothing looked wrong, while an unreachable object
# is prunable by auto-gc and absent from a fresh clone: the slice that depended
# on them would have found its inputs gone. They are now pinned as the tags
# keep/ian260-migration-r605-audit, keep/ian260-migration-r605-corrected and
# keep/ian260-migration-ian184-gate, and the live-corpus block at the bottom of
# this fixture is the regression test for exactly that.
#
# The assertions below are positive throughout. A test that asserts the ABSENCE
# of a finding string passes just as happily against an implementation that has
# stopped running at all, which this repository has shipped three times in two
# days, so every case here asserts either the presence of a finding naming its
# SHA and its citing line, or the presence of the clean summary line carrying a
# non-zero count of what was inspected.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECK="$CLAUDE_HARNESS_ROOT/enforce/doc-sha-reachability.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
lines_matching() { grep -cF "$1" <<< "$OUT"; }

[ -f "$CHECK" ] || { echo "FAIL: no check at $CHECK"; exit 1; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
REPO="$SB/repo"
mkdir -p "$REPO/docs" "$REPO/claude/docs/nested" "$REPO/notes"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
REACHABLE=$(git -C "$REPO" rev-parse --short=8 HEAD)

# An unreachable commit, made the way the real ones were made: a branch that is
# merged nowhere and then deleted. The object survives in this clone until
# auto-gc runs, which is the whole trap.
git -C "$REPO" checkout -q -b throwaway
printf 'work\n' > "$REPO/work.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "work on a branch nobody kept"
GONE=$(git -C "$REPO" rev-parse --short=8 HEAD)
GONE_FULL=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" branch -qD throwaway

FOREIGN=0123456789abcdef0123456789abcdef01234567

# B-1: a document citing a reachable commit passes, and says what it inspected.
printf 'Landed as `%s` on main.\n' "$REACHABLE" > "$REPO/docs/reachable.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/reachable.md 2>&1); ST=$?
check "reachable citation exits 0" test "$ST" -eq 0
check "reachable citation reports what it inspected" reports "doc-sha-reachability: OK, 1 cited token(s)"
check "reachable citation counts the resolved commit" reports "1 resolve here"

# B-2: a document citing an unreachable commit fails, naming the SHA, the file
# and the line.
printf 'Background.\nThe migration source is `%s`, which is on no branch.\n' "$GONE" > "$REPO/docs/gone.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/gone.md 2>&1); ST=$?
check "unreachable citation exits 1" test "$ST" -eq 1
check "unreachable citation names sha, file and line" reports "DOC-SHA-UNREACHABLE: $GONE at docs/gone.md:2"
check "unreachable citation names the full object" reports "$GONE_FULL"
check "unreachable citation summarises the count" reports "doc-sha-reachability: 1 unreachable citation(s)"

# B-3: pinning the commit under a ref clears the finding. This is the repair
# the IAN-260 keep/ tags performed.
git -C "$REPO" tag keep/fixture-pin "$GONE_FULL"
OUT=$(bash "$CHECK" --root "$REPO" docs/gone.md 2>&1); ST=$?
check "a tag makes the same citation pass" test "$ST" -eq 0
check "pinned citation still counts the token" reports "doc-sha-reachability: OK, 1 cited token(s)"
git -C "$REPO" tag -d keep/fixture-pin >/dev/null

# B-4: a token that resolves to no object here is another repository's SHA or a
# hex word in prose, and is never a finding. The clean summary proves the token
# was collected and judged rather than never seen.
printf 'Upstream carries `%s`, and the word `facade0` is prose.\n' "$FOREIGN" > "$REPO/docs/foreign.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/foreign.md 2>&1); ST=$?
check "foreign sha is not a finding" test "$ST" -eq 0
check "foreign sha was collected, not skipped" reports "doc-sha-reachability: OK, 2 cited token(s)"
check "foreign sha resolved to nothing here" reports "0 resolve here"

# B-5: both document roots are scanned when no path is named, and a markdown
# file outside them is not this check's business.
printf 'Ported from `%s`.\n' "$GONE" > "$REPO/claude/docs/nested/ported.md"
printf 'Scratch note about `%s`.\n' "$GONE" > "$REPO/notes/scratch.md"
OUT=$(bash "$CHECK" --root "$REPO" 2>&1); ST=$?
check "default scan exits 1 on the corpus" test "$ST" -eq 1
check "default scan reaches docs/" reports "DOC-SHA-UNREACHABLE: $GONE at docs/gone.md:2"
check "default scan reaches claude/docs/" reports "DOC-SHA-UNREACHABLE: $GONE at claude/docs/nested/ported.md:1"
check "default scan reads both roots and nothing outside them" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 2
rm -f "$REPO/claude/docs/nested/ported.md" "$REPO/notes/scratch.md"

# B-6: the escape hatch. A citation deliberately left unreachable carries an
# adjacent marker naming that same SHA and a reason.
printf 'Superseded by `%s` <!-- unreachable-sha: %s branch deleted after merge, kept as history -->\n' "$GONE" "$GONE" > "$REPO/docs/excused.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused.md 2>&1); ST=$?
check "marker with sha and reason excuses the citation" test "$ST" -eq 0
check "excused citation is still inspected" reports "doc-sha-reachability: OK, 1 cited token(s)"

# B-7: the three ways the marker must NOT fire. Each is a finding, so a marker
# cannot be copied around, cannot be left blank, and cannot drift onto a
# neighbouring line.
printf 'See `%s` <!-- unreachable-sha: %s wrong sha, this marker excuses nothing -->\n' "$GONE" "$FOREIGN" > "$REPO/docs/excused-other-sha.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-other-sha.md 2>&1); ST=$?
check "marker naming another sha does not excuse" test "$ST" -eq 1
check "marker naming another sha reports the finding" reports "DOC-SHA-UNREACHABLE: $GONE at docs/excused-other-sha.md:1"

printf 'See `%s` <!-- unreachable-sha: %s -->\n' "$GONE" "$GONE" > "$REPO/docs/excused-no-reason.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-no-reason.md 2>&1); ST=$?
check "marker with no reason does not excuse" test "$ST" -eq 1
check "marker with no reason reports the finding" reports "DOC-SHA-UNREACHABLE: $GONE at docs/excused-no-reason.md:1"

printf '<!-- unreachable-sha: %s reason on the wrong line -->\nSee `%s`.\n' "$GONE" "$GONE" > "$REPO/docs/excused-prev-line.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-prev-line.md 2>&1); ST=$?
check "marker on another line does not excuse" test "$ST" -eq 1
check "marker on another line reports the finding" reports "DOC-SHA-UNREACHABLE: $GONE at docs/excused-prev-line.md:2"

# B-8: --changed inspects only the documents this branch touched, so the
# historical corpus is reported by --all and gated at the push boundary.
git -C "$REPO" add -A
git -C "$REPO" commit -qm "docs: the fixture corpus"
printf 'New note citing `%s`.\n' "$GONE" > "$REPO/docs/new-note.md"
OUT=$(cd "$REPO" && bash "$CHECK" --changed 2>&1); ST=$?
check "--changed exits 1 on a new bad citation" test "$ST" -eq 1
check "--changed names the changed document" reports "DOC-SHA-UNREACHABLE: $GONE at docs/new-note.md:1"
check "--changed reads the changed document only" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 1
OUT=$(cd "$REPO" && bash "$CHECK" --all 2>&1)
check "--all still sees the committed corpus" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 5
rm -f "$REPO/docs/new-note.md"

# B-9: one git process per token is the shape this repository already paid for
# once (IAN-183). Thirty tokens must not become thirty processes.
BIN="$SB/bin"; mkdir -p "$BIN"
REAL_GIT=$(command -v git)
GIT_LOG="$SB/git-calls.log"
{
  echo '#!/bin/sh'
  echo "printf '%s\\n' \"\$*\" >> \"$GIT_LOG\""
  echo "exec \"$REAL_GIT\" \"\$@\""
} > "$BIN/git"
chmod +x "$BIN/git"
: > "$REPO/docs/many.md"
token_index=0
while [ "$token_index" -lt 30 ]; do
  printf 'Line %s cites `%040d`.\n' "$token_index" "$token_index" >> "$REPO/docs/many.md"
  token_index=$((token_index + 1))
done
: > "$GIT_LOG"
OUT=$(PATH="$BIN:$PATH" bash "$CHECK" --root "$REPO" docs/many.md 2>&1); ST=$?
GIT_CALLS=$(grep -c . "$GIT_LOG" || true)
check "thirty tokens exit 0" test "$ST" -eq 0
check "thirty tokens were collected" reports "doc-sha-reachability: OK, 30 cited token(s)"
check "resolution is batched, not one process per token" test "$GIT_CALLS" -le 8
check "resolution goes through cat-file --batch-check" grep -q 'cat-file --batch-check' "$GIT_LOG"
rm -f "$REPO/docs/many.md"

# B-10: a shallow clone holds none of the objects beyond its graft, so an
# unreachable citation cannot be told from a foreign one. That is a state the
# check announces and refuses to judge from, never one it passes silently.
git -C "$REPO" add -A
git -C "$REPO" commit -qm "docs: fixture corpus, second pass"
git clone -q --depth 1 "file://$REPO" "$SB/shallow"
OUT=$(bash "$CHECK" --root "$SB/shallow" 2>&1); ST=$?
check "shallow repository exits 2" test "$ST" -eq 2
check "shallow repository says it cannot judge" reports "DOC-SHA-DEGRADED: shallow repository"

# B-11: the live corpus. The IAN-260 spec is the motivating document and the
# three keep/ tags are what keep it passing, so this block fails the moment one
# of them is deleted. A shallow checkout (CI clones at depth 1) holds none of
# the objects, so the block states that it cannot run rather than passing blind.
LIVE_ROOT=$(git -C "$CLAUDE_HARNESS_ROOT" rev-parse --show-toplevel 2>/dev/null || true)
LIVE_SPEC="claude/docs/superpowers/specs/2026-09-20-handoff-per-session-files-design.md"
if [ -z "$LIVE_ROOT" ] || [ ! -f "$LIVE_ROOT/$LIVE_SPEC" ]; then
  echo "NOTE: no checkout carrying $LIVE_SPEC, so the live-corpus block did not run"
elif [ "$(git -C "$LIVE_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" != "false" ]; then
  echo "NOTE: the checkout is shallow, so the live-corpus block did not run"
else
  OUT=$(bash "$CHECK" --root "$LIVE_ROOT" "$LIVE_SPEC" 2>&1); ST=$?
  check "IAN-260 spec passes" test "$ST" -eq 0
  check "IAN-260 spec was really inspected" grep -qE 'doc-sha-reachability: OK, ([4-9]|[1-9][0-9]+) cited token\(s\)' <<< "$OUT"
  check "IAN-260 spec carries citations that resolve here" grep -qE 'OK, [0-9]+ cited token\(s\) in 1 document\(s\), [1-9]' <<< "$OUT"
  for pinned in \
    "c6af9dd:keep/ian260-migration-r605-audit" \
    "23cdfca:keep/ian260-migration-r605-corrected" \
    "ef2d24b:keep/ian260-migration-ian184-gate"; do
    pinned_sha=${pinned%%:*}
    pinned_tag=${pinned#*:}
    CONTAINS=$(git -C "$LIVE_ROOT" tag --contains "$pinned_sha" 2>&1)
    check "$pinned_sha is reachable through $pinned_tag" grep -qxF "$pinned_tag" <<< "$CONTAINS"
  done
fi

[ "$fail" -eq 0 ] && echo "doc-sha-reachability.test.sh PASS"
exit "$fail"
