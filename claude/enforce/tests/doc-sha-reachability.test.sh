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
#
# The push-mode, case, marker-context, hostile-filename, resolver-failure and
# process-budget blocks were added by the R-517 review of PR #118, each closing
# a finding that the first round of this fixture could not have caught.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECK="$CLAUDE_HARNESS_ROOT/enforce/doc-sha-reachability.sh"
SAMPLE_HOOK="$CLAUDE_HARNESS_ROOT/hooks/pre-push.sample"
INSTALLER="$CLAUDE_HARNESS_ROOT/hooks/install-git-hooks.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
reports() { grep -qF "$1" <<< "$OUT"; }
lines_matching() { grep -cF "$1" <<< "$OUT"; }
ZEROS=0000000000000000000000000000000000000000

[ -f "$CHECK" ] || { echo "FAIL: no check at $CHECK"; exit 1; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# makeRepository <dir>: a repository holding one reachable commit and one that
# is merged nowhere and whose branch is then deleted, which is how the three
# real ones were made. Sets REACHABLE, GONE and GONE_FULL.
makeRepository() {
  local dir="$1"
  mkdir -p "$dir/docs" "$dir/claude/docs/nested" "$dir/notes"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name t
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "init"
  REACHABLE=$(git -C "$dir" rev-parse --short=8 HEAD)
  git -C "$dir" checkout -q -b throwaway
  printf 'work\n' > "$dir/work.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "work on a branch nobody kept"
  GONE=$(git -C "$dir" rev-parse --short=8 HEAD)
  GONE_FULL=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" checkout -q main
  git -C "$dir" branch -qD throwaway
}

REPO="$SB/repo"
makeRepository "$REPO"
REPO_GONE="$GONE"
REPO_GONE_FULL="$GONE_FULL"
REPO_REACHABLE="$REACHABLE"
FOREIGN=0123456789abcdef0123456789abcdef01234567

# B-1: a document citing a reachable commit passes, and says what it inspected.
printf 'Landed as `%s` on main.\n' "$REPO_REACHABLE" > "$REPO/docs/reachable.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/reachable.md 2>&1); ST=$?
check "reachable citation exits 0" test "$ST" -eq 0
check "reachable citation reports what it inspected" reports "doc-sha-reachability: OK, 1 cited token(s)"
check "reachable citation counts the resolved commit" reports "1 resolve here"

# B-2: a document citing an unreachable commit fails, naming the SHA, the file
# and the line.
printf 'Background.\nThe migration source is `%s`, which is on no branch.\n' "$REPO_GONE" > "$REPO/docs/gone.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/gone.md 2>&1); ST=$?
check "unreachable citation exits 1" test "$ST" -eq 1
check "unreachable citation names sha, file and line" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/gone.md:2"
check "unreachable citation names the full object" reports "$REPO_GONE_FULL"
check "unreachable citation summarises the count" reports "doc-sha-reachability: 1 unreachable citation(s)"

# B-3: pinning the commit under a ref clears the finding. This is the repair
# the IAN-260 keep/ tags performed.
git -C "$REPO" tag keep/fixture-pin "$REPO_GONE_FULL"
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

# B-5: uppercase hexadecimal is the same SHA. Accepting only lowercase made an
# uppercase citation of an unreachable commit invisible, and the summary said
# "0 cited token(s)" while the document plainly cited one (R-517 review).
printf 'Ported from `%s` upstream.\n' "$(printf '%s' "$REPO_GONE" | tr 'a-f' 'A-F')" > "$REPO/docs/uppercase.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/uppercase.md 2>&1); ST=$?
check "uppercase citation exits 1" test "$ST" -eq 1
check "uppercase citation is collected" reports "doc-sha-reachability: 1 unreachable citation(s)"
check "uppercase citation is reported in normalised form" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/uppercase.md:1"

# B-6: both document roots are scanned when no path is named, a markdown file
# outside them is not this check's business, and a filename carrying a colon or
# a newline is inspected like any other. Newline-delimited paths and
# colon-delimited records made both of those invisible (R-517 review).
CORPUS="$SB/corpus"
makeRepository "$CORPUS"
CORPUS_GONE="$GONE"
printf 'Landed as `%s`.\n' "$REACHABLE" > "$CORPUS/docs/reachable.md"
printf 'Background.\nSource `%s`.\n' "$CORPUS_GONE" > "$CORPUS/docs/gone.md"
printf 'Ported from `%s`.\n' "$CORPUS_GONE" > "$CORPUS/claude/docs/nested/ported.md"
printf 'Scratch note about `%s`.\n' "$CORPUS_GONE" > "$CORPUS/notes/scratch.md"
printf 'Colon `%s`.\n' "$CORPUS_GONE" > "$CORPUS/docs/with:colon.md"
NEWLINE_DOC=$(printf 'docs/with\nnewline.md')
printf 'Newline `%s`.\n' "$CORPUS_GONE" > "$CORPUS/$NEWLINE_DOC"
OUT=$(bash "$CHECK" --root "$CORPUS" 2>&1); ST=$?
check "default scan exits 1 on the corpus" test "$ST" -eq 1
check "default scan reaches docs/" reports "DOC-SHA-UNREACHABLE: $CORPUS_GONE at docs/gone.md:2"
check "default scan reaches claude/docs/" reports "DOC-SHA-UNREACHABLE: $CORPUS_GONE at claude/docs/nested/ported.md:1"
check "default scan reads a filename holding a colon" reports "at docs/with:colon.md:1"
check "default scan reads every document under the roots and nothing outside them" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 4

# B-7: the escape hatch. A citation deliberately left unreachable carries an
# adjacent marker naming that same SHA and a reason.
printf 'Superseded by `%s` <!-- unreachable-sha: %s branch deleted after merge, kept as history -->\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused.md 2>&1); ST=$?
check "marker with sha and reason excuses the citation" test "$ST" -eq 0
check "excused citation is still inspected" reports "doc-sha-reachability: OK, 1 cited token(s)"

# B-8: the marker matches its SHA without regard to case, which is the stated
# policy, since the citation itself is normalised.
printf 'Superseded by `%s` <!-- unreachable-sha: %s branch deleted after merge -->\n' "$REPO_GONE" "$(printf '%s' "$REPO_GONE" | tr 'a-f' 'A-F')" > "$REPO/docs/excused-uppercase-marker.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-uppercase-marker.md 2>&1); ST=$?
check "an uppercase marker excuses a lowercase citation" test "$ST" -eq 0
check "the case-insensitive marker match still inspects the token" reports "doc-sha-reachability: OK, 1 cited token(s)"

# B-9: the ways the marker must NOT fire. Each is a finding, so a marker cannot
# be copied around, cannot be left blank or filled with punctuation or
# whitespace, cannot drift onto a neighbouring line, and cannot be written as
# an example inside code or inside an enclosing comment (R-517 review).
printf 'See `%s` <!-- unreachable-sha: %s wrong sha, this marker excuses nothing -->\n' "$REPO_GONE" "$FOREIGN" > "$REPO/docs/excused-other-sha.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-other-sha.md 2>&1); ST=$?
check "marker naming another sha does not excuse" test "$ST" -eq 1
check "marker naming another sha reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-other-sha.md:1"

printf 'See `%s` <!-- unreachable-sha: %s -->\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-no-reason.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-no-reason.md 2>&1); ST=$?
check "marker with no reason does not excuse" test "$ST" -eq 1
check "marker with no reason reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-no-reason.md:1"

printf 'See `%s` <!-- unreachable-sha: %s \t\r -->\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-whitespace-reason.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-whitespace-reason.md 2>&1); ST=$?
check "marker whose reason is only whitespace does not excuse" test "$ST" -eq 1
check "marker whose reason is only whitespace reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-whitespace-reason.md:1"

printf 'See `%s` <!-- unreachable-sha: %s ... -->\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-punctuation-reason.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-punctuation-reason.md 2>&1); ST=$?
check "marker whose reason is only punctuation does not excuse" test "$ST" -eq 1
check "marker whose reason is only punctuation reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-punctuation-reason.md:1"

printf '<!-- unreachable-sha: %s reason on the wrong line -->\nSee `%s`.\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-prev-line.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-prev-line.md 2>&1); ST=$?
check "marker on another line does not excuse" test "$ST" -eq 1
check "marker on another line reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-prev-line.md:2"

printf 'See `%s`, and the marker is written `<!-- unreachable-sha: %s an example, not a real one -->` here.\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-inline-code.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-inline-code.md 2>&1); ST=$?
check "marker inside inline code does not excuse" test "$ST" -eq 1
check "marker inside inline code reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-inline-code.md:1"

{
  echo 'An example block:'
  echo '```'
  printf 'See `%s` <!-- unreachable-sha: %s an example inside a fence -->\n' "$REPO_GONE" "$REPO_GONE"
  echo '```'
} > "$REPO/docs/excused-fenced.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-fenced.md 2>&1); ST=$?
check "marker inside a fenced block does not excuse" test "$ST" -eq 1
check "marker inside a fenced block reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-fenced.md:3"

printf '<!-- a comment that stays open\nSee `%s` <!-- unreachable-sha: %s nested inside an open comment -->\nstill open\n-->\n' "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/excused-enclosed.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/excused-enclosed.md 2>&1); ST=$?
check "marker inside an enclosing comment does not excuse" test "$ST" -eq 1
check "marker inside an enclosing comment reports the finding" reports "DOC-SHA-UNREACHABLE: $REPO_GONE at docs/excused-enclosed.md:2"

# B-10: one marker excuses one citation, not every occurrence on its line.
printf 'Both `%s` and `%s` again <!-- unreachable-sha: %s only one of them is excused -->\n' "$REPO_GONE" "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/two-citations-one-marker.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/two-citations-one-marker.md 2>&1); ST=$?
check "one marker leaves the second occurrence reported" test "$ST" -eq 1
check "one marker excuses exactly one occurrence" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 1

printf 'Both `%s` and `%s` <!-- unreachable-sha: %s first -->  <!-- unreachable-sha: %s second -->\n' "$REPO_GONE" "$REPO_GONE" "$REPO_GONE" "$REPO_GONE" > "$REPO/docs/two-citations-two-markers.md"
OUT=$(bash "$CHECK" --root "$REPO" docs/two-citations-two-markers.md 2>&1); ST=$?
check "two markers excuse two occurrences" test "$ST" -eq 0
check "two excused occurrences were still inspected" reports "doc-sha-reachability: OK, 2 cited token(s)"

# B-11: --changed inspects only the documents this branch touched, so the
# historical corpus is reported by --all and gated at the push boundary.
git -C "$CORPUS" add -A
git -C "$CORPUS" commit -qm "docs: the fixture corpus"
printf 'New note citing `%s`.\n' "$CORPUS_GONE" > "$CORPUS/docs/new-note.md"
OUT=$(cd "$CORPUS" && bash "$CHECK" --changed 2>&1); ST=$?
check "--changed exits 1 on a new bad citation" test "$ST" -eq 1
check "--changed names the changed document" reports "DOC-SHA-UNREACHABLE: $CORPUS_GONE at docs/new-note.md:1"
check "--changed reads the changed document only" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 1
OUT=$(cd "$CORPUS" && bash "$CHECK" --all 2>&1)
check "--all still sees the committed corpus" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 5
rm -f "$CORPUS/docs/new-note.md"

# B-12: the push gate judges the commits being pushed, not the working tree.
# Reading the working tree meant a committed unreachable citation passed the
# moment an uncommitted edit removed it, and a first-push branch with no
# upstream returned "cannot judge", which the hook let through (R-517 review,
# the HIGH).
PUSHED="$SB/pushed"
makeRepository "$PUSHED"
PUSHED_GONE="$GONE"
# --initial-branch is explicit because the bare repository's HEAD decides what
# `git clone` checks out. Without it, HEAD follows the machine's
# init.defaultBranch: `main` here, `master` on the CI runner, where the clone
# below then found no such ref, produced an EMPTY working tree, and the copy
# of the check into it failed. The pre-push hook found nothing to run and
# exited 0 in silence, so two assertions measured a hook that never ran.
git -C "$PUSHED" init -q --bare --initial-branch=main "$SB/remote.git"
git -C "$PUSHED" remote add origin "$SB/remote.git"
printf 'Migrated from `%s`.\n' "$PUSHED_GONE" > "$PUSHED/docs/committed.md"
git -C "$PUSHED" add -A
git -C "$PUSHED" commit -qm "docs: a citation that is already unreachable"
PUSHED_TIP=$(git -C "$PUSHED" rev-parse HEAD)
printf 'Migrated from somewhere.\n' > "$PUSHED/docs/committed.md"
OUT=$(cd "$PUSHED" && printf 'refs/heads/main %s refs/heads/main %s\n' "$PUSHED_TIP" "$ZEROS" | bash "$CHECK" --push origin 2>&1); ST=$?
check "--push exits 1 on a first push of a new branch" test "$ST" -eq 1
check "--push reads the committed blob, not the working tree" reports "DOC-SHA-UNREACHABLE: $PUSHED_GONE at docs/committed.md:1"
git -C "$PUSHED" checkout -q -- docs/committed.md

OUT=$(cd "$PUSHED" && printf 'refs/heads/gone %s refs/heads/gone %s\n' "$ZEROS" "$PUSHED_TIP" | bash "$CHECK" --push origin 2>&1); ST=$?
check "--push ignores a branch deletion" test "$ST" -eq 0
check "--push says it inspected nothing for a deletion" reports "doc-sha-reachability: OK, 0 cited token(s)"

# B-13: the sample pre-push hook aborts the push on a finding, and aborts it
# again when the check declines to judge. Exit 2 used to be an allow, which is
# the fail-open direction (R-517 review, the HIGH).
mkdir -p "$PUSHED/claude/enforce"
cp "$CHECK" "$PUSHED/claude/enforce/doc-sha-reachability.sh"
cp "$CLAUDE_HARNESS_ROOT/enforce/related-tests.sh" "$PUSHED/claude/enforce/related-tests.sh"
cp "$CLAUDE_HARNESS_ROOT/enforce/port-checks.sh" "$PUSHED/claude/enforce/port-checks.sh"
OUT=$(cd "$PUSHED" && printf 'refs/heads/main %s refs/heads/main %s\n' "$PUSHED_TIP" "$ZEROS" | bash "$SAMPLE_HOOK" origin "$SB/remote.git" 2>&1); ST=$?
check "the pre-push sample aborts on a finding" test "$ST" -eq 1
check "the pre-push sample names the finding" reports "DOC-SHA-UNREACHABLE: $PUSHED_GONE at docs/committed.md:1"

git -C "$PUSHED" add -A
git -C "$PUSHED" commit -qm "chore: carry the check for the hook to find"
git -C "$PUSHED" push -q origin main
# A --depth 1 clone over file:// is not reliably shallow on every git build:
# it is shallow on macOS here and was NOT in CI, where these two assertions
# failed while the ambient checkout (itself shallow) made the other shallow
# directions pass. The fixture then measured something other than what it
# claimed. Assert the precondition instead of assuming it, force it when the
# clone did not take, and fail loudly rather than quietly testing nothing.
git clone -q --depth 1 "file://$SB/remote.git" "$SB/shallow-push"
if [ "$(git -C "$SB/shallow-push" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]; then
  git -C "$SB/shallow-push" fetch -q --depth 1 origin main 2>/dev/null || true
fi
check "the shallow-push fixture really is a shallow clone" \
  test "$(git -C "$SB/shallow-push" rev-parse --is-shallow-repository 2>/dev/null)" = "true"
check "the shallow-push clone actually checked out a tree" \
  test -d "$SB/shallow-push/claude/enforce"
cp "$CHECK" "$SB/shallow-push/claude/enforce/doc-sha-reachability.sh"
SHALLOW_TIP=$(git -C "$SB/shallow-push" rev-parse HEAD)
OUT=$(cd "$SB/shallow-push" && printf 'refs/heads/main %s refs/heads/main %s\n' "$SHALLOW_TIP" "$ZEROS" | bash "$SAMPLE_HOOK" origin "file://$SB/remote.git" 2>&1); ST=$?
# These two report what they saw. They failed in CI and passed here, and a
# bare FAIL line with no status and no output cost two diagnostic rounds.
check "the pre-push sample aborts when the check cannot judge (status $ST, output: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-200))" test "$ST" -eq 1
check "the pre-push sample says the check could not judge (output: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-200))" reports "DOC-SHA-DEGRADED: shallow repository"

# B-14: an installed hook is upgraded in place by re-running the installer, so
# the enforcement claim has a path behind it rather than an assumption that
# whoever installed the old one will notice (R-517 review).
INSTALL_TARGET=$(git -C "$PUSHED" rev-parse --git-path hooks)
case "$INSTALL_TARGET" in /*) ;; *) INSTALL_TARGET="$PUSHED/$INSTALL_TARGET" ;; esac
mkdir -p "$INSTALL_TARGET"
{
  echo '#!/usr/bin/env bash'
  echo '# Git pre-push hook for the agent-governance repo: an older copy.'
  echo 'exit 0'
} > "$INSTALL_TARGET/pre-push"
chmod +x "$INSTALL_TARGET/pre-push"
OUT=$(bash "$INSTALLER" "$PUSHED" 2>&1); ST=$?
check "the installer upgrades an older hook in place" test "$ST" -eq 0
check "the upgraded hook carries the cited-SHA gate" grep -q "doc-sha-reachability" "$INSTALL_TARGET/pre-push"

# B-15: a resolver that fails is not a clean corpus. Discarding git cat-file's
# error reported "0 resolve here" and exit 0, which is a false all-clear
# (R-517 review).
BIN="$SB/bin"; mkdir -p "$BIN"
REAL_GIT=$(command -v git)
GIT_LOG="$SB/git-calls.log"
{
  echo '#!/bin/sh'
  echo "printf '%s\\n' \"\$*\" >> \"$GIT_LOG\""
  echo 'case " $* " in'
  echo "  *\" cat-file \"*) [ -n \"\${FIXTURE_BREAK_CAT_FILE:-}\" ] && { echo 'fatal: the object store is unreadable' >&2; exit 128; } ;;"
  echo 'esac'
  echo "exec \"$REAL_GIT\" \"\$@\""
} > "$BIN/git"
chmod +x "$BIN/git"
: > "$GIT_LOG"
OUT=$(FIXTURE_BREAK_CAT_FILE=1 PATH="$BIN:$PATH" bash "$CHECK" --root "$REPO" docs/gone.md 2>&1); ST=$?
check "a failing resolver exits 2" test "$ST" -eq 2
check "a failing resolver says it could not resolve" reports "DOC-SHA-DEGRADED: cannot resolve"

# B-16: a document the check cannot read is reported, not skipped.
if [ "$(id -u)" -ne 0 ]; then
  printf 'Unreadable `%s`.\n' "$REPO_GONE" > "$REPO/docs/unreadable.md"
  chmod 000 "$REPO/docs/unreadable.md"
  OUT=$(bash "$CHECK" --root "$REPO" docs/unreadable.md 2>&1); ST=$?
  chmod 644 "$REPO/docs/unreadable.md"
  rm -f "$REPO/docs/unreadable.md"
  check "an unreadable document exits 2" test "$ST" -eq 2
  check "an unreadable document is named" reports "DOC-SHA-DEGRADED: cannot read docs/unreadable.md"
else
  echo "NOTE: running as root, so the unreadable-document block did not run"
fi

# B-17: one git process per token is the shape this repository already paid for
# once (IAN-183). The tokens here all RESOLVE and are all unreachable, so the
# measured run reaches every stage; the first version of this case generated
# tokens that resolved to nothing, and a mutation adding one git invocation per
# resolved token left it passing (R-517 review).
BUDGET="$SB/budget"
makeRepository "$BUDGET"
git -C "$BUDGET" checkout -q -b budget-throwaway
: > "$BUDGET/docs/many.md"
commit_index=0
while [ "$commit_index" -lt 30 ]; do
  printf '%s\n' "$commit_index" > "$BUDGET/counter.txt"
  git -C "$BUDGET" add counter.txt
  git -C "$BUDGET" commit -qm "commit $commit_index"
  printf 'Line %s cites `%s`.\n' "$commit_index" "$(git -C "$BUDGET" rev-parse --short=10 HEAD)" >> "$BUDGET/docs/many.md"
  commit_index=$((commit_index + 1))
done
git -C "$BUDGET" checkout -q main
git -C "$BUDGET" branch -qD budget-throwaway
: > "$GIT_LOG"
OUT=$(PATH="$BIN:$PATH" bash "$CHECK" --root "$BUDGET" docs/many.md 2>&1); ST=$?
GIT_CALLS=$(grep -c . "$GIT_LOG" || true)
check "thirty resolving tokens exit 1" test "$ST" -eq 1
check "thirty resolving tokens are all reported" test "$(lines_matching 'DOC-SHA-UNREACHABLE:')" -eq 30
check "thirty tokens were collected" reports "out of 30 cited token(s)"
check "resolution is batched, not one process per token" test "$GIT_CALLS" -le 8
check "resolution goes through cat-file --batch-check" grep -q 'cat-file --batch-check' "$GIT_LOG"

# B-18: a shallow clone holds none of the objects beyond its graft, so an
# unreachable citation cannot be told from a foreign one. That is a state the
# check announces and refuses to judge from, never one it passes silently.
git clone -q --depth 1 "file://$CORPUS" "$SB/shallow"
OUT=$(bash "$CHECK" --root "$SB/shallow" 2>&1); ST=$?
check "shallow repository exits 2" test "$ST" -eq 2
check "shallow repository says it cannot judge" reports "DOC-SHA-DEGRADED: shallow repository"

# B-19: the live corpus. The IAN-260 spec is the motivating document and the
# three keep/ tags are what keep it passing, so this block fails the moment one
# of them is deleted. A shallow checkout holds none of the objects, so the block
# states that it cannot run rather than passing blind.
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
