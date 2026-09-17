#!/usr/bin/env bash
# hook-latency.test.sh: fail if a per-event hook chain does heavy work. The
# guarded invariant: per-edit hooks stay bash+jq cheap (no Node startup, no
# network). Absolute wall-clock is load-dependent (a busy dev server inflates
# every process spawn), so the budget is normalized against a same-environment
# control: the chain may cost at most BUDGET_MULTIPLIER times the cost of the
# same number of bare bash+jq spawns, with an absolute floor so an idle
# machine never false-fails. A hook that grows a Node or network dependency
# costs 10-100x a bare spawn and blows the multiplier under any load.
set -euo pipefail

# The LIVE copy on purpose, and the one path in this suite that is not
# overridable by design: this fixture measures what a session actually spawns,
# which is the installed hook, not what the checkout would spawn once synced. A
# settings override below lets a caller name a different chain, but the scripts
# timed are always the installed ones. Recorded here because the asymmetry
# looked like the live-versus-repo drift class and was filed as such (2026-09-17
# audit P2-8); it is a deliberate choice, and its sibling claude-md-lint.test.sh
# was the half that really was inconsistent.
#
# THE DELIBERATE EXCEPTION. The 2026-09-18 sweep moved every other fixture in
# both trees onto enforce/harness-root.sh, so that each one resolves the
# implementation it exercises from the checkout it was read from rather than
# from whatever ./sync.sh last installed. This file stays on $HOME because the
# question it answers is a question about the installed chain: a hook that has
# grown a Node or network dependency costs a session real wall-clock only once
# it is installed, and timing the checkout's copy would answer a question
# nobody asked. enforce/tests/fixture-implementation-root.test.sh carries the
# allowlist that records this exception alongside the sweep it is excepted
# from, so the two cannot drift apart silently.
HOOKS_DIR="$HOME/.claude/hooks"
BUDGET_MULTIPLIER=6
BUDGET_FLOOR_MS=250
ROUNDS=3

# SessionStart:resume own floor (final review, MUST-FIX): the shared 250ms
# floor flapped on this chain. Four consecutive runs against the sandboxed
# resume payload below measured 258, 271, 306, and 264ms per round, all
# straddling the control-derived budget of ~270ms (control ~45ms *
# BUDGET_MULTIPLIER 6). The six SessionStart hooks each do real work (git,
# ps, file hashing) unlike the bare-spawn PreToolUse chains the shared floor
# was tuned for, so the shared floor never had honest headroom for this
# chain. This floor is scoped to SessionStart:resume only, passed through
# assert_chain_under_budget's floor_override parameter; BUDGET_FLOOR_MS,
# BUDGET_MULTIPLIER, and both PreToolUse budgets below are untouched.
SESSION_START_BUDGET_FLOOR_MS=400

# The chains are read from settings.json, not listed here: a hand-kept list
# drifted from the registered chain three audits running (2026-07-31, 2026-08-21
# P3-7, 2026-09-04 P2-7), each time leaving newly registered hooks unmeasured.
# The chain runs sequentially here while Claude Code runs matching hooks in
# parallel, so the budget bounds total spawn cost, not wall-clock.
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
registered_chain() {
  jq -r --arg m "$1" '.hooks.PreToolUse[] | select(.matcher==$m) | .hooks[].command' "$SETTINGS" | sed 's#.*/##' | tr '\n' ' '
}
BASH_HOOKS=$(registered_chain Bash)
WRITE_HOOKS=$(registered_chain "Write|Edit")
[ -n "$BASH_HOOKS" ] && [ -n "$WRITE_HOOKS" ] || { echo "FAIL: could not read the PreToolUse chains from $SETTINGS" >&2; exit 1; }

# SessionStart chain (review round 1, Important finding 2): a separate
# helper, not a change to registered_chain above, so the two existing
# PreToolUse chains and their thresholds stay exactly as pinned. Reads the
# "" (default) matcher, the chain that runs on every session start
# including resume, where session-start.sh's B-8 drift check runs.
registered_chain_for_event() {
  jq -r --arg ev "$1" --arg m "$2" '.hooks[$ev][] | select(.matcher==$m) | .hooks[].command' "$SETTINGS" | sed 's#.*/##' | tr '\n' ' '
}
SESSION_START_HOOKS=$(registered_chain_for_event SessionStart "")
[ -n "$SESSION_START_HOOKS" ] || { echo "FAIL: could not read the SessionStart chain from $SETTINGS" >&2; exit 1; }

PAYLOAD_PLAIN='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
PAYLOAD_WRITE='{"tool_name":"Write","tool_input":{"file_path":"/x/src/services/format/formatDate.ts","content":"export function formatDate() {}"}}'

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

measure_control_ms() {
  local hook_count="$1"
  local started_ms
  started_ms=$(now_ms)
  for _ in $(seq $(( hook_count * ROUNDS ))); do
    printf '{}' | bash -c 'jq -r ".x // \"\"" >/dev/null' 2>/dev/null || true
  done
  echo $(( ($(now_ms) - started_ms) / ROUNDS ))
}

