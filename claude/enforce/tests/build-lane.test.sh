#!/usr/bin/env bash
# build-lane.test.sh: verifies skills/build-fast/scripts/build-lane.sh, the
# build-fast lane classifier (spec 2026-09-27-build-fast-design.md, IAN-401).
#
# Fixture: every case runs inside a sandbox repository built by newOriginRepo.
# That helper creates a bare origin on main, a clone holding one commit on main
# that is pushed, origin/HEAD pointed at main with `git remote set-head`, and a
# feature branch feat/x carrying one commit that adds docs/a.md. commitFile
# writes and commits one file in a given repository. A stub `gh` that reports
# no pull request sits first on PATH so no case reaches the network. The rules
# file is supplied through BUILD_LANE_RULES.
#
# B-1 (criterion 1): an invalid lane-rules file (missing, not JSON, no
# guardedPaths key, an empty list, a non-string entry, a pattern grep -E
# rejects) makes both `classify` and `predict` print exactly one line starting
# `guarded config-failure:` and exit 0, so the lane fails closed.
#
# B-2 (criteria 2 to 5, plus the plan's Review Focus cases): with the default
# rules file, `classify` prints `fast clear: <n> files` for a docs-only,
# README-only, or space-in-path range, and `guarded path: <path>` for a
# migrations/, workers/, billing, or uppercase Billing path and for a range
# that only deletes a migration; a content-pattern line prints `guarded
# security-surface: <first hit>`; no Semgrep and a Semgrep past the deadline
# print `guarded detector-failure:` (the latter leaving TMPDIR empty); a base
# or head naming no commit, a repository with no origin, and a directory
# outside any repository print `guarded range-failure:`; the default base comes
# from origin/<PR baseRefName> or origin/HEAD, never a stale local main. The
# ledger's laneOverride raises or lowers the lane with its suffixes, is ignored
# for another branch or an empty ledger, and never lowers a detector, range,
# or config failure. `predict` maps a scope glob to `guarded path: predicted`,
# `guarded security-surface: predicted`, or `fast predicted`.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
LANE="$CLAUDE_HARNESS_ROOT/skills/build-fast/scripts/build-lane.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home/.claude"; export HOME="$SB/home"
mkdir -p "$SB/bin"
printf '#!/usr/bin/env bash\necho "no pull requests found" >&2\nexit 1\n' > "$SB/bin/gh"
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH"

# commitFile <repo> <path> <content>: writes <content> to <path> inside <repo>
# (creating parent directories) and commits it on the current branch.
commitFile() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -qm "add $path"
}

# newOriginRepo <name>: builds $SB/<name>.git (bare origin on main) and
# $SB/<name> (a clone with main pushed, origin/HEAD set to main, and feat/x
# checked out holding one commit that adds docs/a.md).
newOriginRepo() {
  local name="$1"
  local origin="$SB/$name.git" repo="$SB/$name"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$repo" 2>/dev/null
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -B main
  commitFile "$repo" README.md "fixture"
  git -C "$repo" push -q origin main 2>/dev/null
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout -q -b feat/x
  commitFile "$repo" docs/a.md "a"
}

# ---- B-1: invalid lane rules fail closed ----------------------------------

newOriginRepo rules
REPO="$SB/rules"
RULES_DIR="$SB/rules-files"; mkdir -p "$RULES_DIR"
printf 'this is { not json\n' > "$RULES_DIR/not-json.json"
printf '{"otherKey": ["\\\\.sql$"]}\n' > "$RULES_DIR/missing-key.json"
printf '{"guardedPaths": []}\n' > "$RULES_DIR/empty-list.json"
printf '{"guardedPaths": ["\\\\.sql$", 1]}\n' > "$RULES_DIR/non-string.json"
printf '{"guardedPaths": ["\\\\.sql$", "(unclosed"]}\n' > "$RULES_DIR/bad-pattern.json"

# assertConfigFailure <case label> <rules path> <command args...>: runs the
# classifier with BUILD_LANE_RULES=<rules path> inside the fixture repo and
# checks exit 0, exactly one stdout line, and the config-failure prefix.
assertConfigFailure() {
  local label="$1" rules="$2"; shift 2
  local out st lineCount
  out=$(cd "$REPO" && BUILD_LANE_RULES="$rules" bash "$LANE" "$@" 2>/dev/null); st=$?
  lineCount=$(printf '%s' "$out" | awk 'END { print NR }')
  check "$label: $1 exits 0" test "$st" -eq 0
  check "$label: $1 prints exactly one line" test "$lineCount" -eq 1
  check "$label: $1 prints guarded config-failure" \
    bash -c 'case "$0" in "guarded config-failure:"*) exit 0 ;; *) exit 1 ;; esac' "$out"
}

