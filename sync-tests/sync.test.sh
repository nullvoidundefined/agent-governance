#!/usr/bin/env bash
# sync.test.sh: verifies sync.sh copies each folder into its target, never
# deletes anything it did not install (no rsync --delete, see sync.sh's header
# for why), removes a file it installed once the repository stops tracking it
# and only while its live content is unchanged (IAN-116), refuses on invalid JSON without a partial write, is idempotent, and
# syncs only git-tracked source content (never untracked/gitignored local
# state such as node_modules), and brings the live enforce node_modules in
# line with a synced lockfile, failing loudly when npm cannot. Every target is a temp dir via the SYNC_*_HOME
# overrides, so this never touches a real ~/.claude, ~/.cursor, or ~/.codex.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)

mkdir -p "$TMP/repo/claude" "$TMP/repo/cursor" "$TMP/repo/codex"
mkdir -p "$TMP/live/claude" "$TMP/live/cursor" "$TMP/live/codex"
cp "$REPO_ROOT/sync.sh" "$TMP/repo/sync.sh"; chmod +x "$TMP/repo/sync.sh"

# The fake source repo must be a real git repo: sync.sh now determines what to
# sync from `git ls-files`, not from the raw working directory.
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email "test@example.com"
git -C "$TMP/repo" config user.name "sync-test"

echo "rule content" > "$TMP/repo/claude/CLAUDE.md"
echo '{"a":1}' > "$TMP/repo/claude/settings.json"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" commit -q -m "fixture: initial tracked content"

run_sync() {
  SYNC_CLAUDE_HOME="$TMP/live/claude" SYNC_CURSOR_HOME="$TMP/live/cursor" SYNC_CODEX_HOME="$TMP/live/codex" \
    "$TMP/repo/sync.sh"
}

run_sync >/dev/null
[ -f "$TMP/live/claude/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not synced"; exit 1; }
diff "$TMP/repo/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md" >/dev/null || { echo "FAIL: synced content differs"; exit 1; }

# --- sync never deletes: pre-existing live-only content (runtime state, a
# stray file, anything) survives every sync unconditionally, there is no
# exclude list to keep current because there is nothing to protect against.
mkdir -p "$TMP/live/claude/sessions"; echo "keep me" > "$TMP/live/claude/sessions/marker.txt"
run_sync >/dev/null
[ -f "$TMP/live/claude/sessions/marker.txt" ] || { echo "FAIL: sync deleted live-only content it must never touch"; exit 1; }

cp "$TMP/live/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md.before"
echo "{not json" > "$TMP/repo/claude/settings.json"
if run_sync >/dev/null 2>"$TMP/err.log"; then echo "FAIL: expected sync to refuse on invalid JSON"; exit 1; fi
grep -q "REFUSED" "$TMP/err.log" || { echo "FAIL: expected a REFUSED message"; exit 1; }
diff "$TMP/live/claude/CLAUDE.md" "$TMP/live/claude/CLAUDE.md.before" >/dev/null || { echo "FAIL: partial write happened despite refusal"; exit 1; }
echo '{"a":1}' > "$TMP/repo/claude/settings.json"

run_sync >/dev/null
BEFORE=$(find "$TMP/live/claude" -type f | sort | xargs -I{} shasum {} | shasum)
run_sync >/dev/null
AFTER=$(find "$TMP/live/claude" -type f | sort | xargs -I{} shasum {} | shasum)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: second sync run was not idempotent"; exit 1; }

