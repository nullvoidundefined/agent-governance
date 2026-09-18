#!/usr/bin/env bash
# harness-sync.sh: SessionStart hook for R-003, every session runs under the
# synced harness. Compares the live ~/.claude against the agent-governance
# checkout's tracked claude/ files and runs ./sync.sh when they differ, so a
# cloud container (which starts with no harness at all) and a laptop whose
# checkout moved on both start the session with the hooks, gates, skills,
# and rules the repo committed, not whatever was there before.
#
# The checkout is, in order: the first argument (the repo-level
# .claude/settings.json in agent-governance passes $CLAUDE_PROJECT_DIR, the
# bootstrap case where ~/.claude holds nothing yet); ~/.claude/.sync-source
# (the stamp sync.sh writes, the drift case on any later session in any
# project); $CLAUDE_PROJECT_DIR when it is itself an agent-governance
# checkout. With none of those there is nothing to sync from and the hook
# says so once in a remote session and stays silent locally.
#
# rsync is installed with apt when absent and the session is remote
# (CLAUDE_CODE_REMOTE=true, root in the container); a laptop without rsync
# is told instead. enforce/node_modules is brought in line with the synced
# lockfile by enforce/install-enforce-dependencies.sh (a locked npm ci), which
# ./sync.sh runs after a sync and this hook runs itself when nothing drifted,
# so a stale install is repaired either way; when npm is missing or fails the
# context says so and names the command. Advisory: emits additionalContext,
# never blocks, exits 0 on every path (no set -e; enforce/README hook set
# convention).
#
# HARNESS_SYNC_HOME overrides the live directory's parent (fixtures).
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
HOME_DIR="${HARNESS_SYNC_HOME:-$HOME}"
LIVE="$HOME_DIR/.claude"
REMOTE="${CLAUDE_CODE_REMOTE:-}"

say_context() {
  jq -n --arg m "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}' 2>/dev/null || true
}

is_checkout() { [ -f "$1/sync.sh" ] && [ -f "$1/claude/CLAUDE.md" ] && git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; }

CHECKOUT=""
if [ -n "${1:-}" ] && is_checkout "$1"; then
  CHECKOUT=$(cd "$1" && pwd -P)
elif [ -f "$LIVE/.sync-source" ] && is_checkout "$(cat "$LIVE/.sync-source")"; then
  CHECKOUT=$(cat "$LIVE/.sync-source")
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && is_checkout "$CLAUDE_PROJECT_DIR"; then
  CHECKOUT=$(cd "$CLAUDE_PROJECT_DIR" && pwd -P)
fi
if [ -z "$CHECKOUT" ]; then
  if [ "$REMOTE" = "true" ]; then
    say_context "harness-sync (R-003): no agent-governance checkout is reachable (no argument, no ~/.claude/.sync-source, and this project is not the harness repo), so this remote session runs WITHOUT the synced harness. A project's .claude/settings.json SessionStart hook written by repo-setup clones and syncs it; until then, treat every rule as manual."
  fi
  exit 0
fi

# Drift: any tracked file of any synced payload missing from or different in
# its live tree. ./sync.sh writes all three targets, but this check used to
# compare claude/ alone, so a stale ~/.cursor or ~/.codex could never trigger
# the sync that would repair it: a Cursor or Codex session kept running last
# week's adapter and rules while a Claude session on the same machine was
# current (2026-09-18, found while adding the project-local Cursor bootstrap).
# Each payload's live home honors the same override variables sync.sh reads,
# so a fixture can point all three at a sandbox.
CURSOR_LIVE="${SYNC_CURSOR_HOME:-$HOME_DIR/.cursor}"
CODEX_LIVE="${SYNC_CODEX_HOME:-$HOME_DIR/.codex}"

