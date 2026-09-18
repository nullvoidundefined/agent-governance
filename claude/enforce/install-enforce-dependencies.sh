#!/usr/bin/env bash
# install-enforce-dependencies.sh: brings an enforce/node_modules tree in line
# with the enforce/package-lock.json beside it, through a locked `npm ci`.
#
# sync.sh copies only git-tracked files, so a lockfile that gains a dependency
# reaches the live ~/.claude/enforce while node_modules keeps the old set. That
# happened on 2026-09-18: slice 01 PR 5 added vue-eslint-parser and
# eslint-plugin-vue, lint.mjs crashed with ERR_MODULE_NOT_FOUND, and the ESLint
# push gate could lint nothing until someone ran npm ci by hand. sync.sh and
# the harness-sync SessionStart hook both call this script after a sync, so the
# check lives in one place.
#
# The install is current when the stamp written after the last successful
# install matches the lockfile byte for byte AND every non-optional locked
# package directory exists. The stamp catches version bumps; the directory
# check catches a package deleted from under an otherwise current install.
#
# Usage: install-enforce-dependencies.sh <enforce-dir>
# Exit 0 with no output when there is nothing to do (no lockfile, or current),
# exit 0 printing "installed" when npm ci ran and succeeded, exit 1 with a
# FAILED line on stderr naming the command to run when npm is missing or fails.
# SYNC_NPM overrides the npm executable (fixtures).
#
# The check, install, and stamp run under a lock directory beside node_modules,
# because sync.sh and a parallel session's SessionStart can both find the
# install stale, and npm ci deletes and rebuilds the shared tree. A caller that
# finds the lock held waits up to ENFORCE_INSTALL_LOCK_WAIT seconds (default
# 300), then re-checks, since the holder has usually just installed. The lock
# records its holder's PID and is reclaimed only when that process no longer
# exists, never by age: a slow but live npm ci must keep it (Copilot review on
# #60). A lock with no PID file is treated as held, and the wait then fails
# naming the directory to remove.
set -uo pipefail

ENFORCE_DIR="${1:?usage: install-enforce-dependencies.sh <enforce-dir>}"
NPM_BIN="${SYNC_NPM:-npm}"
LOCK="$ENFORCE_DIR/package-lock.json"
STAMP="$ENFORCE_DIR/node_modules/.enforce-installed-lock"
LOCK_DIR="$ENFORCE_DIR/.enforce-install-lock"
LOCK_WAIT="${ENFORCE_INSTALL_LOCK_WAIT:-300}"

# hasEveryLockedPackage(): true when every non-optional package the lockfile
# names has its directory under the enforce dir. Optional packages are skipped
# because npm leaves out the ones built for other platforms.
hasEveryLockedPackage() {
  local pkg
  while IFS= read -r pkg; do
    [ -d "$ENFORCE_DIR/$pkg" ] || return 1
  done < <(jq -r '.packages // {} | to_entries[] | select(.key != "" and (.value.optional | not)) | .key' "$LOCK")
}

# isInstallCurrent(): true when the last successful install was of this exact
# lockfile and nothing it installed has since gone missing.
isInstallCurrent() {
  cmp -s "$LOCK" "$STAMP" && hasEveryLockedPackage
}

# runLockedInstall(): runs npm ci against the enforce dir and stamps the
# lockfile it installed; on failure prints a FAILED line and npm's last output.
runLockedInstall() {
  local log status
  if ! command -v "$NPM_BIN" >/dev/null 2>&1; then
    echo "FAILED: npm is not installed, so the enforce dependencies locked in $LOCK are not installed and the ESLint push gates cannot lint. Install Node.js and npm, then run: npm ci --prefix $ENFORCE_DIR" >&2
    return 1
  fi
  log=$(mktemp)
  "$NPM_BIN" ci --prefix "$ENFORCE_DIR" --no-audit --no-fund >"$log" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAILED: npm ci --prefix $ENFORCE_DIR exited $status, so the ESLint push gates cannot lint until it succeeds. Last npm output:" >&2
    tail -n 15 "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  if ! cp "$LOCK" "$STAMP"; then
    echo "FAILED: npm ci succeeded but the install stamp $STAMP could not be written, so every sync will reinstall. Check the permissions and free space of $ENFORCE_DIR/node_modules." >&2
    return 1
  fi
  echo "installed"
}

# isLockHolderGone(): true when the lock names a PID and no such process runs,
# which is the only case where another caller may reclaim it.
isLockHolderGone() {
  local holder
  holder=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 1
  [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null
}

# acquireInstallLock(): takes the install lock and records this PID in it,
# reclaiming a lock whose holder has exited; fails naming the lock when a live
# or unidentified holder keeps it past LOCK_WAIT.
acquireInstallLock() {
  local waited=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    if isLockHolderGone; then
      rm -rf "$LOCK_DIR"
      continue
    fi
    if [ "$waited" -ge "$LOCK_WAIT" ]; then
      echo "FAILED: another enforce install has held $LOCK_DIR for over ${LOCK_WAIT}s. If no npm ci is running, remove that directory and run: npm ci --prefix $ENFORCE_DIR" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

[ -f "$LOCK" ] || exit 0
isInstallCurrent && exit 0
acquireInstallLock || exit 1
isInstallCurrent && exit 0
runLockedInstall
