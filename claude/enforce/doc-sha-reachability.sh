#!/usr/bin/env bash
# doc-sha-reachability.sh: the R-215 check. A commit SHA written into a
# document is a promise that the commit can still be fetched, and this reads
# the promise back: every backticked 7-to-40 hexadecimal token in a document
# that resolves to a commit in this repository must be reachable from some ref.
#
# The case it exists for is the IAN-260 spec, which named four migration
# sources and whose three unreachable ones (`c6af9dd`, `23cdfca`, `ef2d24b`)
# sat on no branch at all, because the PR branches carrying them were deleted
# after merge. Each still resolved in the author's clone, so the document read
# as correct there; an unreachable object is nonetheless prunable by auto-gc
# and absent from every fresh clone, so the slice that depended on them would
# have found its inputs gone. They are now pinned as `keep/` tags.
#
#   doc-sha-reachability.sh [--all | --changed | --push <remote> | <path>...] [--root <dir>]
#
#   --all       every *.md under docs/ and claude/docs/ (the default)
#   --changed   the documents under those roots that this branch touched, read
#               from the working tree
#   --push <remote>
#               the gate's mode. Reads git's pre-push ref list on stdin
#               (`<local ref> <local sha> <remote ref> <remote sha>` lines) and
#               inspects the documents as the pushed COMMITS carry them, never
#               as the working tree happens to have them, because what is about
#               to become public is the commit
#   <path>...   exactly the named documents, read from the working tree
#   --root      the repository to read; the default is the one the working
#               directory is in
#
# Exit 0 clean, 1 with findings, 2 when the check declines to judge. Every
# decline prints DOC-SHA-DEGRADED with its reason, and there is no path on
# which the check reports success without having resolved what it collected:
# a shallow clone, an unreadable document, a failing resolver and an
# unreadable change set are all exit 2, never a quiet exit 0. The pre-push
# hook treats exit 2 as a refusal for that reason.
#
# Two deliberate non-findings. A token that resolves to no object here is not
# reported, because documents legitimately cite other repositories and short
# hexadecimal strings occur in prose, and because the one thing this check
# cannot do is tell those two apart. A citation carrying the escape marker
# `<!-- unreachable-sha: <sha> <reason> -->` is not reported either.
#
# What the marker must satisfy, each condition there to keep it from opening by
# accident. It names the same commit the citation names, compared after both
# are lowercased. It sits on the citing line. It carries a reason holding a
# real word (three consecutive letters), so whitespace, `...` and an empty
# reason all fail. It is not written inside inline code, inside a fenced block,
# or inside an HTML comment that opened on an earlier line, so a marker shown
# as an example in prose (this header, the rule text and the PR document all
# show one) excuses nothing. One marker excuses one citation: a line citing the
# same commit twice needs two markers.
#
# Hexadecimal case: a token is collected in either case and normalised to
# lowercase for resolution, for marker matching and for reporting, so
# `C6AF9DD` and `c6af9dd` are one commit and are reported as the latter.
#
# Cost: one `git cat-file --batch-check` over every collected token and one
# `git rev-list --all`, never a git process per token. The hook tree paid for
# that lesson once already (IAN-183, where a process per path component put the
# whole Write chain over budget). Documents are read one process each, and in
# --push mode that process is `git show`, which is per changed document rather
# than per token.
#
# Two limits worth naming. Document order is the order `find` returns, which is
# stable for a given tree but is not lexicographic, because neither BSD nor GNU
# sort can be relied on to sort NUL-delimited input. And --changed inherits
# enforce/related-tests.sh's newline-delimited change set, so a path containing
# a newline is not selected in that mode; --all and --push read NUL-delimited
# lists and do select it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_ROOTS="docs claude/docs"
MODE="all"
MODE_GIVEN=""
PUSH_REMOTE=""
ROOT_ARGUMENT=""
NAMED_PATHS=""

usage() {
  echo "usage: doc-sha-reachability.sh [--all | --changed | --push <remote> | <path>...] [--root <dir>]" >&2
}

