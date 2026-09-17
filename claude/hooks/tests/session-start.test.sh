#!/usr/bin/env bash
# Verifies session-start.sh loads the R-602 canonical handoff path
# (docs/session-handoff/session-handoff.md), SHA-verifies it against git log
# (R-001 step 5), labels an unverifiable handoff, and never injects dated
# audit reports as handoffs (2026-07-31 audits: the hook read docs/audits/).
set -euo pipefail
HOOK="$HOME/.claude/hooks/session-start.sh"

REPO=$(mktemp -d); cd "$REPO"; git init -q
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m "chore: init"
GOOD_SHA=$(git rev-parse --short HEAD)

# Decoy: a dated audit report must NOT be injected as a handoff.
mkdir -p docs/audits docs/session-handoff
printf '# Audit report decoy\n' > docs/audits/2026-01-01-engineering.md

# Canonical handoff with a real SHA -> injected, verified.
printf '# Handoff\n\n- Last commit: `%s` chore: init\n- next: continue\n' "$GOOD_SHA" > docs/session-handoff/session-handoff.md
OUT=$(echo '{}' | "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'session-handoff/session-handoff.md' || { echo "FAIL: canonical handoff not injected"; exit 1; }
printf '%s' "$CTX" | grep -q 'SHA-verified' || { echo "FAIL: expected SHA-verified verdict"; exit 1; }
printf '%s' "$CTX" | grep -q 'Audit report decoy' && { echo "FAIL: audit report injected as handoff"; exit 1; } || true

# Handoff with an unknown SHA -> injected but labeled UNVERIFIED.
printf '# Handoff\n\n- Last commit: `deadbeefcafe` mystery\n' > docs/session-handoff/session-handoff.md
OUT2=$(echo '{}' | "$HOOK")
CTX2=$(printf '%s' "$OUT2" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX2" | grep -q 'UNVERIFIED' || { echo "FAIL: expected UNVERIFIED label for unknown SHA"; exit 1; }

# No handoff file -> no handoff section.
rm docs/session-handoff/session-handoff.md
OUT3=$(echo '{}' | "$HOOK" || true)
printf '%s' "$OUT3" | grep -q 'Most recent handoff doc' && { echo "FAIL: handoff section without a handoff file"; exit 1; } || true

# SHA stamp is keyed by repo toplevel (2026-09-16 audit P3-4): two sessions
# in different repos write different files instead of clobbering one shared
# baseline, and the file carries HEAD of its own repo.
STAMP_TMP=$(mktemp -d)
TMPDIR="$STAMP_TMP" bash "$HOOK" <<< '{}' >/dev/null 2>&1 || true
REPO_KEY=$(printf '%s' "$(git rev-parse --show-toplevel)" | shasum | awk '{print $1}')
STAMP_FILE="$STAMP_TMP/claude-session-start-sha-$REPO_KEY"
[ -f "$STAMP_FILE" ] || { echo "FAIL: expected repo-keyed SHA stamp at claude-session-start-sha-<key>"; exit 1; }
[ "$(cat "$STAMP_FILE")" = "$(git rev-parse HEAD)" ] || { echo "FAIL: keyed stamp must hold this repo's HEAD"; exit 1; }
rm -rf "$STAMP_TMP"

cd / && rm -rf "$REPO"

# --- Resume drift check (B-8 read half) ---
#
# check_resume_drift reads source, transcript_path, and cwd off the
# SessionStart stdin payload; on source == "resume" only, it compares the
# project's snapshot (session-end.sh's write_session_snapshot, B-8 write
# half) against the working tree and adds a "## Resume drift check (B-8)"
# block to additionalContext. Sandboxes HOME per case so the check reads a
# fake project snapshot, never the real one; process cwd is "/" here (see
# the line above), so the handoff section stays empty (no
# docs/session-handoff/session-handoff.md under "/") and each drift-focused
# assertion targets only the drift block, even though the sandbox's
# global-memory/INDEX.md (seeded below) also puts content into every case's
# additionalContext.

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

ctx_has()      { printf '%s' "$1" | grep -qF -- "$2"; }
ctx_lacks()    { ! printf '%s' "$1" | grep -qF -- "$2"; }
ctx_nonempty() { [ -n "$1" ]; }
no_file()      { [ ! -f "$1" ]; }
file_exists()  { [ -f "$1" ]; }

# Runs the hook with HOME=$1 and the JSON payload $2 on stdin, returns the
# additionalContext string (empty if the hook emitted no JSON at all, which
# is the expected shape for a non-resume start with nothing else to say).
get_ctx() {
  local home="$1" payload="$2" raw
  raw=$(HOME="$home" bash "$HOOK" <<< "$payload" 2>/dev/null || true)
  [ -n "$raw" ] || { printf ''; return 0; }
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}

DRIFT_SANDBOX="$(mktemp -d)"

# A minimal global-memory INDEX.md makes the sandbox's non-resume output
# non-empty (review round 1, Important finding 1): without it, a startup
# payload against this sandbox produces empty stdout regardless of whether
# the resume-only guard works, so "no drift text in the output" would be
# proven vacuously by "no output at all". Seeding real, unrelated content
# means the absence check below has something non-trivial to pass.
mkdir -p "$DRIFT_SANDBOX/.claude/global-memory"
printf '# Global memory index\n\nFixture content so a non-resume SessionStart still emits non-empty\nadditionalContext; the drift section must be absent from it, not\nmerely absent because everything was empty.\n' \
  > "$DRIFT_SANDBOX/.claude/global-memory/INDEX.md"

DRIFT_REPO="$DRIFT_SANDBOX/work-repo"
mkdir -p "$DRIFT_REPO"
git -C "$DRIFT_REPO" init -q
git -C "$DRIFT_REPO" config user.email t@t
git -C "$DRIFT_REPO" config user.name t
printf 'hello\n' > "$DRIFT_REPO/survivor.txt"
printf 'orig\n' > "$DRIFT_REPO/altered.txt"
printf 'gone\n' > "$DRIFT_REPO/third.txt"
git -C "$DRIFT_REPO" add -A
git -C "$DRIFT_REPO" commit -qm seed
DRIFT_HEAD=$(git -C "$DRIFT_REPO" rev-parse HEAD)

SURVIVOR_HASH="sha256:$(shasum -a 256 "$DRIFT_REPO/survivor.txt" | awk '{print $1}')"
ALTERED_HASH_ORIG="sha256:$(shasum -a 256 "$DRIFT_REPO/altered.txt" | awk '{print $1}')"
THIRD_HASH_ORIG="sha256:$(shasum -a 256 "$DRIFT_REPO/third.txt" | awk '{print $1}')"

# Expected display paths after tilde redaction: the hook renders its own
# $HOME (== DRIFT_SANDBOX for these invocations) as ~.
ALTERED_DISPLAY="~${DRIFT_REPO#"$DRIFT_SANDBOX"}/altered.txt"
THIRD_DISPLAY="~${DRIFT_REPO#"$DRIFT_SANDBOX"}/third.txt"

resume_payload() {
  # $1 = transcript path, $2 = cwd
  jq -n --arg t "$1" --arg c "$2" '{source:"resume", transcript_path:$t, cwd:$c}'
}
startup_payload() {
  jq -n --arg t "$1" --arg c "$2" '{source:"startup", transcript_path:$t, cwd:$c}'
}
write_snapshot() {
  # $1 = key dir, $2 = snapshot_version, $3 = git_head, $4 = files object (JSON)
  jq -n --argjson v "$2" --arg head "$3" --argjson files "$4" \
    '{snapshot_version: $v, git_head: $head, files: $files}' \
    > "$1/session-snapshot.json"
}

# Case: matching-hash snapshot -> clean line. survivor.txt's recorded hash
# and the repo's recorded HEAD both match current state exactly.
CLEAN_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-clean"
mkdir -p "$CLEAN_KEY_DIR"
write_snapshot "$CLEAN_KEY_DIR" 1 "$DRIFT_HEAD" \
  "$(jq -n --arg f "$DRIFT_REPO/survivor.txt" --arg h "$SURVIVOR_HASH" '{($f): $h}')"
CLEAN_TRANSCRIPT="$CLEAN_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$CLEAN_TRANSCRIPT"
CTX_CLEAN=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$CLEAN_TRANSCRIPT" "$DRIFT_REPO")")
check "clean snapshot reports the clean line" ctx_has "$CTX_CLEAN" "clean: working tree matches the last session-end snapshot"

# Case: altered file -> drifted, naming exactly the changed path. Snapshot
# records altered.txt's ORIGINAL hash; the file is then edited before the
# hook runs, so its current hash no longer matches.
ALTERED_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-altered"
mkdir -p "$ALTERED_KEY_DIR"
write_snapshot "$ALTERED_KEY_DIR" 1 "$DRIFT_HEAD" \
  "$(jq -n --arg f "$DRIFT_REPO/altered.txt" --arg h "$ALTERED_HASH_ORIG" '{($f): $h}')"
ALTERED_TRANSCRIPT="$ALTERED_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$ALTERED_TRANSCRIPT"
printf 'edited\n' > "$DRIFT_REPO/altered.txt"
CTX_ALTERED=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$ALTERED_TRANSCRIPT" "$DRIFT_REPO")")
check "altered file reported as changed, path only, tilde-redacted" ctx_has "$CTX_ALTERED" "changed $ALTERED_DISPLAY"

