#!/usr/bin/env bash
# Covers: hook:audit-log
# Verifies hooks/audit-log.sh (hardening PR 4, spec 2026-10-05-audit-log.md):
# A-1 one JSON line per completed tool call, keys in order, file per UTC day,
# modes 0600/0700, registered under PostToolUse with matcher ".*"; A-2 the
# input summary is capped at 2000 characters with a "..." marker and redacted
# (a run-time-built secret-pattern value and URL userinfo never reach the
# file); A-4 the hook always exits 0 with empty stdout (unwritable directory,
# missing jq, malformed payload); A-5 rotation removes only *.jsonl older than
# 30 days; A-8 a line fits in PIPE_BUF and concurrent calls never interleave.
# Credential-shaped values are built at run time from parts, never literals.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/audit-log.sh"
PATTERNS="$CLAUDE_HARNESS_ROOT/enforce/secret-patterns.txt"
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
[ -f "$HOOK" ] || fail "setup: $HOOK does not exist"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
REPO="$WORK/audit-repo-x"; mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$REPO" init -q
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"

repeat() { printf "$1%.0s" $(seq 1 "$2"); }

# run_hook <audit dir> <payload> [extra env assignment]: sets OUT_FILE, STATUS.
OUT_FILE="$WORK/stdout.txt"
run_hook() {
  STATUS=0
  printf '%s' "$2" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    AGENT_AUDIT_DIR="$1" bash "$HOOK" >"$OUT_FILE" 2>/dev/null || STATUS=$?
}
# expect_quiet <label>: exit 0 and nothing on stdout.
expect_quiet() {
  [ "$STATUS" -eq 0 ] || fail "$1: hook exited $STATUS (must always exit 0)"
  [ ! -s "$OUT_FILE" ] || fail "$1: hook printed to stdout: $(head -c 200 "$OUT_FILE")"
}
payload() { # tool_name tool_input-json [cwd] [session]
  jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-$REPO}" --arg s "${4:-sess-1}" \
    '{hook_event_name:"PostToolUse",session_id:$s,cwd:$c,tool_name:$t,tool_input:$i,tool_response:{}}'
}
TODAY_FILE() { echo "$1/$(date -u +%Y-%m-%d).jsonl"; }

# ---- A-1: one valid line per call, keys in order, UTC-dated file, modes ----
D1="$WORK/audit1"   # not pre-created: the hook makes it 0700
run_hook "$D1" "$(payload Bash '{"command":"ls -la /tmp"}')"; expect_quiet "Bash call"
run_hook "$D1" "$(payload Read '{"file_path":"/etc/hostname"}')"; expect_quiet "Read call"
run_hook "$D1" "$(payload Grep '{"pattern":"needle","path":"/srv/src"}')"; expect_quiet "Grep call"
run_hook "$D1" "$(payload mcp__x__y '{"alpha":"valuea-sentinel","beta":2}')"; expect_quiet "MCP call"
run_hook "$D1" "$(payload Agent '{"description":"survey the tests","prompt":"long prompt body"}')"; expect_quiet "Agent call"
F1=$(TODAY_FILE "$D1")
if [ ! -f "$F1" ]; then
  fail "A-1: no file named for the UTC date at $F1 (dir holds: $(ls "$D1" 2>/dev/null | tr '\n' ' '))"
