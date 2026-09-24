#!/usr/bin/env bash
# lexicon-gate.sh: PreToolUse(Write) gate for the walking-skeleton clause of
# R-330 (added 2026-09-24, IAN-365, prompted by a job_triage naming audit that
# found no repo-wide gate stopped a spec-less project from writing its first
# source file before any domain noun was settled). spec-glossary-check.sh
# already enforces R-330's glossary format once a superpowers spec exists,
# but it is advisory (a PostToolUse nudge) and fires only inside
# docs/superpowers/specs/*-design.md: a Standard-tier task or a walking
# skeleton, which carries no spec by design (task-start.md), never triggers
# it. This hook closes that gap deterministically rather than by recall: no
# judgment call, a grep for one heading.
#
# Fires only when every one of these holds:
#   - the write targets a gated source extension (ts, tsx, js, jsx, mjs, py,
#     rb, go, vue): the languages task-start's stack tracks build against
#   - the target file does not already exist: an edit to an existing file
#     is not a walking-skeleton moment, and re-editing the first file after
#     the glossary lands must not re-trigger this
#   - the file sits inside a git work tree (walked up from its directory,
#     including one that does not exist yet, the normal shape of a new
#     source file's first Write)
#   - that work tree holds zero files, anywhere, containing the heading
#     "## Domain vocabulary" (the exact heading R-330 already fixes, so one
#     glossary satisfies both the advisory spec check and this gate)
#
# Denies with the two places the glossary already belongs: the project's
# docs/spec.md if one exists, or a new docs/lexicon.md, in the `term -
# meaning - chosen over: <alternatives> because <reason>` form R-330 fixes.
# Once any file in the repo carries that heading, this gate is satisfied for
# every future write: it exists to force the vocabulary round once, before
# the first line of code, not to gate every file forever.
#
# Fails open on any error: jq fault, no repo found, an unreadable filesystem.
# A PreToolUse hook that emits nothing is an allow (enforce/README.md), so an
# internal error here can only under-enforce, never lock out real work.
set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

case "$FILE_PATH" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.py|*.rb|*.go|*.vue) ;;
    *) exit 0 ;;
esac

# An existing file has already had its walking-skeleton moment.
[ -e "$FILE_PATH" ] && exit 0

# resolve_start_directory: the nearest existing ancestor of a not-yet-created
# path, so a new file under directories that do not exist yet is judged by
# the repository it would land in (mirrors ticket-at-start-gate.sh).
resolve_start_directory() {
    local path="$1"
    case "$path" in
        /*) : ;;
        *) path="$PWD/$path" ;;
    esac
    local dir
    dir=$(dirname "$path")
    while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
        dir=$(dirname "$dir")
    done
    printf '%s' "$dir"
}

start_dir=$(resolve_start_directory "$FILE_PATH")
[ -n "$start_dir" ] || exit 0

repo_root=""
dir="$start_dir"
while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then
        repo_root="$dir"
        break
    fi
    dir=$(dirname "$dir")
done
[ -n "$repo_root" ] || exit 0

if grep -rlF '## Domain vocabulary' "$repo_root" \
    --include='*.md' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
    --exclude-dir=vendor --exclude-dir=dist --exclude-dir=build \
    >/dev/null 2>&1; then
    exit 0
fi

REL_PATH="${FILE_PATH#"$repo_root"/}"
jq -n --arg p "$REL_PATH" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("R-330: this repository has no \"## Domain vocabulary\" section anywhere yet, and " + $p + " would be its first source file. Settle the lexicon first, before this write: add a \"## Domain vocabulary\" section to docs/spec.md if one exists, or write a new docs/lexicon.md, one line per domain noun as `term - meaning - chosen over: <alternatives> because <reason>`. Once that heading exists anywhere in the repo, every future write passes this gate.")
  }
}'