# Case: a tracked path containing a space -> drifted, naming it exactly
# with the space intact (review round 2: the batched shasum fix in
# check_resume_drift was proven correct for spaced paths only by manual,
# uncommitted verification during re-review; this is the checked-in
# regression fixture for that bug class, which this repo has hit before).
# The batched call maps each shasum output line back to its recorded hash
# via the parallel existing_paths/existing_recorded arrays, by POSITION,
# never by splitting the output line on whitespace, so a space inside the
# path was never actually at risk; this fixture pins that down so a future
# change to the mapping can't reintroduce a whitespace-split bug silently.
SPACED_FILE="$DRIFT_REPO/spaced file.txt"
printf 'orig\n' > "$SPACED_FILE"
SPACED_HASH_ORIG="sha256:$(shasum -a 256 "$SPACED_FILE" | awk '{print $1}')"
SPACED_DISPLAY="~${DRIFT_REPO#"$DRIFT_SANDBOX"}/spaced file.txt"

SPACED_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-spaced"
mkdir -p "$SPACED_KEY_DIR"
write_snapshot "$SPACED_KEY_DIR" 1 "$DRIFT_HEAD" \
  "$(jq -n --arg f "$SPACED_FILE" --arg h "$SPACED_HASH_ORIG" '{($f): $h}')"