else
  [ "$(wc -l <"$F1")" -eq 5 ] || fail "A-1: expected 5 lines for 5 calls, got $(wc -l <"$F1")"
  jq -e . "$F1" >/dev/null 2>&1 || fail "A-1: a line is not valid JSON"
  [ "$(stat -c %a "$F1")" = 600 ] || fail "A-1: file mode $(stat -c %a "$F1"), want 600"
  [ "$(stat -c %a "$D1")" = 700 ] || fail "A-1: dir mode $(stat -c %a "$D1"), want 700"
  while IFS= read -r line; do
    keys=$(printf '%s' "$line" | jq -r 'keys_unsorted | join(",")' 2>/dev/null)
    [ "$keys" = "ts,session,event,tool,repo,cwd,input" ] || fail "A-1: key order was '$keys'"
  done <"$F1"
  l() { sed -n "$1p" "$F1"; }
  [ "$(l 1 | jq -r .tool)" = Bash ] && [ "$(l 1 | jq -r .event)" = tool ] || fail "A-1: line 1 not a Bash tool event"
  [ "$(l 1 | jq -r .session)" = sess-1 ] || fail "A-1: session not taken from session_id"
  [ "$(l 1 | jq -r .repo)" = audit-repo-x ] || fail "A-1: repo should be the git top-level basename, got $(l 1 | jq -r .repo)"
  [ "$(l 1 | jq -r .cwd)" = "$REPO" ] || fail "A-1: cwd not recorded"
  l 1 | jq -r .ts | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' || fail "A-1: ts is not UTC ISO-8601: $(l 1 | jq -r .ts)"
  [ "$(l 1 | jq -r .input)" = "ls -la /tmp" ] || fail "A-1: Bash input should be the command, got $(l 1 | jq -r .input)"
  [ "$(l 2 | jq -r .input)" = "/etc/hostname" ] || fail "A-1: Read input should be file_path, got $(l 2 | jq -r .input)"
  l 3 | jq -r .input | grep -q needle && l 3 | jq -r .input | grep -q /srv/src || fail "A-1: Grep input should hold pattern and path"
  mi=$(l 4 | jq -r .input)
  { printf '%s' "$mi" | grep -q alpha && printf '%s' "$mi" | grep -q beta; } || fail "A-1: MCP input should name the argument keys, got $mi"
  printf '%s' "$mi" | grep -q 'valuea-sentinel' && fail "A-1: MCP input leaked an argument value"
  [ "$(l 4 | jq -r .tool)" = mcp__x__y ] || fail "A-1: MCP tool name not recorded"
  [ "$(l 5 | jq -r .input)" = "survey the tests" ] || fail "A-1: Agent input should be the description, got $(l 5 | jq -r .input)"
fi

# Non-git cwd and missing session id give "-".
D1B="$WORK/audit1b"
run_hook "$D1B" "$(jq -nc --arg c "$PLAIN" '{tool_name:"Bash",cwd:$c,tool_input:{command:"true"},tool_response:{}}')"
F1B=$(TODAY_FILE "$D1B")
if [ -f "$F1B" ]; then
  [ "$(jq -r .repo "$F1B")" = "-" ] || fail "A-1: repo outside git should be -, got $(jq -r .repo "$F1B")"
  [ "$(jq -r .session "$F1B")" = "-" ] || fail "A-1: missing session_id should be -, got $(jq -r .session "$F1B")"
else
  fail "A-1: no file written for a non-git cwd"
fi

# Registration in settings.json: PostToolUse, matcher ".*".
jq -e '.hooks.PostToolUse[] | select(.matcher == ".*") | .hooks[] | select(.command | test("audit-log\\.sh$"))' \
  "$CLAUDE_HARNESS_ROOT/settings.json" >/dev/null 2>&1 \
  || fail "A-1: settings.json does not register audit-log.sh under PostToolUse with matcher \".*\""

# ---- A-2: cap and redaction ----
D2="$WORK/audit2"
LONG=$(repeat x 5000)
run_hook "$D2" "$(payload Bash "$(jq -nc --arg c "$LONG" '{command:$c}')")"; expect_quiet "long command"
F2=$(TODAY_FILE "$D2")
if [ -f "$F2" ]; then
  inp=$(head -1 "$F2" | jq -r .input)
  n=${#inp}
  { [ "$n" -ge 1997 ] && [ "$n" -le 2003 ]; } || fail "A-2: capped input length $n, want about 2000"
  case "$inp" in *...) : ;; *) fail "A-2: capped input does not end with the ... marker" ;; esac
else
  fail "A-2: no file for the long command"
fi

