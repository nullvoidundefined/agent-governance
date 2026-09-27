#!/usr/bin/env bash
# Covers: hook:clean-code-reminder
# Covers: hook:observability-reminder
# Covers: hook:new-file-header-reminder
# Covers: hook:dockerfile-reminder
# Covers: hook:flat-directory-reminder
# Covers: hook:single-file-folder-reminder
# build-lane-quiet.test.sh: verifies that the six reminder-only hooks go quiet
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
# Then an input clean-code-reminder's own fixture expects to be silent (a short
# function) is still silent with no ledger, so the existing exemptions hold.
# Finally the two blocking gates, protected-path-guard.sh and
# scope-widening-gate.sh, fed one Write into the sandbox repository, produce
# byte-identical output with and without the fast lane on the ledger, both
# with no scope declared and with a declared scope the target falls outside.
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
# clean-code-reminder: a function body past the R-322 ceiling, plus a short one.
mkdir -p "$REPO/src"
{
  printf 'export function oversizedComputation(): number {\n'
  printf '    let total = 0;\n'
  for i in $(seq 1 30); do printf '    total += %s;\n' "$i"; done
  printf '    return total;\n}\n'
} > "$REPO/src/long.ts"
printf 'export function addNumbers(a: number, b: number): number {\n    return a + b;\n}\n' > "$REPO/src/short.ts"
# observability-reminder: an Express app with routes and no /health.
mkdir -p "$REPO/apps/server/src"
printf 'import express from "express";\nconst app = express();\napp.use(express.json());\napp.get("/notes", listNotes);\nexport { app };\n' > "$REPO/apps/server/src/app.ts"
# dockerfile-reminder: a server entry file in a repository with no Dockerfile.
printf 'import { app } from "./app.js";\napp.listen(3000);\n' > "$REPO/apps/server/src/index.ts"
# flat-directory-reminder: a directory holding 21 source modules.
mkdir -p "$REPO/over"
for i in $(seq 1 21); do printf 'export function f%s() {}\n' "$i" > "$REPO/over/module$i.ts"; done
git -C "$REPO" add -A; git -C "$REPO" commit -qm "init"
# single-file-folder-reminder: the last commit adds a folder with one module.
mkdir -p "$REPO/src/voices"
printf 'export function getVoice() {\n  return "x";\n}\n' > "$REPO/src/voices/voices.ts"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "add voices"

# --- Hook drivers --------------------------------------------------------------
# Each driver runs its hook from inside the sandbox repository and leaves the
# hook's stdout in OUT, its stderr in ERR, and its exit status in ST.
drive() { # drive <hook-name> <payload> [env assignments...]
  local hook="$1" payload="$2"; shift 2
  local out_file="$SB/out" err_file="$SB/err"
  (cd "$REPO" && printf '%s' "$payload" | env "$@" bash "$HOOKS/$hook.sh" >"$out_file" 2>"$err_file")
  ST=$?
  OUT=$(cat "$out_file"); ERR=$(cat "$err_file")
}
post_write() { # post_write <file-path> [content]
  jq -nc --arg f "$1" --arg c "${2:-}" --arg d "$REPO" \
    '{hook_event_name:"PostToolUse",tool_name:"Write",cwd:$d,tool_input:{file_path:$f}}
     + (if $c == "" then {} else {tool_input:{file_path:$f,content:$c}} end)'
}
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

run_clean_code() { drive clean-code-reminder "$(post_write "$REPO/src/long.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_observability() { drive observability-reminder "$(post_write "$REPO/apps/server/src/app.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_new_file_header() { drive new-file-header-reminder "$(post_write "$REPO/src/services/foo.ts" 'export const x = 1;
')" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_dockerfile() { drive dockerfile-reminder "$(post_write "$REPO/apps/server/src/index.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_flat_directory() { drive flat-directory-reminder "$(post_write "$REPO/over/module21.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"; }
run_single_file_folder() {
  drive single-file-folder-reminder \
    "$(jq -nc --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:"git push origin feat/q"}}')" \
    CLAUDE_ENFORCE_BASE=HEAD~1 CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"
}

# Reminder predicates: the same text each hook's own fixture asserts.
reminds_clean_code() { context | grep -q 'R-322'; }
reminds_observability() { context | grep -q 'R-345'; }
reminds_new_file_header() { context | grep -q 'has no file-level header'; }
reminds_dockerfile() { context | grep -q 'R-351.*no Dockerfile exists'; }
reminds_flat_directory() { context | grep -q 'R-310'; }
reminds_single_file_folder() { grep -q 'src/voices' <<< "$ERR"; }

is_quiet() { [ -z "$OUT" ] && [ -z "$ERR" ] && [ "$ST" -eq 0 ]; }

set_ledger() { # set_ledger <state>
  case "$1" in
    fast) printf '{"branch":"feat/q","lane":"fast"}\n' > "$LEDGER" ;;
    guarded) printf '{"branch":"feat/q","lane":"guarded"}\n' > "$LEDGER" ;;
    other-branch) printf '{"branch":"other","lane":"fast"}\n' > "$LEDGER" ;;
    malformed) printf '{' > "$LEDGER" ;;
    absent) rm -f "$LEDGER" ;;
  esac
}

# --- The five ledger states for each reminder-only hook --------------------------
for hook in clean_code observability new_file_header dockerfile flat_directory single_file_folder; do
  set_ledger fast; "run_$hook"
  check "$hook: fast lane on this branch prints nothing and exits 0" is_quiet
  for state in guarded other-branch malformed absent; do
    set_ledger "$state"; "run_$hook"
    check "$hook: ledger $state still prints the reminder" "reminds_$hook"
  done
done

# --- Existing exemptions hold: a short function stays silent with no ledger ------
set_ledger absent
drive clean-code-reminder "$(post_write "$REPO/src/short.ts")" CLAUDE_FIRE_LOG="$CLAUDE_FIRE_LOG"
check "clean_code: a short function is silent with no ledger" is_quiet

# --- Blocking gates decide the same with and without the fast lane ---------------
GATE_PAYLOAD=$(jq -nc --arg f "$REPO/.enforce.json" --arg d "$REPO" \
  '{hook_event_name:"PreToolUse",tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"{}"}}')
gate_output() { # gate_output <hook-name>: stdout and stderr together, then the exit status
  (cd "$REPO" && printf '%s' "$GATE_PAYLOAD" | bash "$HOOKS/$1.sh" 2>&1; echo "exit=$?")
}
for gate in protected-path-guard scope-widening-gate; do
  set_ledger absent; WITHOUT_LANE=$(gate_output "$gate")
  set_ledger fast; WITH_LANE=$(gate_output "$gate")
  check "$gate: identical output with no ledger and with the fast lane" test "$WITHOUT_LANE" = "$WITH_LANE"

  printf '{"branch":"feat/q","scope":["docs/**"]}\n' > "$LEDGER"; WITHOUT_LANE=$(gate_output "$gate")
  printf '{"branch":"feat/q","scope":["docs/**"],"lane":"fast"}\n' > "$LEDGER"; WITH_LANE=$(gate_output "$gate")
  check "$gate: identical output with a declared scope, with and without the fast lane" test "$WITHOUT_LANE" = "$WITH_LANE"
  check "$gate: the scoped Write draws a decision rather than silence" test "$WITH_LANE" != "exit=0"
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "build-lane-quiet.test.sh PASS"
