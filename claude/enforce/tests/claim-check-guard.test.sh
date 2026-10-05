#!/usr/bin/env bash
# Covers: hook:claim-check-guard
# Verifies the Stop/SubagentStop hook claim-check-guard.sh blocks a final
# message that claims something verified, fixed, or passing without citing a
# command run this turn or hedging, and fails open on anything it cannot read.
# Fixtures: fixtures/claim-check/<block|pass>-<name>.jsonl. The expected
# decision is the filename prefix; the final message is the last assistant
# text entry of the transcript. Each fixture runs twice: transcript only, and
# with that message also carried as last_assistant_message in the payload.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/claim-check-guard.sh"
SETTINGS="$CLAUDE_HARNESS_ROOT/settings.json"
FIXDIR="$HERE/fixtures/claim-check"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

FAILS=0
CASES=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# A missing hook must fail every case, including the "no output" ones.
run_hook() { # stdin JSON on $1; sets OUT and RC
  local input="$1"
  if [ ! -x "$HOOK" ]; then OUT=""; RC=127; return; fi
  OUT=$(printf '%s' "$input" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR "$HOOK" 2>/dev/null)
  RC=$?
}

assert_pass() { # name
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "$1: expected no output and exit 0, got rc=$RC out=$OUT"; fi
}

assert_block() { # name
  local name="$1" decision reason
  if [ "$RC" -ne 0 ]; then fail "$name: expected exit 0 with a block, got rc=$RC"; return; fi
  decision=$(printf '%s' "$OUT" | jq -r '.decision // "none"' 2>/dev/null || echo invalid)
  [ "$decision" = "block" ] || { fail "$name: expected block, got decision=$decision out=$OUT"; return; }
  reason=$(printf '%s' "$OUT" | jq -r '.reason // ""')
  case "$reason" in *"assumed, not run"*) ;; *) fail "$name: reason lacks 'assumed, not run'" ;; esac
}

event() { # transcript path, [stop_hook_active]
  jq -cn --arg p "$1" --argjson a "${2:-false}" \
    '{session_id:"s",transcript_path:$p,hook_event_name:"Stop",stop_hook_active:$a}'
}

final_of() { # transcript file: text of the last assistant entry holding text
  jq -rs 'map(select(.type=="assistant" and (.message.content|type)=="array" and any(.message.content[]; .type=="text")))
          | last | .message.content | map(select(.type=="text")|.text) | join("\n")' "$1"
}

check() { # name, expected (block|pass)
  if [ "$2" = block ]; then assert_block "$1"; else assert_pass "$1"; fi
}

