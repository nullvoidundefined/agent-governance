#!/usr/bin/env bash
# sync.test.sh: verifies sync.sh copies each folder into its target, never
# deletes anything already there (no rsync --delete, see sync.sh's header for
# why), refuses on invalid JSON without a partial write, is idempotent, and
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

# --- a tracked file removed from source (git rm) is NOT removed from the
# destination on the next sync: sync only ever adds or updates, it never
# deletes, even a file it once put there itself stays behind once the
# source stops tracking it, until someone cleans it up by hand.
echo "temporary" > "$TMP/repo/claude/removable.txt"
git -C "$TMP/repo" add claude/removable.txt
git -C "$TMP/repo" commit -q -m "fixture: add removable tracked file"
run_sync >/dev/null
[ -f "$TMP/live/claude/removable.txt" ] || { echo "FAIL: tracked file was not synced"; exit 1; }
git -C "$TMP/repo" rm -q claude/removable.txt
run_sync >/dev/null
[ -f "$TMP/live/claude/removable.txt" ] || { echo "FAIL: sync deleted a file from the destination; it must never delete anything"; exit 1; }

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
jq -r '.packages | to_entries[] | select(.key != "" and (.value.optional | not)) | .key' "$prefix/package-lock.json" |
  while IFS= read -r pkg; do mkdir -p "$prefix/$pkg"; done
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

rm -rf "$TMP"
echo "sync.test.sh PASS"
