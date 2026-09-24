#!/usr/bin/env bash
# Shard: slow
# Verifies that `tdd.sh abandon` reads the lock's mtime correctly under GNU
# stat (R-412). GNU `stat -f` means file-system status and exits 0, so a BSD
# `stat -f %m` tried first returns something other than the mtime on Linux,
# and a fresh lock read as stale (CI on PR #125). A stub on PATH behaves as
# GNU stat does, so the fixture reproduces on macOS as well.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"
export CLAUDE_TDD_HOME="$CLAUDE_HARNESS_ROOT"
STUB_DIR=$(cd "$(mktemp -d)" && pwd -P)
export CLAUDE_TDD_ABANDON_LOG="$STUB_DIR/tdd-abandon.jsonl"

# GNU-shaped stat: `-c %Y` prints the mtime, `-f` prints file-system data.
cat > "$STUB_DIR/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -c ] && [ "$2" = %Y ]; then date -r "$3" +%s; exit 0; fi
if [ "$1" = -f ]; then printf '?\n'; exit 0; fi
exit 1
EOF
chmod +x "$STUB_DIR/stat"

P=$(cd "$(mktemp -d)" && pwd -P)
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
mkdir -p "$P/tests" "$P/scripts"
printf '.claude/tdd-lock.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\necho "baseline PASS"\n' > "$P/tests/baseline.test.sh"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

bash "$TDD" open "G-1 score.sh prints 2" >/dev/null
printf '#!/usr/bin/env bash\nset -euo pipefail\nout=$(bash "$(dirname "$0")/../scripts/score.sh")\n[ "$out" = 2 ] || { echo "FAIL: expected 2, got $out"; exit 1; }\necho "score.test.sh PASS"\n' > tests/score.test.sh
bash "$TDD" red tests/score.test.sh >/dev/null
printf '#!/usr/bin/env bash\necho 2\n' > scripts/score.sh
git add -A && git commit -qm "feat: score prints 2"

if out=$(PATH="$STUB_DIR:$PATH" bash "$TDD" abandon 2>&1); then
  echo "FAIL: a lock written seconds ago must not be abandoned under GNU stat; got: $out"; exit 1
fi
grep -q 'hours' <<< "$out" || { echo "FAIL: the refusal must name the stale window; got: $out"; exit 1; }

cd /; rm -rf "$P" "$STUB_DIR"
echo "tdd-abandon-gnu-stat.test.sh PASS"
