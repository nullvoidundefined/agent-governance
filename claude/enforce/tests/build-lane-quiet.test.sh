#!/usr/bin/env bash
# Covers: hook:observability-reminder
# Covers: hook:new-file-header-reminder
# Covers: hook:dockerfile-reminder
# Covers: hook:flat-directory-reminder
# build-lane-quiet.test.sh: verifies that the four reminder-only hooks go quiet
# in the build-fast fast lane and only there (IAN-401, spec B-6, acceptance
# criterion 9). Every hook runs inside one sandbox git repository on branch
# feat/q, with the working directory inside that repository and a file path
# that resolves into it, fed the same triggering input its own fixture uses.
# Each hook runs under five ledger states at <repo>/.claude/task-tier.json:
#   1. {"branch":"feat/q","lane":"fast"}: no stdout, no stderr, exit 0.
#   2. {"branch":"feat/q","lane":"guarded"}: the hook's existing reminder.
#   3. {"branch":"other","lane":"fast"}: the reminder (another task's ledger).
#   4. malformed JSON: the reminder (fail toward reminding).
#   5. no ledger: the reminder.
# Finally the blocking gate protected-path-guard.sh, fed one Write into the
# sandbox repository, produces byte-identical output with and without the fast
# lane on the ledger, both with no scope declared and with a declared scope
# the target falls outside. (clean-code-reminder and scope-widening-gate were
# removed in IAN-568.)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOKS="$CLAUDE_HARNESS_ROOT/hooks"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
SB=$(cd "$SB" && pwd -P)
export HOME="$SB/home"; mkdir -p "$HOME"
export CLAUDE_FIRE_LOG="$SB/fire.log"
REPO="$SB/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b feat/q
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
mkdir -p "$REPO/.claude"
LEDGER="$REPO/.claude/task-tier.json"

# --- Triggering inputs, one per hook, taken from each hook's own fixture ------
mkdir -p "$REPO/src"
# observability-reminder: an Express app with routes and no /health.
mkdir -p "$REPO/apps/server/src"
printf 'import express from "express";\nconst app = express();\napp.use(express.json());\napp.get("/notes", listNotes);\nexport { app };\n' > "$REPO/apps/server/src/app.ts"
# dockerfile-reminder: a server entry file in a repository with no Dockerfile.
printf 'import { app } from "./app.js";\napp.listen(3000);\n' > "$REPO/apps/server/src/index.ts"
# flat-directory-reminder: a directory holding 21 source modules.
mkdir -p "$REPO/over"
for i in $(seq 1 21); do printf 'export function f%s() {}\n' "$i" > "$REPO/over/module$i.ts"; done
git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"

# --- Hook drivers --------------------------------------------------------------
# Each driver runs its hook from inside the sandbox repository and leaves the
# hook's stdout in OUT, its stderr in ERR, and its exit status in ST. DRIVE_HOOKS
# points the drivers at another hooks directory (a copy missing the helper).
drive() { # drive <hook-name> <payload> [env assignments...]
  local hook="$1" payload="$2"; shift 2
  local out_file="$SB/out" err_file="$SB/err"
  (cd "$REPO" && printf '%s' "$payload" | env "$@" bash "${DRIVE_HOOKS:-$HOOKS}/$hook.sh" >"$out_file" 2>"$err_file")
  ST=$?
  OUT=$(cat "$out_file"); ERR=$(cat "$err_file")
}
post_write() { # post_write <file-path> [content]
  jq -nc --arg f "$1" --arg c "${2:-}" --arg d "$REPO" \
    '{hook_event_name:"PostToolUse",tool_name:"Write",cwd:$d,tool_input:{file_path:$f}}
     + (if $c == "" then {} else {tool_input:{file_path:$f,content:$c}} end)'
}
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