# --- untracked source content must never sync and must never trip the JSON
# pre-flight, even when it is invalid JSON. This is the real-world scenario:
# `npm ci` drops a gitignored enforce/node_modules/ tree full of its own
# (non-strict) tsconfig.json files under claude/ in the working directory.
echo "{not valid json at all" > "$TMP/repo/claude/untracked-invalid.json"
mkdir -p "$TMP/repo/claude/untracked-dir/nested"
echo "{also not json" > "$TMP/repo/claude/untracked-dir/nested/tsconfig.json"
run_sync >"$TMP/untracked-run.log" 2>&1 || { echo "FAIL: sync refused because of untracked invalid JSON"; cat "$TMP/untracked-run.log"; exit 1; }
[ ! -e "$TMP/live/claude/untracked-invalid.json" ] || { echo "FAIL: untracked file leaked into destination"; exit 1; }
[ ! -e "$TMP/live/claude/untracked-dir" ] || { echo "FAIL: untracked directory leaked into destination"; exit 1; }
rm -rf "$TMP/repo/claude/untracked-invalid.json" "$TMP/repo/claude/untracked-dir"

# --- safe removal (IAN-116). sync.sh writes <target>/.sync-manifest, one
# "<sha256>  <path>" line per file it installed. On the next run it removes a
# live file only when the previous manifest lists it, the repository no longer
# tracks it, and its live content still hashes to the manifest's value; a file
# edited live is kept and reported, a file sync never installed is never
# touched, and a directory is removed only when that removal emptied it.
MANIFEST="$TMP/live/claude/.sync-manifest"
[ -f "$MANIFEST" ] || { echo "FAIL: sync did not write $MANIFEST"; exit 1; }
expected_line="$(shasum -a 256 "$TMP/repo/claude/CLAUDE.md" | awk '{print $1}')  CLAUDE.md"
grep -qxF "$expected_line" "$MANIFEST" || { echo "FAIL: manifest lacks '$expected_line'"; cat "$MANIFEST"; exit 1; }

mkdir -p "$TMP/repo/claude/nested/deep" "$TMP/repo/claude/shared"
echo "temporary" > "$TMP/repo/claude/removable.txt"
echo "temporary nested" > "$TMP/repo/claude/nested/deep/removable.txt"
echo "temporary shared" > "$TMP/repo/claude/shared/removable.txt"
echo "edited later" > "$TMP/repo/claude/edited.txt"
git -C "$TMP/repo" add -A
git -C "$TMP/repo" commit -q -m "fixture: add removable tracked files"
run_sync >/dev/null
for f in removable.txt nested/deep/removable.txt shared/removable.txt edited.txt; do
  [ -f "$TMP/live/claude/$f" ] || { echo "FAIL: tracked file $f was not synced"; exit 1; }
done
# A live-only file beside a synced one: sync never installed it, so neither it
# nor the directory holding it may go when the synced neighbor is removed.
echo "mine" > "$TMP/live/claude/shared/own.txt"
echo "edited live" > "$TMP/live/claude/edited.txt"
git -C "$TMP/repo" rm -q claude/removable.txt claude/nested/deep/removable.txt claude/shared/removable.txt claude/edited.txt
git -C "$TMP/repo" commit -q -m "fixture: stop tracking the removable files"
run_sync >"$TMP/remove.out" 2>"$TMP/remove.err"
[ ! -e "$TMP/live/claude/removable.txt" ] || { echo "FAIL: a file sync installed and the repo stopped tracking was not removed"; exit 1; }
[ ! -e "$TMP/live/claude/nested" ] || { echo "FAIL: directories emptied by the removal were left behind"; exit 1; }
[ -f "$TMP/live/claude/shared/own.txt" ] || { echo "FAIL: a live file sync never installed was removed"; exit 1; }
[ ! -e "$TMP/live/claude/shared/removable.txt" ] || { echo "FAIL: a removed file beside a live-only file was not removed"; exit 1; }
[ -f "$TMP/live/claude/edited.txt" ] || { echo "FAIL: a file edited live since sync installed it was removed"; exit 1; }
grep -q "edited.txt" "$TMP/remove.err" || { echo "FAIL: a kept live-edited file was not reported"; cat "$TMP/remove.out" "$TMP/remove.err"; exit 1; }
grep -q "removable.txt" "$TMP/remove.out" || { echo "FAIL: a removal was not reported"; cat "$TMP/remove.out"; exit 1; }
[ -f "$TMP/live/claude/sessions/marker.txt" ] || { echo "FAIL: live-only runtime state was removed"; exit 1; }
if grep -q "removable.txt\|edited.txt" "$MANIFEST"; then echo "FAIL: the new manifest still lists files the repo no longer tracks"; exit 1; fi