for rulesCase in missing not-json missing-key empty-list non-string bad-pattern; do
  rulesPath="$RULES_DIR/$rulesCase.json"
  assertConfigFailure "rules $rulesCase" "$rulesPath" classify
  assertConfigFailure "rules $rulesCase" "$rulesPath" predict 'docs/*.md'
done

check "missing rules file really is absent" test ! -e "$RULES_DIR/missing.json"

# ---- B-2: classify, predict, and the lane override ------------------------
#
# Every case below uses the default rules file (skills/build-fast/lane-rules.json)
# and the checkout's real enforce/security-surface.json, which the detector in
# hooks/security-surface.sh reads. CLEAN_STUB stands in for Semgrep in every
# case with a code file, reporting a complete scan with no findings, so the
# path and content triggers are each observed alone.
unset BUILD_LANE_RULES CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS

CLEAN_STUB="$SB/clean-semgrep"
# Reports a complete clean scan the way real Semgrep does: every target it was
# given is listed under paths.scanned (copied from security-surface.test.sh).
cat > "$CLEAN_STUB" <<'STUB'
#!/bin/sh
skip_next=0
targets=""
for argument in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$argument" in
    --config) skip_next=1 ;;
    --*) ;;
    *) targets="$targets$argument
" ;;
  esac
done
printf '%s' "$targets" | jq -R . | jq -sc '{results: [], errors: [], paths: {scanned: .}}'
exit 0
STUB
chmod +x "$CLEAN_STUB"
export CLAUDE_SEMGREP_CMD="$CLEAN_STUB"

# A Semgrep stand-in that never finishes inside a one-second deadline.
SLOW_STUB="$SB/slow-semgrep"
printf '#!/bin/sh\nsleep 30\n' > "$SLOW_STUB"
chmod +x "$SLOW_STUB"

# A PATH carrying only bash, git, jq, and mktemp plus the system dirs, so
# neither semgrep nor uvx resolves on it (the BARE_PATH technique of
# security-surface.test.sh).
TOOLS_DIR="$SB/tools"
mkdir -p "$TOOLS_DIR"
ln -s "$(command -v bash)" "$TOOLS_DIR/bash"
ln -s "$(command -v git)" "$TOOLS_DIR/git"
ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
ln -s "$(command -v mktemp)" "$TOOLS_DIR/mktemp"
BARE_PATH="$TOOLS_DIR:/usr/bin:/bin"
semgrepAbsentOnBarePath() {
  ! PATH="$BARE_PATH" command -v semgrep >/dev/null 2>&1 && ! PATH="$BARE_PATH" command -v uvx >/dev/null 2>&1
}
check "precondition: neither semgrep nor uvx resolves on $BARE_PATH" semgrepAbsentOnBarePath

# runLane <repo> <command args...>: runs the classifier from inside <repo>
# with the default rules file; sets OUT (stdout), ST (exit status), and
# OUT_LINES (stdout line count). Variables assigned before the call reach the
# classifier's environment.
runLane() {
  local repo="$1"; shift
  OUT=$(cd "$repo" && bash "$LANE" "$@" 2>/dev/null); ST=$?
  OUT_LINES=$(printf '%s' "$OUT" | awk 'END { print NR }')
}

# runLaneWithoutSemgrep <repo> <command args...>: runLane with
# CLAUDE_SEMGREP_CMD unset and PATH set to BARE_PATH, so no Semgrep resolves.
runLaneWithoutSemgrep() {
  local resultFile="$SB/without-semgrep.out"
  (
    unset CLAUDE_SEMGREP_CMD
    PATH="$BARE_PATH" runLane "$@"
    printf '%s\n%s\n%s\n' "$ST" "$OUT_LINES" "$OUT"
  ) > "$resultFile"
  ST=$(sed -n 1p "$resultFile"); OUT_LINES=$(sed -n 2p "$resultFile"); OUT=$(sed -n '3,$p' "$resultFile")
}

# startsWith <text> <prefix>: literal prefix test (no glob in the prefix).
startsWith() { [ "${1#"$2"}" != "$1" ]; }

