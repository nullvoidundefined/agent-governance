#!/usr/bin/env bash
# Covers: hook:credential-read-guard
# C-7: the Read and Grep tool calls on a credential path deny, ordinary paths
# pass, settings.json registers credential-read-guard.sh for Read, Grep and
# Bash, and permissions.deny carries Read entries for ~/.kube/** and
# **/*.tfvars as the second layer. Everything runs in a temp repo and a temp
# HOME; no real file is touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
REPO="$WORK/repo"; FAKE_HOME="$WORK/home"
mkdir -p "$REPO/src" "$REPO/infra" "$FAKE_HOME/.aws" "$FAKE_HOME/.ssh" "$FAKE_HOME/.kube"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q
fail=0
bad() { echo "FAIL: $*"; fail=1; }

HOOK="$CLAUDE_HARNESS_ROOT/hooks/credential-read-guard.sh"
SETTINGS="$CLAUDE_HARNESS_ROOT/settings.json"
if [ ! -f "$HOOK" ]; then
  bad "hook missing: $HOOK"
fi

# decide <payload>: prints allow or deny (exit 2 counts as deny).
decide() {
  local out rc d
  [ -f "$HOOK" ] || { printf 'error(hook missing)'; return; }
  out=$(cd "$REPO" && printf '%s' "$1" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    HOME="$FAKE_HOME" CLAUDE_FIRE_LOG=/dev/null CLAUDE_HARNESS_ROOT="$CLAUDE_HARNESS_ROOT" bash "$HOOK" 2>/dev/null); rc=$?
  if [ "$rc" -eq 2 ]; then printf 'deny'; return; fi
  if [ "$rc" -ne 0 ]; then printf 'error(exit %s)' "$rc"; return; fi
  [ -n "$out" ] || { printf 'allow'; return; }
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  case "$d" in allow|ask|deny) printf '%s' "$d" ;; *) printf 'error(no decision)' ;; esac
}

check_read() { # <want> <path>
  local got
  got=$(decide "$(jq -n --arg p "$2" --arg c "$REPO" '{tool_name:"Read",tool_input:{file_path:$p},cwd:$c}')")
  [ "$got" = "$1" ] || bad "Read $2: expected $1, got $got"
}
check_grep() { # <want> <path>
  local got
  got=$(decide "$(jq -n --arg p "$2" --arg c "$REPO" '{tool_name:"Grep",tool_input:{pattern:"x",path:$p},cwd:$c}')")
  [ "$got" = "$1" ] || bad "Grep path $2: expected $1, got $got"
}

check_read deny  "$REPO/.env"
check_read deny  "$FAKE_HOME/.aws/credentials"
check_read deny  "$REPO/infra/prod.tfvars"
check_read deny  "$FAKE_HOME/.kube/config"
check_grep deny  "$FAKE_HOME/.ssh"
check_read allow "$REPO/.env.example"
check_read allow "$FAKE_HOME/.ssh/id_ed25519.pub"
check_read allow "$REPO/src/app.ts"
check_grep allow "$REPO/src"

# A deny never carries a value from the file.
SENT="sentinel-$RANDOM-$RANDOM"
printf 'STRIPE_SECRET_KEY=%s\n' "$SENT" >"$REPO/.env"
if [ -f "$HOOK" ]; then
  out=$(cd "$REPO" && jq -n --arg p "$REPO/.env" --arg c "$REPO" '{tool_name:"Read",tool_input:{file_path:$p},cwd:$c}' \
    | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE HOME="$FAKE_HOME" CLAUDE_FIRE_LOG=/dev/null bash "$HOOK" 2>&1)
  case "$out" in *"$SENT"*) bad "hook output contains the file's value" ;; esac
fi

# Registration in settings.json.
registered() { # <tool name>: does a PreToolUse matcher covering it run the hook?
  jq -e --arg t "$1" '[.hooks.PreToolUse[]
    | select(.matcher as $m | $t | test("^(" + $m + ")$"))
    | .hooks[].command | select(endswith("credential-read-guard.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1
}
for t in Read Grep Bash; do
  registered "$t" || bad "settings.json: credential-read-guard.sh is not registered for $t"
done
for p in 'Read(~/.kube/**)' 'Read(**/*.tfvars)'; do
  jq -e --arg p "$p" '[.permissions.deny[] | select(contains($p) or (. == $p) or (sub("^Read\\(//?"; "Read(") == $p))] | length > 0' "$SETTINGS" >/dev/null 2>&1 \
    || bad "settings.json: permissions.deny has no entry for $p"
done

[ "$fail" -eq 0 ] && echo "PASS: credential-read-guard-tools"
exit "$fail"