SPACED_TRANSCRIPT="$SPACED_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$SPACED_TRANSCRIPT"
printf 'edited\n' > "$SPACED_FILE"
CTX_SPACED=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$SPACED_TRANSCRIPT" "$DRIFT_REPO")")
check "spaced-path file reported as changed, space intact, tilde-redacted" ctx_has "$CTX_SPACED" "changed $SPACED_DISPLAY"

# Case: deleted file -> missing line. Snapshot records third.txt's original
# hash; the file is removed before the hook runs.
DELETED_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-deleted"
mkdir -p "$DELETED_KEY_DIR"
write_snapshot "$DELETED_KEY_DIR" 1 "$DRIFT_HEAD" \
  "$(jq -n --arg f "$DRIFT_REPO/third.txt" --arg h "$THIRD_HASH_ORIG" '{($f): $h}')"
DELETED_TRANSCRIPT="$DELETED_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$DELETED_TRANSCRIPT"
rm -f "$DRIFT_REPO/third.txt"
CTX_DELETED=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$DELETED_TRANSCRIPT" "$DRIFT_REPO")")
check "deleted file reported as missing, path only, tilde-redacted" ctx_has "$CTX_DELETED" "missing $THIRD_DISPLAY"

# Case: moved HEAD -> the HEAD line with both short SHAs. A second, separate
# repo with two commits; the snapshot records the first commit, the repo now
# sits on the second. No files tracked, isolating the HEAD-move assertion.
HEAD_REPO="$DRIFT_SANDBOX/head-move-repo"
mkdir -p "$HEAD_REPO"
git -C "$HEAD_REPO" init -q
git -C "$HEAD_REPO" config user.email t@t
git -C "$HEAD_REPO" config user.name t
git -C "$HEAD_REPO" commit -q --allow-empty -m one
HEAD_OLD=$(git -C "$HEAD_REPO" rev-parse HEAD)
git -C "$HEAD_REPO" commit -q --allow-empty -m two
HEAD_NEW=$(git -C "$HEAD_REPO" rev-parse HEAD)

