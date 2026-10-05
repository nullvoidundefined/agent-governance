#!/usr/bin/env bash
# Covers: hook:destructive-ops-guard hook:destructive-db-guard hook:destructive-command-guard hook:git-workflow-guard
# guard-corpus: feeds every row of fixtures/guard-corpus.txt through every
# PreToolUse Bash hook registered in settings.json, in a scratch git repo, and
# compares the combined decision (deny beats ask beats allow) with the row's
# expected one. The corpus holds both commands that must be stopped and safe
# look-alikes that must pass, so a guard change that adds false positives
# fails here as surely as one that lets a destructive command through.
#
# Row format: <allow|ask|deny> <command>, split at the first space. Blank
# lines and lines starting with # are skipped. A hook that exits 2 counts as
# deny; a hook file that is missing, exits with any other nonzero status, or
# prints something other than a decision fails the run, so a broken guard can
# never read as allow.
#
# The scratch repo carries a fixed .enforce.json (environments), so rows can
# exercise the production/preview/testing lists: production holds
# db.internal.acme.net and gke_acme_main, preview holds *.preview.acme.dev,
# testing holds ci-db.acme.net and prod-mirror.testing.acme.net.
#
# The same corpus then runs through codex/hooks/codex-hook-adapter.sh and
# cursor/hooks/claude-hook-adapter.sh with the same hook list. Each adapter
# must reach the row's decision too; a mismatch prints
# "FAIL: <adapter>: expected X, got Y: cmd". Codex cannot ask, so the Codex run
# sets CLAUDE_CODEX_ASK_POLICY=allow and reads the CONFIRM note as an ask.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CORPUS="$(dirname "${BASH_SOURCE[0]}")/fixtures/guard-corpus.txt"
CORPUS="$(cd "$(dirname "$CORPUS")" && pwd)/$(basename "$CORPUS")"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
[ -f "$CORPUS" ] || { echo "FAIL: corpus missing: $CORPUS"; exit 1; }

HOOKS=()
while IFS= read -r h; do
  HOOKS+=("${h/#\~\/.claude/$CLAUDE_HARNESS_ROOT}")
done < <(jq -r '.hooks.PreToolUse[] | select(.matcher as $m | "Bash" | test("^(" + $m + ")$")) | .hooks[].command' "$CLAUDE_HARNESS_ROOT/settings.json")
[ "${#HOOKS[@]}" -gt 0 ] || { echo "FAIL: no PreToolUse Bash hooks found in settings.json"; exit 1; }
for h in "${HOOKS[@]}"; do [ -f "$h" ] || { echo "FAIL: registered hook missing: $h"; exit 1; }; done

WORK=$(mktemp -d) || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# Physical path: macOS mktemp returns /var/..., a symlink to /private/var/...,
# and the delete guard resolves targets physically.
WORK=$(cd "$WORK" && pwd -P)
REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q
cat >"$REPO/.enforce.json" <<'EOF'
{"environments": {
  "production": ["db.internal.acme.net", "gke_acme_main"],
  "preview": ["*.preview.acme.dev"],
  "testing": ["ci-db.acme.net", "prod-mirror.testing.acme.net"]
}}
EOF
CODEX_ADAPTER="$CLAUDE_HARNESS_ROOT/../codex/hooks/codex-hook-adapter.sh"
CURSOR_ADAPTER="$CLAUDE_HARNESS_ROOT/../cursor/hooks/claude-hook-adapter.sh"
for a in "$CODEX_ADAPTER" "$CURSOR_ADAPTER"; do
  [ -f "$a" ] || { echo "FAIL: adapter missing: $a"; exit 1; }
done
# The adapters also mirror the permissions.deny/ask rules of settings.json,
# which the Claude run above does not evaluate (Claude Code applies those
# itself). To compare hook decisions only, the adapters get a copy of the
# settings with the permissions block emptied.
ADAPTER_SETTINGS="$WORK/adapter-settings.json"
jq '.permissions = {allow: [], deny: [], ask: []}' "$CLAUDE_HARNESS_ROOT/settings.json" >"$ADAPTER_SETTINGS" \
  || { echo "FAIL: cannot derive adapter settings"; exit 1; }
HOOK_NAMES=()
for h in "${HOOKS[@]}"; do b=$(basename "$h"); HOOK_NAMES+=("${b%.sh}"); done