# printDegraded <reason>: says why the check declined to judge. Every exit 2
# goes through here, so a caller never has to guess whether an empty report
# meant a clean corpus or a check that never ran.
printDegraded() {
  echo "DOC-SHA-DEGRADED: $1" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) MODE="all"; MODE_GIVEN="yes"; shift ;;
    --changed) MODE="changed"; MODE_GIVEN="yes"; shift ;;
    --push)
      if [ "$#" -lt 2 ]; then usage; printDegraded "--push needs the remote's name, which git passes to the hook as its first argument"; exit 2; fi
      MODE="push"; MODE_GIVEN="yes"; PUSH_REMOTE="$2"; shift 2 ;;
    --root)
      if [ "$#" -lt 2 ]; then usage; printDegraded "--root needs a directory"; exit 2; fi
      ROOT_ARGUMENT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) usage; printDegraded "unknown option $1"; exit 2 ;;
    *) NAMED_PATHS="$NAMED_PATHS$1
"; shift ;;
  esac
done

if [ -n "$NAMED_PATHS" ] && [ -n "$MODE_GIVEN" ]; then
  usage
  printDegraded "named paths and --$MODE are two different questions; pass one or the other"
  exit 2
fi
[ -n "$NAMED_PATHS" ] && MODE="paths"

if [ -n "$ROOT_ARGUMENT" ]; then
  [ -d "$ROOT_ARGUMENT" ] || { printDegraded "no directory at $ROOT_ARGUMENT"; exit 2; }
  cd "$ROOT_ARGUMENT" || { printDegraded "cannot enter $ROOT_ARGUMENT"; exit 2; }
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printDegraded "$(pwd) is not inside a git repository, so no commit can be resolved"
  exit 2
}
cd "$ROOT" || { printDegraded "cannot enter $ROOT"; exit 2; }

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  printDegraded "shallow repository at $ROOT holds no objects beyond its graft, so an unreachable citation cannot be told from another repository's SHA; deepen it (git fetch --unshallow) and run again"
  exit 2
fi

WORK_DIR=$(mktemp -d) || { printDegraded "cannot create a working directory"; exit 2; }
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/blobs" "$WORK_DIR/meta"

# Every document is copied to $WORK_DIR/blobs/<n> and its real path recorded
# beside it. Nothing downstream ever handles a path as a delimited field, which
# is what let a filename carrying a colon or a newline slip through unexamined
# (R-517 review of PR #118); the number is the only key that travels.
DOCUMENT_COUNT=0

# addDocument <path> <source>: source is the literal "worktree" or a revision
# whose blob to read. A document that cannot be read is a decline, never a
# document quietly dropped from the corpus.
addDocument() {
  local document_path="$1" source="$2" target
  DOCUMENT_COUNT=$((DOCUMENT_COUNT + 1))
  target="$WORK_DIR/blobs/$DOCUMENT_COUNT"
  if [ "$source" = "worktree" ]; then
    cat -- "$document_path" > "$target" 2>/dev/null || {
      printDegraded "cannot read $document_path under $ROOT"
      return 1
    }
  else
    git show "$source:$document_path" > "$target" 2>/dev/null || {
      printDegraded "cannot read $document_path at $source"
      return 1
    }
  fi
  printf '%s' "$document_path" > "$WORK_DIR/meta/$DOCUMENT_COUNT.path"
  printf '%s' "$source" > "$WORK_DIR/meta/$DOCUMENT_COUNT.source"
  return 0
}

# addDocumentsFrom <source> < NUL-delimited paths: reads a path list and takes
# each document from that source.
addDocumentsFrom() {
  local source="$1" document_path
  while IFS= read -r -d '' document_path; do
    [ -n "$document_path" ] || continue
    addDocument "$document_path" "$source" || return 1
  done
  return 0
}