# countDriftedFiles: tracked files of the three payloads that are missing from
# their live tree or differ from it. One `git ls-files` lists all three; a
# missing file is counted with the shell's own test; every pair present on both
# sides is compared by content in one batch (countDifferingPairs). One cmp per
# tracked file cost about 0.8 s on every SessionStart with 531 tracked files,
# more than the rest of the SessionStart chain together, and even batched, one
# pass per payload tripled the fixed process cost (IAN-115).
countDriftedFiles() {
  local rel live tracked count=0 pairs=0 pair_list=""
  tracked=$(git -C "$CHECKOUT" ls-files -- claude cursor codex 2>/dev/null)
  while IFS= read -r rel; do
    case "$rel" in
      claude/*) live="$LIVE/${rel#claude/}" ;;
      cursor/*) live="$CURSOR_LIVE/${rel#cursor/}" ;;
      codex/*) live="$CODEX_LIVE/${rel#codex/}" ;;
      "") continue ;;
      # A name git prints C-quoted (a tab, a newline, a double quote) matches
      # no payload prefix; it counts as drift so it is never silently left
      # out, the answer the per-file loop gave too (Copilot review on #67).
      *) count=$((count + 1)); continue ;;
    esac
    if [ -f "$live" ] && [ -f "$CHECKOUT/$rel" ]; then
      pair_list+="$rel"$'\n'; pairs=$((pairs + 1))
    else
      count=$((count + 1))
    fi
  done <<< "$tracked"
  if [ "$pairs" -gt 0 ]; then
    count=$((count + $(countDifferingPairs "$pairs" "$pair_list")))
  fi
  count=$((count + $(countPendingRemovals claude "$LIVE" "$tracked")))
  count=$((count + $(countPendingRemovals cursor "$CURSOR_LIVE" "$tracked")))
  count=$((count + $(countPendingRemovals codex "$CODEX_LIVE" "$tracked")))
  printf '%s' "$count"
}

# countPendingRemovals(payload, liveRoot, trackedList): files sync.sh would
# remove on its next run, counted as drift so that a commit whose only change
# stops tracking a file still triggers the sync that removes it (local review
# on #69). A candidate is a path the live .sync-manifest lists, the checkout no
# longer tracks (compared ignoring case, as sync.sh does), and the live tree
# still holds. sync.sh drops every such path from its next manifest, removed or
# kept, so a candidate is drift for one run only and never forces a sync at
# every SessionStart. A path that is absolute or has a ".." component is
# skipped, as sync.sh skips it.
countPendingRemovals() {
  local payload="$1" live_root="$2" tracked="$3" rel pending=0
  [ -f "$live_root/.sync-manifest" ] || { printf '0'; return; }
  while IFS= read -r rel; do
    case "/$rel/" in //* | */../*) continue ;; esac
    if [ -f "$live_root/$rel" ] || [ -L "$live_root/$rel" ]; then pending=$((pending + 1)); fi
  done < <(printf '%s\n' "$tracked" | awk -v prefix="$payload/" '
    NR == FNR { if (index($0, prefix) == 1) tracked[tolower(substr($0, length(prefix) + 1))] = 1; next }
    substr($0, 65, 2) == "  " && substr($0, 1, 64) !~ /[^0-9a-f]/ && !(tolower(substr($0, 67)) in tracked) { print substr($0, 67) }
  ' - "$live_root/.sync-manifest")
  printf '%s' "$pending"
}

# countDifferingPairs(pairCount, relList): how many of the newline-terminated
# checkout-relative paths differ between the checkout and the live trees. Both
# sides are hashed from relative paths, so a checkout or home path containing a
# newline cannot split an entry (Copilot review on #67): the checkout side runs
# in the checkout, and the live side runs in a temporary directory whose
# claude, cursor, and codex entries are symlinks to the three live trees. Two
# `git hash-object --stdin-paths` processes hash every file; --no-filters
# hashes the raw bytes, which is what sync.sh copies and what cmp compared.
# When either batch fails or comes back short (a file unreadable or removed
# mid-run), it falls back to one cmp per pair, so an error can cost time but
# never hide drift, and a temporary directory that cannot be made counts every
# pair as drift for the same reason. countDriftedFiles passes only names that
# git printed unquoted, so an entry of relList is always one line.
countDifferingPairs() {
  local pair_count="$1" rel_list="$2" live_view left_hashes right_hashes rel differing=0
  live_view=$(mktemp -d "${TMPDIR:-/tmp}/harness-sync.XXXXXX" 2>/dev/null) || { printf '%s' "$pair_count"; return; }
  ln -s "$LIVE" "$live_view/claude"; ln -s "$CURSOR_LIVE" "$live_view/cursor"; ln -s "$CODEX_LIVE" "$live_view/codex"
  if left_hashes=$(printf '%s' "$rel_list" | git -C "$CHECKOUT" hash-object --no-filters --stdin-paths 2>/dev/null) \
    && right_hashes=$(printf '%s' "$rel_list" | (cd "$live_view" && git hash-object --no-filters --stdin-paths) 2>/dev/null) \
    && [ "$(grep -c . <<< "$left_hashes")" -eq "$pair_count" ] \
    && [ "$(grep -c . <<< "$right_hashes")" -eq "$pair_count" ]; then
    differing=$(paste -d ' ' <(printf '%s\n' "$left_hashes") <(printf '%s\n' "$right_hashes") | awk '$1 != $2 { n++ } END { print n + 0 }')
  else
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      cmp -s "$CHECKOUT/$rel" "$live_view/$rel" || differing=$((differing + 1))
    done <<< "$rel_list"
  fi
  rm -f "$live_view/claude" "$live_view/cursor" "$live_view/codex"; rmdir "$live_view" 2>/dev/null
  printf '%s' "$differing"
}

drifted=$(countDriftedFiles)

notes=()
if [ "$drifted" -gt 0 ]; then
  if ! command -v rsync >/dev/null 2>&1; then
    if [ "$REMOTE" = "true" ] && command -v apt-get >/dev/null 2>&1; then
      (apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq rsync >/dev/null 2>&1) || true
    fi
    if ! command -v rsync >/dev/null 2>&1; then
      say_context "harness-sync (R-003): the live harness (~/.claude, ~/.cursor, ~/.codex) differs from $CHECKOUT in $drifted tracked file(s), and rsync is not installed, so ./sync.sh cannot run. Install rsync and run ./sync.sh from the checkout before relying on any gate this session."
      exit 0
    fi
    notes+=("rsync installed")
  fi
  if sync_err=$(cd "$CHECKOUT" && SYNC_CLAUDE_HOME="$LIVE" SYNC_CURSOR_HOME="${SYNC_CURSOR_HOME:-$HOME_DIR/.cursor}" SYNC_CODEX_HOME="${SYNC_CODEX_HOME:-$HOME_DIR/.codex}" ./sync.sh 2>&1 >/dev/null); then
    notes+=("synced $drifted changed or missing file(s) from $CHECKOUT")
    # sync.sh keeps a file it installed once the repository stops tracking it
    # when that file was edited live, and says so on stderr (IAN-116); a
    # successful run's stderr is otherwise dropped, so the KEPT lines are
    # carried into the context where the session can see them.
    kept=$(grep '^KEPT:' <<< "$sync_err" | paste -sd ';' -)
    [ -n "$kept" ] && notes+=("$kept")
  elif grep -q '^REFUSED' <<< "$sync_err"; then
    say_context "harness-sync (R-003): ./sync.sh failed from $CHECKOUT (a JSON file that does not parse refuses its payload: $sync_err); sync.sh copies claude/, cursor/, then codex/, so a payload before the refused one may already be updated while the refused one and those after it are not, and $drifted tracked file(s) differed before the run. Fix the checkout and re-run ./sync.sh before relying on any gate this session."
    exit 0
  elif grep -q '^FAILED:' <<< "$sync_err"; then
    # Only the enforce installer writes FAILED:, and sync.sh runs it after every
    # payload copied, so the files synced and the install is what failed.
    notes+=("synced $drifted changed or missing file(s) from $CHECKOUT, but ./sync.sh then failed: $sync_err")
  else
    # Anything else stopped sync.sh mid-copy (an rsync, mkdir, or git failure).
    say_context "harness-sync (R-003): ./sync.sh failed before its copy completed from $CHECKOUT: $sync_err. Payloads are copied claude/, cursor/, then codex/, so the live trees may be partly updated; $drifted tracked file(s) differed before the run. Fix the cause and re-run ./sync.sh before relying on any gate this session."
    exit 0
  fi
else
  notes+=("live ~/.claude matches $CHECKOUT")
  # Nothing drifted, so ./sync.sh did not run its own install check; a live
  # node_modules can still lag its lockfile (a sync from before this check
  # existed, or a package deleted by hand), and the ESLint push gates need it.
  if [ -f "$LIVE/enforce/package-lock.json" ] && [ -f "$CHECKOUT/claude/enforce/install-enforce-dependencies.sh" ]; then
    if install_out=$(bash "$CHECKOUT/claude/enforce/install-enforce-dependencies.sh" "$LIVE/enforce" 2>&1); then
      [ -n "$install_out" ] && { notes+=("enforce dependencies installed"); deps_reported=1; }
    else
      notes+=("enforce dependencies NOT installed: $install_out")
      deps_reported=1
    fi
  fi
fi

if [ "$drifted" -gt 0 ] || [ "$REMOTE" = "true" ] || [ -n "${deps_reported:-}" ]; then
  say_context "harness-sync (R-003): $(IFS='; '; echo "${notes[*]}"). Hooks registered in the synced settings.json apply from the next tool call; the rules in CLAUDE.md apply now."
fi
exit 0
