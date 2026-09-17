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
# is told instead. enforce/node_modules is installed with npm when absent
# so the ESLint push gates can run; best effort, since a container may have
# no network. Advisory: emits additionalContext, never blocks, exits 0 on
# every path (no set -e; enforce/README hook set convention).
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

# countDriftedPayloadFiles(payload, liveRoot): tracked files under <payload>/
# in the checkout that are missing from liveRoot or differ from it.
countDriftedPayloadFiles() {
  local payload="$1" live_root="$2" rel live count=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    live="$live_root/${rel#"$payload"/}"
    if [ ! -f "$live" ] || ! cmp -s "$CHECKOUT/$rel" "$live"; then count=$((count + 1)); fi
  done < <(git -C "$CHECKOUT" ls-files -- "$payload" 2>/dev/null)
  printf '%s' "$count"
}

drifted=$(countDriftedPayloadFiles claude "$LIVE")
drifted=$((drifted + $(countDriftedPayloadFiles cursor "$CURSOR_LIVE")))
drifted=$((drifted + $(countDriftedPayloadFiles codex "$CODEX_LIVE")))

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
  if (cd "$CHECKOUT" && SYNC_CLAUDE_HOME="$LIVE" SYNC_CURSOR_HOME="${SYNC_CURSOR_HOME:-$HOME_DIR/.cursor}" SYNC_CODEX_HOME="${SYNC_CODEX_HOME:-$HOME_DIR/.codex}" ./sync.sh >/dev/null 2>&1); then
    notes+=("synced $drifted changed or missing file(s) from $CHECKOUT")
  else
    say_context "harness-sync (R-003): ./sync.sh failed from $CHECKOUT (a JSON file that does not parse refuses the whole sync); the live ~/.claude is unchanged and $drifted tracked file(s) differ. Fix the checkout and re-run ./sync.sh before relying on any gate this session."
    exit 0
  fi
else
  notes+=("live ~/.claude matches $CHECKOUT")
fi

# The ESLint push gates need the enforce dependencies beside the live tree.
if [ -f "$LIVE/enforce/package.json" ] && [ ! -d "$LIVE/enforce/node_modules" ] && command -v npm >/dev/null 2>&1; then
  if npm install --prefix "$LIVE/enforce" --silent --no-audit --no-fund >/dev/null 2>&1; then
    notes+=("enforce dependencies installed")
  else
    notes+=("enforce dependencies NOT installed (npm install failed; the ESLint push gates will refuse until it succeeds)")
  fi
fi

if [ "$drifted" -gt 0 ] || [ "$REMOTE" = "true" ]; then
  say_context "harness-sync (R-003): $(IFS='; '; echo "${notes[*]}"). Hooks registered in the synced settings.json apply from the next tool call; the rules in CLAUDE.md apply now."
fi
exit 0
