#!/usr/bin/env bash
# judge-diff.sh: the CI rule judge for the llm-judge tier rules in
# manifest.json (R-315, R-316, R-317, R-325, R-334), the semantic rules no
# linter can express. Asks a fast model to judge the diff between two refs.
# Exit 1 on an error-severity finding at or above the confidence threshold,
# printing one "<rule> [<file>]: <why>" line each on stdout; warn-severity
# findings go to stderr (as ::warning:: annotations under GitHub Actions).
# Fails open, exit 0 with a notice, when no API key is available or the model
# reply does not parse: the deterministic gates remain the hard guarantee.
# Moved off the local push path into .github/workflows/rule-judge.yml on
# 2026-09-18 (IAN-98), because the push-time hook averaged 171 s per push.
# EGRESS: sends the diff to api.anthropic.com under ANTHROPIC_API_KEY.
#
# Usage: judge-diff.sh <base-ref> [<head-ref>], run inside the target repo.
# set -uo, no -e, as in every guard here: an unexpected internal error must
# reach a decision rather than kill the script (enforce/README.md).
set -uo pipefail
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$ENFORCE_DIR/.." && pwd)"
BASE="${1:-}"
HEAD_REF="${2:-HEAD}"
[ -n "$BASE" ] || { echo "usage: judge-diff.sh <base-ref> [<head-ref>]" >&2; exit 2; }

# run_git_on_target <git arguments...>
# Runs git in the current repository. Kept under the push hook's name so the
# moved vocabulary collector and diff read unchanged.
run_git_on_target() { git "$@"; }


# collect_project_vocabulary
# Prints the `## Domain vocabulary` sections of the target repository's design
# specs (R-330), one after another, capped so the payload stays bounded the way
# the diff is. Takes no arguments. Prints nothing and returns 0 when the
# repository has no such section, which is the signal to stop judging R-334.
collect_project_vocabulary() {
  local root spec_file collected
  root=$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$root" ] || return 0
  collected=""
  for spec_file in "$root"/docs/superpowers/specs/*-design.md "$root"/claude/docs/superpowers/specs/*-design.md; do
    [ -f "$spec_file" ] || continue
    collected="$collected$(awk '
      /^## Domain vocabulary/ { p = 1; print; next }
      p && /^## / { exit }
      p { print }
    ' "$spec_file")"
  done
  printf '%s' "$collected" | head -c "${CLAUDE_JUDGE_VOCAB_MAX_BYTES:-20000}"
}

# Source extensions the naming and structure rules actually govern. `.js`,
# The exclusions carry `glob` magic deliberately. Without it, `**/dist/**`
# matches a nested `apps/web/dist/x.ts` and NOT a top-level `dist/x.ts`, so
# generated output at the repository root was judged while the same output one
# directory down was skipped, which is worse than no exclusion because it is
# inconsistent and silent. The fixtures below pin both depths.
#
# Excluding generated output is a correctness rule, not a cost saving: the fix
# for a name in a generated file is never in that file, it is in the source the
# generator read, which the judge already sees. Do not prune this list to make
# the payload smaller; raise the exclusions or narrow the change instead.
#
# `.mjs`, and `.vue` were added 2026-09-18 with R-334: migrations in the
# node-pg-migrate projects are JavaScript and components in the Vue track are
# `.vue`, so table names and component names, the two layers R-334 is most
# about, were bypassing this gate entirely. Generated trees are excluded
# because a judge reporting a naming defect in build output wastes the push
# it interrupts.
DIFF=$(run_git_on_target diff --diff-filter=ACMR "$BASE".."$HEAD_REF" -- \
  '*.ts' '*.tsx' '*.js' '*.mjs' '*.vue' '*.py' '*.rb' '*.go' \
  ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/dist/**' ':(exclude,glob)**/build/**' \
  ':(exclude,glob)**/.output/**' ':(exclude,glob)**/*.gen.*' ':(exclude,glob)**/*.min.js' 2>/dev/null || true)
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
MANIFEST="${CLAUDE_MANIFEST_FILE:-$ENFORCE_DIR/manifest.json}"

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
    NOTICE_PREFIX=""
    [ "${GITHUB_ACTIONS:-}" = "true" ] && NOTICE_PREFIX="::notice::"
    echo "${NOTICE_PREFIX}llm-rule-judge: no API key in env, the macOS keychain, secret-tool, or pass ($JUDGE_KEYCHAIN_SERVICE), skipping semantic gate" >&2
    exit 0
  fi
  RULE_IDS=$(jq -r '.rules[] | select(.tier=="llm-judge") | .id' "$MANIFEST")

  # R-334 judges a name against the aggregate roots its project settled, and
  # this payload otherwise carries only rulebook text and the diff. Without the
  # project's own glossary the judge would have to invent a root list, so the
  # glossary is collected here and R-334 is dropped from the judged set when a
  # repository has none. A rule that cannot be decided is not judged.
  PROJECT_VOCABULARY=$(collect_project_vocabulary)
  if [ -z "$PROJECT_VOCABULARY" ]; then
    RULE_IDS=$(printf '%s\n' "$RULE_IDS" | grep -v '^R-334$' || true)
  fi
  [ -n "$RULE_IDS" ] || exit 0
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
  USERMSG=$(jq -n --arg rt "$RULETEXT" --arg d "$DIFF" --arg tr "$DIFF_TRUNCATED" --arg pv "$PROJECT_VOCABULARY" \
    '{rules:$rt, diff:$d, diff_truncated:($tr == "true"), project_vocabulary:$pv} | tostring')
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
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::warning::llm-rule-judge: $why" >&2
    else
      echo "llm-rule-judge: $why" >&2
    fi
  fi
done < <(printf '%s' "$ALL_HITS" | jq -c '.[]?' 2>/dev/null || true)


COUNT=$(printf '%s' "$ASK_HITS" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  printf '%s' "$ASK_HITS" | jq -r '.[] | "\(.rule) [\(.file)]: \(.why)"'
  exit 1
fi
exit 0