# assertOneLine <label>: the last runLane exited 0 and printed exactly one line.
assertOneLine() {
  check "$1: exits 0" test "$ST" -eq 0
  check "$1: prints exactly one line (got: $OUT)" test "$OUT_LINES" -eq 1
}

# assertLine <label> <expected line>: exit 0, one line, and that exact line.
assertLine() {
  assertOneLine "$1"
  check "$1: prints '$2' (got: $OUT)" test "$OUT" = "$2"
}

# assertPrefix <label> <expected prefix>: exit 0, one line, starting with it.
assertPrefix() {
  assertOneLine "$1"
  check "$1: starts with '$2' (got: $OUT)" startsWith "$OUT" "$2"
}

# assertSuffix <label> <expected suffix>: the last output ends with it.
assertSuffix() {
  check "$1: ends with '$2' (got: $OUT)" test "${OUT%"$2"}" != "$OUT"
}

# writeLedger <repo> <branch> <laneOverride>: writes the checkout's
# .claude/task-tier.json naming <branch> with that lane override.
writeLedger() {
  mkdir -p "$1/.claude"
  jq -n --arg b "$2" --arg o "$3" \
    '{tier: "standard", reason: "r", branch: $b, ticket: "IAN-401", laneOverride: $o}' > "$1/.claude/task-tier.json"
}

# newFeatureBranch <repo> <branch>: checks out a new branch from local main,
# which newOriginRepo leaves equal to origin/main.
newFeatureBranch() {
  git -C "$1" checkout -q -b "$2" main
}

# ---- B-2 classify paths (criterion 2) and Review Focus 1 to 3 --------------

newOriginRepo clear
CLEAR="$SB/clear"
runLane "$CLEAR" classify
assertLine "docs-only range on the default base" "fast clear: 1 files"

newFeatureBranch "$CLEAR" feat/readme
commitFile "$CLEAR" README.md "a changed readme"
runLane "$CLEAR" classify
assertLine "README-only range" "fast clear: 1 files"

newFeatureBranch "$CLEAR" feat/spaced
commitFile "$CLEAR" "docs/my notes.md" "notes"
runLane "$CLEAR" classify
assertLine "a path containing a space" "fast clear: 1 files"

newOriginRepo paths
PATHS="$SB/paths"
# assertGuardedPath <branch> <path> <content>: commits <path> on a new branch
# off main and expects `guarded path: <path>`.
assertGuardedPath() {
  newFeatureBranch "$PATHS" "$1"
  commitFile "$PATHS" "$2" "$3"
  runLane "$PATHS" classify
  assertLine "guarded path $2" "guarded path: $2"
}
assertGuardedPath feat/migration migrations/0001_create_orders.txt "create orders"
assertGuardedPath feat/worker workers/sync.ts "export const syncCount = 1;"
assertGuardedPath feat/billing src/billing/charge.ts "export const chargeCount = 1;"
assertGuardedPath feat/upper src/Billing/Invoice.ts "export const invoiceCount = 1;"

# Review Focus 3: a range whose only change deletes a migrations/ file.
newOriginRepo deleted
DELETED="$SB/deleted"
git -C "$DELETED" checkout -q main
commitFile "$DELETED" migrations/0001_create_orders.txt "create orders"
git -C "$DELETED" push -q origin main 2>/dev/null
git -C "$DELETED" checkout -q -b feat/drop main
git -C "$DELETED" rm -q migrations/0001_create_orders.txt
git -C "$DELETED" commit -qm "drop migration"
runLane "$DELETED" classify
assertLine "a range deleting a migrations/ file" "guarded path: migrations/0001_create_orders.txt"

# ---- B-2 range: explicit and default head, unresolvable base ---------------

newOriginRepo heads
HEADS="$SB/heads"
docsOnlyHead=$(git -C "$HEADS" rev-parse HEAD)
commitFile "$HEADS" migrations/0002_add_index.txt "add index"
runLane "$HEADS" classify
assertLine "default HEAD classifies HEAD's range" "guarded path: migrations/0002_add_index.txt"
runLane "$HEADS" classify --head "$docsOnlyHead"
assertLine "explicit --head classifies its own range" "fast clear: 1 files"
runLane "$HEADS" classify --base "$docsOnlyHead"
assertLine "explicit --base classifies its own range" "guarded path: migrations/0002_add_index.txt"

