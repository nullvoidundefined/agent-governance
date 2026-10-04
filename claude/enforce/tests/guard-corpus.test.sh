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

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q

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

fail=0; n=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  want=${line%% *}; cmd=${line#* }
  case "$want" in allow|ask|deny) ;; *) echo "FAIL: bad expectation '$want' in row: $line"; fail=1; continue ;; esac
  n=$((n + 1))
  got=$(decide_command "$cmd")
  [ "$got" = "$want" ] || { echo "FAIL: expected $want, got $got: $cmd"; fail=1; }
done < "$CORPUS"

[ "$n" -gt 0 ] || { echo "FAIL: corpus has no rows"; exit 1; }
[ "$fail" -eq 0 ] && echo "PASS: guard-corpus ($n rows, ${#HOOKS[@]} hooks)"
exit "$fail"
