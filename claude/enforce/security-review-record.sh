#!/usr/bin/env bash
# security-review-record.sh: records, at review time, which Security review
# artefact the reviewer saved and the exact bytes it held (R-109, B-10b). The
# merge gate in hooks/git-workflow-guard.sh later refuses a merge whose
# artefact, read at the PR head, is not the blob recorded here, so an artefact
# edited after the review cannot pass as the review's output.
#
#   security-review-record.sh <artefact repo-relative path>
#
# Run it from any directory inside the repository with the reviewed head
# checked out. It reads the artefact's git blob at HEAD (`git rev-parse
# HEAD:<path>`, never the working-tree copy) and writes it into the untracked
# ledger .claude/security-review-ledger.json at the repository top level, one
# JSON object keyed by the full head sha:
#   { "<head sha>": { "path": "<path>", "blob": "<blob oid>",
#                     "recordedAt": "YYYY-MM-DDTHH:MM:SSZ" } }
# An existing ledger is merged into, and entries for other heads are kept. The
# first record for a head stands (B-10c): recording again for a head the
# ledger already holds is refused, so an artefact cannot be swapped for another
# after the review. The write goes to a temporary file first and is moved into
# place, so a failure leaves the old ledger as it was. It exits non-zero and
# writes nothing when it is not in a repository, when the path does not exist
# at HEAD, when an existing ledger is not a JSON object, or when the ledger
# already holds an entry for the head. The ledger is a gate
# input: protected-path-guard.sh denies a Write tool call to it, so this
# script, run through Bash, is its only writer.
set -uo pipefail

LEDGER_RELATIVE_PATH=".claude/security-review-ledger.json"

# fail_record <message>: prints the message to stderr and exits non-zero.
fail_record() {
  echo "security-review-record.sh: $1" >&2
  exit 1
}

# read_existing_ledger <ledger path>: prints the ledger's JSON object, `{}`
# when the file does not exist, and returns non-zero when it exists but is not
# a JSON object.
read_existing_ledger() {
  [ -e "$1" ] || { echo '{}'; return 0; }
  jq -ce 'select(type == "object")' "$1" 2>/dev/null
}

# is_head_recorded <ledger json> <head>: true when the ledger object already
# holds an entry for <head>; false when it does not or jq cannot tell, and the
# caller reads the ledger as a JSON object first, so a false answer never
# comes from a ledger it could not read.
is_head_recorded() {
  jq -e --arg head "$2" 'has($head)' <<< "$1" >/dev/null 2>&1
}

# write_ledger_entry <ledger path> <existing ledger json> <head> <path> <blob>
# <recorded at>: merges the entry for <head> into the existing ledger through a
# temporary file beside it and moves it into place; returns non-zero, leaving
# the ledger untouched, when any step fails.
write_ledger_entry() {
  local temporary_ledger
  mkdir -p "$(dirname "$1")" || return 1
  temporary_ledger=$(mktemp "$1.XXXXXX") || return 1
  if jq -e --arg head "$3" --arg path "$4" --arg blob "$5" --arg recorded_at "$6" \
      '.[$head] = {path: $path, blob: $blob, recordedAt: $recorded_at}' <<< "$2" >"$temporary_ledger" 2>/dev/null &&
    mv "$temporary_ledger" "$1"; then
    return 0
  fi
  rm -f "$temporary_ledger"
  return 1
}

# record_security_review <artefact path>: resolves the repository top level,
# the head, and the artefact's blob at HEAD, reads the existing ledger, refuses
# a head it already holds, then writes the ledger entry.
record_security_review() {
  local artefact_path="$1" repository_top head_commit artefact_blob recorded_at ledger_path existing_ledger
  [ -n "$artefact_path" ] || fail_record "usage: security-review-record.sh <artefact repo-relative path>"
  repository_top=$(git rev-parse --show-toplevel 2>/dev/null) || fail_record "not inside a git repository"
  head_commit=$(git -C "$repository_top" rev-parse --verify --quiet HEAD 2>/dev/null) || fail_record "the repository has no HEAD commit"
  artefact_blob=$(git -C "$repository_top" rev-parse --verify --quiet "HEAD:$artefact_path" 2>/dev/null) ||
    fail_record "\`$artefact_path\` does not exist at HEAD $head_commit; commit the artefact before recording it"
  recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || fail_record "could not read the current time"
  ledger_path="$repository_top/$LEDGER_RELATIVE_PATH"
  existing_ledger=$(read_existing_ledger "$ledger_path") ||
    fail_record "$LEDGER_RELATIVE_PATH exists but is not a JSON object; it is left as it is"
  ! is_head_recorded "$existing_ledger" "$head_commit" ||
    fail_record "$LEDGER_RELATIVE_PATH already holds the record for head $head_commit, and the first record for a head stands; commit the new artefact so it lands on a new head, then record it there"
  write_ledger_entry "$ledger_path" "$existing_ledger" "$head_commit" "$artefact_path" "$artefact_blob" "$recorded_at" ||
    fail_record "could not write $LEDGER_RELATIVE_PATH; the existing ledger is left as it is"
  echo "security-review-record.sh: recorded $artefact_path (blob $artefact_blob) for head $head_commit in $LEDGER_RELATIVE_PATH"
}

record_security_review "${1:-}"
