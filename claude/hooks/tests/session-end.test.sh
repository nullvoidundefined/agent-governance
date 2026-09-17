#!/usr/bin/env bash
# Test harness for session-end.sh rule-log routing.
#
# Runs the hook against a sandbox HOME so it reads a fake project memory
# dir and writes to throwaway logs. Covers the two bugs fixed in this
# change:
#   1. Hook must NOT embed the sanitized local cwd path in log entries
#      (it leaks a filesystem path into the public ~/.claude repo).
#   2. Dedupe must ignore the leading date, so the same fired:/miss:
#      line is not re-appended with a fresh date every session.
#
# Run: ~/.claude/hooks/tests/session-end.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../session-end.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PROJECT_TAG="-fake-project-path-that-must-not-leak"
MEM_DIR="$SANDBOX/.claude/projects/$PROJECT_TAG/memory"
mkdir -p "$MEM_DIR"
cat > "$MEM_DIR/feedback.md" <<'EOF'
fired: R-207 no-em-dash.sh blocked an Edit; replaced with colon
miss: R-102 leaked a value via sed; gap: codify compare-in-shell
EOF

FIRES="$SANDBOX/.claude/global-memory/rule_fires.md"
MISSES="$SANDBOX/.claude/global-memory/rule_misses.md"

# Pre-seed the fires log with an identical-content entry under an OLD
# date. A correct, date-insensitive dedupe must NOT add a second copy
# when the hook runs today.
mkdir -p "$SANDBOX/.claude/global-memory"
printf '# Rule fires log\n\nheader\n\n2020-01-01 R-207 no-em-dash.sh blocked an Edit; replaced with colon\n' > "$FIRES"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

# No stdin payload here: these two calls predate the B-8 snapshot writer
# and must keep working with nothing piped in. Explicit </dev/null keeps
# the fixture hermetic regardless of what stdin the test runner inherits.
HOME="$SANDBOX" bash "$HOOK" < /dev/null

no_tag()      { ! grep -q -- "$PROJECT_TAG" "$1"; }
has_line()    { grep -q -- "$2" "$1"; }
count_is()    { [ "$(grep -c -- "$2" "$1")" -eq "$3" ]; }

check "no local project-path tag in fires log"  no_tag "$FIRES"
check "no local project-path tag in misses log" no_tag "$MISSES"
check "fire entry was written"  has_line "$FIRES"  "R-207 no-em-dash.sh blocked an Edit"
check "miss entry was written"  has_line "$MISSES" "R-102 MISS leaked a value via sed"
check "fire not duplicated across dates" count_is "$FIRES" "no-em-dash.sh blocked an Edit" 1

# Running the hook a second time on the same day must also not duplicate.
HOME="$SANDBOX" bash "$HOOK" < /dev/null
check "fire not duplicated on re-run" count_is "$FIRES" "no-em-dash.sh blocked an Edit" 1
check "miss not duplicated on re-run" count_is "$MISSES" "R-102 MISS leaked a value via sed" 1

# --- Resume snapshot writer (B-8 write half) ---
#
# write_session_snapshot reads transcript_path and cwd off the SessionEnd
# stdin payload, hashes the files Write/Edit/NotebookEdit touched, and
# writes $HOME/.claude/projects/<key>/session-snapshot.json atomically.

file_exists()     { [ -f "$1" ]; }
no_file()         { [ ! -f "$1" ]; }
jq_true()         { jq -e "$2" "$1" >/dev/null 2>&1; }
exit_code_is()    { [ "$1" -eq "$2" ]; }

# Case 1: two Write entries, one file deleted before the hook runs. Asserts
# the sha256 hash for the survivor, "missing" for the deleted file, and the
# repo's real HEAD.
REPO="$SANDBOX/work-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test User"
echo "hello" > "$REPO/survivor.txt"
echo "bye" > "$REPO/deleted.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm seed
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
rm -f "$REPO/deleted.txt"

SNAP_KEY_DIR="$SANDBOX/.claude/projects/snapshot-project-key"
mkdir -p "$SNAP_KEY_DIR"
TRANSCRIPT="$SNAP_KEY_DIR/fake-session.jsonl"
cat > "$TRANSCRIPT" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"$REPO/survivor.txt","content":"hello"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"$REPO/deleted.txt","content":"bye"}}]}}
EOF

PAYLOAD=$(jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" '{transcript_path:$t, cwd:$c}')
printf '%s' "$PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"

SNAPSHOT="$SNAP_KEY_DIR/session-snapshot.json"
SURVIVOR_HASH=$(shasum -a 256 "$REPO/survivor.txt" | awk '{print $1}')

check "snapshot file written under the project key" file_exists "$SNAPSHOT"
check "snapshot_version is 1" jq_true "$SNAPSHOT" '.snapshot_version == 1'
check "snapshot records the repo's real HEAD" jq_true "$SNAPSHOT" ".git_head == \"$HEAD_SHA\""
check "snapshot hashes the surviving file" jq_true "$SNAPSHOT" ".files[\"$REPO/survivor.txt\"] == \"sha256:$SURVIVOR_HASH\""
check "snapshot marks the deleted file missing" jq_true "$SNAPSHOT" ".files[\"$REPO/deleted.txt\"] == \"missing\""

# Case 2: cwd is not a git work tree at all -> git_head records "none".
NOGIT_DIR="$SANDBOX/no-git-dir"
mkdir -p "$NOGIT_DIR"
echo "content" > "$NOGIT_DIR/plain.txt"

NOGIT_KEY_DIR="$SANDBOX/.claude/projects/nogit-project-key"
mkdir -p "$NOGIT_KEY_DIR"
NOGIT_TRANSCRIPT="$NOGIT_KEY_DIR/fake-session.jsonl"
cat > "$NOGIT_TRANSCRIPT" <<EOF
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"$NOGIT_DIR/plain.txt"}}]}}
EOF

NOGIT_PAYLOAD=$(jq -n --arg t "$NOGIT_TRANSCRIPT" --arg c "$NOGIT_DIR" '{transcript_path:$t, cwd:$c}')
printf '%s' "$NOGIT_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"

NOGIT_SNAPSHOT="$NOGIT_KEY_DIR/session-snapshot.json"
check "no-git-cwd snapshot still written" file_exists "$NOGIT_SNAPSHOT"
check "no-git-cwd records git_head as none" jq_true "$NOGIT_SNAPSHOT" '.git_head == "none"'

# Case 3: the transcript is garbage JSONL, not merely empty of tool_use
# entries. Chosen degrade posture: no snapshot is written at all, the hook
# still exits 0 (advisory infrastructure never breaks session end).
CORRUPT_KEY_DIR="$SANDBOX/.claude/projects/corrupt-project-key"
mkdir -p "$CORRUPT_KEY_DIR"
CORRUPT_TRANSCRIPT="$CORRUPT_KEY_DIR/fake-session.jsonl"
printf 'this is not json\nneither is this {{{\nstill garbage\n' > "$CORRUPT_TRANSCRIPT"

CORRUPT_PAYLOAD=$(jq -n --arg t "$CORRUPT_TRANSCRIPT" --arg c "$SANDBOX" '{transcript_path:$t, cwd:$c}')
printf '%s' "$CORRUPT_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"
CORRUPT_EXIT=$?

CORRUPT_SNAPSHOT="$CORRUPT_KEY_DIR/session-snapshot.json"
check "hook exits 0 on a corrupt transcript" exit_code_is "$CORRUPT_EXIT" 0
check "no snapshot written for a corrupt transcript" no_file "$CORRUPT_SNAPSHOT"

if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "FAILURES PRESENT"
    exit 1
fi
