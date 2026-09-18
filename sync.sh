#!/usr/bin/env bash
# sync.sh: copies each tool folder's tracked content from this monorepo into
# its live config directory. A copy with no build or translate step; see
# docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md
# (Dependencies, Non-goals) for why none exists yet. The one step beyond the
# copy is a locked `npm ci` of the live enforce/ dependencies when the synced
# lockfile no longer matches what is installed (see the end of this file).
#
# Only files tracked by git in each source folder are ever synced. Untracked
# or gitignored working-directory state (build artifacts, installed
# dependencies, caches) must never reach the destination and must never be
# considered by the JSON pre-flight check: a source folder is a git checkout,
# not a scratch directory, and its local side effects (e.g. `npm ci` dropping
# node_modules/ under claude/enforce/) are not part of what ships.
#
# Never deletes anything it did not install (no rsync --delete). An earlier
# version did, gated by a hand-maintained per-tool exclude list meant to
# protect each tool's own runtime state (sessions, auth, caches, logs, local
# config). That list needed to name every such path, forever, across three
# different, evolving tools, and it did not: the first real run deleted a live
# SDD workspace directory outright, plus Codex's entire config.toml and its
# 696KB global-state file, none of which were in the list. A hand-typed
# denylist that must be exhaustive to be safe is the wrong shape.
#
# Removal is an allowlist instead (IAN-116). Each run writes
# <target>/.sync-manifest, one "<sha256>  <path>" line per file it installed.
# The next run removes a live file only when all three hold: the previous
# manifest lists it, the repository no longer tracks it, and its live content
# still hashes to the manifest's value. A file edited live since it was
# installed is kept and reported on stderr, a file sync never installed is
# never looked at, a manifest path that is absolute or climbs out of the
# target is ignored, and a directory is removed only when removing a file
# emptied it. A run with no previous manifest (an install synced before
# manifests existed) removes nothing, so files orphaned before then still
# need cleaning up by hand.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_CLAUDE="${SYNC_CLAUDE_HOME:-$HOME/.claude}"
TARGET_CURSOR="${SYNC_CURSOR_HOME:-$HOME/.cursor}"
TARGET_CODEX="${SYNC_CODEX_HOME:-$HOME/.codex}"

# sha256Tool: prints the SHA-256 command available here, sha256sum on Linux
# and shasum -a 256 on macOS; both print "<hex>  <path>" lines.
sha256Tool() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"; else echo "shasum -a 256"; fi
}
SHA256=$(sha256Tool)

# hashLiveEntry(path): the manifest hash of one path, the content hash for a
# regular file and the hash of "symlink:<target>" for a symlink, so a tracked
# symlink is compared by where it points rather than by what it points at.
hashLiveEntry() {
  if [ -L "$1" ]; then
    printf 'symlink:%s' "$(readlink "$1")" | $SHA256 | awk '{print $1}'
  else
    $SHA256 < "$1" | awk '{print $1}'
  fi
}

# writeManifestLines(stagedFolder): one "<sha256>  <path>" line per file in the
# staged tree, paths relative to it, sorted so an unchanged tree writes an
# identical manifest. Regular files are hashed in batches by find -exec, which
# runs nothing for an empty tree (xargs would hash empty stdin instead).
writeManifestLines() {
  local staged="$1" link
  {
    (cd "$staged" && find . -type f -exec $SHA256 {} +) | sed 's#  \./#  #'
    while IFS= read -r -d '' link; do
      printf '%s  %s\n' "$(hashLiveEntry "$staged/$link")" "${link#./}"
    done < <(cd "$staged" && find . -type l -print0)
  } | LC_ALL=C sort -k2
}

# isInsideTarget(relPath): true when a manifest path stays inside its target:
# not empty, not absolute, and with no ".." component.
isInsideTarget() {
  case "/$1/" in
    //) return 1 ;;
    //*) return 1 ;;
    */../*) return 1 ;;
  esac
  return 0
}

# pruneEmptiedDirectories(dest, removedPath): removes the removed file's
# parent directory and then each ancestor below dest, stopping at the first
# that is not empty; rmdir refuses a non-empty directory, so only directories
# this removal emptied can go.
pruneEmptiedDirectories() {
  local dest="$1" dir
  dir=$(dirname "$2")
  while [ "$dir" != "$dest" ] && [ "${dir#"$dest"/}" != "$dir" ]; do
    rmdir "$dir" 2>/dev/null || break
    dir=$(dirname "$dir")
  done
}

# removeUntrackedInstalledFiles(dest, newManifest): applies the three-part
# removal rule above to every path the previous manifest lists and the new one
# does not, printing each removal on stdout and each kept file on stderr. The
# awk filter checks the 64-hex-digit hash without a regex interval, which
# mawk (Ubuntu's default awk) has not always supported.
removeUntrackedInstalledFiles() {
  local dest="$1" new_manifest="$2" old_manifest="$1/.sync-manifest" line recorded rel live
  [ -f "$old_manifest" ] || return 0
  while IFS= read -r line; do
    recorded="${line%%  *}"; rel="${line#*  }"
    isInsideTarget "$rel" || continue
    live="$dest/$rel"
    { [ -f "$live" ] || [ -L "$live" ]; } || continue
    if [ "$(hashLiveEntry "$live")" = "$recorded" ]; then
      rm -f "$live"
      pruneEmptiedDirectories "$dest" "$live"
      echo "removed $live (installed by an earlier sync, no longer tracked)"
    else
      echo "KEPT: $live is no longer tracked but was edited since sync installed it; remove it by hand if it is not needed" >&2
    fi
  done < <(awk 'NR == FNR { tracked[substr($0, 67)] = 1; next } substr($0, 65, 2) == "  " && substr($0, 1, 64) !~ /[^0-9a-f]/ && !(substr($0, 67) in tracked)' "$new_manifest" "$old_manifest")
}

sync_one() {
  local folder="$1" dest="$2"
  # --checksum: a live file edited to the same size within the same second as
  # the tracked one is still drift (the R-003 hook compares content), so the
  # copy decides by content too, never by size and mtime alone.
  local rsync_args=(-a --checksum)

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

  local new_manifest
  new_manifest=$(mktemp)
  writeManifestLines "$staging/$folder" > "$new_manifest"

  rsync "${rsync_args[@]}" "$staging/$folder/" "$dest/"
  rm -rf "$staging"
  removeUntrackedInstalledFiles "$dest" "$new_manifest"
  mv "$new_manifest" "$dest/.sync-manifest"
  echo "synced $REPO_ROOT/$folder -> $dest"
}

sync_one claude "$TARGET_CLAUDE"
sync_one cursor "$TARGET_CURSOR"
sync_one codex "$TARGET_CODEX"

# Stamp the source so hook-integrity-check.sh can compare the live copy
# against this checkout (2026-09-16 audit P2-11: after the migration nothing
# verified live == repo, a property `git status` used to provide for free).
printf '%s\n' "$REPO_ROOT" > "$TARGET_CLAUDE/.sync-source"

# The copy ships enforce/package-lock.json but never node_modules, so a lockfile
# that gained a dependency used to leave lint.mjs crashing on the live side
# (2026-09-18). This runs after the stamp so the files stay synced even when the
# install fails; set -e then turns that failure into a nonzero exit, and the
# script's FAILED line on stderr names the command to run by hand.
if [ -f "$TARGET_CLAUDE/enforce/package-lock.json" ]; then
  bash "$REPO_ROOT/claude/enforce/install-enforce-dependencies.sh" "$TARGET_CLAUDE/enforce" >/dev/null
fi
