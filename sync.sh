#!/usr/bin/env bash
# sync.sh: copies each tool folder's tracked content from this monorepo into
# its live config directory. Pure copy, no build or translate step; see
# docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md
# (Dependencies, Non-goals) for why none exists yet.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_CLAUDE="${SYNC_CLAUDE_HOME:-$HOME/.claude}"
TARGET_CURSOR="${SYNC_CURSOR_HOME:-$HOME/.cursor}"
TARGET_CODEX="${SYNC_CODEX_HOME:-$HOME/.codex}"

EXCLUDE_CLAUDE=(sessions cache history.jsonl paste-cache shell-snapshots projects .git backups 'daemon*' file-history)
EXCLUDE_CURSOR=(extensions ide_state.json cli-config.json argv.json ai-tracking .git)
EXCLUDE_CODEX=(sessions log cache auth.json history.jsonl '*.sqlite*' .tmp ipc dictation-history .git)

sync_one() {
  local src="$1" dest="$2"; shift 2
  local excludes=("$@")
  local rsync_args=(-a --delete)
  for e in "${excludes[@]}"; do rsync_args+=(--exclude "$e"); done
  mkdir -p "$dest"
  while IFS= read -r -d '' jsonfile; do
    if ! jq empty "$jsonfile" 2>/dev/null; then
      echo "REFUSED: $jsonfile is not valid JSON, $dest left untouched" >&2
      return 1
    fi
  done < <(find "$src" -name "*.json" -print0)
  rsync "${rsync_args[@]}" "$src/" "$dest/"
  echo "synced $src -> $dest"
}

sync_one "$REPO_ROOT/claude" "$TARGET_CLAUDE" "${EXCLUDE_CLAUDE[@]}"
sync_one "$REPO_ROOT/cursor" "$TARGET_CURSOR" "${EXCLUDE_CURSOR[@]}"
sync_one "$REPO_ROOT/codex" "$TARGET_CODEX" "${EXCLUDE_CODEX[@]}"
