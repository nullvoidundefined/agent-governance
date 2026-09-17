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

# --- Task state render into the handoff doc ---
#
# render_task_state_section reads the CURRENT session's
# task-state.<session-id>.jsonl (task-state-tracker.sh's append-only event
# log; fix round 1, C1) and renders it into a marker-delimited "## Task
# state" section (<!-- task-state:begin/end -->; fix round 1, I2) of
# docs/session-handoff/session-handoff.md under the session cwd's repo, but
# only when that handoff file already exists (the handoff is repo-owned).
# Then deletes the session's task-state log when every task is completed;
# otherwise leaves it in place for the next session-start to offer as
# interrupted work.

# append_task_line: appends one task-state-tracker.sh-shaped event line to
# log file $1: ts=$2, task_id=$3, subject=$4, status=$5, cwd=$6, branch=$7.
append_task_line() {
  jq -nc --arg ts "$2" --arg tid "$3" --arg subj "$4" --arg st "$5" --arg cwd "$6" --arg br "$7" \
    '{ts:$ts, task_id:$tid, subject:$subj, status:$st, cwd:$cwd, branch:$br}' >> "$1"
}

handoff_has()      { grep -qF -- "$2" "$1"; }
handoff_count()    { [ "$(grep -c -- "$2" "$1")" -eq "$3" ]; }
ctx_lacks_file()   { ! grep -qF -- "$2" "$1"; }

# Case A: some tasks incomplete -> section rendered with all tasks (not
# just the incomplete ones), log left in place.
TS_REPO="$SANDBOX/task-state-repo"
mkdir -p "$TS_REPO/docs/session-handoff"
git -C "$TS_REPO" init -q
git -C "$TS_REPO" config user.email t@t
git -C "$TS_REPO" config user.name t
cat > "$TS_REPO/docs/session-handoff/session-handoff.md" <<'EOF'
# Handoff

- Last commit: `deadbeef` chore: seed

## Pending

- something pending
EOF
git -C "$TS_REPO" add -A
git -C "$TS_REPO" commit -qm seed

TS_KEY_DIR="$SANDBOX/.claude/projects/task-state-render-key"
mkdir -p "$TS_KEY_DIR"
TS_TRANSCRIPT="$TS_KEY_DIR/render-session.jsonl"
printf '{}\n' > "$TS_TRANSCRIPT"
TS_LOG="$TS_KEY_DIR/task-state.render-session.jsonl"
append_task_line "$TS_LOG" "2026-09-17T00:00:00Z" "1" "Ship the render" "created" "$TS_REPO" "main"
append_task_line "$TS_LOG" "2026-09-17T00:05:00Z" "1" "" "completed" "$TS_REPO" "main"
append_task_line "$TS_LOG" "2026-09-17T00:01:00Z" "2" "Write the docs" "created" "$TS_REPO" "main"
append_task_line "$TS_LOG" "2026-09-17T00:10:00Z" "2" "" "in_progress" "$TS_REPO" "main"

TS_PAYLOAD=$(jq -n --arg t "$TS_TRANSCRIPT" --arg c "$TS_REPO" '{transcript_path:$t, cwd:$c}')
printf '%s' "$TS_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"

TS_HANDOFF="$TS_REPO/docs/session-handoff/session-handoff.md"

check "handoff gains a Task state heading" handoff_has "$TS_HANDOFF" "## Task state"
check "handoff is wrapped in begin/end markers (I2)" handoff_has "$TS_HANDOFF" "<!-- task-state:begin -->"
check "handoff renders the completed task with its id (M1)" handoff_has "$TS_HANDOFF" "- [completed] Ship the render (task 1) (updated 2026-09-17T00:05:00Z)"
check "handoff renders the in-progress task with its id (M1)" handoff_has "$TS_HANDOFF" "- [in_progress] Write the docs (task 2) (updated 2026-09-17T00:10:00Z)"
check "prior handoff content (Pending section) is preserved" handoff_has "$TS_HANDOFF" "## Pending"
check "Task state heading appears exactly once" handoff_count "$TS_HANDOFF" "## Task state" 1
check "begin marker appears exactly once" handoff_count "$TS_HANDOFF" "<!-- task-state:begin -->" 1
check "log left in place (not all completed)" file_exists "$TS_LOG"