# A value matching a secret-patterns.txt pattern (built at run time, and
# proven to match the real pattern list) and URL userinfo.
SECRET="ghp_$(repeat a 36)"
PAT=$(grep -vE '^[[:space:]]*(#|$)' "$PATTERNS" | paste -sd'|' -)
printf '%s' "$SECRET" | grep -qE "$PAT" || fail "setup: the run-time secret does not match secret-patterns.txt"
SENT="pw$(printf 'Qz')$(repeat 7 9)Lm"
URLV="postgres://u:${SENT}@h/db"
BEAR="bearer$(repeat k 12)tok"
D3="$WORK/audit3"
run_hook "$D3" "$(payload Bash "$(jq -nc --arg c "curl -H 'Authorization: Bearer $BEAR' $URLV -d password=$SENT token=$SENT x=$SECRET" '{command:$c}')")"; expect_quiet "secret command"
run_hook "$D3" "$(payload Read "$(jq -nc --arg f "/tmp/$SECRET" '{file_path:$f}')")"
F3=$(TODAY_FILE "$D3")
if [ -f "$F3" ]; then
  for v in "$SECRET" "$SENT" "$BEAR"; do
    grep -qF "$v" "$F3" && fail "A-2: a redacted value reached the file (${v:0:6}...)"
  done
  head -1 "$F3" | jq -r .input | grep -qF '***' || fail "A-2: redaction marker *** missing"
  head -1 "$F3" | jq -r .input | grep -qF 'postgres://' || fail "A-2: the URL scheme should survive redaction"
else
  fail "A-2: no file for the secret command"
fi

# ---- A-10: keyed redaction covers quoted values and the colon separator ----
KV="kv$(printf 'Wx')$(repeat 5 8)Zd"   # run-time value, no secret-pattern shape
n10=0
check_redacted() { # label command-text value
  local d f
  n10=$((n10 + 1)); d="$WORK/audit10_$n10"
  run_hook "$d" "$(payload Bash "$(jq -nc --arg c "$2" '{command:$c}')")"
  f=$(TODAY_FILE "$d")
  [ -f "$f" ] || { fail "$1: no file written"; return; }
  grep -qF "$3" "$f" && fail "$1: the value reached the file"
  head -1 "$f" | jq -r .input | grep -qF '***' || fail "$1: *** marker missing: $(head -1 "$f" | jq -r .input)"
}
for key in password passwd secret token api_key api-key access_token auth_token PASSWORD Api_Key; do
  check_redacted "A-10 $key=\"v\"" "run --$key=\"$KV\" x" "$KV"
  check_redacted "A-10 $key='v'" "run $key='$KV' x" "$KV"
  check_redacted "A-10 $key: v" "run $key: $KV x" "$KV"
  check_redacted "A-10 $key: 'v'" "run $key: '$KV' x" "$KV"
  check_redacted "A-10 \"$key\": \"v\"" "echo '{\"$key\": \"$KV\"}'" "$KV"
  check_redacted "A-10 $key=v" "run $key=$KV x" "$KV"
done

# ---- A-11: mysql -p<value> and credential-bearing headers ----
check_redacted "A-11 mysql -pVALUE" "mysql -u root -p$KV db" "$KV"
check_redacted "A-11 X-Api-Key header" "curl -H 'X-Api-Key: $KV' https://example.org" "$KV"
check_redacted "A-11 Cookie header" "curl -H 'Cookie: sid=$KV' https://example.org" "$KV"
check_redacted "A-11 Set-Cookie header" "curl -H \"Cookie: $KV\" https://example.org" "$KV"
check_redacted "A-11 X-Auth-Token header" "curl -H 'X-Auth-Token: $KV' https://example.org" "$KV"
check_redacted "A-11 X-Secret header" "curl -H 'X-Secret: $KV' https://example.org" "$KV"
# Negative: a harmless header and a plain -p option are left alone.
D11="$WORK/audit11n"
run_hook "$D11" "$(payload Bash '{"command":"curl -H '"'"'Accept: text/html'"'"' https://example.org"}')"
F11=$(TODAY_FILE "$D11")
[ -f "$F11" ] && head -1 "$F11" | jq -r .input | grep -qF 'Accept: text/html' || fail "A-11: a harmless Accept header was redacted"

