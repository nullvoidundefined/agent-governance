#!/usr/bin/env bash
# Verifies status-line.sh (hardening spec B-5): renders the HUD line from the
# documented statusLine stdin JSON, degrades every missing field to a
# placeholder, and exits 0 on every path including broken input. Hermetic:
# fabricated payloads and a mktemp git repo for the branch field.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$SCRIPT_DIR/../../status-line.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
rendersAllFields() { # payload-json, expected-grep
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE "$2" <<<"$out"
}
exitsZeroOnGarbage() { printf '%s' "$1" | bash "$SL" >/dev/null 2>&1; }
modelSurvivesMalformedField() { # payload-json, expected-placeholder-grep
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE '^keepme \|' <<<"$out" && grep -qE "$2" <<<"$out"
}
allNumericFieldsDegradeIndividually() { # payload-json
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE '^keepme \|' <<<"$out" && grep -qE 'ctx - ' <<<"$out" \
    && grep -qE '\$- ' <<<"$out" && grep -qE '5h -%' <<<"$out"
}

REPO=$(mktemp -d); trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q -b probe-branch
FULL=$(jq -n --arg cwd "$REPO" '{model:{display_name:"opusplan"},context_window:{used_percentage:42.7},cwd:$cwd,cost:{total_cost_usd:1.2345,total_duration_ms:5400000},rate_limits:{five_hour:{used_percentage:12}}}')
check "full payload renders model" rendersAllFields "$FULL" '^opusplan \|'
check "full payload renders branch" rendersAllFields "$FULL" 'probe-branch'
check "full payload renders ctx percent" rendersAllFields "$FULL" 'ctx 43%'
check "full payload renders cost" rendersAllFields "$FULL" '\$1\.23'
check "full payload renders elapsed" rendersAllFields "$FULL" '1h30m'
check "full payload renders rate limit" rendersAllFields "$FULL" '5h 12%'
: >"$REPO/dirty-file"
check "dirty repo shows the marker" rendersAllFields "$FULL" 'probe-branch\*'
NULLS='{"model":{"display_name":"opusplan"},"context_window":{"used_percentage":null},"cwd":"/nonexistent-dir","cost":{"total_cost_usd":null,"total_duration_ms":0}}'
# Anchored on the payload's model name ("opusplan") at line start (review
# round 1, Minor finding): the bare fallback line ("claude | - | ctx - | $- |
# - | 5h -%") also matches "ctx - ", "$- ", and "| - |" as plain substrings,
# so an un-anchored regex here cannot tell a correctly degraded field apart
# from a regression that collapses the whole line to emit_fallback.
# Anchoring on "^opusplan \|" requires the real per-field degradation path,
# since the fallback line always starts with the literal "claude", never the
# payload's model name.
check "null ctx degrades to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*ctx - '
check "null cost degrades to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*\$- '
check "no-repo cwd degrades branch to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*\| - \|'
check "garbage input still exits 0" exitsZeroOnGarbage 'not json at all'
check "garbage input prints a fallback line" rendersAllFields 'not json at all' 'claude'
check "empty input still exits 0" exitsZeroOnGarbage ''

# Regression (review round 1): a non-numeric value in one numeric field must
# not collapse the whole line to emit_fallback; only that field degrades.
COST_MALFORMED='{"model":{"display_name":"keepme"},"cost":{"total_cost_usd":"not-a-number"}}'
CTX_MALFORMED='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":"not-a-number"}}'
RATE_MALFORMED='{"model":{"display_name":"keepme"},"rate_limits":{"five_hour":{"used_percentage":"not-a-number"}}}'
ALL_MALFORMED='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":"nope"},"cost":{"total_cost_usd":"nope"},"rate_limits":{"five_hour":{"used_percentage":"nope"}}}'
CTX_INFINITE='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":1e400}}'
check "malformed cost degrades alone, model survives" modelSurvivesMalformedField "$COST_MALFORMED" '\$- '
check "malformed ctx degrades alone, model survives" modelSurvivesMalformedField "$CTX_MALFORMED" 'ctx - '
check "malformed rate degrades alone, model survives" modelSurvivesMalformedField "$RATE_MALFORMED" '5h -%'
check "all malformed numeric fields degrade individually, model survives" allNumericFieldsDegradeIndividually "$ALL_MALFORMED"
check "infinite ctx normalizes to placeholder, model survives" modelSurvivesMalformedField "$CTX_INFINITE" 'ctx - '

[ "$fail" -eq 0 ] && echo "status-line.test.sh PASS" || exit 1
