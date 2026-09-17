#!/usr/bin/env bash
# llm-rule-judge.sh: on git push, ask a fast model to judge the outgoing diff
# against the semantic-tier rules in the manifest (those a linter cannot express).
# ASK (2026-09-05, human-in-the-loop) on a violation whose rule has severity
# "error" in the manifest AND confidence >= threshold: the human adjudicates a
# naming finding at push time instead of the model losing the push to a judge. Warn-severity rule violations are printed to stderr
# but do not block the push. Fails OPEN (allows the push, logs to stderr) if the
# key is unset or the judge errors / returns unparseable output: the deterministic
# gates remain the hard guarantee, and a flaky model must not block legitimate work.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

# The rule text, the judge prompt and the manifest are files this repo ships,
# so they are resolved beside the hook rather than through the live install: a
# hook run out of a checkout must judge against that checkout's rules.
CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENFORCE_DIR="$CLAUDE_DIR/enforce"
# shellcheck source=../enforce/resolve-outgoing-base.sh
source "$ENFORCE_DIR/resolve-outgoing-base.sh"

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`
# (2026-09-16 audit P2-1; the normalizer lives once in git-invocation.sh),
# then recover which repository the push names so that every query below
# runs against THAT repository (2026-09-18 audit, defect 4).
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), which is a silent
# fail-open for a guard.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  # The target is read from the UNSTRIPPED command, because stripping is
  # exactly what throws it away (2026-09-18 audit, defect 4).
  parse_git_target_options "$RAW_CMD" push
fi
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

# EGRESS NOTE (2026-07-31 security audit P1): when live, this hook sends the
# outgoing diff to api.anthropic.com under ANTHROPIC_API_KEY. Repos listed in
# exempt-repos.txt are excluded, same as the linter gates; the judge previously
# carried no exemption at all. Disclosure lives in README.md (Enforcement).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

DIFF=$(run_git_on_target diff --diff-filter=ACMR "$BASE"..HEAD -- '*.ts' '*.tsx' '*.py' '*.rb' '*.go' 2>/dev/null || true)
[ -z "$DIFF" ] && exit 0

# Input budget. max_tokens caps what the model writes, never what it reads, so
# an unbounded outgoing diff was an unbounded paid request and an unbounded
# wait at push time (2026-09-18 external audit, finding 9). A diff over the cap
# is truncated and the truncation is stated in the payload, so the judge knows
# it is reasoning about a prefix rather than silently treating it as the whole
# change. Raise the cap deliberately; do not remove it.
JUDGE_DIFF_MAX_BYTES="${CLAUDE_JUDGE_DIFF_MAX_BYTES:-200000}"
DIFF_BYTES=$(printf '%s' "$DIFF" | wc -c | tr -d ' ')
DIFF_TRUNCATED="false"
if [ "$DIFF_BYTES" -gt "$JUDGE_DIFF_MAX_BYTES" ]; then
  DIFF=$(printf '%s' "$DIFF" | head -c "$JUDGE_DIFF_MAX_BYTES")
  DIFF_TRUNCATED="true"
  echo "llm-rule-judge: diff is ${DIFF_BYTES} bytes, over the ${JUDGE_DIFF_MAX_BYTES}-byte input budget; judging the first ${JUDGE_DIFF_MAX_BYTES} bytes" >&2
fi

THRESH=0.8
MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"

if [ -n "${CLAUDE_JUDGE_CMD:-}" ]; then
  RESP=$("$CLAUDE_JUDGE_CMD")
else
  # Key resolution: env first, then every supported secret store (2026-08-01
  # judge activation; the store list joined 2026-09-18 after the PR #8 review).
  # A store keeps the key out of dotfiles, transcripts, and hook argv (R-102);
  # provision once, interactively so the value never touches a shell history:
  #   security add-generic-password -a "$USER" -s claude-judge-api-key -w
  #   secret-tool store --label='claude judge' service claude-judge-api-key
  #   pass insert claude-judge-api-key
  # The list has to match the one enforcement-guard-check.sh probes when it
  # decides whether the judge tier is live: while this path read the macOS
  # keychain alone, a Linux host with a secret-tool or pass entry cleared the
  # degraded-judge warning and still got a judge that fail-opened on every push.
  JUDGE_KEYCHAIN_SERVICE="${CLAUDE_JUDGE_KEYCHAIN_SERVICE:-claude-judge-api-key}"
  # read_judge_key_from_stores(): the key held by the first secret store that
  # has one, printed to stdout; exits non-zero when no store answers. Each probe
  # is guarded on its binary existing, because `security` is macOS-only and
  # secret-tool and pass are typically Linux.
  read_judge_key_from_stores() {
    local found=""
    if command -v security >/dev/null 2>&1; then
      found=$(security find-generic-password -s "$JUDGE_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
      [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    fi
    if command -v secret-tool >/dev/null 2>&1; then
      found=$(secret-tool lookup service "$JUDGE_KEYCHAIN_SERVICE" 2>/dev/null || true)
      [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    fi
    if command -v pass >/dev/null 2>&1; then
      found=$(pass show "$JUDGE_KEYCHAIN_SERVICE" 2>/dev/null | head -1 || true)
      [ -n "$found" ] && { printf '%s' "$found"; return 0; }
    fi
    return 1
  }
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    ANTHROPIC_API_KEY=$(read_judge_key_from_stores || true)
  fi
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "llm-rule-judge: no API key in env, the macOS keychain, secret-tool, or pass ($JUDGE_KEYCHAIN_SERVICE), skipping semantic gate" >&2
    exit 0
  fi
  RULE_IDS=$(jq -r '.rules[] | select(.tier=="llm-judge") | .id' "$MANIFEST")
  # Full rule blocks (norm + Spec) from the reference file; CLAUDE.md carries
  # only one-line norms since the 2026-07-29 restructure.
  RULETEXT=$(for r in $RULE_IDS; do
    awk -v id="$r" '
      index($0, id ": ") == 1 || index($0, id " [") == 1 { p = 1; print; next }
      p && (/^R-[0-9]/ || /^## /) { exit }
      p { print }
    ' "$CLAUDE_DIR/rulebook/reference.md" || true
  done)
  SYS=$(cat "$ENFORCE_DIR/judge-prompt.md")
  USERMSG=$(jq -n --arg rt "$RULETEXT" --arg d "$DIFF" --arg tr "$DIFF_TRUNCATED" \
    '{rules:$rt, diff:$d, diff_truncated:($tr == "true")} | tostring')
  BODY=$(jq -n --arg s "$SYS" --arg u "$USERMSG" '{model:"claude-haiku-4-5-20251001",max_tokens:1024,temperature:0,system:$s,messages:[{role:"user",content:$u}]}')
  # A push-time gate must not be able to hang a push indefinitely: the request
  # carries its own connect and total timeouts rather than relying on whatever
  # outer bound the calling framework happens to impose (external audit,
  # finding 9). A timeout lands on the same path as any other request failure,
  # which this hook's documented policy already covers.
  JUDGE_TIMEOUT_SECONDS="${CLAUDE_JUDGE_TIMEOUT_SECONDS:-60}"
  JUDGE_START_MS=$(date +%s000)
  RAW=$(curl -sS --connect-timeout 10 --max-time "$JUDGE_TIMEOUT_SECONDS" https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d "$BODY" 2>/dev/null || true)
  # Usage and latency are recorded so the cost of this tier is measurable
  # rather than assumed; the log carries no diff content, only counts.
  JUDGE_USAGE=$(printf '%s' "$RAW" | jq -c '.usage // {}' 2>/dev/null || printf '{}')
  JUDGE_ELAPSED_MS=$(( $(date +%s000) - JUDGE_START_MS ))
  JUDGE_USAGE_LOG="${CLAUDE_JUDGE_USAGE_LOG:-$HOME/.claude/global-memory/judge_usage.log}"
  if [ -d "$(dirname "$JUDGE_USAGE_LOG")" ]; then
    printf '%s\tusage=%s\telapsed_ms=%s\tdiff_bytes=%s\ttruncated=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JUDGE_USAGE" "$JUDGE_ELAPSED_MS" "$DIFF_BYTES" "$DIFF_TRUNCATED" \
      >> "$JUDGE_USAGE_LOG" 2>/dev/null || true
  fi
  TEXT=$(printf '%s' "$RAW" | jq -r '.content[0].text // ""' 2>/dev/null || true)
  # Extract the first balanced-brace JSON object; Haiku may append trailing prose after the
  # closing fence, which would survive a simple sed strip and break jq.
  RESP=$(printf '%s' "$TEXT" | awk '
    BEGIN { depth=0; buf=""; capturing=0 }
    {
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        c = chars[i]
        if (!capturing && c == "{") { capturing = 1 }
        if (capturing) {
          buf = buf c
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth == 0) { print buf; exit } }
        }
      }
      if (capturing) buf = buf "\n"
    }
  ')
fi

# Partition violations: those with confidence >= threshold get checked against manifest severity.
# Only "error"-severity rules produce a deny; "warn"-severity rules print to stderr.
ALL_HITS=$(printf '%s' "$RESP" | jq -c --argjson t "$THRESH" '[.violations[]? | select(.confidence >= $t)]' 2>/dev/null || echo '[]')

ASK_HITS='[]'
while IFS= read -r violation; do
  rule_id=$(printf '%s' "$violation" | jq -r '.rule // ""')
  # A rule id can carry several manifest rows across tiers (R-324/R-329 have
  # eslint+ruff+golangci entries); take the llm-judge row's severity, falling
  # back to the strictest row for the id (2026-07-31 criticism audit P1: the
  # unfiltered multi-line result never equaled "error", silently downgrading
  # every judged rule to warn).
  severity=$(jq -r --arg id "$rule_id" '
    [.rules[] | select(.id==$id)] as $rows
    | ([$rows[] | select(.tier=="llm-judge")] | first // ($rows | first))
    | .severity // "error"' "$MANIFEST" 2>/dev/null || echo "error")
  [ -z "$severity" ] && severity="error"
  if [ "$severity" = "error" ]; then
    ASK_HITS=$(printf '%s\n%s' "$ASK_HITS" "$violation" | jq -cs '.[0] + [.[1:][]]' 2>/dev/null || echo "$ASK_HITS")
  else
    why=$(printf '%s' "$violation" | jq -r '"[warn] \(.rule) [\(.file)]: \(.why)"')
    echo "llm-rule-judge: $why" >&2
  fi
done < <(printf '%s' "$ALL_HITS" | jq -c '.[]?' 2>/dev/null || true)

COUNT=$(printf '%s' "$ASK_HITS" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  while IFS= read -r fired_rule; do
    [ -n "$fired_rule" ] && log_rule_fire "$fired_rule" "llm-rule-judge" "ask"
  done < <(printf '%s' "$ASK_HITS" | jq -r '.[].rule' 2>/dev/null || true)
  REASON=$(printf '%s' "$ASK_HITS" | jq -r '.[] | "\(.rule) [\(.file)]: \(.why)"')
  jq -n --arg r "Rule-judge findings on the outgoing diff (confidence >= $THRESH); approve the push only if each is a false positive:
$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