# ---- A-12: degraded redaction when secret-patterns.txt is missing or broken ----
# The helper finds the patterns at <its dir>/../enforce/secret-patterns.txt, so
# a copy of hooks/ in a temp root with no enforce/ has no patterns file.
check_degraded() { # label root
  local d f line inp
  d="$WORK/audit12_$1"
  printf '%s' "$(payload Bash "$(jq -nc --arg c "echo hello password=$KV; curl -H 'X-Api-Key: $KV' https://example.org; mysql -p$KV db" '{command:$c}')")" \
    | env -u GIT_DIR AGENT_AUDIT_DIR="$d" bash "$2/hooks/audit-log.sh" >"$OUT_FILE" 2>/dev/null
  f=$(TODAY_FILE "$d")
  [ -f "$f" ] || { fail "A-12 $1: no line written when patterns are unavailable"; return; }
  line=$(head -1 "$f")
  inp=$(printf '%s' "$line" | jq -r .input)
  [ "$inp" != '***' ] || fail "A-12 $1: the whole field was blanked to ***"
  case "$inp" in *"echo hello"*) : ;; *) fail "A-12 $1: the non-secret text was lost: $inp" ;; esac
  grep -qF "$KV" "$f" && fail "A-12 $1: a keyed value reached the file"
  printf '%s' "$inp" | grep -qF '***' || fail "A-12 $1: keyed values were not redacted"
  [ "$(printf '%s' "$line" | jq -r .redaction)" = degraded ] || fail "A-12 $1: line lacks \"redaction\":\"degraded\": $line"
}
R12="$WORK/root12"; mkdir -p "$R12"; cp -R "$CLAUDE_HARNESS_ROOT/hooks" "$R12/hooks"
check_degraded missing "$R12"
R12B="$WORK/root12b"; mkdir -p "$R12B/enforce"; cp -R "$CLAUDE_HARNESS_ROOT/hooks" "$R12B/hooks"
printf '%s\n' 'ghp_[A-Za-z0-9]{36}' '(unclosed[' > "$R12B/enforce/secret-patterns.txt"
check_degraded broken-pattern "$R12B"
# A healthy run carries no degraded marker.
if [ -f "$F3" ]; then
  head -1 "$F3" | jq -e 'has("redaction") | not' >/dev/null 2>&1 || fail "A-12: a healthy line carries a redaction marker"
fi

