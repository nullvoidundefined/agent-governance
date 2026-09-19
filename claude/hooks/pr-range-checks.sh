#!/usr/bin/env bash
# pr-range-checks.sh: sourced helper, not a hook. The R-605 questions asked
# of a pull request's commit range, shared by pr-ticket-ref-gate.sh (which
# asks them before `gh pr create`) and draft-pr-on-first-push.sh (which asks
# them before opening a draft itself), so the two can never disagree about
# what counts as a ticket reference or an exemption (IAN-137). A reference is
# a line of the form `Refs: <KEY>`, KEY matching [A-Z][A-Z0-9]+-[0-9]+; a bare
# key match would read rule IDs (R-605) and strings such as SHA-256 as keys.

KEY_PATTERN='[A-Z][A-Z0-9]+-[0-9]+'
REFS_LINE_PATTERN="^[[:space:]\"']*Refs:[[:space:]]*${KEY_PATTERN}([^A-Za-z0-9-]|\$)"

# has_refs_line <text>: true when some line of the text is a Refs trailer
# naming a ticket key, optionally preceded by an opening quote.
has_refs_line() {
  grep -Eq -- "$REFS_LINE_PATTERN" <<< "$1"
}

# resolve_pr_base <base-name> <repo-top>: prints the merge base of HEAD with
# the pull request's base branch; empty when none of the candidates exist.
resolve_pr_base() {
  local named="$1" dir="$2" default="" candidate merge_base
  if [ -n "${CLAUDE_ENFORCE_BASE:-}" ]; then printf '%s' "$CLAUDE_ENFORCE_BASE"; return; fi
  default=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  for candidate in ${named:+"origin/$named" "$named"} ${default:+"$default"} origin/main main origin/master master; do
    git -C "$dir" rev-parse --verify -q "$candidate" >/dev/null 2>&1 || continue
    merge_base=$(git -C "$dir" merge-base "$candidate" HEAD 2>/dev/null || true)
    [ -n "$merge_base" ] && { printf '%s' "$merge_base"; return; }
  done
}

# commits_have_reference <target-dir> <base>: true when a commit message in
# base..HEAD carries a Refs line.
commits_have_reference() {
  local dir="$1" base="$2"
  [ -n "$base" ] || return 1
  has_refs_line "$(git -C "$dir" log --format=%B "$base..HEAD" 2>/dev/null)"
}

# is_docs_only_range <target-dir> <base>: true when the range changes at
# least one path and every changed path is *.md or under docs/. An empty or
# unreadable range is not docs-only, so it cannot exempt anything.
is_docs_only_range() {
  local dir="$1" base="$2" changed
  [ -n "$base" ] || return 1
  changed=$(git -C "$dir" diff --name-only "$base...HEAD" 2>/dev/null) || return 1
  [ -n "$changed" ] || return 1
  ! grep -Evq '(\.md$|^docs/)' <<< "$changed"
}

# is_trivial_tier <repo-top>: true when task-start's ledger records the
# trivial tier for the branch currently checked out (a ledger left from an
# earlier branch does not count).
is_trivial_tier() {
  local top="$1" ledger="$1/.claude/task-tier.json" branch
  [ -f "$ledger" ] || return 1
  branch=$(git -C "$top" branch --show-current 2>/dev/null || true)
  jq -e --arg b "$branch" '.tier == "trivial" and ((.branch // "") == "" or .branch == $b)' "$ledger" >/dev/null 2>&1
}