# $4 (home_override) and $5 (warm_up) are new and optional; both default to
# off, exactly the prior behavior for the two PreToolUse chains below.
# home_override: when set, each hook in the chain runs with that HOME
# instead of the ambient one, so a SessionStart chain can be measured
# against a sandboxed, realistic project directory rather than whatever
# happens to be under the real ~/.claude. warm_up: when "1", runs the chain
# once, untimed, before the timed rounds start. rounds_override: when set,
# times this many rounds instead of the shared $ROUNDS (control_ms still
# uses $ROUNDS internally; measure_control_ms already normalizes its own
# result to a per-round cost, so the two stay comparable regardless of how
# many rounds the chain itself is timed over).
#
# Both warm_up and rounds_override exist for one reason: a 6-hook chain
# whose hooks each do real work (git, ps, file hashing) has a warm per-round
# cost that sits close to BUDGET_FLOOR_MS by construction of the existing
# floor/multiplier formula, not because any one hook regressed. ROUNDS=3 is
# few enough samples that ordinary machine jitter plus one cold-cache first
# round made the new SessionStart:resume call flip pass/fail run to run.
# More, warmed rounds converge on the same true per-round cost with less
# noise; they do not raise the budget or change what is being measured. The
# two PreToolUse chains do not opt into either: they already pass
# consistently, and the review said to leave them and their thresholds
# alone.
assert_chain_under_budget() {
  local label="$1" hooks="$2" payload="$3" home_override="${4:-}" warm_up="${5:-0}" rounds_override="${6:-$ROUNDS}" floor_override="${7:-$BUDGET_FLOOR_MS}"
  local hook_count started_ms per_event_ms control_ms budget_ms hook
  hook_count=$(echo "$hooks" | wc -w | tr -d ' ')
  control_ms=$(measure_control_ms "$hook_count")
  budget_ms=$(( control_ms * BUDGET_MULTIPLIER ))
  [ "$budget_ms" -lt "$floor_override" ] && budget_ms=$floor_override
  if [ "$warm_up" = "1" ]; then
    for hook in $hooks; do
      if [ -n "$home_override" ]; then
        printf '%s' "$payload" | HOME="$home_override" bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
      else
        printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
      fi
    done
  fi
  started_ms=$(now_ms)
  for _ in $(seq "$rounds_override"); do
    for hook in $hooks; do
      if [ -n "$home_override" ]; then
        printf '%s' "$payload" | HOME="$home_override" bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
      else
        printf '%s' "$payload" | bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
      fi
    done
  done
  per_event_ms=$(( ($(now_ms) - started_ms) / rounds_override ))
  if [ "$per_event_ms" -gt "$budget_ms" ]; then
    echo "FAIL: $label chain took ${per_event_ms}ms per event vs a ${control_ms}ms bare-spawn control (budget ${budget_ms}ms). A per-edit hook has grown expensive; find it and move the heavy work to the push boundary." >&2
    exit 1
  fi
  echo "  $label: ${per_event_ms}ms per event (control ${control_ms}ms, budget ${budget_ms}ms)"
}

assert_chain_under_budget "PreToolUse:Bash" "$BASH_HOOKS" "$PAYLOAD_PLAIN"
assert_chain_under_budget "PreToolUse:Write" "$WRITE_HOOKS" "$PAYLOAD_WRITE"

# SessionStart:resume chain (review round 1, finding 2). Sandboxes HOME with
# a real git repo and a realistic ~10-file resume snapshot (B-8), so
# session-start.sh's check_resume_drift actually does its per-file work
# (one batched shasum call over every tracked file, not one spawn per file)
# rather than short-circuiting on an absent snapshot. Reuses the same
# dynamic, control-normalized formula as the two chains above
# (BUDGET_MULTIPLIER), but with its own floor (SESSION_START_BUDGET_FLOOR_MS,
# defined above with the measurement basis) since the shared BUDGET_FLOOR_MS
# flapped on this heavier, real-work chain.
SS_SANDBOX="$(mktemp -d)"
SS_REPO="$SS_SANDBOX/work-repo"
mkdir -p "$SS_REPO"
git -C "$SS_REPO" init -q
git -C "$SS_REPO" config user.email t@t
git -C "$SS_REPO" config user.name t
git -C "$SS_REPO" commit -q --allow-empty -m seed
SS_HEAD=$(git -C "$SS_REPO" rev-parse HEAD)

SS_KEY_DIR="$SS_SANDBOX/.claude/projects/latency-key"
mkdir -p "$SS_KEY_DIR"
SS_TRANSCRIPT="$SS_KEY_DIR/fake-session.jsonl"
printf '{}\n' > "$SS_TRANSCRIPT"

SS_FILES_JSON="{}"
for i in $(seq 1 10); do
  f="$SS_REPO/file$i.txt"
  printf 'content %s\n' "$i" > "$f"
  h="sha256:$(shasum -a 256 "$f" | awk '{print $1}')"
  SS_FILES_JSON=$(printf '%s' "$SS_FILES_JSON" | jq -c --arg k "$f" --arg v "$h" '. + {($k): $v}')
done

jq -n --argjson v 1 --arg head "$SS_HEAD" --argjson files "$SS_FILES_JSON" \
  '{snapshot_version: $v, git_head: $head, files: $files}' \
  > "$SS_KEY_DIR/session-snapshot.json"

PAYLOAD_SESSION_START_RESUME=$(jq -n --arg t "$SS_TRANSCRIPT" --arg c "$SS_REPO" '{source:"resume", transcript_path:$t, cwd:$c}')

assert_chain_under_budget "SessionStart:resume" "$SESSION_START_HOOKS" "$PAYLOAD_SESSION_START_RESUME" "$SS_SANDBOX" 1 8 "$SESSION_START_BUDGET_FLOOR_MS"

rm -rf "$SS_SANDBOX"

echo "hook-latency.test.sh PASS"
