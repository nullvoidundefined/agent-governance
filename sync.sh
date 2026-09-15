#!/usr/bin/env bash
# sync.sh: copies each tool folder's tracked content from this monorepo into
# its live config directory. Pure copy, no build or translate step; see
# docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md
# (Dependencies, Non-goals) for why none exists yet.
#
# Only files tracked by git in each source folder are ever synced. Untracked
# or gitignored working-directory state (build artifacts, installed
# dependencies, caches) must never reach the destination and must never be
# considered by the JSON pre-flight check: a source folder is a git checkout,
# not a scratch directory, and its local side effects (e.g. `npm ci` dropping
# node_modules/ under claude/enforce/) are not part of what ships.
#
# Never deletes anything from a live directory (no rsync --delete). An
# earlier version did, gated by a hand-maintained per-tool exclude list
# meant to protect each tool's own runtime state (sessions, auth, caches,
# logs, local config). That list needed to name every such path, forever,
# across three different, evolving tools, and it did not: the first real
# run deleted a live SDD workspace directory outright, plus Codex's entire
# config.toml and its 696KB global-state file, none of which were in the
# list. A hand-typed denylist that must be exhaustive to be safe is the
# wrong shape. Sync now only ever adds or updates tracked files; nothing
# already sitting in a live directory is ever removed by it, even a
# tracked file removed from the source stays behind until cleaned up by
# hand. That is a strictly safer trade than the alternative.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_CLAUDE="${SYNC_CLAUDE_HOME:-$HOME/.claude}"
TARGET_CURSOR="${SYNC_CURSOR_HOME:-$HOME/.cursor}"
TARGET_CODEX="${SYNC_CODEX_HOME:-$HOME/.codex}"

sync_one() {
  local folder="$1" dest="$2"
  local rsync_args=(-a)

  # Stage a copy of only the git-tracked files for this folder. Building a
  # clean staging tree keeps the "only ship what's tracked" semantics simple
  # and correct: the final rsync below copies exactly that tree, nothing more.
  local filelist staging
  filelist=$(mktemp)
  git -C "$REPO_ROOT" ls-files -- "$folder" > "$filelist"

  staging=$(mktemp -d)
  mkdir -p "$staging/$folder"
  if [ -s "$filelist" ]; then
    rsync -a --files-from="$filelist" "$REPO_ROOT/" "$staging/"
  fi
  rm -f "$filelist"

  mkdir -p "$dest"
  while IFS= read -r -d '' jsonfile; do
    if ! jq empty "$jsonfile" 2>/dev/null; then
      echo "REFUSED: $jsonfile is not valid JSON, $dest left untouched" >&2
      rm -rf "$staging"
      return 1
    fi
  done < <(find "$staging/$folder" -name "*.json" -print0)

  rsync "${rsync_args[@]}" "$staging/$folder/" "$dest/"
  rm -rf "$staging"
  echo "synced $REPO_ROOT/$folder -> $dest"
}

sync_one claude "$TARGET_CLAUDE"
sync_one cursor "$TARGET_CURSOR"
sync_one codex "$TARGET_CODEX"
