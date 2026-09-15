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
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_CLAUDE="${SYNC_CLAUDE_HOME:-$HOME/.claude}"
TARGET_CURSOR="${SYNC_CURSOR_HOME:-$HOME/.cursor}"
TARGET_CODEX="${SYNC_CODEX_HOME:-$HOME/.codex}"

EXCLUDE_CLAUDE=(sessions cache history.jsonl paste-cache shell-snapshots projects .git backups 'daemon*' file-history)
EXCLUDE_CURSOR=(extensions ide_state.json cli-config.json argv.json ai-tracking .git)
EXCLUDE_CODEX=(sessions log cache auth.json history.jsonl '*.sqlite*' .tmp ipc dictation-history .git)

sync_one() {
  local folder="$1" dest="$2"; shift 2
  local excludes=("$@")
  local rsync_args=(-a --delete)
  for e in "${excludes[@]}"; do rsync_args+=(--exclude "$e"); done

  # Stage a copy of only the git-tracked files for this folder. Building a
  # clean staging tree (rather than filtering rsync's own --delete pass
  # against the live working directory) keeps the "mirror what's tracked"
  # semantics simple and correct: the final rsync below is a plain, ordinary
  # full-tree sync from staging, so --delete behaves exactly as it always has.
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

sync_one claude "$TARGET_CLAUDE" "${EXCLUDE_CLAUDE[@]}"
sync_one cursor "$TARGET_CURSOR" "${EXCLUDE_CURSOR[@]}"
sync_one codex "$TARGET_CODEX" "${EXCLUDE_CODEX[@]}"
