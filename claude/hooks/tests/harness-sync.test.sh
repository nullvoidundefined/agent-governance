#!/usr/bin/env bash
# Covers: hook:harness-sync
# harness-sync.test.sh: verifies hooks/harness-sync.sh (R-003) against a
# sandbox checkout and a fake HOME: the first run syncs the checkout's tracked
# claude/ files into ~/.claude and says so; a second run finds no drift and
# stays silent locally; a drifted live file is re-synced; with no reachable
# checkout the hook is silent locally and reports once in a remote session;
# a sync.sh refusal (invalid JSON) leaves the live tree unchanged and is
# reported; a live enforce node_modules missing a locked package is repaired
# with or without drift, and an unavailable npm is reported; the logs
# session-end.sh writes live are neither drift nor overwritten; the no-drift
# check over 1000 tracked files starts a bounded number of processes rather
# than one per file, its fallback finds exactly the drift there is when the
# batch hash fails, and a live home with a newline in its path is compared
# correctly. Needs rsync,
# which sync.sh needs too.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/harness-sync.sh"
# sync.sh sits beside claude/ at the repository root, so the harness root
# locates it directly. The two fallbacks remain for a run whose root is an
# installed copy rather than a checkout: a symlinked install resolves to its
# checkout, and a copied one carries the .sync-source stamp that names it.
REAL_SYNC="$(cd "$CLAUDE_HARNESS_ROOT/.." && pwd)/sync.sh"
[ -f "$REAL_SYNC" ] || REAL_SYNC="$(cd "$(dirname "$(readlink -f "$CLAUDE_HARNESS_ROOT")")" && pwd)/sync.sh"
[ -f "$REAL_SYNC" ] || REAL_SYNC="$(cat "$CLAUDE_HARNESS_ROOT/.sync-source" 2>/dev/null)/sync.sh"
[ -f "$REAL_SYNC" ] || { echo "FAIL: cannot locate the checkout's sync.sh from $CLAUDE_HARNESS_ROOT"; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "FAIL: rsync is required by sync.sh and this fixture"; exit 1; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
# The session running this fixture may itself be an agent-governance checkout
# in a remote container; neither must leak into the sandbox.
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_REMOTE

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
reports() { context | grep -qF "$1"; }
silent() { [ -z "$OUT" ]; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
CO="$SB/agent-governance"; mkdir -p "$CO/claude/hooks" "$CO/cursor" "$CO/codex"
# The hook stamps and reports the checkout's PHYSICAL path (macOS mktemp
# hands out /var/... which is a symlink to /private/var/...), so resolve CO
# the same way before building expected strings, or every path comparison
# fails on macOS while passing on Linux CI.
CO=$(cd "$CO" && pwd -P)
git -C "$CO" init -q -b main
git -C "$CO" config user.email t@example.invalid; git -C "$CO" config user.name t
cp "$REAL_SYNC" "$CO/sync.sh"; chmod +x "$CO/sync.sh"
printf '# rules\n' > "$CO/claude/CLAUDE.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CO/claude/hooks/sample.sh"
printf '{"hooks":{}}\n' > "$CO/claude/settings.json"
printf '# cursor\n' > "$CO/cursor/README.md"; printf '# codex\n' > "$CO/codex/README.md"
git -C "$CO" add -A; git -C "$CO" commit -qm init
FAKE="$SB/home"; mkdir -p "$FAKE"
export HARNESS_SYNC_HOME="$FAKE" SYNC_CURSOR_HOME="$SB/home/.cursor" SYNC_CODEX_HOME="$SB/home/.codex"

# 1. Bootstrap: nothing live, checkout passed as the argument.
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" "$CO" 2>/dev/null)
check "bootstrap syncs the live tree" test -f "$FAKE/.claude/hooks/sample.sh"
check "bootstrap copies the rules" cmp -s "$CO/claude/CLAUDE.md" "$FAKE/.claude/CLAUDE.md"
check "bootstrap stamps the source" test "$(cat "$FAKE/.claude/.sync-source")" = "$CO"
# Five, not three: the sandbox checkout carries three tracked claude/ files
# plus cursor/README.md and codex/README.md, and the drift check counts every
# payload ./sync.sh writes rather than claude/ alone (2026-09-18).
check "bootstrap reports the count" reports "synced 5 changed or missing file(s) from $CO"

# 2. No drift: silent locally, in-sync line remotely, source found from the stamp.
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "in sync is silent locally" silent
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" 2>/dev/null)
check "in sync is reported remotely" reports "live ~/.claude matches $CO"

# 3. Drift: a live file edited out from under the checkout is re-synced.
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/.claude/hooks/sample.sh"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "drifted file re-synced" cmp -s "$CO/claude/hooks/sample.sh" "$FAKE/.claude/hooks/sample.sh"
check "drift reported with its count" reports "synced 1 changed or missing file(s)"

# 3b. Drift in a NON-claude payload also triggers the sync. ./sync.sh writes all
# three live trees, but the drift check compared claude/ alone, so a stale
# ~/.cursor or ~/.codex could never trigger the sync that repairs it: a Cursor
# session kept running last week's adapter while a Claude session on the same
# machine was current (2026-09-18). Each payload is checked in its own case so a
# regression names which one stopped being seen.
printf '# stale cursor rule\n' > "$SB/home/.cursor/README.md"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "cursor drift re-synced" cmp -s "$CO/cursor/README.md" "$SB/home/.cursor/README.md"
check "cursor drift reported" reports "synced 1 changed or missing file(s)"

printf '# stale codex guidance\n' > "$SB/home/.codex/README.md"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "codex drift re-synced" cmp -s "$CO/codex/README.md" "$SB/home/.codex/README.md"
check "codex drift reported" reports "synced 1 changed or missing file(s)"

# 3c. Enforce dependencies (2026-09-18). A lockfile synced without an install
# left lint.mjs crashing on ERR_MODULE_NOT_FOUND, and the old install step ran
# only when node_modules was absent altogether, so a stale-but-present tree was
# never repaired. The hook must repair a live node_modules missing a locked
# package even when no tracked file drifted, and must say so when it cannot.
STUB_NPM="$SB/stub-npm"
cat > "$STUB_NPM" <<'STUB'
#!/usr/bin/env bash
prefix=""
while [ $# -gt 0 ]; do [ "$1" = "--prefix" ] && prefix="$2"; shift; done
jq -r '.packages | to_entries[] | select(.key != "" and (.value.optional | not)) | .key' "$prefix/package-lock.json" |
  while IFS= read -r pkg; do mkdir -p "$prefix/$pkg"; done
STUB
chmod +x "$STUB_NPM"
mkdir -p "$CO/claude/enforce"
cp "$CLAUDE_HARNESS_ROOT/enforce/install-enforce-dependencies.sh" "$CO/claude/enforce/"
printf '{"name":"enforce","private":true}\n' > "$CO/claude/enforce/package.json"
printf '{"name":"enforce","lockfileVersion":3,"packages":{"":{"name":"enforce"},"node_modules/eslint":{"version":"1.0.0"}}}\n' > "$CO/claude/enforce/package-lock.json"
git -C "$CO" add -A; git -C "$CO" commit -qm "enforce lock"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "drift sync installs the locked enforce dependencies" test -d "$FAKE/.claude/enforce/node_modules/eslint"

rm -rf "$FAKE/.claude/enforce/node_modules/eslint"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "no-drift run repairs a missing locked package" test -d "$FAKE/.claude/enforce/node_modules/eslint"
check "no-drift repair is reported" reports "enforce dependencies installed"

rm -rf "$FAKE/.claude/enforce/node_modules/eslint"
OUT=$(printf '{}' | SYNC_NPM="$SB/no-such-npm" bash "$HOOK" 2>/dev/null)
check "unavailable npm is reported with the fix" reports "npm ci --prefix $FAKE/.claude/enforce"

# 3d. A copy that fails for any reason other than a JSON refusal (Copilot review
# on #55) must not be reported as a completed sync followed by a failed
# install. The live codex home is replaced by a plain file, so sync.sh's
# mkdir -p of that target fails in the middle of the copy.
mv "$SB/home/.codex" "$SB/home/.codex.saved"; printf 'not a directory\n' > "$SB/home/.codex"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
rm -f "$SB/home/.codex"; mv "$SB/home/.codex.saved" "$SB/home/.codex"
check "a failed copy is not reported as synced" bash -c '! grep -qF "but ./sync.sh then failed" <<<"$1"' _ "$(context)"
check "a failed copy is reported as a failed copy" reports "failed before its copy completed"

# 3e. Files a hook writes into the live tree must not be tracked (IAN-114).
# session-end.sh rolls rule fires into the live global-memory/rule_fires.md, and
# that path used to be tracked too, so the live copy never matched the checkout:
# every SessionStart saw drift, ran a full ./sync.sh, and the sync overwrote the
# roll-up, discarding every fire recorded since the last commit; rule_misses.md
# had the same shape for miss: lines. The sandbox
# checkout carries exactly what the real checkout tracks under global-memory/,
# then the real session-end.sh writes a roll-up into the synced live tree.
REAL_CHECKOUT=$(dirname "$REAL_SYNC")
while IFS= read -r tracked; do
  mkdir -p "$CO/$(dirname "$tracked")"; cp "$REAL_CHECKOUT/$tracked" "$CO/$tracked"
done < <(git -C "$REAL_CHECKOUT" ls-files -- claude/global-memory)
git -C "$CO" add -A; git -C "$CO" commit -qm "global memory"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
mkdir -p "$FAKE/.claude/projects/fixture/memory" "$FAKE/.claude/telemetry"
printf 'miss: R-998 fixture miss; gap: none\n' > "$FAKE/.claude/projects/fixture/memory/feedback_fixture.md"
printf '2026-09-18T00:00:00Z|R-999|fixture-hook|deny\n' > "$FAKE/.claude/telemetry/rule-fires.log"
(cd "$SB" && printf '' | HOME="$FAKE" bash "$CLAUDE_HARNESS_ROOT/hooks/session-end.sh" >/dev/null 2>&1)
check "session-end wrote the live roll-up" grep -qF "R-999" "$FAKE/.claude/global-memory/rule_fires.md"
check "session-end wrote the live miss log" grep -qF "R-998" "$FAKE/.claude/global-memory/rule_misses.md"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "a live-written roll-up is not drift" bash -c '! grep -qF "changed or missing file(s)" <<<"$1"' _ "$(context)"
check "a live-written roll-up survives the next SessionStart" grep -qF "R-999" "$FAKE/.claude/global-memory/rule_fires.md"
check "a live-written miss log survives the next SessionStart" grep -qF "R-998" "$FAKE/.claude/global-memory/rule_misses.md"

# 3f. The no-drift check costs a bounded number of processes, not one per
# tracked file (IAN-115). It ran one cmp per tracked file, so with the real
# checkout's 531 tracked files every SessionStart spent about 0.8 s (1.2 s under
# load) confirming that nothing had changed, more than the rest of the
# SessionStart chain together. The sandbox checkout gains 1000 tracked files,
# and pass-through cmp and git wrappers on PATH count every comparison process
# a no-drift run starts: a per-file loop starts about a thousand, a batched
# check a handful. Counting processes rather than timing them keeps the case
# deterministic under any machine load (Copilot review on #67).
DRIFT_CHECK_PROCESS_BUDGET=20
mkdir -p "$CO/claude/bulk"
for i in $(seq 1000); do printf 'bulk %s\n' "$i" > "$CO/claude/bulk/file$i.md"; done
git -C "$CO" add -A; git -C "$CO" commit -qm "bulk"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "bulk files synced" test -f "$FAKE/.claude/bulk/file1000.md"
COUNTING_BIN="$SB/counting-bin"; PROCESS_LOG="$SB/comparison-processes.log"; mkdir -p "$COUNTING_BIN"
for tool in cmp git; do
  real_tool=$(command -v "$tool")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$tool" "$PROCESS_LOG" "$real_tool" > "$COUNTING_BIN/$tool"
  chmod +x "$COUNTING_BIN/$tool"
done
: > "$PROCESS_LOG"
OUT=$(printf '{}' | PATH="$COUNTING_BIN:$PATH" SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
comparison_processes=$(wc -l < "$PROCESS_LOG" | tr -d ' ')
echo "  no-drift check over 1000+ tracked files started $comparison_processes cmp or git process(es) (budget $DRIFT_CHECK_PROCESS_BUDGET)"
check "the no-drift check does not start a process per tracked file" test "$comparison_processes" -lt "$DRIFT_CHECK_PROCESS_BUDGET"
check "the batched check still finds no drift" bash -c '! grep -qF "changed or missing file(s)" <<<"$1"' _ "$(context)"
printf 'edited live\n' > "$FAKE/.claude/bulk/file500.md"; rm -f "$FAKE/.claude/bulk/file501.md"
OUT=$(printf '{}' | SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "the batched check counts an edited and a missing file" reports "synced 2 changed or missing file(s)"
check "the batched check's sync repairs both" bash -c 'cmp -s "$1/claude/bulk/file500.md" "$2/.claude/bulk/file500.md" && test -f "$2/.claude/bulk/file501.md"' _ "$CO" "$FAKE"

# 3g. When the batch hash fails, the per-pair fallback still finds exactly the
# drift there is (Copilot review on #67). A git wrapper on PATH fails every
# hash-object call and passes everything else through, so the fallback is the
# only comparison that runs: it must count one edited file as one, repair it,
# and report nothing once the trees match again.
FAILING_HASH_BIN="$SB/failing-hash-bin"; mkdir -p "$FAILING_HASH_BIN"
printf '#!/usr/bin/env bash\ncase " $* " in *" hash-object "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$FAILING_HASH_BIN/git"
chmod +x "$FAILING_HASH_BIN/git"
printf 'edited live again\n' > "$FAKE/.claude/bulk/file42.md"
OUT=$(printf '{}' | PATH="$FAILING_HASH_BIN:$PATH" SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "the fallback counts the one edited file" reports "synced 1 changed or missing file(s)"
check "the fallback's sync repairs it" cmp -s "$CO/claude/bulk/file42.md" "$FAKE/.claude/bulk/file42.md"
OUT=$(printf '{}' | PATH="$FAILING_HASH_BIN:$PATH" SYNC_NPM="$STUB_NPM" bash "$HOOK" 2>/dev/null)
check "the fallback finds no drift in matching trees" bash -c '! grep -qF "changed or missing file(s)" <<<"$1"' _ "$(context)"

# 3h. A live home whose path contains a newline is compared correctly (Copilot
# review on #67). The batch passes paths to git one per line, so an absolute
# path with a newline in it would split, every pair would look drifted, and
# every SessionStart would run a full sync. The home is bootstrapped once;
# the next run must find nothing to sync.
NEWLINE_HOME="$SB/home with
newline"
mkdir -p "$NEWLINE_HOME"
OUT=$(printf '{}' | HARNESS_SYNC_HOME="$NEWLINE_HOME" SYNC_CURSOR_HOME="$NEWLINE_HOME/.cursor" SYNC_CODEX_HOME="$NEWLINE_HOME/.codex" SYNC_NPM="$STUB_NPM" bash "$HOOK" "$CO" 2>/dev/null)
check "a newline home is bootstrapped" test -f "$NEWLINE_HOME/.claude/bulk/file1.md"
OUT=$(printf '{}' | HARNESS_SYNC_HOME="$NEWLINE_HOME" SYNC_CURSOR_HOME="$NEWLINE_HOME/.cursor" SYNC_CODEX_HOME="$NEWLINE_HOME/.codex" SYNC_NPM="$STUB_NPM" bash "$HOOK" "$CO" 2>/dev/null)
check "a newline home in sync is not drift" bash -c '! grep -qF "changed or missing file(s)" <<<"$1"' _ "$(context)"

# 3i. A tracked name that git quotes (a tab, a newline, a double quote) is
# never silently left out of the drift check (Copilot review on #67). Without
# -z, `git ls-files` prints such a name C-quoted, so it matches no payload
# prefix; the check counts it as drift rather than skipping it, the same
# answer the per-file loop gave. A separate sandbox keeps the quoted name away
# from the cases above.
QUOTED_CO="$SB/quoted-checkout"; mkdir -p "$QUOTED_CO/claude"; QUOTED_CO=$(cd "$QUOTED_CO" && pwd -P)
QUOTED_HOME="$SB/quoted-home"; mkdir -p "$QUOTED_HOME"
git -C "$QUOTED_CO" init -q -b main
git -C "$QUOTED_CO" config user.email t@example.invalid; git -C "$QUOTED_CO" config user.name t
cp "$REAL_SYNC" "$QUOTED_CO/sync.sh"; chmod +x "$QUOTED_CO/sync.sh"
printf '# rules\n' > "$QUOTED_CO/claude/CLAUDE.md"
printf 'tabbed\n' > "$QUOTED_CO/claude/tab$(printf '\t')name.md"
git -C "$QUOTED_CO" add -A; git -C "$QUOTED_CO" commit -qm init
quoted_run() { printf '{}' | HARNESS_SYNC_HOME="$QUOTED_HOME" SYNC_CURSOR_HOME="$QUOTED_HOME/.cursor" SYNC_CODEX_HOME="$QUOTED_HOME/.codex" bash "$HOOK" "$QUOTED_CO" 2>/dev/null; }
quoted_run >/dev/null
mkdir -p "$QUOTED_HOME/.claude"; cp "$QUOTED_CO/claude/CLAUDE.md" "$QUOTED_HOME/.claude/CLAUDE.md"
printf 'tabbed\n' > "$QUOTED_HOME/.claude/tab$(printf '\t')name.md"
OUT=$(quoted_run)
check "a git-quoted tracked name is not silently skipped" reports "harness-sync (R-003)"

# 4. No reachable checkout: silent locally, one report remotely.
rm -rf "$FAKE/.claude"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "no checkout is silent locally" silent
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" 2>/dev/null)
check "no checkout reported remotely" reports "runs WITHOUT the synced harness"
check "no checkout writes nothing" test ! -e "$FAKE/.claude"

# 5. A sync.sh refusal (invalid JSON in the checkout) is reported, live tree untouched.
printf '{"hooks":' > "$CO/claude/settings.json"; git -C "$CO" commit -qam "break json"
OUT=$(printf '{}' | bash "$HOOK" "$CO" 2>/dev/null)
check "sync refusal reported" reports "sync.sh failed"
check "sync refusal leaves the live tree absent" test ! -e "$FAKE/.claude/CLAUDE.md"

[ "$fail" -eq 0 ] && echo "harness-sync.test.sh PASS"
exit "$fail"