# ---- V-7 corpus size
NB=$(ls "$FIXDIR"/block-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
NP=$(ls "$FIXDIR"/pass-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
CASES=$((CASES + 1))
[ "$NB" -ge 15 ] || fail "v7: need at least 15 block fixtures, found $NB"
[ "$NP" -ge 15 ] || fail "v7: need at least 15 pass fixtures, found $NP"

if [ ! -x "$HOOK" ]; then
  fail "hook missing or not executable: $HOOK"
fi

# ---- V-1..V-4 over the corpus, both payload shapes
for f in "$FIXDIR"/block-*.jsonl "$FIXDIR"/pass-*.jsonl; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .jsonl)"
  want="${name%%-*}"
  msg="$(final_of "$f")"

  CASES=$((CASES + 1))
  run_hook "$(event "$f")"
  check "$name (transcript only)" "$want"

  CASES=$((CASES + 1))
  run_hook "$(event "$f" | jq -c --arg m "$msg" '. + {last_assistant_message:$m}')"
  check "$name (payload message)" "$want"
done

# ---- V-4 payload message wins over the transcript tail, both directions
BLOCK_FIX="$(ls "$FIXDIR"/block-*.jsonl 2>/dev/null | head -n 1)"
PASS_FIX="$(ls "$FIXDIR"/pass-*.jsonl 2>/dev/null | head -n 1)"
if [ -n "$BLOCK_FIX" ] && [ -n "$PASS_FIX" ]; then
  CASES=$((CASES + 1))
  run_hook "$(event "$PASS_FIX" | jq -c --arg m "$(final_of "$BLOCK_FIX")" '. + {last_assistant_message:$m}')"
  assert_block "v4 claiming payload over clean transcript"

  CASES=$((CASES + 1))
  run_hook "$(event "$BLOCK_FIX" | jq -c --arg m "$(final_of "$PASS_FIX")" '. + {last_assistant_message:$m}')"
  assert_pass "v4 clean payload over claiming transcript"
fi

# ---- V-5 SubagentStop uses agent_transcript_path, else transcript_path
if [ -n "$BLOCK_FIX" ] && [ -n "$PASS_FIX" ]; then
  sub_event() { # transcript_path, agent_transcript_path (may be empty)
    jq -cn --arg p "$1" --arg a "$2" \
      '{session_id:"s",transcript_path:$p,hook_event_name:"SubagentStop",stop_hook_active:false}
       + (if $a == "" then {} else {agent_transcript_path:$a} end)'
  }
  CASES=$((CASES + 1))
  run_hook "$(sub_event "$PASS_FIX" "$BLOCK_FIX")"
  assert_block "v5 subagent claim in agent_transcript_path"

  CASES=$((CASES + 1))
  run_hook "$(sub_event "$BLOCK_FIX" "$PASS_FIX")"
  assert_pass "v5 agent_transcript_path preferred over transcript_path"

  CASES=$((CASES + 1))
  run_hook "$(sub_event "$BLOCK_FIX" "")"
  assert_block "v5 subagent falls back to transcript_path"
fi

# ---- V-6 fail open
if [ -n "$BLOCK_FIX" ]; then
  CASES=$((CASES + 1))
  run_hook "$(event "$BLOCK_FIX" true)"
  assert_pass "v6 stop_hook_active true"

  CASES=$((CASES + 1))
  run_hook "$(event "$WORK/does-not-exist.jsonl")"
  assert_pass "v6 missing transcript"

  CASES=$((CASES + 1))
  run_hook '{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}'
  assert_pass "v6 no transcript_path"

  CASES=$((CASES + 1))
  run_hook 'not json at all'
  assert_pass "v6 malformed payload"

  CASES=$((CASES + 1))
  printf 'not json\n{broken\n' > "$WORK/bad.jsonl"
  run_hook "$(event "$WORK/bad.jsonl")"
  assert_pass "v6 malformed transcript"
fi

# ---- V-8 registration and runtime
CASES=$((CASES + 1))
ORDER=$(jq -r '[.hooks.Stop // [] | .[] | .hooks[]? | .command // ""] | to_entries
  | (map(select(.value | contains("turn-summary-guard.sh"))) | first | .key // -1) as $t
  | (map(select(.value | contains("claim-check-guard.sh"))) | first | .key // -1) as $c
  | if $t >= 0 and $c > $t then "ok" else "bad" end' "$SETTINGS" 2>/dev/null || echo bad)
[ "$ORDER" = ok ] || fail "v8: claim-check-guard.sh must be registered under Stop after turn-summary-guard.sh"

CASES=$((CASES + 1))
TIMEOUT=$(jq -r '[.hooks.Stop // [] | .[] | .hooks[]? | select((.command // "") | contains("claim-check-guard.sh")) | .timeout] | first // "none"' "$SETTINGS" 2>/dev/null || echo none)
[ "$TIMEOUT" = 10 ] || fail "v8: claim-check-guard.sh Stop timeout must be 10, got $TIMEOUT"

CASES=$((CASES + 1))
SUB_HITS=$(jq '[.hooks.SubagentStop // [] | .[] | .hooks[]? | select((.command // "") | contains("claim-check-guard.sh"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
[ "$SUB_HITS" -ge 1 ] || fail "v5/v8: claim-check-guard.sh not registered under SubagentStop"

CASES=$((CASES + 1))
if command -v python3 >/dev/null 2>&1; then
  python3 - "$WORK/big.jsonl" <<'PY'
import json, sys
pad = "x" * 900
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}) + "\n")
    for i in range(5500):
        if i % 2:
            e = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t%d" % i, "name": "Bash", "input": {"command": "echo step %d %s" % (i, pad)}}]}}
        else:
            e = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t%d" % (i - 1), "content": pad}]}}
        f.write(json.dumps(e) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Tests pass (`echo step 5 `)."}]}}) + "\n")
PY
  SIZE=$(wc -c < "$WORK/big.jsonl" | tr -d ' ')
  [ "$SIZE" -ge 5000000 ] || fail "v8: generated transcript only $SIZE bytes"
  T0=$(date +%s%N)
  run_hook "$(event "$WORK/big.jsonl")"
  T1=$(date +%s%N)
  MS=$(( (T1 - T0) / 1000000 ))
  [ "$MS" -lt 300 ] || fail "v8: 5 MB transcript took ${MS} ms, limit 300"
  [ "$RC" -eq 0 ] || fail "v8: 5 MB transcript run exited $RC"
else
  fail "v8: python3 needed to generate the 5 MB transcript"
fi

# ---- V-9 ports marked unported with a reason
for map in codex-port-map.json cursor-port-map.json; do
  CASES=$((CASES + 1))
  REASON=$(jq -r '.unported_reasons["claim-check-guard"] // ""' "$REPO_ROOT/translate/$map" 2>/dev/null)
  [ "${#REASON}" -ge 10 ] || fail "v9: translate/$map lacks an unported_reasons entry for claim-check-guard"
done

echo "$CASES cases, $FAILS failures"
[ "$FAILS" -eq 0 ]
