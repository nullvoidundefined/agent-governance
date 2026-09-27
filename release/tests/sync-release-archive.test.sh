#!/usr/bin/env bash
# sync-release-archive.test.sh: verifies sync.sh installs from an extracted
# release archive through RELEASE-FILES when its directory is not its own git
# checkout, refuses with every target untouched when the list is missing or
# unsafe, and keeps using git ls-files in a real checkout (IAN-478). Targets
# are temp dirs via the SYNC_*_HOME overrides.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# makeExtract(dir): a release-archive-shaped tree with one file per payload,
# one unlisted file, and a valid RELEASE-FILES.
makeExtract() {
  local dir="$1"
  mkdir -p "$dir/claude/hooks" "$dir/cursor" "$dir/codex"
  cp "$REPO_ROOT/sync.sh" "$dir/sync.sh"
  echo "rule" > "$dir/claude/CLAUDE.md"
  echo "hook" > "$dir/claude/hooks/guard.sh"
  echo "cursor rule" > "$dir/cursor/rules.md"
  echo "codex rule" > "$dir/codex/AGENTS.md"
  echo "not listed" > "$dir/claude/unlisted.md"
  printf '%s\n' claude/CLAUDE.md claude/hooks/guard.sh codex/AGENTS.md cursor/rules.md sync.sh > "$dir/RELEASE-FILES"
}

# runSyncFrom(sourceDir, liveDir): runs that tree's sync.sh into liveDir/{claude,cursor,codex}.
runSyncFrom() {
  SYNC_CLAUDE_HOME="$2/claude" SYNC_CURSOR_HOME="$2/cursor" SYNC_CODEX_HOME="$2/codex" bash "$1/sync.sh"
}

# assertTargetsAbsent(liveDir, label): no target folder was created.
assertTargetsAbsent() {
  [ ! -e "$1/claude" ] && [ ! -e "$1/cursor" ] && [ ! -e "$1/codex" ] || fail "$2: a target was written despite the refusal"
}

# --- B-1: an extract with a valid list installs exactly the listed files.
makeExtract "$TMP/b1"
runSyncFrom "$TMP/b1" "$TMP/live-b1" > "$TMP/b1.out" 2>&1 || { cat "$TMP/b1.out"; fail "B-1: sync from an extract exited nonzero"; }
grep -q "source: release archive RELEASE-FILES" "$TMP/b1.out" || fail "B-1: sync did not name the release-archive source"
diff "$TMP/b1/claude/hooks/guard.sh" "$TMP/live-b1/claude/hooks/guard.sh" >/dev/null || fail "B-1: a listed claude file was not installed"
[ -f "$TMP/live-b1/cursor/rules.md" ] || fail "B-1: the listed cursor file was not installed"
[ -f "$TMP/live-b1/codex/AGENTS.md" ] || fail "B-1: the listed codex file was not installed"
[ ! -e "$TMP/live-b1/claude/unlisted.md" ] || fail "B-1: a file absent from RELEASE-FILES was installed"

# --- B-1b: an extract untarred inside another git repository still uses its
# own list, because that repository's ls-files names none of these files.
mkdir -p "$TMP/outer"; git -C "$TMP/outer" init -q
makeExtract "$TMP/outer/agent-governance-v0.1.0"
runSyncFrom "$TMP/outer/agent-governance-v0.1.0" "$TMP/live-b1b" > "$TMP/b1b.out" 2>&1 || { cat "$TMP/b1b.out"; fail "B-1b: sync from a nested extract exited nonzero"; }
[ -f "$TMP/live-b1b/claude/CLAUDE.md" ] || fail "B-1b: an extract inside another git repo installed nothing"

# --- B-2: no git checkout and no list refuses and touches nothing.
makeExtract "$TMP/b2"; rm "$TMP/b2/RELEASE-FILES"
if runSyncFrom "$TMP/b2" "$TMP/live-b2" > "$TMP/b2.out" 2>&1; then fail "B-2: sync ran with neither git nor RELEASE-FILES"; fi
grep -q "REFUSED: .* neither a git checkout nor a release archive" "$TMP/b2.out" || { cat "$TMP/b2.out"; fail "B-2: the refusal did not name the missing source"; }
assertTargetsAbsent "$TMP/live-b2" "B-2"

# --- B-3: each unsafe list entry refuses the whole run. The bad entry is the
# last line with no trailing newline, so an unterminated final line is read.
caseNumber=0
for bad in "/etc/passwd" "claude/../../escape" "" "claude/missing.md"; do
  caseNumber=$((caseNumber + 1))
  label="B-3 entry '$bad'"
  dir="$TMP/b3-$caseNumber"; makeExtract "$dir"
  printf '%s' "$bad" >> "$dir/RELEASE-FILES"
  [ -n "$bad" ] || printf '\n\n' >> "$dir/RELEASE-FILES"
  if runSyncFrom "$dir" "$dir-live" > "$dir.out" 2>&1; then fail "$label: sync accepted an unsafe list"; fi
  grep -q "REFUSED: RELEASE-FILES" "$dir.out" || { cat "$dir.out"; fail "$label: no RELEASE-FILES refusal"; }
  assertTargetsAbsent "$dir-live" "$label"