# Re-run to prove replace, not accumulate: the heading still appears once
# and stale content from a prior render is gone. A second event line is
# appended (the log is append-only; nothing ever rewrites an old line).
append_task_line "$TS_LOG" "2026-09-17T00:20:00Z" "2" "" "completed" "$TS_REPO" "main"
printf '%s' "$TS_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"
check "Task state heading still appears exactly once after a second render" handoff_count "$TS_HANDOFF" "## Task state" 1
check "begin marker still appears exactly once after a second render" handoff_count "$TS_HANDOFF" "<!-- task-state:begin -->" 1
check "second render reflects the updated status" handoff_has "$TS_HANDOFF" "- [completed] Write the docs (task 2) (updated 2026-09-17T00:20:00Z)"
check "second render drops the stale in_progress line" ctx_lacks_file "$TS_HANDOFF" "- [in_progress] Write the docs"

# Case B: all tasks completed -> log deleted after render.
check "all-completed log is deleted after render" no_file "$TS_LOG"

# Case C: no handoff file in the session cwd's repo -> render is skipped
# entirely (the handoff is repo-owned), but the hook still exits 0 and a
# fully-completed log is still pruned.
NOHANDOFF_REPO="$SANDBOX/no-handoff-repo"
mkdir -p "$NOHANDOFF_REPO"
git -C "$NOHANDOFF_REPO" init -q
git -C "$NOHANDOFF_REPO" config user.email t@t
git -C "$NOHANDOFF_REPO" config user.name t
git -C "$NOHANDOFF_REPO" commit -q --allow-empty -m seed

NOHANDOFF_KEY_DIR="$SANDBOX/.claude/projects/no-handoff-key"
mkdir -p "$NOHANDOFF_KEY_DIR"
NOHANDOFF_TRANSCRIPT="$NOHANDOFF_KEY_DIR/nohandoff-session.jsonl"
printf '{}\n' > "$NOHANDOFF_TRANSCRIPT"
NOHANDOFF_LOG="$NOHANDOFF_KEY_DIR/task-state.nohandoff-session.jsonl"
append_task_line "$NOHANDOFF_LOG" "2026-09-17T00:00:00Z" "1" "Solo task" "created" "$NOHANDOFF_REPO" "main"
append_task_line "$NOHANDOFF_LOG" "2026-09-17T00:00:30Z" "1" "" "completed" "$NOHANDOFF_REPO" "main"

NOHANDOFF_PAYLOAD=$(jq -n --arg t "$NOHANDOFF_TRANSCRIPT" --arg c "$NOHANDOFF_REPO" '{transcript_path:$t, cwd:$c}')
NOHANDOFF_EXIT=0
printf '%s' "$NOHANDOFF_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK" || NOHANDOFF_EXIT=$?
check "hook exits 0 with no handoff file present" exit_code_is "$NOHANDOFF_EXIT" 0
check "no handoff file was created" no_file "$NOHANDOFF_REPO/docs/session-handoff/session-handoff.md"
check "log is still pruned once all tasks are completed" no_file "$NOHANDOFF_LOG"

# --- M2: a folded task with no TaskCreate line renders a subject
# placeholder in the handoff section too ---
ORPHAN_REPO="$SANDBOX/orphan-render-repo"
mkdir -p "$ORPHAN_REPO/docs/session-handoff"
git -C "$ORPHAN_REPO" init -q
git -C "$ORPHAN_REPO" config user.email t@t
git -C "$ORPHAN_REPO" config user.name t
printf '# Handoff\n' > "$ORPHAN_REPO/docs/session-handoff/session-handoff.md"
git -C "$ORPHAN_REPO" add -A
git -C "$ORPHAN_REPO" commit -qm seed