# A rename that changes only letter case (local review on #69): on a
# case-insensitive volume (macOS by default) rsync --checksum leaves the old
# entry in place under the old spelling, and the old path resolves to the file
# the repository still tracks, so removing it would delete a tracked file. A
# candidate whose path matches a tracked path ignoring case is never removed.
echo "case rename" > "$TMP/repo/claude/CaseRename.txt"
git -C "$TMP/repo" add -A; git -C "$TMP/repo" commit -q -m "fixture: add case-rename file"
run_sync >/dev/null
git -C "$TMP/repo" mv claude/CaseRename.txt claude/caserename.txt
git -C "$TMP/repo" commit -q -m "fixture: rename by case only"
run_sync >/dev/null
[ -f "$TMP/live/claude/caserename.txt" ] || { echo "FAIL: a case-only rename removed the file the repository still tracks"; exit 1; }

# First run with no manifest (an install synced before manifests existed):
# nothing is removed, and the manifest is written for the next run.
echo "legacy" > "$TMP/repo/claude/legacy.txt"
git -C "$TMP/repo" add -A; git -C "$TMP/repo" commit -q -m "fixture: add legacy file"
run_sync >/dev/null
rm -f "$MANIFEST"
git -C "$TMP/repo" rm -q claude/legacy.txt; git -C "$TMP/repo" commit -q -m "fixture: stop tracking legacy file"
run_sync >/dev/null
[ -f "$TMP/live/claude/legacy.txt" ] || { echo "FAIL: a run with no previous manifest removed a file"; exit 1; }
[ -f "$MANIFEST" ] || { echo "FAIL: a run with no previous manifest did not write one"; exit 1; }

# A manifest line naming a path outside the target is never acted on.
outside="$TMP/outside.txt"; echo "outside" > "$outside"
printf '%s  ../outside.txt\n' "$(shasum -a 256 "$outside" | awk '{print $1}')" >> "$MANIFEST"
run_sync >/dev/null 2>&1
[ -f "$outside" ] || { echo "FAIL: a manifest entry escaping the target removed a file outside it"; exit 1; }