done

# --- B-3b (security review #6): a listed symlink whose target leaves the
# extract refuses the run; a symlink that stays inside it installs as a link.
caseNumber=0
for escapingTarget in "/etc/passwd" "../../../../outside" "../missing-dir/x"; do
  caseNumber=$((caseNumber + 1))
  label="B-3b symlink to '$escapingTarget'"
  dir="$TMP/b3b-$caseNumber"; makeExtract "$dir"
  ln -s "$escapingTarget" "$dir/claude/escape.md"
  printf '%s\n' claude/escape.md >> "$dir/RELEASE-FILES"
  if runSyncFrom "$dir" "$dir-live" > "$dir.out" 2>&1; then fail "$label: sync accepted an escaping symlink"; fi
  grep -q "REFUSED: RELEASE-FILES" "$dir.out" || { cat "$dir.out"; fail "$label: no RELEASE-FILES refusal"; }
  assertTargetsAbsent "$dir-live" "$label"
done
makeExtract "$TMP/b3b-inside"
ln -s CLAUDE.md "$TMP/b3b-inside/claude/alias.md"
printf '%s\n' claude/alias.md >> "$TMP/b3b-inside/RELEASE-FILES"
runSyncFrom "$TMP/b3b-inside" "$TMP/live-b3b-inside" > "$TMP/b3b-inside.out" 2>&1 || { cat "$TMP/b3b-inside.out"; fail "B-3b: a symlink inside the extract was refused"; }
[ "$(readlink "$TMP/live-b3b-inside/claude/alias.md")" = "CLAUDE.md" ] || fail "B-3b: an inside symlink was not installed as a link"

# --- B-3c (security review round 2, finding 1): a listed file reached
# through an unlisted directory symlink refuses the run, wherever that
# directory symlink points: absolute, or relative and climbing out.
mkdir -p "$TMP/outside-dir"; echo "outside" > "$TMP/outside-dir/secret.txt"
caseNumber=0
for directoryTarget in "$TMP/outside-dir" "../../outside-dir"; do
  caseNumber=$((caseNumber + 1))
  label="B-3c entry under a directory symlink to '$directoryTarget'"
  dir="$TMP/b3c-$caseNumber"; makeExtract "$dir"
  ln -s "$directoryTarget" "$dir/claude/linked"
  [ -f "$dir/claude/linked/secret.txt" ] || fail "$label: the fixture's directory symlink does not resolve"
  printf '%s\n' "claude/linked/secret.txt" >> "$dir/RELEASE-FILES"
  if runSyncFrom "$dir" "$dir-live" > "$dir.out" 2>&1; then fail "$label: sync accepted a path through a directory symlink"; fi
  grep -q "REFUSED: RELEASE-FILES" "$dir.out" || { cat "$dir.out"; fail "$label: no RELEASE-FILES refusal"; }
  assertTargetsAbsent "$dir-live" "$label"
done

# --- B-4: a directory holding both .git and RELEASE-FILES is ambiguous, and
# git mode would skip every list check, so it refuses and touches nothing.
# That holds for a real checkout with a stray list and for an archive that
# ships its own .git; a checkout without the list still uses git ls-files.
makeExtract "$TMP/b4"
git -C "$TMP/b4" init -q
git -C "$TMP/b4" -c user.email=t@example.com -c user.name=t add claude/CLAUDE.md cursor codex sync.sh
git -C "$TMP/b4" -c user.email=t@example.com -c user.name=t commit -q -m fixture
if runSyncFrom "$TMP/b4" "$TMP/live-b4" > "$TMP/b4.out" 2>&1; then fail "B-4: a checkout holding RELEASE-FILES was synced"; fi
grep -q "REFUSED: .*both .git and RELEASE-FILES" "$TMP/b4.out" || { cat "$TMP/b4.out"; fail "B-4: the refusal did not name the ambiguity"; }
assertTargetsAbsent "$TMP/live-b4" "B-4 checkout"

makeExtract "$TMP/b4-shipped"
mkdir "$TMP/b4-shipped/.git"
if runSyncFrom "$TMP/b4-shipped" "$TMP/live-b4-shipped" > "$TMP/b4-shipped.out" 2>&1; then fail "B-4: an archive shipping .git was synced"; fi
grep -q "REFUSED: .*both .git and RELEASE-FILES" "$TMP/b4-shipped.out" || { cat "$TMP/b4-shipped.out"; fail "B-4: the shipped-.git refusal did not name the ambiguity"; }
assertTargetsAbsent "$TMP/live-b4-shipped" "B-4 shipped .git"

rm "$TMP/b4/RELEASE-FILES"
runSyncFrom "$TMP/b4" "$TMP/live-b4-clean" > "$TMP/b4-clean.out" 2>&1 || { cat "$TMP/b4-clean.out"; fail "B-4: a clean checkout exited nonzero"; }
grep -q "source: git checkout" "$TMP/b4-clean.out" || fail "B-4: a clean checkout did not use git ls-files"
[ ! -e "$TMP/live-b4-clean/claude/hooks/guard.sh" ] || fail "B-4: an untracked file was installed from a checkout"

echo "sync-release-archive.test.sh PASS"