runLane "$HEADS" classify --base 0123456789abcdef0123456789abcdef01234567
assertPrefix "a base naming no commit" "guarded range-failure:"
runLane "$HEADS" classify --head 0123456789abcdef0123456789abcdef01234567
assertPrefix "a head naming no commit" "guarded range-failure:"

NO_ORIGIN="$SB/no-origin"
git init -q -b main "$NO_ORIGIN"
git -C "$NO_ORIGIN" config user.email t@example.invalid
git -C "$NO_ORIGIN" config user.name t
commitFile "$NO_ORIGIN" README.md "fixture"
git -C "$NO_ORIGIN" checkout -q -b feat/x
commitFile "$NO_ORIGIN" docs/a.md "a"
runLane "$NO_ORIGIN" classify
assertPrefix "no origin to take a default base from (local main is never used)" "guarded range-failure:"

# Review Focus 4: outside any git repository.
NOT_REPO="$SB/not-a-repo"; mkdir -p "$NOT_REPO"
GIT_CEILING_DIRECTORIES="$(cd "$SB" && pwd -P)" runLane "$NOT_REPO" classify
assertPrefix "classify outside any git repository" "guarded range-failure:"

# ---- B-2 range (criterion 3): stale local main, current origin/main --------

newOriginRepo stale
STALE="$SB/stale"
git clone -q "$SB/stale.git" "$SB/stale-other" 2>/dev/null
git -C "$SB/stale-other" config user.email t@example.invalid
git -C "$SB/stale-other" config user.name t
git -C "$SB/stale-other" checkout -q main
commitFile "$SB/stale-other" migrations/0003_add_totals.txt "add totals"
git -C "$SB/stale-other" push -q origin main 2>/dev/null
git -C "$STALE" fetch -q origin
git -C "$STALE" rebase -q origin/main 2>/dev/null
localMainIsStale() {
  [ "$(git -C "$STALE" rev-parse main)" != "$(git -C "$STALE" rev-parse origin/main)" ] \
    && git -C "$STALE" merge-base --is-ancestor origin/main HEAD
}
check "precondition: local main is stale and feat/x sits on origin/main" localMainIsStale
runLane "$STALE" classify
assertLine "stale local main: the base comes from origin/main" "fast clear: 1 files"

# The PR's base branch wins over origin/HEAD when gh names it: origin/release
# carries a migration that origin/main lacks, and feat/y branches from
# release, so only a release base leaves a docs-only range.
newOriginRepo prbase
PRBASE="$SB/prbase"
git -C "$PRBASE" checkout -q -b release main
commitFile "$PRBASE" migrations/0004_release_only.txt "release only"
git -C "$PRBASE" push -q origin release 2>/dev/null
git -C "$PRBASE" checkout -q -b feat/y release
commitFile "$PRBASE" docs/b.md "b"
PR_BIN="$SB/pr-bin"; mkdir -p "$PR_BIN"
# A gh stand-in whose `pr view` names release as the PR's base branch, as
# plain text under --jq or -q and as JSON otherwise.
cat > "$PR_BIN/gh" <<'STUB'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in --jq|-q|--jq=*) echo release; exit 0 ;; esac
done
echo '{"baseRefName":"release"}'
STUB
chmod +x "$PR_BIN/gh"
PATH="$PR_BIN:$PATH" runLane "$PRBASE" classify
assertLine "the PR's baseRefName sets the base" "fast clear: 1 files"

# ---- B-2 security (criterion 2) --------------------------------------------

newOriginRepo security
SECURITY="$SB/security"
newFeatureBranch "$SECURITY" feat/content
commitFile "$SECURITY" docs/deploy.md "app.add_middleware(CORSMiddleware)"
runLane "$SECURITY" classify
assertLine "a content-pattern line is the only security trigger" \
  "guarded security-surface: docs/deploy.md:1 content"

newFeatureBranch "$SECURITY" feat/nosemgrep
commitFile "$SECURITY" app/models.py "order_count = 1"
noSemgrepBase=$(git -C "$SECURITY" rev-parse main)
runLaneWithoutSemgrep "$SECURITY" classify --base "$noSemgrepBase"
assertPrefix "no Semgrep resolvable on a .py range" "guarded detector-failure:"