HEADMOVE_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-headmove"
mkdir -p "$HEADMOVE_KEY_DIR"
write_snapshot "$HEADMOVE_KEY_DIR" 1 "$HEAD_OLD" '{}'
HEADMOVE_TRANSCRIPT="$HEADMOVE_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$HEADMOVE_TRANSCRIPT"
CTX_HEADMOVE=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$HEADMOVE_TRANSCRIPT" "$HEAD_REPO")")
check "moved HEAD reported with both short SHAs" ctx_has "$CTX_HEADMOVE" "HEAD moved ${HEAD_OLD:0:7} -> ${HEAD_NEW:0:7}"

# Case: absent snapshot -> the none line. No session-snapshot.json exists
# under this key at all.
NONE_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-none"
mkdir -p "$NONE_KEY_DIR"
NONE_TRANSCRIPT="$NONE_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$NONE_TRANSCRIPT"
CTX_NONE=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$NONE_TRANSCRIPT" "$DRIFT_REPO")")
check "absent snapshot reports the none line" ctx_has "$CTX_NONE" "no drift check ran; no snapshot"

# Case: snapshot_version 2 -> stale warning AND the snapshot file removed,
# so the next session-end rewrites it.
STALE_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/drift-stale"
mkdir -p "$STALE_KEY_DIR"
write_snapshot "$STALE_KEY_DIR" 2 "$DRIFT_HEAD" '{}'
STALE_SNAPSHOT="$STALE_KEY_DIR/session-snapshot.json"
STALE_TRANSCRIPT="$STALE_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$STALE_TRANSCRIPT"
CTX_STALE=$(get_ctx "$DRIFT_SANDBOX" "$(resume_payload "$STALE_TRANSCRIPT" "$DRIFT_REPO")")
check "stale snapshot_version warns" ctx_has "$CTX_STALE" "stale snapshot (version 2, expected 1)"
check "stale snapshot file is deleted" no_file "$STALE_SNAPSHOT"

# Case: a startup-reason payload with a drifted snapshot present -> NO drift
# output at all. Reuses the altered-file drift state above (still drifted on
# disk); only the source differs. The INDEX.md seeded above means CTX_STARTUP
# is non-empty on its own merits, so "contains no drift text" is a real
# assertion, not a side effect of empty stdout (review round 1, finding 1).
# CTX_ALTERED (computed earlier, same snapshot, same files, source=resume)
# is the positive control: it already asserted "changed $ALTERED_DISPLAY" is
# present, so the pair together prove the guard is gated on source, not on
# whether a snapshot happens to be drifted.
CTX_STARTUP=$(get_ctx "$DRIFT_SANDBOX" "$(startup_payload "$ALTERED_TRANSCRIPT" "$DRIFT_REPO")")
check "startup context is non-empty (INDEX.md still loads)" ctx_nonempty "$CTX_STARTUP"
check "non-resume start emits no drift heading" ctx_lacks "$CTX_STARTUP" "Resume drift check"
check "non-resume start emits no changed line" ctx_lacks "$CTX_STARTUP" "changed "
check "non-resume start emits no missing line" ctx_lacks "$CTX_STARTUP" "missing "
check "non-resume start emits no HEAD moved line" ctx_lacks "$CTX_STARTUP" "HEAD moved"
check "positive control: resume on the identical snapshot DOES drift" ctx_has "$CTX_ALTERED" "changed $ALTERED_DISPLAY"