# decide_command: prints the combined decision of every Bash hook for $1.
decide_command() {
  local input out rc d verdict=allow h
  input=$(jq -n --arg c "$1" --arg cwd "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,hook_event_name:"PreToolUse"}')
  for h in "${HOOKS[@]}"; do
    out=$(cd "$REPO" && printf '%s' "$input" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      CLAUDE_FIRE_LOG=/dev/null CLAUDE_HARNESS_ROOT="$CLAUDE_HARNESS_ROOT" bash "$h" 2>/dev/null); rc=$?
    if [ "$rc" -eq 2 ]; then d=deny
    elif [ "$rc" -ne 0 ]; then d="error(exit $rc in $(basename "$h"))"
    elif [ -z "$out" ]; then d=allow
    else
      d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
      case "$d" in allow|ask|deny) ;; *) d="error(no decision from $(basename "$h"))" ;; esac
    fi
    case "$d" in
      error*) printf '%s' "$d"; return ;;
      deny) verdict=deny ;;
      ask) [ "$verdict" = deny ] || verdict=ask ;;
    esac
  done
  printf '%s' "$verdict"
}

# decide_codex: the decision the Codex adapter reaches for $1.
decide_codex() {
  local input out rc d
  input=$(jq -n --arg c "$1" --arg cwd "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,hook_event_name:"PreToolUse"}')
  out=$(cd "$REPO" && printf '%s' "$input" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u CLAUDE_HOOK_RUNTIME \
    CLAUDE_FIRE_LOG=/dev/null CLAUDE_HOME="$CLAUDE_HARNESS_ROOT" CLAUDE_SETTINGS_FILE="$ADAPTER_SETTINGS" CLAUDE_CODEX_ASK_POLICY=allow \
    CLAUDE_CODEX_STATE_DIR="$WORK/codex-state" CLAUDE_CODEX_WRITE_TARGET_HOOKS="" \
    bash "$CODEX_ADAPTER" "${HOOK_NAMES[@]}" 2>/dev/null); rc=$?
  if [ "$rc" -eq 2 ]; then printf 'deny'; return; fi
  if [ "$rc" -ne 0 ]; then printf 'error(exit %s)' "$rc"; return; fi
  [ -n "$out" ] || { printf 'allow'; return; }
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  case "$d" in
    deny) printf 'deny'; return ;;
    '') ;;
    *) printf 'error(decision %s)' "$d"; return ;;
  esac
  if printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null | grep -q 'CONFIRM WITH THE USER BEFORE PROCEEDING'; then
    printf 'ask'
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    printf 'allow'
  else
    printf 'error(no decision)'
  fi
}

# decide_cursor: the decision the Cursor adapter reaches for $1.
decide_cursor() {
  local input out rc d
  input=$(jq -n --arg c "$1" --arg cwd "$REPO" '{command:$c,cwd:$cwd,workspace_roots:[$cwd],conversation_id:"guard-corpus"}')
  out=$(cd "$REPO" && printf '%s' "$input" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    CLAUDE_FIRE_LOG=/dev/null CLAUDE_HOME="$CLAUDE_HARNESS_ROOT" CLAUDE_SETTINGS_FILE="$ADAPTER_SETTINGS" \
    CLAUDE_CURSOR_STATE_DIR="$WORK/cursor-state" \
    bash "$CURSOR_ADAPTER" beforeShellExecution "${HOOK_NAMES[@]}" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then printf 'error(exit %s)' "$rc"; return; fi
  d=$(printf '%s' "$out" | jq -r '.permission // empty' 2>/dev/null)
  case "$d" in allow|ask|deny) printf '%s' "$d" ;; *) printf 'error(no decision)' ;; esac
}

fail=0; n=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  want=${line%% *}; cmd=${line#* }
  case "$want" in allow|ask|deny) ;; *) echo "FAIL: bad expectation '$want' in row: $line"; fail=1; continue ;; esac
  n=$((n + 1))
  got=$(decide_command "$cmd")
  [ "$got" = "$want" ] || { echo "FAIL: expected $want, got $got: $cmd"; fail=1; }
  got=$(decide_codex "$cmd")
  [ "$got" = "$want" ] || { echo "FAIL: codex adapter: expected $want, got $got: $cmd"; fail=1; }
  got=$(decide_cursor "$cmd")
  [ "$got" = "$want" ] || { echo "FAIL: cursor adapter: expected $want, got $got: $cmd"; fail=1; }
done < "$CORPUS"

[ "$n" -gt 0 ] || { echo "FAIL: corpus has no rows"; exit 1; }
[ "$fail" -eq 0 ] && echo "PASS: guard-corpus ($n rows, ${#HOOKS[@]} hooks, claude+codex+cursor)"
exit "$fail"
