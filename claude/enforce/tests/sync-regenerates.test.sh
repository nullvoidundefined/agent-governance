#!/usr/bin/env bash
# Shard: slow
# Verifies sync.sh regenerates first (spec B-6). rules/ is the source of the
# generated claude/, codex/ and cursor/ trees, so sync.sh runs
# `node translate/all.mjs --write` before installing: an edit to rules/ that was
# never regenerated still reaches the install and the count is reported as
# "regenerated N files"; a source error stops the run before any target is
# written; a machine without node installs the committed trees after printing
# "node not found". It lives here rather than in sync-tests/sync.test.sh because
# the test-author role may not write that path; run-tests.sh runs it in CI.
# Every target is a temp dir via the SYNC_*_HOME overrides.
set -uo pipefail
REPO_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
for v in $(env | grep -o '^GIT_[A-Z_]*' || true); do unset "$v"; done
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

make_fixture() {
  local dst="$1"
  mkdir -p "$dst"
  git -C "$REPO_ROOT" ls-files -z -- rules translate claude codex cursor \
    | tar -C "$REPO_ROOT" --null -T - -cf - | tar -C "$dst" -xf -
  cp "$REPO_ROOT/sync.sh" "$dst/sync.sh"; chmod +x "$dst/sync.sh"
  git -C "$dst" init -q
  git -C "$dst" config user.email "test@example.com"
  git -C "$dst" config user.name "sync-test"
  git -C "$dst" add -A
  git -C "$dst" commit -q -m "fixture: tracked sources"
}
run_sync() { # $1 = fixture, $2 = live root
  SYNC_CLAUDE_HOME="$2/claude" SYNC_CURSOR_HOME="$2/cursor" SYNC_CODEX_HOME="$2/codex" "$1/sync.sh"
}
tree_hash() {
  (cd "$1" && find . -type f ! -name .sync-source | sort | while read -r f; do $SHA "$f"; done) | $SHA
}
die() { echo "FAIL: $1"; shift; [ $# -gt 0 ] && cat "$@"; exit 1; }

# Case 1: a rules/ edit that was not regenerated reaches the installed CLAUDE.md.
F1="$TMP/f1"; L1="$TMP/l1"
make_fixture "$F1"
printf '\nZZ-SYNC-REGEN-MARKER stays in the installed rules.\n' >> "$F1/rules/GLOBAL.md"
grep -q "ZZ-SYNC-REGEN-MARKER" "$F1/claude/CLAUDE.md" && die "fixture bug: committed CLAUDE.md already has the marker"
run_sync "$F1" "$L1" >"$TMP/1.out" 2>"$TMP/1.err" || die "sync failed on a fixture with a stale rules/ edit" "$TMP/1.out" "$TMP/1.err"
grep -q "ZZ-SYNC-REGEN-MARKER" "$L1/claude/CLAUDE.md" 2>/dev/null \
  || die "installed CLAUDE.md lacks the rules/GLOBAL.md edit (sync did not regenerate first)"
cat "$TMP/1.out" "$TMP/1.err" | grep -Eq 'regenerated [1-9][0-9]* files' \
  || die "sync did not report 'regenerated N files' with N > 0" "$TMP/1.out" "$TMP/1.err"
echo "PASS: stale rules/ edit is regenerated, installed and reported"

# Case 2: a malformed only: tag stops the run; installed files stay as they were.
F2="$TMP/f2"; L2="$TMP/l2"
make_fixture "$F2"
run_sync "$F2" "$L2" >/dev/null 2>&1 || die "clean fixture sync failed"
B1=$(tree_hash "$L2/claude"); B2=$(tree_hash "$L2/codex"); B3=$(tree_hash "$L2/cursor")
printf '\n<!-- only: Codex -->\nbroken\n<!-- /only -->\n' >> "$F2/rules/GLOBAL.md"
# A tracked edit that a run which ignored the error would install.
printf '\nZZ-SHOULD-NOT-INSTALL\n' >> "$F2/claude/README.md"
if run_sync "$F2" "$L2" >"$TMP/2.out" 2>"$TMP/2.err"; then die "sync exited 0 despite a malformed only: tag"; fi
[ "$B1" = "$(tree_hash "$L2/claude")" ] || die "installed claude files changed after a source error"
[ "$B2" = "$(tree_hash "$L2/codex")" ] || die "installed codex files changed after a source error"
[ "$B3" = "$(tree_hash "$L2/cursor")" ] || die "installed cursor files changed after a source error"
cat "$TMP/2.out" "$TMP/2.err" | grep -q "GLOBAL.md" || die "the source error does not name rules/GLOBAL.md" "$TMP/2.out" "$TMP/2.err"
echo "PASS: a source error exits nonzero and installs nothing"

# Case 3: no node on PATH. One warning, and the committed trees still install.
NOBIN="$TMP/nonode-bin"; mkdir -p "$NOBIN"
for tool in bash env git rsync jq awk sed grep find xargs sort cat cp mv mkdir rm rmdir dirname basename readlink mktemp tr head tail cut diff wc date sha256sum shasum chmod ln tee uname printf touch sleep comm uniq ls stat id realpath cmp; do
  t=$(command -v "$tool" 2>/dev/null || true)
  case "$t" in /*) ln -sf "$t" "$NOBIN/$tool" ;; esac
done
[ ! -e "$NOBIN/node" ] || die "fixture bug: node is on the stripped PATH"
F3="$TMP/f3"; L3="$TMP/l3"
make_fixture "$F3"
printf '\nZZ-SYNC-REGEN-MARKER stays in the installed rules.\n' >> "$F3/rules/GLOBAL.md"
PATH="$NOBIN" run_sync "$F3" "$L3" >"$TMP/3.out" 2>"$TMP/3.err" || die "sync aborted when node is absent" "$TMP/3.out" "$TMP/3.err"
cat "$TMP/3.out" "$TMP/3.err" | grep -q 'node not found' || die "sync did not print 'node not found' when node is absent" "$TMP/3.out" "$TMP/3.err"
diff "$F3/claude/CLAUDE.md" "$L3/claude/CLAUDE.md" >/dev/null 2>&1 || die "without node, the committed CLAUDE.md was not installed as is"
[ -f "$L3/codex/AGENTS.md" ] || die "without node, the codex tree was not installed"
echo "PASS: no node prints a warning and installs the committed trees"

echo "sync-regenerates.test.sh PASS"