run_observability() { drive observability-reminder "$(post_write "$REPO/apps/server/src/app.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_new_file_header() { drive new-file-header-reminder "$(post_write "$REPO/src/services/foo.ts" 'export const x = 1;
')" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_dockerfile() { drive dockerfile-reminder "$(post_write "$REPO/apps/server/src/index.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_flat_directory() { drive flat-directory-reminder "$(post_write "$REPO/over/module21.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }

# Reminder predicates: the same text each hook's own fixture asserts.
reminds_observability() { context | grep -q 'R-345'; }
reminds_new_file_header() { context | grep -q 'has no file-level header'; }
reminds_dockerfile() { context | grep -q 'R-351.*no Dockerfile exists'; }
reminds_flat_directory() { context | grep -q 'R-310'; }

is_quiet() { [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$ST" -eq 0 ]; }

set_ledger() { # set_ledger <state>
  case "$1" in
    fast) printf '{"branch":"feat/q","lane":"fast"}\n' > "$LEDGER" ;;
    guarded) printf '{"branch":"feat/q","lane":"guarded"}\n' > "$LEDGER" ;;
    other-branch) printf '{"branch":"other","lane":"fast"}\n' > "$LEDGER" ;;
    malformed) printf '{' > "$LEDGER" ;;
    concatenated) printf '{"branch":"feat/q","lane":"fast"}{"branch":"feat/q","lane":"fast"}\n' > "$LEDGER" ;;
    array) printf '[{"branch":"feat/q","lane":"fast"}]\n' > "$LEDGER" ;;
    absent) rm -f "$LEDGER" ;;
  esac
}

# --- The five ledger states for each reminder-only hook --------------------------
for hook in observability new_file_header dockerfile flat_directory; do
  set_ledger fast; "run_$hook"
  check "$hook: fast lane on this branch prints nothing and exits 0" is_quiet
  for state in guarded other-branch malformed absent; do
    set_ledger "$state"; "run_$hook"
    check "$hook: ledger $state still prints the reminder" "reminds_$hook"
  done
done

# --- Blocking gates decide the same with and without the fast lane ---------------
GATE_PAYLOAD=$(jq -nc --arg f "$REPO/.enforce.json" --arg d "$REPO" \
  '{hook_event_name:"PreToolUse",tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"{}"}}')
gate_output() { # gate_output <hook-name>: stdout and stderr together, then the exit status
  (cd "$REPO" && printf '%s' "$GATE_PAYLOAD" | bash "$HOOKS/$1.sh" 2>&1; echo "exit=$?")
}
for gate in protected-path-guard; do
  set_ledger absent; WITHOUT_LANE=$(gate_output "$gate")
  set_ledger fast; WITH_LANE=$(gate_output "$gate")
  check "$gate: identical output with no ledger and with the fast lane" test "$WITHOUT_LANE" = "$WITH_LANE"

  printf '{"branch":"feat/q","scope":["docs/**"]}\n' > "$LEDGER"; WITHOUT_LANE=$(gate_output "$gate")
  printf '{"branch":"feat/q","scope":["docs/**"],"lane":"fast"}\n' > "$LEDGER"; WITH_LANE=$(gate_output "$gate")
  check "$gate: identical output with a declared scope, with and without the fast lane" test "$WITHOUT_LANE" = "$WITH_LANE"
  check "$gate: the scoped Write draws a decision rather than silence" test "$WITH_LANE" != "exit=0"
done

# --- Hardening: ledger shapes, HEAD state, ledger provenance, helper loss ------
REMINDER_HOOKS="observability new_file_header dockerfile flat_directory"
check_all_remind() { # check_all_remind <label>: every reminder hook prints its reminder
  local hook
  for hook in $REMINDER_HOOKS; do
    "run_$hook"
    check "$hook: $1 still prints the reminder" "reminds_$hook"
  done
}

# Two concatenated objects and a one-element array are not one ledger object.
for state in concatenated array; do
  set_ledger "$state"; check_all_remind "ledger of shape $state"
done

# A detached HEAD names no branch, so no ledger can name the checked-out branch.
set_ledger fast
git -C "$REPO" checkout -q --detach
check_all_remind "detached HEAD with the fast ledger"
git -C "$REPO" checkout -q feat/q
set_ledger absent

# A committed ledger is repository content, not the owner's session opt-in.
set_ledger fast
git -C "$REPO" add -f .claude/task-tier.json
git -C "$REPO" commit -qm "track ledger"
check_all_remind "tracked (committed) fast ledger"
git -C "$REPO" reset -q --hard HEAD~1
mkdir -p "$REPO/.claude"
set_ledger absent
check "tracked-ledger case restored the sandbox history" test "$(git -C "$REPO" log -1 --format=%s)" = "init"