# --- enforce dependencies (2026-09-18): a synced claude/enforce/package-lock.json
# that adds a dependency must reach the live node_modules. The copy used to be
# the whole sync, so a lockfile gaining vue-eslint-parser landed in the live
# tree while node_modules kept the old set, and lint.mjs crashed with
# ERR_MODULE_NOT_FOUND on every push until someone ran npm ci by hand. A stub
# npm (SYNC_NPM) records each call and materializes the locked packages, so
# this runs offline and asserts on what the live tree ends up holding.
STUB_NPM="$TMP/stub-npm"
NPM_LOG="$TMP/npm-calls.log"
cat > "$STUB_NPM" <<'STUB'
#!/usr/bin/env bash
# stub npm: records the call, then installs every non-optional locked package
# as an empty directory, which is all the dependency check looks at.
printf '%s\n' "$*" >> "$NPM_LOG"
[ "${STUB_NPM_FAIL:-}" = "1" ] && { echo "stub npm: registry unreachable" >&2; exit 1; }
prefix=""
while [ $# -gt 0 ]; do [ "$1" = "--prefix" ] && prefix="$2"; shift; done
# npm ci deletes node_modules before installing, stamp included.
rm -f "$prefix/node_modules/.enforce-installed-lock"
jq -r '.packages | to_entries[] | select(.key != "" and (.value.optional | not)) | .key' "$prefix/package-lock.json" |
  while IFS= read -r pkg; do mkdir -p "$prefix/$pkg"; done
# STUB_NPM_READONLY: leave node_modules unwritable, so the stamp copy that
# follows a successful install fails.
[ "${STUB_NPM_READONLY:-}" = "1" ] && chmod a-w "$prefix/node_modules"
exit 0
STUB
chmod +x "$STUB_NPM"
export NPM_LOG

# writeEnforceLock(packages...): writes a package.json and a lockfile that
# locks the named packages, then commits both into the fake source repo.
writeEnforceLock() {
  local pkg lock='{"name":"enforce","lockfileVersion":3,"packages":{"":{"name":"enforce"}}}'
  for pkg in "$@"; do lock=$(printf '%s' "$lock" | jq --arg k "node_modules/$pkg" '.packages[$k] = {version: "1.0.0"}'); done
  mkdir -p "$TMP/repo/claude/enforce"
  printf '{"name":"enforce","private":true}\n' > "$TMP/repo/claude/enforce/package.json"
  printf '%s\n' "$lock" > "$TMP/repo/claude/enforce/package-lock.json"
  git -C "$TMP/repo" add -A
  git -C "$TMP/repo" commit -q -m "fixture: enforce lock $*"
}

# npmCallCount(): prints how many times the stub npm has been called.
npmCallCount() { [ -f "$NPM_LOG" ] && wc -l < "$NPM_LOG" | tr -d ' ' || echo 0; }

mkdir -p "$TMP/repo/claude/enforce"
cp "$REPO_ROOT/claude/enforce/install-enforce-dependencies.sh" "$TMP/repo/claude/enforce/"
writeEnforceLock eslint
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1 || { echo "FAIL: sync with an enforce lockfile failed"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/eslint" ] || { echo "FAIL: first sync did not install the locked enforce dependencies"; exit 1; }
grep -q -- "ci --prefix $TMP/live/claude/enforce" "$NPM_LOG" || { echo "FAIL: install was not a locked npm ci against the live enforce dir"; exit 1; }

calls=$(npmCallCount)
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1
[ "$(npmCallCount)" = "$calls" ] || { echo "FAIL: an unchanged, complete install ran npm again"; exit 1; }

# The regression itself: the source lock adds a dependency the live tree lacks.
writeEnforceLock eslint vue-eslint-parser
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1 || { echo "FAIL: sync after a lockfile change failed"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/vue-eslint-parser" ] || { echo "FAIL: a dependency added to the synced lockfile never reached the live node_modules"; exit 1; }

# Same lockfile, but a locked package vanished from the live node_modules.
rm -rf "$TMP/live/claude/enforce/node_modules/vue-eslint-parser"
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1 || { echo "FAIL: sync repairing a missing package failed"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/vue-eslint-parser" ] || { echo "FAIL: a locked package missing from the live node_modules was not reinstalled"; exit 1; }

# npm unavailable: the files still sync, but the run fails loudly and names the fix.
writeEnforceLock eslint vue-eslint-parser eslint-plugin-vue
if SYNC_NPM="$TMP/no-such-npm" run_sync >/dev/null 2>"$TMP/nonpm.err"; then echo "FAIL: sync succeeded although npm is unavailable and the lockfile changed"; exit 1; fi
grep -q "npm ci --prefix $TMP/live/claude/enforce" "$TMP/nonpm.err" || { echo "FAIL: missing-npm failure does not name the npm ci command"; cat "$TMP/nonpm.err"; exit 1; }
cmp -s "$TMP/repo/claude/enforce/package-lock.json" "$TMP/live/claude/enforce/package-lock.json" || { echo "FAIL: missing npm blocked the file sync itself"; exit 1; }

# npm present but failing: loud, nonzero, and retried on the next sync.
if STUB_NPM_FAIL=1 SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>"$TMP/npmfail.err"; then echo "FAIL: sync succeeded although npm ci failed"; exit 1; fi
grep -q "FAILED" "$TMP/npmfail.err" || { echo "FAIL: npm ci failure was not reported"; cat "$TMP/npmfail.err"; exit 1; }
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1 || { echo "FAIL: sync did not recover once npm worked"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/eslint-plugin-vue" ] || { echo "FAIL: a failed install was not retried on the next sync"; exit 1; }

# Copilot review on #55: the stamp copy is the installer's last step, and a
# helper without set -e used to report "installed" even when it failed, so the
# sync claimed success with no stamp written.
writeEnforceLock eslint vue-eslint-parser eslint-plugin-vue typescript
if STUB_NPM_READONLY=1 SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>"$TMP/stamp.err"; then
  chmod u+w "$TMP/live/claude/enforce/node_modules"; echo "FAIL: sync succeeded although the install stamp could not be written"; exit 1
fi
chmod u+w "$TMP/live/claude/enforce/node_modules"
grep -q "FAILED" "$TMP/stamp.err" || { echo "FAIL: a stamp write failure was not reported"; cat "$TMP/stamp.err"; exit 1; }

# Copilot review on #55: sync.sh and a parallel session's SessionStart can both
# find the install stale, and npm ci rebuilds the shared node_modules, so the
# install is serialized by a lock. A lock held by someone else is waited on and
# then reported, never run through.
mkdir "$TMP/live/claude/enforce/.enforce-install-lock"
calls=$(npmCallCount)
if ENFORCE_INSTALL_LOCK_WAIT=1 SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>"$TMP/lock.err"; then echo "FAIL: sync installed through a lock held by another install"; exit 1; fi
[ "$(npmCallCount)" = "$calls" ] || { echo "FAIL: npm ran while another install held the lock"; exit 1; }
grep -q "enforce-install-lock" "$TMP/lock.err" || { echo "FAIL: a held install lock was not named"; cat "$TMP/lock.err"; exit 1; }
rmdir "$TMP/live/claude/enforce/.enforce-install-lock"
SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1 || { echo "FAIL: sync did not install once the lock was released"; exit 1; }
[ ! -e "$TMP/live/claude/enforce/.enforce-install-lock" ] || { echo "FAIL: the install left its lock behind"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/typescript" ] || { echo "FAIL: install after the lock release did not complete"; exit 1; }

# Copilot review on #60: an age-based expiry let a second caller clear the lock
# under a slow but live npm ci. The lock now records its holder's PID and is
# reclaimed only when that process is gone, never because it is old. A live
# holder (this shell) is waited on; a dead one is reclaimed at once.
writeEnforceLock eslint vue-eslint-parser eslint-plugin-vue typescript zod
LIVE_LOCK="$TMP/live/claude/enforce/.enforce-install-lock"
mkdir "$LIVE_LOCK"; echo "$$" > "$LIVE_LOCK/pid"; touch -t 200001010000 "$LIVE_LOCK"
if ENFORCE_INSTALL_LOCK_WAIT=1 SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>&1; then echo "FAIL: an old lock held by a live process was reclaimed"; exit 1; fi
sleep 0 & dead_pid=$!; wait "$dead_pid"
echo "$dead_pid" > "$LIVE_LOCK/pid"
ENFORCE_INSTALL_LOCK_WAIT=1 SYNC_NPM="$STUB_NPM" run_sync >/dev/null 2>"$TMP/dead.err" || { echo "FAIL: a lock left by a dead process was not reclaimed"; cat "$TMP/dead.err"; exit 1; }
[ -d "$TMP/live/claude/enforce/node_modules/zod" ] || { echo "FAIL: install after reclaiming a dead lock did not complete"; exit 1; }
[ ! -e "$LIVE_LOCK" ] || { echo "FAIL: the install left its lock behind"; exit 1; }

rm -rf "$TMP"
echo "sync.test.sh PASS"