newFeatureBranch "$SECURITY" feat/slow
commitFile "$SECURITY" src/report.ts "export const reportCount = 1;"
DEADLINE_TMP="$SB/deadline-tmp"; mkdir -p "$DEADLINE_TMP"
deadlineStart=$SECONDS
CLAUDE_SEMGREP_CMD="$SLOW_STUB" CLAUDE_SECURITY_DETECTOR_TIMEOUT_SECONDS=1 TMPDIR="$DEADLINE_TMP" \
  runLane "$SECURITY" classify
deadlineElapsed=$((SECONDS - deadlineStart))
assertPrefix "a Semgrep sleeping past a one-second deadline" "guarded detector-failure:"
check "the deadline stops the run well before the 30s sleep (took ${deadlineElapsed}s)" test "$deadlineElapsed" -lt 20
deadlineTmpIsEmpty() { [ -z "$(ls -A "$DEADLINE_TMP")" ]; }
check "the timed-out detector leaves no work directory in TMPDIR" deadlineTmpIsEmpty

# ---- B-2 override (criterion 4) and Review Focus 5 -------------------------

git -C "$CLEAR" checkout -q feat/x
mkdir -p "$CLEAR/.claude"; : > "$CLEAR/.claude/task-tier.json"
runLane "$CLEAR" classify
assertLine "an empty ledger file is ignored" "fast clear: 1 files"

writeLedger "$CLEAR" feat/x guarded
runLane "$CLEAR" classify
assertLine "a raise from fast to guarded" "guarded clear: 1 files; override from fast"

writeLedger "$CLEAR" feat/other guarded
runLane "$CLEAR" classify
assertLine "an override on another branch's ledger is ignored" "fast clear: 1 files"
rm -f "$CLEAR/.claude/task-tier.json"

git -C "$SECURITY" checkout -q feat/content
writeLedger "$SECURITY" feat/content fast
runLane "$SECURITY" classify
assertLine "a lowered security-surface range" \
  "fast security-surface: docs/deploy.md:1 content; override from guarded; r109-required"

git -C "$PATHS" checkout -q feat/migration
writeLedger "$PATHS" feat/migration fast
runLane "$PATHS" classify
assertLine "a lowered path range" "fast path: migrations/0001_create_orders.txt; override from guarded"
rm -f "$PATHS/.claude/task-tier.json"

git -C "$SECURITY" checkout -q feat/nosemgrep
writeLedger "$SECURITY" feat/nosemgrep fast
runLaneWithoutSemgrep "$SECURITY" classify --base "$noSemgrepBase"
assertPrefix "a lower of a detector failure is refused" "guarded detector-failure:"
rm -f "$SECURITY/.claude/task-tier.json"

git -C "$HEADS" checkout -q feat/x
writeLedger "$HEADS" feat/x fast
runLane "$HEADS" classify --base 0123456789abcdef0123456789abcdef01234567
assertPrefix "a lower of a range failure is refused" "guarded range-failure:"
BUILD_LANE_RULES="$RULES_DIR/missing.json" runLane "$HEADS" classify
assertPrefix "a lower of a config failure is refused" "guarded config-failure:"
rm -f "$HEADS/.claude/task-tier.json"

# ---- B-2 predict (criterion 5) ---------------------------------------------

newOriginRepo predict
PREDICT="$SB/predict"
commitFile "$PREDICT" src/billing/charge.ts "export const chargeCount = 1;"
commitFile "$PREDICT" src/auth/login.ts "export const loginCount = 1;"
runLane "$PREDICT" predict 'src/billing/**'
assertPrefix "predict src/billing/**" "guarded path: predicted "
runLane "$PREDICT" predict README.md
assertLine "predict README.md" "fast predicted"
runLane "$PREDICT" predict 'src/payments/**'
assertPrefix "predict a glob matching no file yet tests the glob text" "guarded path: predicted "
runLane "$PREDICT" predict 'src/auth/**'
assertPrefix "predict src/auth/**" "guarded security-surface: predicted "
writeLedger "$PREDICT" feat/x fast
runLane "$PREDICT" predict 'src/auth/**'
assertPrefix "a lowered security-surface prediction" "fast security-surface: predicted "
assertSuffix "a lowered security-surface prediction" "; override from guarded; r109-required"
writeLedger "$PREDICT" feat/x guarded
runLane "$PREDICT" predict README.md
assertLine "a raised prediction" "guarded predicted; override from fast"
rm -f "$PREDICT/.claude/task-tier.json"

[ "$fail" -eq 0 ] || exit 1
echo "build-lane.test.sh PASS"