ORPHAN_KEY_DIR="$SANDBOX/.claude/projects/orphan-render-key"
mkdir -p "$ORPHAN_KEY_DIR"
ORPHAN_TRANSCRIPT="$ORPHAN_KEY_DIR/orphan-session.jsonl"
printf '{}\n' > "$ORPHAN_TRANSCRIPT"
ORPHAN_LOG="$ORPHAN_KEY_DIR/task-state.orphan-session.jsonl"
append_task_line "$ORPHAN_LOG" "2026-09-17T00:00:00Z" "9" "" "in_progress" "$ORPHAN_REPO" "main"

ORPHAN_PAYLOAD=$(jq -n --arg t "$ORPHAN_TRANSCRIPT" --arg c "$ORPHAN_REPO" '{transcript_path:$t, cwd:$c}')
printf '%s' "$ORPHAN_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"
ORPHAN_HANDOFF="$ORPHAN_REPO/docs/session-handoff/session-handoff.md"

check "handoff renders the unknown-subject placeholder (M2)" handoff_has "$ORPHAN_HANDOFF" "(unknown subject: 9)"
check "handoff renders the orphan task's id (M1)" handoff_has "$ORPHAN_HANDOFF" "(task 9)"

# --- I2: a handoff whose fenced code block quotes an example "## Task
# state" heading (no markers inside the fence) must survive the render
# byte-identical outside the <!-- task-state:begin/end --> markers. The
# old heading-based stripper destroyed the fence and everything after it
# up to the next "##" heading; the marker-delimited replacer never matches
# inside a fence because it only ever matches the literal marker lines,
# never a "## " heading. ---
FENCE_REPO="$SANDBOX/fence-repo"
mkdir -p "$FENCE_REPO/docs/session-handoff"
git -C "$FENCE_REPO" init -q
git -C "$FENCE_REPO" config user.email t@t
git -C "$FENCE_REPO" config user.name t
FENCE_HANDOFF="$FENCE_REPO/docs/session-handoff/session-handoff.md"
cat > "$FENCE_HANDOFF" <<'EOF'
# Handoff

## Notes

Example of the generated block:

```markdown
## Next

- real next step, no trailing newline

## Task state

- [in_progress] T (updated a)
```

## Pending

- something pending
EOF
git -C "$FENCE_REPO" add -A
git -C "$FENCE_REPO" commit -qm seed

FENCE_ORIGINAL_CONTENT=$(cat "$FENCE_HANDOFF")

FENCE_KEY_DIR="$SANDBOX/.claude/projects/fence-render-key"
mkdir -p "$FENCE_KEY_DIR"
FENCE_TRANSCRIPT="$FENCE_KEY_DIR/fence-session.jsonl"
printf '{}\n' > "$FENCE_TRANSCRIPT"
FENCE_LOG="$FENCE_KEY_DIR/task-state.fence-session.jsonl"
append_task_line "$FENCE_LOG" "2026-09-17T00:00:00Z" "1" "Real live task" "in_progress" "$FENCE_REPO" "main"

FENCE_PAYLOAD=$(jq -n --arg t "$FENCE_TRANSCRIPT" --arg c "$FENCE_REPO" '{transcript_path:$t, cwd:$c}')
printf '%s' "$FENCE_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK"

# fence_prefix_matches: true if the handoff's content, up to (not
# including) the first begin-marker line, still equals the original
# content (both compared with trailing newlines stripped, since command
# substitution strips them from both sides identically).
fence_prefix_matches() {
  local handoff="$1" original="$2" marker_line prefix
  marker_line=$(grep -n -F -- '<!-- task-state:begin -->' "$handoff" | head -1 | cut -d: -f1)
  [ -n "$marker_line" ] || return 1
  prefix=$(sed -n "1,$(( marker_line - 1 ))p" "$handoff")
  [ "$prefix" = "$original" ]
}

check "the fenced example survives byte-identical outside the markers (I2)" fence_prefix_matches "$FENCE_HANDOFF" "$FENCE_ORIGINAL_CONTENT"
check "the fence's closing delimiter is intact" handoff_has "$FENCE_HANDOFF" '```'
check "the real Pending section after the fence is intact" handoff_has "$FENCE_HANDOFF" "## Pending"
check "the newly rendered task is present after the markers" handoff_has "$FENCE_HANDOFF" "Real live task"

if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "FAILURES PRESENT"
    exit 1
fi
