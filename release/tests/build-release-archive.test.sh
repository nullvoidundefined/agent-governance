#!/usr/bin/env bash
# build-release-archive.test.sh: verifies the release archive for a tag
# excludes site/, carries a RELEASE-FILES equal to its contents, verifies
# against its checksum, rebuilds byte-identically, installs through sync.sh
# from the extract, and that bad or missing tags are refused (IAN-477).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A fixture repository shaped like this one: payload folders, a site/ that
# must not ship, the real sync.sh and packaging script, and a v1.2.3 tag.
FIX="$TMP/repo"
mkdir -p "$FIX/claude/hooks" "$FIX/cursor" "$FIX/codex" "$FIX/site/public" "$FIX/release"
cp "$REPO_ROOT/sync.sh" "$FIX/sync.sh"
cp "$REPO_ROOT/release/build-release-archive.sh" "$FIX/release/"
cp "$REPO_ROOT/.gitattributes" "$FIX/.gitattributes"
echo "rule" > "$FIX/claude/CLAUDE.md"
echo "hook" > "$FIX/claude/hooks/guard.sh"
ln -s CLAUDE.md "$FIX/claude/link.md"
echo "cursor" > "$FIX/cursor/rules.md"
echo "codex" > "$FIX/codex/AGENTS.md"
echo "<h1>site</h1>" > "$FIX/site/public/index.html"
git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@example.com -c user.name=t add -A
git -C "$FIX" -c user.email=t@example.com -c user.name=t commit -q -m fixture
git -C "$FIX" tag v1.2.3

OUT="$TMP/out"; mkdir -p "$OUT"
bash "$FIX/release/build-release-archive.sh" v1.2.3 "$OUT" > "$TMP/build.out" 2>&1 || { cat "$TMP/build.out"; fail "packaging v1.2.3 exited nonzero"; }
ARCHIVE="$OUT/agent-governance-v1.2.3.tar.gz"
[ -f "$ARCHIVE" ] || fail "no archive at $ARCHIVE"

# B-5: no site/ path, one top-level folder.
tar -tzf "$ARCHIVE" > "$TMP/listing"
if grep -q "^agent-governance-v1.2.3/site" "$TMP/listing"; then fail "B-5: the archive ships site/"; fi
[ "$(cut -d/ -f1 "$TMP/listing" | sort -u)" = "agent-governance-v1.2.3" ] || fail "B-5: the archive has more than one top-level folder"

# B-6: RELEASE-FILES equals the archive's files and symlinks, minus itself, sorted.
tar -xzf "$ARCHIVE" -C "$TMP"
EXTRACT="$TMP/agent-governance-v1.2.3"
(cd "$EXTRACT" && find . \( -type f -o -type l \) ! -path ./RELEASE-FILES | sed 's#^\./##' | LC_ALL=C sort) > "$TMP/expected-files"
diff "$TMP/expected-files" "$EXTRACT/RELEASE-FILES" > "$TMP/files.diff" || { cat "$TMP/files.diff"; fail "B-6: RELEASE-FILES differs from the archive contents"; }
grep -qx "claude/link.md" "$EXTRACT/RELEASE-FILES" || fail "B-6: a tracked symlink is missing from RELEASE-FILES"

# B-7: the checksum verifies, and a rebuild is byte-identical.
(cd "$OUT" && shasum -a 256 -c agent-governance-v1.2.3.tar.gz.sha256 >/dev/null) || fail "B-7: the checksum does not verify"
firstChecksum=$(shasum -a 256 < "$ARCHIVE")
bash "$FIX/release/build-release-archive.sh" v1.2.3 "$OUT" >/dev/null 2>&1
[ "$(shasum -a 256 < "$ARCHIVE")" = "$firstChecksum" ] || fail "B-7: two builds of one tag differ"

# B-8: the extract installs through sync.sh.
SYNC_CLAUDE_HOME="$TMP/live/claude" SYNC_CURSOR_HOME="$TMP/live/cursor" SYNC_CODEX_HOME="$TMP/live/codex" \
  bash "$EXTRACT/sync.sh" > "$TMP/sync.out" 2>&1 || { cat "$TMP/sync.out"; fail "B-8: sync.sh from the extract exited nonzero"; }
[ -f "$TMP/live/claude/hooks/guard.sh" ] || fail "B-8: the extract did not install claude/hooks/guard.sh"
[ -f "$TMP/live/codex/AGENTS.md" ] || fail "B-8: the extract did not install codex/AGENTS.md"

# B-9: a malformed tag and a missing tag are refused and write nothing.
caseNumber=0
for tag in "1.2.3" "v1.2" "v1.2.3-rc1" "v9.9.9"; do
  caseNumber=$((caseNumber + 1))
  emptyDir="$TMP/empty-$caseNumber"; mkdir -p "$emptyDir"
  if bash "$FIX/release/build-release-archive.sh" "$tag" "$emptyDir" > "$emptyDir.out" 2>&1; then fail "B-9: tag '$tag' was accepted"; fi
  grep -q "REFUSED:" "$emptyDir.out" || fail "B-9: tag '$tag' was not refused by name"
  [ -z "$(ls -A "$emptyDir")" ] || fail "B-9: tag '$tag' wrote into the output folder"
done

echo "build-release-archive.test.sh PASS"