# A ledger that is a symlink to a file outside the repository is not trusted.
OUTSIDE_LEDGER="$SB/outside-ledger.json"
printf '{"branch":"feat/q","lane":"fast"}\n' > "$OUTSIDE_LEDGER"
ln -s "$OUTSIDE_LEDGER" "$LEDGER"
check_all_remind "symlinked fast ledger pointing outside the repository"
rm -f "$LEDGER"

# A .claude entry that is itself a symlink is not the owner's session opt-in,
# even when the ledger reached through it is a regular fast-lane file.
# Form (a): a relative .claude -> ledgers symlink committed with its target.
rm -rf "$REPO/.claude"
mkdir -p "$REPO/ledgers"
printf '{"branch":"feat/q","lane":"fast"}\n' > "$REPO/ledgers/task-tier.json"
ln -s ledgers "$REPO/.claude"
git -C "$REPO" add -f .claude ledgers/task-tier.json
git -C "$REPO" commit -qm "track symlinked claude dir"
check "committed .claude symlink resolves to a regular fast ledger" \
  test -f "$LEDGER" -a ! -L "$LEDGER" -a -L "$REPO/.claude"
check_all_remind "committed .claude symlink to an in-repository fast ledger"
git -C "$REPO" reset -q --hard HEAD~1
rm -rf "$REPO/.claude" "$REPO/ledgers"
mkdir -p "$REPO/.claude"
check "committed .claude symlink case restored the sandbox history" \
  test "$(git -C "$REPO" log -1 --format=%s)" = "init"

# Form (b): an untracked .claude symlink to a directory outside the repository.
OUTSIDE_CLAUDE_DIR="$SB/outside-claude-dir"
mkdir -p "$OUTSIDE_CLAUDE_DIR"
printf '{"branch":"feat/q","lane":"fast"}\n' > "$OUTSIDE_CLAUDE_DIR/task-tier.json"
rm -rf "$REPO/.claude"
ln -s "$OUTSIDE_CLAUDE_DIR" "$REPO/.claude"
check "untracked .claude symlink resolves to a regular fast ledger" \
  test -f "$LEDGER" -a ! -L "$LEDGER" -a -L "$REPO/.claude"
check_all_remind "untracked .claude symlink to an outside directory holding the fast ledger"
rm -f "$REPO/.claude"
mkdir -p "$REPO/.claude"
check "untracked .claude symlink case restored a real .claude directory" \
  test -d "$REPO/.claude" -a ! -L "$REPO/.claude"

# On a case-insensitive filesystem (macOS APFS, where git sets
# core.ignorecase=true), a fast ledger committed under a case variant of the
# ledger path is the file the helper opens as .claude/task-tier.json, yet it is
# repository content rather than the owner's session opt-in, so every reminder
# still prints. On a case-sensitive filesystem the variant is a different file
# the helper never opens, so these assertions are skipped.
: > "$SB/CaseProbe"
if [ -e "$SB/caseprobe" ]; then IS_CASE_INSENSITIVE_FS=1; else IS_CASE_INSENSITIVE_FS=0; fi
rm -f "$SB/CaseProbe"
check_case_variant_ledger() { # check_case_variant_ledger <directory-name> <file-name>
  local variant_dir="$1" variant_file="$2"
  rm -rf "$REPO/.claude"
  mkdir -p "$REPO/$variant_dir"
  printf '{"branch":"feat/q","lane":"fast"}\n' > "$REPO/$variant_dir/$variant_file"
  git -C "$REPO" add -f -- "$variant_dir/$variant_file"
  git -C "$REPO" commit -qm "track case-variant ledger"
  check "committed $variant_dir/$variant_file is tracked under that exact case" \
    test "$(git -C "$REPO" ls-files -- "$variant_dir/$variant_file")" = "$variant_dir/$variant_file"
  check "committed $variant_dir/$variant_file leaves a clean working tree" \
    test -z "$(git -C "$REPO" status --porcelain)"
  check "committed $variant_dir/$variant_file is reachable as the ledger path" \
    test -f "$LEDGER" -a ! -L "$LEDGER"
  check_all_remind "committed case-variant fast ledger $variant_dir/$variant_file"
  git -C "$REPO" reset -q --hard HEAD~1
  rm -rf "$REPO/$variant_dir" "$REPO/.claude"
  mkdir -p "$REPO/.claude"
  check "case-variant $variant_dir/$variant_file case restored the sandbox history" \
    test "$(git -C "$REPO" log -1 --format=%s)" = "init"
  check "case-variant $variant_dir/$variant_file case restored a lowercase .claude directory" \
    bash -c 'ls -a "$1" | grep -qx "\.claude" && [ -d "$1/.claude" ] && [ ! -L "$1/.claude" ]' _ "$REPO"
}
if [ "$IS_CASE_INSENSITIVE_FS" -eq 1 ]; then
  check "git records core.ignorecase=true in the sandbox repository" \
    test "$(git -C "$REPO" config --bool core.ignorecase)" = "true"
  check_case_variant_ledger ".Claude" "task-tier.json"
  check_case_variant_ledger ".claude" "Task-Tier.json"
