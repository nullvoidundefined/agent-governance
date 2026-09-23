#!/usr/bin/env bash
# scope-match.sh: the shared reader for the task-start ledger's declared file
# scope, sourced by every gate that has to decide whether a path belongs to
# the task in hand (IAN-201).
#
# Two hooks ask that question from opposite ends. scope-widening-gate.sh asks
# it per write, before the edit lands (R-212), and commit-message-guard.sh
# asks it per commit, over the staged diff (R-214). They must agree: a path
# the write gate waved through and the commit gate then refuses, or the
# reverse, is worse than either gate alone, because the session learns the
# rules are arbitrary. A second copy of the matcher is how that disagreement
# starts, and this repository has already been bitten by a local helper
# silently shadowed by a shared one (IAN-152), so the matcher lives here once
# and nowhere else.
#
# Sourced, never executed. Every function prints or returns; none exits, so a
# caller keeps control of its own decision and its own failure mode.

# read_declared_scope <top> <branch>: prints one declared scope entry per
# line, or nothing at all when the ledger is absent, unreadable, belongs to
# another branch, or declares no scope. Nothing is the honest answer for all
# four, because declaring no paths declares no constraint, and a caller reads
# an empty result as "this rule does not apply here" rather than as "nothing
# is in scope".
read_declared_scope() {
  local top="$1" branch="$2" ledger="$1/.claude/task-tier.json" ledger_branch
  [ -f "$ledger" ] || return 0
  jq -e 'type == "object"' "$ledger" >/dev/null 2>&1 || return 0
  ledger_branch=$(jq -r '.branch // "" | strings' "$ledger" 2>/dev/null)
  [ "$ledger_branch" = "$branch" ] || return 0
  jq -r '(.scope // []) | if type == "array" then .[] | strings else empty end' "$ledger" 2>/dev/null
}

# read_declared_ticket <top> <branch>: prints the ticket key the ledger holds
# for this branch, so a caller can tell the task's own ticket apart from a
# ticket naming separate work.
read_declared_ticket() {
  local top="$1" branch="$2" ledger="$1/.claude/task-tier.json" ledger_branch
  [ -f "$ledger" ] || return 0
  ledger_branch=$(jq -r '.branch // "" | strings' "$ledger" 2>/dev/null)
  [ "$ledger_branch" = "$branch" ] || return 0
  jq -r '.ticket // "" | strings' "$ledger" 2>/dev/null
}

# is_in_scope <relative-path> <entry>...: true when the path matches any
# declared entry. An entry holding a glob character is matched as a shell
# pattern, in which `*` crosses separators, so `src/api/**` and `src/api/*`
# both cover that whole tree. An entry holding none is a prefix that must end
# on a separator, so `docs/a` covers `docs/a/b.md` and never `docs/ab.md`:
# matching by bare substring would quietly pull in a sibling whose name merely
# starts the same way, which is the opposite of declaring a scope.
is_in_scope() {
  local rel="$1" entry
  shift
  for entry in "$@"; do
    entry="${entry#./}"
    entry="${entry%/}"
    [ -n "$entry" ] || continue
    case "$entry" in
      *[\*\?\[]*) case "$rel" in $entry) return 0 ;; esac ;;
      *) [ "$rel" = "$entry" ] && return 0
         case "$rel" in "$entry"/*) return 0 ;; esac ;;
    esac
  done
  return 1
}

# is_exempt_scope_path <top> <relative-path>: true for a path no scope
# declaration should ever have to name. The repository's own .claude/ holds
# the ledger and the slice lock, which every task writes whatever it is
# about, and a git-ignored path is scratch or build output that no reviewer
# reads. Gating either would make the rule fire constantly on work that is
# not widening anything.
is_exempt_scope_path() {
  local top="$1" rel="$2"
  case "$rel" in .claude/*) return 0 ;; esac
  git -C "$top" check-ignore -q -- "$top/$rel" 2>/dev/null
}