# ---- A-13: every test that runs a guard hook sets AGENT_AUDIT_DIR ----
TESTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
# Only hooks that source audit-log-append.sh write decision lines; a test that
# names one of them (or drives every registered hook through an adapter or the
# settings.json hook list) must point AGENT_AUDIT_DIR at a scratch directory.
LOGGING=$(grep -l 'audit_log_' "$CLAUDE_HARNESS_ROOT"/hooks/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -v '^audit-log' | sed 's/\.sh$//' | paste -sd'|' -)
[ -n "$LOGGING" ] || fail "A-13: no guard sources audit-log-append.sh"
for t in "$TESTS_DIR"/*.test.sh; do
  case "$(basename "$t")" in audit-log.test.sh | audit-log-decisions.test.sh | audit-dir-protection.test.sh) continue ;; esac
  grep -qE "hooks/($LOGGING)\.sh|HOOKS\[|-hook-adapter\.sh" "$t" || continue
  grep -q 'AGENT_AUDIT_DIR\|harness-root\.sh' "$t" || fail "A-13: $(basename "$t") runs a logging guard but neither sets AGENT_AUDIT_DIR nor sources harness-root.sh"
done
grep -q 'AGENT_AUDIT_DIR' "$CLAUDE_HARNESS_ROOT/enforce/harness-root.sh" \
  || fail "A-13: enforce/harness-root.sh does not export AGENT_AUDIT_DIR to a scratch dir when unset"

# ---- A-4: never blocks ----
echo plain > "$WORK/afile"
run_hook "$WORK/afile/sub" "$(payload Bash '{"command":"ls"}')"; expect_quiet "unwritable dir"
run_hook "$WORK/audit4" 'not json {{{'; expect_quiet "malformed JSON"
[ -f "$HOOK" ] && [ -z "$(ls "$WORK/audit4" 2>/dev/null)" ] || [ ! -f "$HOOK" ] || fail "A-4: malformed JSON produced a log line"
run_hook "$WORK/audit4" ''; expect_quiet "empty stdin"

NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
OLD_IFS=$IFS; IFS=:
for dir in $PATH; do
  [ -d "$dir" ] || continue
  for prog in "$dir"/*; do
    [ -f "$prog" ] && [ -x "$prog" ] || continue
    name=$(basename "$prog"); [ "$name" = jq ] && continue
    [ -e "$NOJQ/$name" ] || ln -s "$prog" "$NOJQ/$name"
  done
done
IFS=$OLD_IFS
if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then fail "setup: jq still resolves on the no-jq PATH"; fi
STATUS=0
payload Bash '{"command":"ls"}' | env -u GIT_DIR AGENT_AUDIT_DIR="$WORK/audit5" PATH="$NOJQ" bash "$HOOK" >"$OUT_FILE" 2>/dev/null || STATUS=$?
expect_quiet "missing jq"

# ---- A-5: rotation ----
D6="$WORK/audit6"; mkdir -p "$D6"; chmod 700 "$D6"
OLD=$(date -u -d '31 days ago' +%Y-%m-%d); NEW=$(date -u -d '29 days ago' +%Y-%m-%d)
printf '{}\n' > "$D6/$OLD.jsonl"; touch -d '31 days ago' "$D6/$OLD.jsonl"
printf '{}\n' > "$D6/$NEW.jsonl"; touch -d '29 days ago' "$D6/$NEW.jsonl"
printf 'keep\n' > "$D6/notes.txt"; touch -d '90 days ago' "$D6/notes.txt"
run_hook "$D6" "$(payload Bash '{"command":"ls"}')"; expect_quiet "rotation call"
[ ! -e "$D6/$OLD.jsonl" ] || fail "A-5: the 31-day-old .jsonl was not removed"
[ -e "$D6/$NEW.jsonl" ] || fail "A-5: the 29-day-old .jsonl was removed"
[ -e "$D6/notes.txt" ] || fail "A-5: a non-jsonl file was removed"
[ -f "$(TODAY_FILE "$D6")" ] || fail "A-5: today's file was not written"

# ---- A-8: one write per line, at most PIPE_BUF, no interleaving ----
D7="$WORK/audit7"
BIG=$(repeat y 5000)
pids=()
for i in $(seq 1 20); do
  ( run_hook() { :; }
    jq -nc --arg c "$BIG$i" --arg s "s$i" --arg d "$REPO" '{session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c},tool_response:{}}' \
      | AGENT_AUDIT_DIR="$D7" bash "$HOOK" >/dev/null 2>&1 ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
F7=$(TODAY_FILE "$D7")
if [ -f "$F7" ]; then
  [ "$(wc -l <"$F7")" -eq 20 ] || fail "A-8: expected 20 lines from 20 concurrent calls, got $(wc -l <"$F7")"
  jq -e . "$F7" >/dev/null 2>&1 || fail "A-8: interleaved or invalid line among concurrent writes"
  max=$(awk '{ if (length($0) + 1 > m) m = length($0) + 1 } END { print m + 0 }' "$F7")
  [ "$max" -le 4096 ] || fail "A-8: a line is $max bytes, over PIPE_BUF (4096)"
else
  fail "A-8: no file written by concurrent calls"
fi

if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS assertion(s)"; exit 1; fi
echo "PASS: audit-log"