else
  echo "PASS: SKIP: case-insensitive filesystem only (committed .Claude/task-tier.json and .claude/Task-Tier.json ledgers)"
fi

# A relative path starting with a dash resolves as a path: the nested
# repository at -nested/ has no ledger, so the outer fast lane must not apply.
set_ledger fast
git -C "$REPO" init -q -b feat/q -- "$REPO/-nested" 2>/dev/null || (mkdir -p "$REPO/-nested" && cd "$REPO/-nested" && git init -q -b feat/q)
dash_path_quiet_status() {
  (cd "$REPO" && . "$HOOKS/build-lane-quiet.sh" && is_reminder_quiet "-nested/sub/x.ts" 2>/dev/null)
  echo $?
}
check "is_reminder_quiet -nested/sub/x.ts answers for the nested repository (returns 1)" test "$(dash_path_quiet_status)" = "1"
rm -rf "$REPO/-nested"
set_ledger absent

# A hooks directory missing build-lane-quiet.sh still reminds, exits 0, and
# says nothing about the missing helper on stderr.
NOHELPER="$SB/nohelper"
mkdir -p "$NOHELPER/enforce"
cp -R "$HOOKS" "$NOHELPER/hooks"
rm -rf "$NOHELPER/hooks/build-lane-quiet.sh" "$NOHELPER/hooks/tests"
cp "$CLAUDE_HARNESS_ROOT"/enforce/*.sh "$NOHELPER/enforce/"
for hook in $REMINDER_HOOKS; do
  DRIVE_HOOKS="$NOHELPER/hooks" "run_$hook"
  check "$hook: without build-lane-quiet.sh exits 0" test "$ST" -eq 0
  check "$hook: without build-lane-quiet.sh prints the reminder" "reminds_$hook"
  check "$hook: without build-lane-quiet.sh keeps stderr free of the helper name" \
    bash -c '! grep -q build-lane-quiet <<< "$1"' _ "$ERR"
done

# Exactly the four reminder hooks source the helper.
HELPER_USERS=$(cd "$HOOKS" && grep -l 'build-lane-quiet' -- *.sh | grep -vx 'build-lane-quiet.sh' | sort | tr '\n' ' ')
EXPECTED_USERS=$(printf '%s\n' dockerfile-reminder.sh flat-directory-reminder.sh \
  new-file-header-reminder.sh observability-reminder.sh | sort | tr '\n' ' ')
check "only the four reminder hooks reference build-lane-quiet" test "$HELPER_USERS" = "$EXPECTED_USERS"

# new-file-header-reminder's own exemption: content opening with a comment.
set_ledger absent
drive new-file-header-reminder "$(post_write "$REPO/src/services/headed.ts" '// header
export const x = 1;
')" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"
check "new_file_header: content opening with a comment is silent with no ledger" is_quiet

# The real ledger writer's fast lane silences a reminder.
(cd "$REPO" && bash "$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh" set standard r --ticket IAN-1 --lane fast >/dev/null 2>&1)
check "task-tier.sh --lane fast wrote a fast ledger" test "$(jq -r '.lane' "$LEDGER" 2>/dev/null)" = "fast"
run_observability
check "observability: a ledger written by task-tier.sh --lane fast is quiet" is_quiet
set_ledger absent

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "build-lane-quiet.test.sh PASS"
