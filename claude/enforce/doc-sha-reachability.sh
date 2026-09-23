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
#   doc-sha-reachability.sh [--all | --changed | <path>...] [--root <dir>]
#
#   --all       every *.md under docs/ and claude/docs/ (the default)
#   --changed   only the documents under those roots that this branch touched,
#               which is the push boundary's mode
#   <path>...   exactly the named documents, wherever they live
#   --root      the repository to read; the default is the one the working
#               directory is in
#
# Exit 0 clean, 1 with findings, 2 when the check declines to judge: a usage
# error, a directory that is no git repository, or a shallow clone. A shallow
# clone is the case worth naming, because it holds none of the objects beyond
# its graft, so every unreachable citation in it looks exactly like a citation
# of another repository's commit and a silent pass would be a false all-clear.
#
# Two deliberate non-findings. A token that resolves to no object here is not
# reported, because documents legitimately cite other repositories and short
# hexadecimal strings occur in prose, and because the one thing this check
# cannot do is tell those two apart. A citation carrying the escape marker
# `<!-- unreachable-sha: <sha> <reason> -->` is not reported either; the marker
# must name the same token the citation names, sit on the same line, and carry
# a reason, so that it cannot be copied onto a line it was not written for.
#
# Cost: one `git cat-file --batch-check` over every collected token and one
# `git rev-list --all`, never a git process per token. The hook tree paid for
# that lesson once already (IAN-183, where a process per path component put the
# whole Write chain over budget).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_ROOTS="docs claude/docs"
MODE="all"
MODE_GIVEN=""
ROOT_ARGUMENT=""
NAMED_PATHS=""