# isUnderDocumentRoots <path>: the roots this rule governs.
isUnderDocumentRoots() {
  case "$1" in
    docs/*.md|claude/docs/*.md) return 0 ;;
  esac
  return 1
}

# listDocumentsUnderRoots: every *.md below the roots that exist, NUL
# delimited, repository relative.
listDocumentsUnderRoots() {
  local present="" doc_root
  for doc_root in $DOC_ROOTS; do
    [ -d "$doc_root" ] && present="$present $doc_root"
  done
  [ -n "$present" ] || return 0
  # shellcheck disable=SC2086  # the roots are this script's own literals
  find $present -type f -name '*.md' -print0 2>/dev/null
}

# listChangedDocuments: the documents under the roots that this branch touched,
# from the same change set the R-509 turn-end gate reads.
listChangedDocuments() {
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/related-tests.sh" || return 1
  local changed changed_path
  changed=$(listChangedFiles) || return 1
  printf '%s\n' "$changed" | while IFS= read -r changed_path; do
    isUnderDocumentRoots "$changed_path" || continue
    [ -f "$changed_path" ] || continue
    printf '%s\0' "$changed_path"
  done
}

# collectPushedDocuments: the documents the pushed commits carry, read from git
# rather than from the working tree. A ref being deleted carries nothing. The
# commits that are new to the remote come from one rev-list and their paths
# from one diff-tree, so the cost is two processes per pushed ref plus one
# `git show` per changed document.
collectPushedDocuments() {
  local local_ref local_sha remote_ref remote_sha
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    case "$local_sha" in
      *[!0]*) ;;
      *) continue ;;
    esac
    git rev-list "$local_sha" --not --remotes="$PUSH_REMOTE" > "$WORK_DIR/pushed-commits" 2>/dev/null || {
      printDegraded "cannot list the commits $local_ref would add to $PUSH_REMOTE, so the push cannot be judged"
      return 1
    }
    [ -s "$WORK_DIR/pushed-commits" ] || continue
    git diff-tree -r -z --no-commit-id --name-only --stdin < "$WORK_DIR/pushed-commits" \
      > "$WORK_DIR/pushed-paths" 2>/dev/null || {
      printDegraded "cannot list the paths $local_ref would change, so the push cannot be judged"
      return 1
    }
    local pushed_path
    while IFS= read -r -d '' pushed_path; do
      isUnderDocumentRoots "$pushed_path" || continue
      git cat-file -e "$local_sha:$pushed_path" 2>/dev/null || continue
      addDocument "$pushed_path" "$local_sha" || return 1
    done < "$WORK_DIR/pushed-paths"
  done
  return 0
}

case "$MODE" in
  all)
    listDocumentsUnderRoots > "$WORK_DIR/documents"
    addDocumentsFrom worktree < "$WORK_DIR/documents" || exit 2 ;;
  changed)
    if ! listChangedDocuments > "$WORK_DIR/documents"; then
      printDegraded "this branch's change set cannot be read (no commit to compare against), so --changed has nothing to select from"
      exit 2
    fi
    addDocumentsFrom worktree < "$WORK_DIR/documents" || exit 2 ;;
  push)
    collectPushedDocuments || exit 2 ;;
  paths)
    printf '%s' "$NAMED_PATHS" | while IFS= read -r named_path; do
      [ -n "$named_path" ] || continue
      case "$named_path" in
        "$ROOT"/*) printf '%s\0' "${named_path#"$ROOT"/}" ;;
        *) printf '%s\0' "$named_path" ;;
      esac
    done > "$WORK_DIR/documents"
    while IFS= read -r -d '' named_path; do
      [ -n "$named_path" ] || continue
      [ -f "$named_path" ] || { printDegraded "no document at $named_path under $ROOT"; exit 2; }
    done < "$WORK_DIR/documents"
    addDocumentsFrom worktree < "$WORK_DIR/documents" || exit 2 ;;
esac

if [ "$DOCUMENT_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, 0 cited token(s) in 0 document(s), 0 resolve here, all of those reachable"
  exit 0
fi

# One awk pass over every collected document does all of the text work:
# citations with their occurrence number, and the markers that are real rather
# than examples. Keeping fence state, comment state and inline-code stripping
# here rather than in a second bash pass is what makes the marker rules
# checkable at all; a regex built per candidate line could not see that the
# line sits inside a fenced block that opened forty lines earlier.
awk '
function isHexToken(candidate) {
  return (length(candidate) >= 7 && length(candidate) <= 40)
}
FNR == 1 {
  document = FILENAME
  sub(/.*\//, "", document)
  inside_fence = 0
  inside_comment = 0
}
{
  line = $0
  comment_at_line_start = inside_comment

  # Citations, from the raw line, numbered per token per line so that one
  # marker can excuse exactly one of them.
  split("", seen_on_line)
  remainder = line
  while (match(remainder, /`[0-9a-fA-F]+`/)) {
    token = substr(remainder, RSTART + 1, RLENGTH - 2)
    remainder = substr(remainder, RSTART + RLENGTH)
    if (!isHexToken(token)) continue
    token = tolower(token)
    seen_on_line[token]++
    print "CITE\t" document "\t" FNR "\t" seen_on_line[token] "\t" token
  }

  # Markers, from a line with its inline code removed, and only when the line
  # is neither inside a fenced block nor inside a comment that opened earlier.
  if (!inside_fence && !comment_at_line_start) {
    stripped = line
    gsub(/`[^`]*`/, "", stripped)
    remainder = stripped
    while (match(remainder, /<!--[ \t]*unreachable-sha:[^>]*-->/)) {
      marker = substr(remainder, RSTART, RLENGTH)
      remainder = substr(remainder, RSTART + RLENGTH)
      body = marker
      sub(/^<!--[ \t]*unreachable-sha:[ \t]*/, "", body)
      sub(/[ \t]*-->$/, "", body)
      if (!match(body, /^[0-9a-fA-F]+/)) continue
      marker_sha = substr(body, 1, RLENGTH)
      reason = substr(body, RLENGTH + 1)
      if (!isHexToken(marker_sha)) continue
      # The reason must be separated from the SHA by whitespace and must carry
      # a word: whitespace alone and punctuation alone are not reasons.
      if (reason !~ /^[[:space:]]/) continue
      if (reason !~ /[A-Za-z][A-Za-z][A-Za-z]/) continue
      print "MARK\t" document "\t" FNR "\t" tolower(marker_sha)
    }
  }

  # Fence and comment state for the lines that follow.
  if (line ~ /^[ \t]*(```|~~~)/) inside_fence = 1 - inside_fence
  scan = line
  while (1) {
    if (inside_comment == 0) {
      if (match(scan, /<!--/)) { inside_comment = 1; scan = substr(scan, RSTART + 4) } else break
    } else {
      if (match(scan, /-->/)) { inside_comment = 0; scan = substr(scan, RSTART + 3) } else break
    }
  }
}
' "$WORK_DIR"/blobs/* > "$WORK_DIR/records" || {
  printDegraded "cannot read the collected documents"
  exit 2
}

CITATION_COUNT=$(grep -c '^CITE' "$WORK_DIR/records" || true)
if [ "$CITATION_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, 0 cited token(s) in $DOCUMENT_COUNT document(s), 0 resolve here, all of those reachable"
  exit 0
fi

awk -F'\t' '$1 == "CITE" { print $5 }' "$WORK_DIR/records" | LC_ALL=C sort -u > "$WORK_DIR/tokens"
TOKEN_COUNT=$(grep -c . "$WORK_DIR/tokens" || true)

# The one resolution pass. `^{commit}` makes a tree, a blob, or a tag that
# peels to none of them answer "missing" exactly as an absent object does,
# which is what keeps a token that names no commit here out of the findings.
# A resolver that fails is a decline, not a clean corpus: discarding the error
# here reported "0 resolve here" and exit 0 against an unreadable object store
# (R-517 review of PR #118).
sed 's/$/^{commit}/' "$WORK_DIR/tokens" > "$WORK_DIR/queries"
if ! git cat-file --batch-check < "$WORK_DIR/queries" > "$WORK_DIR/batch" 2>/dev/null; then
  printDegraded "cannot resolve the cited tokens: git cat-file --batch-check failed in $ROOT"
  exit 2
fi
BATCH_COUNT=$(grep -c . "$WORK_DIR/batch" || true)
if [ "$BATCH_COUNT" -ne "$TOKEN_COUNT" ]; then
  printDegraded "cannot resolve the cited tokens: git cat-file --batch-check answered $BATCH_COUNT of $TOKEN_COUNT"
  exit 2
fi
paste -d' ' "$WORK_DIR/tokens" "$WORK_DIR/batch" \
  | awk '$3 == "commit" { print $1 "\t" $2 }' \
  > "$WORK_DIR/resolved"

RESOLVED_COUNT=$(grep -c . "$WORK_DIR/resolved" || true)
if [ "$RESOLVED_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), 0 resolve here, all of those reachable"
  exit 0
fi

# The one reachability pass. --all is every ref plus HEAD, across every linked
# worktree, so a commit held only by a tag (the keep/ pins) counts as reached.
awk '{ print $2 }' "$WORK_DIR/resolved" | LC_ALL=C sort -u > "$WORK_DIR/resolved-shas"
if ! git rev-list --all > "$WORK_DIR/reachable-raw" 2>/dev/null; then
  printDegraded "cannot list the reachable commits: git rev-list --all failed in $ROOT"
  exit 2
fi
LC_ALL=C sort -u "$WORK_DIR/reachable-raw" > "$WORK_DIR/reachable-shas"
LC_ALL=C comm -23 "$WORK_DIR/resolved-shas" "$WORK_DIR/reachable-shas" > "$WORK_DIR/unreachable-shas"

if [ ! -s "$WORK_DIR/unreachable-shas" ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), $RESOLVED_COUNT resolve here, all of those reachable"
  exit 0
fi

# Back from objects to the lines that cite them, applying the markers. A
# citation is excused when its occurrence number is within the count of valid
# markers for that commit on that line, so the second citation of a commit
# needs a second marker.
awk -F'\t' '
NR == FNR { unreachable[$1] = 1; next }
FILENAME == resolved_file { if ($2 in unreachable) full[$1] = $2; next }
$1 == "MARK" { marks[$2 "\t" $3 "\t" $4]++; next }
$1 == "CITE" { citations[++citation_index] = $0 }
END {
  for (i = 1; i <= citation_index; i++) {
    split(citations[i], field, "\t")
    token = field[5]
    if (!(token in full)) continue
    if (field[4] <= marks[field[2] "\t" field[3] "\t" token]) continue
    print field[2] "\t" field[3] "\t" token "\t" full[token]
  }
}
' "$WORK_DIR/unreachable-shas" resolved_file="$WORK_DIR/resolved" "$WORK_DIR/resolved" "$WORK_DIR/records" \
  > "$WORK_DIR/findings"

findings=0
finding_documents=""
while IFS=$'\t' read -r document_number citation_line citation_token full_sha; do
  [ -n "${document_number:-}" ] || continue
  document_path=$(cat "$WORK_DIR/meta/$document_number.path")
  document_source=$(cat "$WORK_DIR/meta/$document_number.source")
  if [ "$document_source" = "worktree" ]; then
    echo "DOC-SHA-UNREACHABLE: $citation_token at $document_path:$citation_line resolves to $full_sha, which no ref in $ROOT reaches"
  else
    echo "DOC-SHA-UNREACHABLE: $citation_token at $document_path:$citation_line (in the pushed commit $document_source) resolves to $full_sha, which no ref in $ROOT reaches"
  fi
  findings=$((findings + 1))
  case "$finding_documents" in
    *"|$document_number|"*) ;;
    *) finding_documents="$finding_documents|$document_number|" ;;
  esac
done < "$WORK_DIR/findings"

if [ "$findings" -eq 0 ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), $RESOLVED_COUNT resolve here, all of those reachable"
  exit 0
fi

FINDING_DOCUMENT_COUNT=$(printf '%s' "$finding_documents" | tr '|' '\n' | grep -c . || true)
echo "doc-sha-reachability: $findings unreachable citation(s) in $FINDING_DOCUMENT_COUNT document(s), out of $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s)"
echo "Each one resolves here and nowhere else: no ref reaches it, auto-gc may prune it, and a fresh clone will not have it."
echo "Pin it, which keeps the object and the citation honest:  git tag keep/<slug> <sha> && git push origin keep/<slug>"
echo "Or, when the citation is a historical note that is meant to be unreachable, put a marker naming that SHA and a reason on the citing line."
exit 1