# --- Interrupted task offering (task-state-tracker) ---
#
# check_interrupted_tasks scans ~/.claude/projects/<key>/task-state.*.json
# for the CURRENT project key (same key session-start.sh's other checks
# derive from transcript_path). A file from a DIFFERENT session id holding
# at least one non-completed task is offered as interrupted work; a file
# whose tasks are ALL completed is pruned (deleted) and never offered. Runs
# on every start reason, not gated to source == "resume" (unlike the B-8
# drift check above): a fresh startup after a crash is exactly when a prior
# session's tasks need offering.

TASK_KEY_DIR="$DRIFT_SANDBOX/.claude/projects/taskstate-current"
mkdir -p "$TASK_KEY_DIR"
CURRENT_TASK_TRANSCRIPT="$TASK_KEY_DIR/current-session.jsonl"
printf '{}\n' > "$CURRENT_TASK_TRANSCRIPT"

# Interrupted state file from another session id -> injection block naming
# the subject and status; its completed sibling task is not offered; the
# file itself is left in place for the next scan.
INTERRUPTED_STATE="$TASK_KEY_DIR/task-state.other-session.json"
jq -n '{
  state_version: 1,
  session_id: "other-session",
  cwd: "/some/repo",
  branch: "feature/x",
  updated_at: "2026-09-17T00:00:00Z",
  tasks: {
    "1": {subject: "Finish the migration", status: "in_progress", created_at: "2026-09-17T00:00:00Z", updated_at: "2026-09-17T00:00:00Z"},
    "2": {subject: "Write the tests", status: "completed", created_at: "2026-09-17T00:00:00Z", updated_at: "2026-09-17T00:00:00Z"}
  }
}' > "$INTERRUPTED_STATE"

CTX_TASKSTATE=$(get_ctx "$DRIFT_SANDBOX" "$(startup_payload "$CURRENT_TASK_TRANSCRIPT" "$DRIFT_REPO")")
check "interrupted task names the status and subject" ctx_has "$CTX_TASKSTATE" "[in_progress] Finish the migration"
check "interrupted block names the prior session id" ctx_has "$CTX_TASKSTATE" "other-session"
check "interrupted block names the prior branch" ctx_has "$CTX_TASKSTATE" "feature/x"
check "completed sibling task is not offered" ctx_lacks "$CTX_TASKSTATE" "Write the tests"
check "interrupted state file is left in place" file_exists "$INTERRUPTED_STATE"

# All-completed file -> pruned (deleted), no injection block for it.
ALLDONE_STATE="$TASK_KEY_DIR/task-state.alldone-session.json"
jq -n '{
  state_version: 1,
  session_id: "alldone-session",
  cwd: "/some/repo",
  branch: "main",
  updated_at: "2026-09-17T00:00:00Z",
  tasks: {
    "1": {subject: "Ship the release", status: "completed", created_at: "2026-09-17T00:00:00Z", updated_at: "2026-09-17T00:00:00Z"}
  }
}' > "$ALLDONE_STATE"

CTX_ALLDONE=$(get_ctx "$DRIFT_SANDBOX" "$(startup_payload "$CURRENT_TASK_TRANSCRIPT" "$DRIFT_REPO")")
check "all-completed state file is pruned" no_file "$ALLDONE_STATE"
check "all-completed file yields no injection block" ctx_lacks "$CTX_ALLDONE" "Ship the release"

rm -rf "$DRIFT_SANDBOX"

if [ "$fail" -eq 0 ]; then
  echo "session-start.test.sh PASS"
  exit 0
else
  echo "session-start.test.sh: FAILURES PRESENT"
  exit 1
fi