usage() {
  echo "usage: doc-sha-reachability.sh [--all | --changed | <path>...] [--root <dir>]" >&2
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

# listDocumentsUnderRoots: every *.md below the document roots that exist,
# repository relative and in a stable order, so two runs of the same corpus
# report their findings in the same sequence.
listDocumentsUnderRoots() {
  local present="" doc_root
  for doc_root in $DOC_ROOTS; do
    [ -d "$doc_root" ] && present="$present $doc_root"
  done
  [ -n "$present" ] || return 0
  # shellcheck disable=SC2086  # the roots are this script's own literals
  find $present -type f -name '*.md' 2>/dev/null | sed 's#^\./##' | LC_ALL=C sort
}

# listChangedDocuments: the documents under the roots that this branch
# touched, from the same change set the R-509 turn-end gate reads, so a
# document is "changed" here in exactly the sense it is changed there.
listChangedDocuments() {
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/related-tests.sh" || return 1
  local changed
  changed=$(listChangedFiles) || return 1
  printf '%s\n' "$changed" \
    | grep -E '^(docs|claude/docs)/.*\.md$' \
    | while IFS= read -r changed_path; do
        [ -f "$changed_path" ] && printf '%s\n' "$changed_path"
      done \
    | LC_ALL=C sort -u
}

case "$MODE" in
  all) listDocumentsUnderRoots > "$WORK_DIR/documents" ;;
  changed)
    if ! listChangedDocuments > "$WORK_DIR/documents"; then
      printDegraded "this branch's change set cannot be read (no commit to compare against), so --changed has nothing to select from"
      exit 2
    fi ;;
  paths)
    printf '%s' "$NAMED_PATHS" | while IFS= read -r named_path; do
      [ -n "$named_path" ] || continue
      case "$named_path" in
        "$ROOT"/*) printf '%s\n' "${named_path#"$ROOT"/}" ;;
        *) printf '%s\n' "$named_path" ;;
      esac
    done > "$WORK_DIR/documents"
    while IFS= read -r named_path; do
      [ -n "$named_path" ] || continue
      [ -f "$named_path" ] || { printDegraded "no document at $named_path under $ROOT"; exit 2; }
    done < "$WORK_DIR/documents" ;;
esac

DOCUMENT_COUNT=$(grep -c . "$WORK_DIR/documents" || true)
if [ "$DOCUMENT_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, 0 cited token(s) in 0 document(s), 0 resolve here, all of those reachable"
  exit 0
fi

# One grep over the whole document list rather than one per file. -H keeps the
# filename on every line when the list is a single file, so the citation lines
# have one shape: <path>:<line>:`<token>`.
tr '\n' '\0' < "$WORK_DIR/documents" \
  | xargs -0 grep -HonE '`[0-9a-f]{7,40}`' 2>/dev/null \
  > "$WORK_DIR/citations" || true

CITATION_COUNT=$(grep -c . "$WORK_DIR/citations" || true)
if [ "$CITATION_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, 0 cited token(s) in $DOCUMENT_COUNT document(s), 0 resolve here, all of those reachable"
  exit 0
fi

sed -E 's/.*`([0-9a-f]{7,40})`$/\1/' "$WORK_DIR/citations" | LC_ALL=C sort -u > "$WORK_DIR/tokens"

# The one resolution pass. `^{commit}` makes a tree, a blob, or a tag that
# peels to none of them answer "missing" exactly as an absent object does,
# which is what keeps a token that names no commit here out of the findings.
sed 's/$/^{commit}/' "$WORK_DIR/tokens" > "$WORK_DIR/queries"
git cat-file --batch-check < "$WORK_DIR/queries" > "$WORK_DIR/batch" 2>/dev/null || true
paste -d' ' "$WORK_DIR/tokens" "$WORK_DIR/batch" \
  | awk '$3 == "commit" { print $1 " " $2 }' \
  > "$WORK_DIR/resolved"

RESOLVED_COUNT=$(grep -c . "$WORK_DIR/resolved" || true)
if [ "$RESOLVED_COUNT" -eq 0 ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), 0 resolve here, all of those reachable"
  exit 0
fi

# The one reachability pass. --all is every ref plus HEAD, across every linked
# worktree, so a commit held only by a tag (the keep/ pins) counts as reached.
awk '{ print $2 }' "$WORK_DIR/resolved" | LC_ALL=C sort -u > "$WORK_DIR/resolved-shas"
git rev-list --all 2>/dev/null | LC_ALL=C sort -u > "$WORK_DIR/reachable-shas"
LC_ALL=C comm -23 "$WORK_DIR/resolved-shas" "$WORK_DIR/reachable-shas" > "$WORK_DIR/unreachable-shas"

if [ ! -s "$WORK_DIR/unreachable-shas" ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), $RESOLVED_COUNT resolve here, all of those reachable"
  exit 0
fi

# Back from objects to the lines that cite them: the tokens whose commit no ref
# reaches, joined against the citation list, so every finding can name a file
# and a line rather than a SHA on its own.
awk 'NR == FNR { unreachable[$1] = 1; next } ($2 in unreachable) { print $1 " " $2 }' \
  "$WORK_DIR/unreachable-shas" "$WORK_DIR/resolved" > "$WORK_DIR/unreachable-tokens"

findings=0
finding_documents=""
while IFS= read -r citation; do
  [ -n "$citation" ] || continue
  citation_path=${citation%%:*}
  citation_rest=${citation#*:}
  citation_line=${citation_rest%%:*}
  citation_token=${citation_rest#*:}
  citation_token=${citation_token//\`/}
  full_sha=$(awk -v token="$citation_token" '$1 == token { print $2 }' "$WORK_DIR/unreachable-tokens")
  [ -n "$full_sha" ] || continue
  # The escape hatch, checked against the citing line itself. All three
  # conditions are load-bearing: same token, same line, and a reason after the
  # token, so that a marker cannot excuse a citation it was not written for.
  line_text=$(sed -n "${citation_line}p" "$citation_path" 2>/dev/null)
  if printf '%s' "$line_text" | grep -qE "<!-- unreachable-sha: ${citation_token} [^ >][^>]*-->"; then
    continue
  fi
  echo "DOC-SHA-UNREACHABLE: $citation_token at $citation_path:$citation_line resolves to $full_sha, which no ref in $ROOT reaches"
  findings=$((findings + 1))
  case "$finding_documents" in
    *"|$citation_path|"*) ;;
    *) finding_documents="$finding_documents|$citation_path|" ;;
  esac
done < "$WORK_DIR/citations"

if [ "$findings" -eq 0 ]; then
  echo "doc-sha-reachability: OK, $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s), $RESOLVED_COUNT resolve here, all of those reachable"
  exit 0
fi

FINDING_DOCUMENT_COUNT=$(printf '%s' "$finding_documents" | tr '|' '\n' | grep -c . || true)
echo "doc-sha-reachability: $findings unreachable citation(s) in $FINDING_DOCUMENT_COUNT document(s), out of $CITATION_COUNT cited token(s) in $DOCUMENT_COUNT document(s)"
echo "Each one resolves here and nowhere else: no ref reaches it, auto-gc may prune it, and a fresh clone will not have it."
echo "Pin it, which keeps the object and the citation honest:  git tag keep/<slug> <sha> && git push origin keep/<slug>"
echo "Or, when the citation is a historical note that is meant to be unreachable, put the marker on the citing line:  <!-- unreachable-sha: <sha> <reason> -->"
exit 1
